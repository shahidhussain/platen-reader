import AppKit
import Combine
import PlatenCore
import SwiftUI
import WebKit
import os

private let log = Logger(subsystem: "Platen Reader", category: "reader")

/// The reader for one book: a web view running foliate-js, the overlay, the
/// open-progress indicator and the failure message.
///
/// Opening runs two things in parallel and joins them:
/// 1. the web view loads the reader shell (usually already warm), and
/// 2. the book file is read and checked on a background queue.
/// When both are ready, the book is handed to the shell.
final class ReaderViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate, NSMenuItemValidation {
    private let document: BookDocument
    private let schemeHandler = ReaderSchemeHandler()
    private let settings = ReaderSettings.shared
    let state = ReaderState()

    private var webView: ReaderWebView!
    private var overlayHost: NSHostingView<OverlayBar>!
    private var spinner: NSProgressIndicator!
    private var failureHost: NSView?

    private var book: Book?
    private var record: BookRecord?
    private var shellReady = false
    private var bookSentToShell = false
    private var hasRendered = false
    private var openStarted = CFAbsoluteTimeGetCurrent()

    private var overlayVisible = false
    private var titleBarVisible = false
    private var hideTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?

    /// The book's own title, once known (used for the window title).
    var bookTitle: String? { state.title.isEmpty ? nil : state.title }

    init(document: BookDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - View setup

    override func loadView() {
        let root = ReaderRootView()
        root.onMouseMoved = { [weak self] point in self?.mouseMoved(to: point) }
        root.wantsLayer = true

        // Web view
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: ReaderSchemeHandler.scheme)
        config.userContentController.add(WeakScriptMessageHandler(self), name: "platen")
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.isTextInteractionEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true // the shell's own scripts

        webView = ReaderWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground") // the page draws the theme colour
        webView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)

        // Overlay (bottom bar). Starts hidden.
        let actions = OverlayActions(
            previousPage: { [weak self] in self?.js("platen.prev()") },
            nextPage: { [weak self] in self?.js("platen.next()") },
            goToFraction: { [weak self] f in self?.js("platen.goToFraction(\(f))") },
            setFlow: { [weak self] flow in self?.setFlow(flow) },
            setTheme: { [weak self] theme in
                guard let self else { return }
                self.settings.setTheme(theme, for: self.view.effectiveAppearance)
            },
            currentTheme: { [weak self] in self?.currentTheme ?? .light },
            interacted: { [weak self] in self?.restartHideTimer() }
        )
        overlayHost = NSHostingView(rootView: OverlayBar(state: state, actions: actions))
        overlayHost.translatesAutoresizingMaskIntoConstraints = false
        overlayHost.alphaValue = 0
        overlayHost.isHidden = true
        root.addSubview(overlayHost)

        // Quiet progress indicator, shown only if opening takes > 500 ms.
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            overlayHost.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            overlayHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            overlayHost.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            overlayHost.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            overlayHost.widthAnchor.constraint(equalToConstant: 720).withPriority(.defaultHigh),

            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.flow = settings.defaultFlow

        // Re-style whenever a global setting changes (in any window).
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.pushSettings() }
            .store(in: &cancellables)

        RemoteContentBlocker.load { [weak self] list in
            guard let self else { return }
            if let list { self.webView.configuration.userContentController.add(list) }
            self.webView.load(URLRequest(url: ReaderSchemeHandler.shellURL))
        }
        loadBook()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.hasRendered, self.failureHost == nil else { return }
            self.spinner.startAnimation(nil)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(webView)
        applyChromeVisibility(animated: false)
        applyWindowTheme()
        // Follow the system's light/dark switch (including Auto at sunset).
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.pushSettings() }
        }
    }

    // MARK: - Opening

    private func loadBook() {
        guard let url = document.fileURL else { return }
        openStarted = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Book.open(url: url, coordinated: true) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let book):
                    let elapsed = (CFAbsoluteTimeGetCurrent() - self.openStarted) * 1000
                    log.info("Read \(url.lastPathComponent, privacy: .public) in \(elapsed, format: .fixed(precision: 0)) ms")
                    for warning in book.warnings { log.notice("\(warning, privacy: .public)") }
                    if book.isRepaired { log.notice("Opened a damaged book using a rebuilt package") }
                    self.book = book
                    self.schemeHandler.book = book
                    self.state.title = book.title ?? ""
                    self.state.isFixedLayout = book.isFixedLayout
                    self.loadRecord(for: book, url: url)
                    self.sendBookIfReady()
                case .failure(let error):
                    self.showFailure(error)
                }
            }
        }
    }

    private func loadRecord(for book: Book, url: URL) {
        var record = PositionStore.shared.load(key: book.key)
            ?? BookRecord(key: book.key, uniqueIdentifier: book.package?.uniqueIdentifier, fingerprint: book.fingerprint)
        record.lastKnownPath = url.path
        record.lastOpened = Date()
        self.record = record
        if book.isFixedLayout {
            state.flow = .paginated
        } else if let mode = record.readingMode.flatMap(ReadingFlow.init) {
            state.flow = mode
        }
    }

    private func sendBookIfReady() {
        guard shellReady, let book, !bookSentToShell else { return }
        bookSentToShell = true
        var options: [String: Any] = [
            "format": book.format.rawValue,
            "settings": settings.webPayload(theme: currentTheme, flow: state.flow),
        ]
        if book.format == .epub {
            options["sizes"] = book.entrySizes.mapValues { Int(clamping: $0) }
        }
        if let cfi = record?.lastCFI { options["lastCFI"] = cfi }
        webView.callAsyncJavaScript("platen.open(options)", arguments: ["options": options], in: nil, in: .page) { result in
            if case .failure(let error) = result { log.error("open failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func showFailure(_ error: Error) {
        log.error("Could not open \(self.document.fileURL?.lastPathComponent ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
        spinner.stopAnimation(nil)
        webView.isHidden = true
        let title: String
        let detail: String?
        if let error = error as? LocalizedError {
            title = error.errorDescription ?? error.localizedDescription
            detail = error.recoverySuggestion
        } else {
            title = String(localized: "This book could not be opened.")
            detail = error.localizedDescription
        }
        let host = NSHostingView(rootView: OpenFailureView(title: title, detail: detail))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        failureHost = host
        #if DEBUG
        DebugHooks.snapshotView(view, name: document.fileURL?.deletingPathExtension().lastPathComponent ?? "book")
        #endif
        // With no page to read, show the title bar so the window can be closed.
        titleBarVisible = true
        applyChromeVisibility(animated: false)
    }

    // MARK: - Messages from JavaScript

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            shellReady = true
            sendBookIfReady()

        case "firstRender":
            hasRendered = true
            spinner.stopAnimation(nil)
            let elapsed = (CFAbsoluteTimeGetCurrent() - openStarted) * 1000
            log.info("First page visible after \(elapsed, format: .fixed(precision: 0)) ms")
            #if DEBUG
            DebugHooks.afterFirstRender(webView: webView, bookName: document.fileURL?.deletingPathExtension().lastPathComponent ?? "book") { [weak self] script in
                self?.webView.evaluateJavaScript(script, completionHandler: nil)
            }
            #endif

        case "opened":
            if let title = body["title"] as? String, !title.isEmpty { state.title = title }
            state.author = body["author"] as? String ?? ""
            state.isFixedLayout = body["fixedLayout"] as? Bool ?? false
            state.isRightToLeft = (body["dir"] as? String) == "rtl"
            state.sectionFractions = (body["sectionFractions"] as? [NSNumber])?.map(\.doubleValue) ?? []
            state.toc = ((body["toc"] as? [[String: Any]]) ?? []).enumerated().map { index, item in
                ReaderState.TOCItem(id: index, label: item["label"] as? String ?? "",
                                    href: item["href"] as? String ?? "", depth: item["depth"] as? Int ?? 0)
            }
            view.window?.windowController?.synchronizeWindowTitleWithDocumentName()
            showFirstRunExplainerIfNeeded()

        case "relocate":
            state.fraction = (body["fraction"] as? NSNumber)?.doubleValue ?? state.fraction
            state.chapter = body["chapter"] as? String ?? ""
            state.printedPage = body["page"] as? String
            view.window?.subtitle = state.chapter
            if let cfi = body["cfi"] as? String, var record {
                record.lastCFI = cfi
                record.readingMode = state.flow.rawValue
                self.record = record
                PositionStore.shared.scheduleSave(record) // debounced
            }

        case "click":
            handleClick(zone: body["zone"] as? String ?? "centre")

        case "externalLink":
            // Links to the web open in the user's browser, never in the reader.
            if let href = body["href"] as? String, let url = URL(string: href),
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }

        case "error":
            log.error("reader error: \(body["message"] as? String ?? "", privacy: .public)\n\(body["stack"] as? String ?? "", privacy: .public)")
            showFailure(BookOpenError.unreadable(body["message"] as? String ?? ""))

        case "log":
            log.notice("js: \(body["message"] as? String ?? "", privacy: .public)")

        default:
            break
        }
    }

    // MARK: - Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the shell and its blob: iframes may load. Anything else (a book
        // trying to navigate the window) is refused.
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        if ["platen", "blob", "about", "data"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // If WebKit's content process crashes, reload and reopen at the last
        // saved position rather than leaving a blank window.
        log.error("Web content process terminated; reloading")
        shellReady = false
        bookSentToShell = false
        webView.load(URLRequest(url: ReaderSchemeHandler.shellURL))
    }

    // MARK: - Input

    /// Click zones: in paginated mode the left third goes back, the right
    /// third forward and the centre toggles the overlay. In scroll mode any
    /// click toggles the overlay.
    private func handleClick(zone: String) {
        if state.flow == .scrolled || zone == "centre" {
            setOverlay(visible: !overlayVisible)
        } else if zone == "left" {
            js("platen.goLeft()")
        } else {
            js("platen.goRight()")
        }
    }

    /// Keys that are not menu shortcuts. Returns true if handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: // space
            js(shift ? "platen.prev()" : "platen.next()")
        case 121: js("platen.next()") // page down
        case 116: js("platen.prev()") // page up
        case 123: previousPageLeft(nil) // ←
        case 124: nextPageRight(nil) // →
        case 125: js(state.flow == .scrolled ? "platen.scrollLines(1)" : "platen.next()") // ↓
        case 126: js(state.flow == .scrolled ? "platen.scrollLines(-1)" : "platen.prev()") // ↑
        case 53: // Esc: hide the overlay; exit full screen if it is already hidden
            if overlayVisible {
                setOverlay(visible: false)
            } else if view.window?.styleMask.contains(.fullScreen) == true {
                view.window?.toggleFullScreen(nil)
            } else {
                return false
            }
        default:
            return false
        }
        return true
    }

    private func mouseMoved(to point: NSPoint) {
        // Reveal the title bar when the pointer reaches the top edge.
        let nearTop = point.y > view.bounds.height - 36
        if nearTop != titleBarVisible && !overlayVisible {
            titleBarVisible = nearTop
            applyChromeVisibility(animated: true)
        }
        if overlayVisible { restartHideTimer() }
    }

    // MARK: - Overlay and chrome

    private func setOverlay(visible: Bool) {
        overlayVisible = visible
        titleBarVisible = visible
        applyChromeVisibility(animated: true)
        if visible { restartHideTimer() } else { hideTimer?.invalidate() }
    }

    /// Hide the overlay after 4 s without pointer movement, unless the
    /// pointer is over it (it is being used).
    private func restartHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, self.overlayVisible else { return }
            if let window = self.view.window {
                let point = self.overlayHost.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.overlayHost.bounds.contains(point) { return self.restartHideTimer() }
            }
            self.setOverlay(visible: false)
        }
    }

    private func applyChromeVisibility(animated: Bool) {
        guard let window = view.window else { return }
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0
        // The title bar container holds the window buttons, title and its
        // background. Fading it (rather than hiding it) keeps the top edge
        // draggable.
        let titleBar = window.standardWindowButton(.closeButton)?.superview?.superview
        window.titleVisibility = titleBarVisible ? .visible : .hidden
        window.titlebarAppearsTransparent = !titleBarVisible
        if overlayVisible { overlayHost.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            titleBar?.animator().alphaValue = titleBarVisible || window.styleMask.contains(.fullScreen) ? 1 : 0
            overlayHost.animator().alphaValue = overlayVisible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Hidden views take no clicks, so the page underneath gets them.
            self.overlayHost.isHidden = !self.overlayVisible
        })
        // Keep VoiceOver from landing on invisible controls.
        overlayHost.setAccessibilityElement(overlayVisible)
    }

    func fullScreenChanged() {
        applyChromeVisibility(animated: false)
    }

    // MARK: - Settings and theme

    private var currentTheme: Theme {
        settings.theme(for: view.effectiveAppearance)
    }

    private func pushSettings() {
        applyWindowTheme()
        guard bookSentToShell else { return }
        let payload = settings.webPayload(theme: currentTheme, flow: state.flow)
        webView.callAsyncJavaScript("platen.setSettings(s)", arguments: ["s": payload], in: nil, in: .page, completionHandler: nil)
    }

    private func applyWindowTheme() {
        let theme = currentTheme
        view.window?.backgroundColor = theme.nsBackground
        // Chrome and the overlay follow the page's lightness.
        view.window?.appearance = theme.appearance
    }

    private func setFlow(_ flow: ReadingFlow) {
        guard !state.isFixedLayout, flow != state.flow else { return }
        state.flow = flow
        pushSettings()
        // M1: flash the click-zone explainer for the first three switches.
    }

    // MARK: - First-run explainer (placeholder until M1's zone overlay)

    private func showFirstRunExplainerIfNeeded() {
        // M1: draw the "Back / Show controls / Forward" zones over the page.
        // For the spike, briefly show the overlay so its existence is obvious.
        let key = "hasSeenReadingControls"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setOverlay(visible: true)
    }

    // MARK: - Saving

    func savePositionNow() {
        guard var record else { return }
        record.readingMode = state.flow.rawValue
        PositionStore.shared.saveNow(record)
    }

    // MARK: - Helpers

    private func js(_ script: String) {
        guard bookSentToShell else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Menu actions (found through the responder chain)

    @objc func previousPageLeft(_ sender: Any?) { js("platen.goLeft()") }
    @objc func nextPageRight(_ sender: Any?) { js("platen.goRight()") }
    @objc func previousChapter(_ sender: Any?) { js("platen.prevSection()") }
    @objc func nextChapter(_ sender: Any?) { js("platen.nextSection()") }
    @objc func goBackInHistory(_ sender: Any?) { js("platen.back()") }
    @objc func showPaginated(_ sender: Any?) { setFlow(.paginated) }
    @objc func showScroll(_ sender: Any?) { setFlow(.scrolled) }
    @objc func makeTextBigger(_ sender: Any?) { settings.biggerText() }
    @objc func makeTextSmaller(_ sender: Any?) { settings.smallerText() }
    @objc func makeTextDefaultSize(_ sender: Any?) { settings.defaultTextSize() }
    @objc func toggleReaderControls(_ sender: Any?) { setOverlay(visible: !overlayVisible) }

    @objc func setPageLayout(_ sender: NSMenuItem) {
        if let layout = (sender.representedObject as? String).flatMap(PageLayout.init) { settings.pageLayout = layout }
    }

    @objc func setThemeFromMenu(_ sender: NSMenuItem) {
        if let theme = (sender.representedObject as? String).flatMap(Theme.init) {
            settings.setTheme(theme, for: view.effectiveAppearance)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let ready = book != nil && failureHost == nil
        switch item.action {
        case #selector(showPaginated(_:)):
            item.state = state.flow == .paginated ? .on : .off
            return ready
        case #selector(showScroll(_:)):
            item.state = state.flow == .scrolled ? .on : .off
            item.toolTip = state.isFixedLayout ? String(localized: "Fixed-layout books are always paginated.") : nil
            return ready && !state.isFixedLayout
        case #selector(setPageLayout(_:)):
            item.state = (item.representedObject as? String) == settings.pageLayout.rawValue ? .on : .off
            return ready && state.flow == .paginated && !state.isFixedLayout
        case #selector(setThemeFromMenu(_:)):
            item.state = (item.representedObject as? String) == currentTheme.rawValue ? .on : .off
            return true
        case #selector(makeTextBigger(_:)):
            return !state.isFixedLayout && settings.fontSizeIndex < ReaderSettings.fontSizes.count - 1
        case #selector(makeTextSmaller(_:)):
            return !state.isFixedLayout && settings.fontSizeIndex > 0
        case #selector(makeTextDefaultSize(_:)):
            return !state.isFixedLayout
        case #selector(toggleReaderControls(_:)):
            item.title = overlayVisible ? String(localized: "Hide Controls") : String(localized: "Show Controls")
            return ready
        default:
            return ready
        }
    }
}

// MARK: - Supporting views

/// The root view: tracks the pointer so the title bar can be revealed at the
/// top edge and the overlay kept alive while the pointer moves.
final class ReaderRootView: NSView {
    var onMouseMoved: ((NSPoint) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }
}

/// A WKWebView that lets the reader handle page-turn keys before WebKit
/// (which would otherwise try to scroll the shell page).
final class ReaderWebView: WKWebView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
