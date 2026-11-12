import AppKit
import Combine
import PlatenCore
import SwiftUI
import WebKit
import os

/// The reader for one book: a web view running foliate-js, the overlay, the
/// open-progress indicator and the failure message.
///
/// Opening runs two things in parallel and joins them:
/// 1. the web view loads the reader shell (usually already warm), and
/// 2. the book file is read and checked on a background queue.
/// When both are ready, the book is handed to the shell.
final class ReaderViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate, NSMenuItemValidation {
    let document: BookDocument
    let schemeHandler = ReaderSchemeHandler()
    let settings = ReaderSettings.shared
    let state = ReaderState()

    var webView: ReaderWebView!
    /// What VoiceOver reads: the text on screen (see BookPageAccessibilityView).
    let bookPage = BookPageAccessibilityView()
    var overlayHost: NSHostingView<OverlayBar>!
    var explainerHost: NSView?
    /// Backing for the title when it is shown, drawn by us so the real title
    /// bar can stay transparent (see `applyChromeVisibility`).
    var titleBacking: PassThroughEffectView!
    var titleBackingHeight: NSLayoutConstraint!
    var imageZoom: ImageZoomView?
    /// The strip under the (transparent) title bar that drags the window.
    var dragStrip: WindowDragView!
    var scrollMonitor: Any?
    var keyMonitor: Any?
    var swipe = SwipeTracker()
    var pageTurn: PageTurnView?
    /// Counts turns, so a turn that was overtaken by a newer one is dropped.
    var turnGeneration = 0
    /// When the last page turn was asked for, to spot rapid key presses.
    var lastTurnRequest: TimeInterval = 0
    var spinner: NSProgressIndicator!
    var failureHost: NSView?

    var book: Book?
    var record: BookRecord?
    var shellReady = false
    var bookSentToShell = false
    var hasRendered = false
    var openStarted = CFAbsoluteTimeGetCurrent()


    var overlayVisible = false
    var titleBarVisible = false
    var hideTimer: Timer?
    var cancellables: Set<AnyCancellable> = []
    var appearanceObservation: NSKeyValueObservation?
    var voiceOverObservation: NSKeyValueObservation?

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
        webView.menuCustomiser = { [weak self] menu in self?.customiseContextMenu(menu) }
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)

        // VoiceOver reads the book through this stand-in, not the web view.
        bookPage.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bookPage)
        root.hiddenFromAccessibility = webView
        webView.accessibilityStandIn = bookPage

        // Contents, bookmarks and search: a popover from the overlay's
        // Contents button.
        let sidebarActions = ContentsActions(
            // Choosing a chapter or bookmark closes the popover; search
            // results keep it open so the reader can step through them.
            goToTOCItem: { [weak self] item in self?.jump(to: item.href); self?.setSidebar(visible: false) },
            goToBookmark: { [weak self] bookmark in self?.jump(to: bookmark.cfi); self?.setSidebar(visible: false) },
            removeBookmark: { [weak self] bookmark in self?.removeBookmark(cfi: bookmark.cfi) },
            search: { [weak self] query in self?.startSearch(query) },
            goToHit: { [weak self] hit in self?.goToHit(hit) },
            close: { [weak self] in self?.setSidebar(visible: false) }
        )

        // Overlay (bottom bar). Starts hidden.
        let actions = OverlayActions(
            previousPage: { [weak self] in self?.turn(.prev) },
            nextPage: { [weak self] in self?.turn(.next) },
            goToFraction: { [weak self] f in self?.callPlaten("jumpToFraction", f) },
            goBack: { [weak self] in self?.goBackInHistory(nil) },
            toggleContents: { [weak self] in self?.toggleContents(nil) },
            setLayout: { [weak self] layout in self?.setLayout(layout) },
            toggleBookmark: { [weak self] in self?.toggleBookmark(nil) },
            interacted: { [weak self] in self?.restartHideTimer() }
        )
        overlayHost = NSHostingView(rootView: OverlayBar(state: state, actions: actions, sidebarActions: sidebarActions))
        overlayHost.translatesAutoresizingMaskIntoConstraints = false
        overlayHost.alphaValue = 0
        overlayHost.isHidden = true
        root.addSubview(overlayHost)

        titleBacking = PassThroughEffectView()
        titleBacking.material = .titlebar
        titleBacking.blendingMode = .withinWindow
        titleBacking.alphaValue = 0
        titleBacking.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleBacking)
        titleBackingHeight = titleBacking.heightAnchor.constraint(equalToConstant: 28)

        // The web view fills the whole window, title bar area included, and
        // web views never let a click move the window. This strip, the
        // height of the title bar, gives the window back its drag handle.
        dragStrip = WindowDragView()
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(dragStrip)

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
            bookPage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bookPage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bookPage.topAnchor.constraint(equalTo: root.topAnchor),
            bookPage.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            overlayHost.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            overlayHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            overlayHost.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            overlayHost.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            overlayHost.widthAnchor.constraint(equalToConstant: 720).withPriority(.defaultHigh),


            titleBacking.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBacking.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBacking.topAnchor.constraint(equalTo: root.topAnchor),
            titleBackingHeight,

            dragStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dragStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dragStrip.topAnchor.constraint(equalTo: root.topAnchor),
            dragStrip.heightAnchor.constraint(equalTo: titleBacking.heightAnchor),

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

        state.$sidebarVisible
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] open in if !open { DispatchQueue.main.async { self?.sidebarDidClose() } } }
            .store(in: &cancellables)

        // When the Aa popover closes, the overlay's hide countdown restarts.
        state.$overlayPopoverOpen
            .removeDuplicates()
            .sink { [weak self] open in if !open { self?.restartHideTimer() } }
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
        installScrollMonitor()
        // VoiceOver turned on or off while a book is open.
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] workspace, _ in
            DispatchQueue.main.async { self?.callPlaten("setVoiceOver", workspace.isVoiceOverEnabled) }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        scrollMonitor = nil
        keyMonitor = nil
    }

    // MARK: - Opening

    func loadBook() {
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

    func loadRecord(for book: Book, url: URL) {
        var record = PositionStore.shared.load(key: book.key)
            ?? BookRecord(key: book.key, uniqueIdentifier: book.package?.uniqueIdentifier, fingerprint: book.fingerprint)
        record.lastKnownPath = url.path
        record.lastOpened = Date()
        self.record = record
        state.bookmarks = record.bookmarks
        if book.isFixedLayout {
            state.flow = .paginated
        } else if let mode = record.readingMode.flatMap(ReadingFlow.init) {
            state.flow = mode
        }
    }

    func sendBookIfReady() {
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

    func showFailure(_ error: Error) {
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

    // MARK: - Overlay and chrome

    func setOverlay(visible: Bool) {
        // Popovers hang from the overlay, so they go with it.
        if !visible && state.sidebarVisible { state.sidebarVisible = false }
        overlayVisible = visible
        titleBarVisible = visible
        applyChromeVisibility(animated: true)
        if visible { restartHideTimer() } else { hideTimer?.invalidate() }
    }

    /// Hide the overlay after 4 s without pointer movement, unless the
    /// pointer is over it (it is being used).
    func restartHideTimer() {
        hideTimer?.invalidate()
        guard overlayVisible else { return }
        // With VoiceOver, the controls stay until dismissed (C or Esc):
        // VoiceOver users move through them without the pointer, and the
        // bar vanishing mid-way sent VoiceOver's cursor elsewhere.
        if NSWorkspace.shared.isVoiceOverEnabled { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, self.overlayVisible else { return }
            // Never hide from under an open popover; closing it restarts this.
            if self.state.overlayPopoverOpen || self.state.sidebarVisible { return }
            if let window = self.view.window {
                let point = self.overlayHost.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.overlayHost.bounds.contains(point) { return self.restartHideTimer() }
            }
            self.setOverlay(visible: false)
        }
    }

    func applyChromeVisibility(animated: Bool) {
        guard let window = view.window else { return }
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0
        // The title bar container holds the window buttons and title. Fading
        // it (rather than hiding it) keeps the top edge draggable.
        //
        // The title bar always stays transparent: an opaque title bar takes
        // its height away from the content, so the page would shrink and the
        // text re-flow every time the controls appeared. Instead it floats
        // over the page, on a backing view of our own (as in IINA).
        let titleBar = window.standardWindowButton(.closeButton)?.superview?.superview
        window.titleVisibility = titleBarVisible ? .visible : .hidden
        window.titlebarAppearsTransparent = true
        let fullScreen = window.styleMask.contains(.fullScreen)
        titleBackingHeight.constant = max(0, view.bounds.height - window.contentLayoutRect.height)
        if overlayVisible { overlayHost.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            titleBar?.animator().alphaValue = titleBarVisible || fullScreen ? 1 : 0
            titleBacking.animator().alphaValue = titleBarVisible && !fullScreen ? 0.55 : 0 // translucent
            overlayHost.animator().alphaValue = overlayVisible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Hidden views take no clicks, so the page underneath gets them.
            self.overlayHost.isHidden = !self.overlayVisible
        })
        // VoiceOver skips the bar while it is hidden (hidden views are left
        // out of the accessibility tree), and sees every control in it when
        // shown. (Marking the bar itself as one accessibility element hid
        // some of its buttons from VoiceOver.)
    }

    /// Settings shows a note when Two Pages is chosen but the front book
    /// window is too narrow for them.
    func reportLayoutToSettings() {
        guard view.window?.isKeyWindow == true else { return }
        let narrow = state.twoPagesTooNarrow
        if settings.frontWindowTooNarrowForTwoPages != narrow { settings.frontWindowTooNarrowForTwoPages = narrow }
    }

    func fullScreenChanged() {
        applyChromeVisibility(animated: false)
    }

    // MARK: - Settings and theme

    /// Decided from the system's appearance, not the window's: the window's
    /// own appearance is forced to match the theme, so it cannot tell us
    /// when macOS switches between Light and Dark.
    var currentTheme: Theme {
        settings.theme(for: NSApp.effectiveAppearance)
    }

    func pushSettings() {
        applyWindowTheme()
        guard bookSentToShell else { return }
        let payload = settings.webPayload(theme: currentTheme, flow: state.flow)
        callPlaten("setSettings", payload)
    }

    func applyWindowTheme() {
        let theme = currentTheme
        view.window?.backgroundColor = theme.nsBackground
        // Chrome and the overlay follow the page's lightness.
        view.window?.appearance = theme.appearance
    }

    /// One page, two pages or scroll (⌘1, ⌘2, ⌘3). The page count is a
    /// global setting; paginated or scroll is remembered for this book.
    func setLayout(_ layout: ReadingLayout) {
        if let pages = layout.pages, pages != settings.pageLayout {
            settings.pageLayout = pages // re-styles every open window
        }
        setFlow(layout.flow)
    }

    func setFlow(_ flow: ReadingFlow) {
        guard !state.isFixedLayout, flow != state.flow else { return }
        state.flow = flow
        pushSettings()
        // Briefly show the click zones for the new mode, for the first three
        // switches only.
        let count = UserDefaults.standard.integer(forKey: ReadingControlsExplainer.switchCountKey)
        if count < 3 {
            UserDefaults.standard.set(count + 1, forKey: ReadingControlsExplainer.switchCountKey)
            showExplainer(flash: true)
        }
    }

    // MARK: - Click-zone explainer

    /// The click zones are shown over the page for the first few books
    /// opened, until the reader has had a chance to learn them. Any click
    /// dismisses them.
    func showFirstRunExplainerIfNeeded() {
        let key = ReadingControlsExplainer.shownCountKey
        let count = UserDefaults.standard.integer(forKey: key)
        guard count < ReadingControlsExplainer.opensToShow else { return }
        UserDefaults.standard.set(count + 1, forKey: key)
        showExplainer(flash: false)
    }

    /// Shows the zones over the page. Any click dismisses them; a "flash"
    /// (after a mode switch) also goes away on its own.
    func showExplainer(flash: Bool) {
        dismissExplainer()
        let host = ExplainerHostView(
            rootView: ReadingControlsExplainer(flow: state.flow, rightToLeft: state.isRightToLeft))
        host.onClick = { [weak self] in self?.dismissExplainer() }
        host.translatesAutoresizingMaskIntoConstraints = false
        host.alphaValue = 0
        view.addSubview(host, positioned: .below, relativeTo: overlayHost)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        explainerHost = host
        NSAnimationContext.runAnimationGroup { $0.duration = reducedMotion ? 0 : 0.15; host.animator().alphaValue = 1 }
        if flash {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self, weak host] in
                if let host, self?.explainerHost === host { self?.dismissExplainer() }
            }
        }
        #if DEBUG
        DebugHooks.snapshotView(view, name: "explainer")
        #endif
    }

    func dismissExplainer() {
        guard let host = explainerHost else { return }
        explainerHost = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = reducedMotion ? 0 : 0.15; host.animator().alphaValue = 0 },
                                             completionHandler: { host.removeFromSuperview() })
        view.window?.makeFirstResponder(webView)
    }

    var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - Saving

    func savePositionNow() {
        guard var record else { return }
        record.readingMode = state.flow.rawValue
        PositionStore.shared.saveNow(record)
    }

    // MARK: - Helpers

    /// Runs a fixed script in the reader page, e.g. `js("platen.next()")`.
    /// Never paste values into the script: use `callPlaten` for those.
    func js(_ script: String) {
        guard bookSentToShell else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Calls `platen.<function>(…)` in the reader page with values passed as
    /// real arguments (never pasted into the script), so any string is safe.
    func callPlaten(_ function: String, _ arguments: Any...) {
        guard bookSentToShell else { return }
        var named: [String: Any] = [:]
        for (i, value) in arguments.enumerated() { named["a\(i)"] = value }
        let list = arguments.indices.map { "a\($0)" }.joined(separator: ", ")
        webView.callAsyncJavaScript("platen.\(function)(\(list))", arguments: named, in: nil, in: .page, completionHandler: nil)
    }

}
