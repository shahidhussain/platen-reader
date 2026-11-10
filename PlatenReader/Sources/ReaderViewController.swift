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
    private var explainerHost: NSView?
    /// Backing for the title when it is shown, drawn by us so the real title
    /// bar can stay transparent (see `applyChromeVisibility`).
    private var titleBacking: PassThroughEffectView!
    private var titleBackingHeight: NSLayoutConstraint!
    private var imageZoom: ImageZoomView?
    /// The strip under the (transparent) title bar that drags the window.
    private var dragStrip: WindowDragView!
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    private var swipe = SwipeTracker()
    private var pageTurn: PageTurnView?
    /// Counts turns, so a turn that was overtaken by a newer one is dropped.
    private var turnGeneration = 0
    /// When the last page turn was asked for, to spot rapid key presses.
    private var lastTurnRequest: TimeInterval = 0
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
        webView.menuCustomiser = { [weak self] menu in self?.customiseContextMenu(menu) }
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)

        // Contents, bookmarks and search: a popover from the overlay's
        // Contents button.
        let sidebarActions = SidebarActions(
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
            goToFraction: { [weak self] f in self?.js("platen.jumpToFraction(\(f))") },
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
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        scrollMonitor = nil
        keyMonitor = nil
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
        state.bookmarks = record.bookmarks
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
            DebugHooks.afterFirstRender(webView: webView, bookName: document.fileURL?.deletingPathExtension().lastPathComponent ?? "book", root: view) { [weak self] step in
                guard let self else { return }
                if step.hasPrefix("@tab:"), let tab = ReaderState.SidebarTab(rawValue: String(step.dropFirst(5))) {
                    self.setSidebar(visible: true, tab: tab)
                } else if step.hasPrefix("@search:") {
                    self.setSidebar(visible: true, tab: .search)
                    self.startSearch(String(step.dropFirst("@search:".count)))
                } else if step.hasPrefix("@key:") {
                    // "@key:cmd+w": a real keystroke, through the app's
                    // normal key handling (menus first).
                    let spec = String(step.dropFirst(5)).lowercased()
                    var flags: NSEvent.ModifierFlags = []
                    if spec.contains("cmd+") { flags.insert(.command) }
                    if spec.contains("shift+") { flags.insert(.shift) }
                    let key = String(spec.split(separator: "+").last ?? "")
                    if let window = self.view.window,
                       let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: key, charactersIgnoringModifiers: key,
                                                    isARepeat: false,
                                                    keyCode: ["w": 13, "q": 12, "t": 17, "f": 3, "d": 2, "c": 8, "k": 40][key] ?? 0) {
                        NSApp.sendEvent(event)
                    }
                } else if step.hasPrefix("@") {
                    // Through this window's responder chain, as a menu shortcut
                    // would be (the app may not be frontmost during checks).
                    let action = NSSelectorFromString(String(step.dropFirst()))
                    if self.view.window?.firstResponder?.tryToPerform(action, with: nil) != true {
                        NSApp.sendAction(action, to: self, from: nil)
                    }
                } else {
                    self.webView.evaluateJavaScript(step) { result, error in
                        if let result = result as? String { log.info("step result: \(result, privacy: .public)") }
                        // Steps often return a Promise, which WebKit cannot pass back; that is fine.
                        if let error = error as? NSError, error.code != 5 {
                            log.error("step failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
            #endif

        case "opened":
            if let title = body["title"] as? String, !title.isEmpty { state.title = title }
            state.author = body["author"] as? String ?? ""
            state.isFixedLayout = body["fixedLayout"] as? Bool ?? false
            state.isRightToLeft = (body["dir"] as? String) == "rtl"
            state.sectionFractions = (body["sectionFractions"] as? [NSNumber])?.map(\.doubleValue) ?? []
            view.window?.windowController?.synchronizeWindowTitleWithDocumentName()
            sendBookmarksToPage()
            showFirstRunExplainerIfNeeded()

        case "contents":
            // Arrives after the first page is on screen (built in the background).
            state.toc = ((body["toc"] as? [[String: Any]]) ?? []).enumerated().map { index, item in
                ReaderState.TOCItem(id: index, label: item["label"] as? String ?? "",
                                    href: item["href"] as? String ?? "", depth: item["depth"] as? Int ?? 0)
            }
            state.sectionLabels = body["sectionLabels"] as? [String] ?? []
            log.debug("contents: \(self.state.toc.count) entries\((body["synthesised"] as? Bool) == true ? " (built from headings)" : "", privacy: .public)")

        case "back":
            state.backLabel = body["label"] as? String
            log.debug("back label: \(self.state.backLabel ?? "none", privacy: .public)")

        case "pageBookmarked":
            state.isPageBookmarked = body["bookmarked"] as? Bool ?? false
            log.debug("page bookmarked: \(self.state.isPageBookmarked)")

        case "addBookmark":
            addBookmark(from: body)

        case "removeBookmark":
            if let cfi = body["cfi"] as? String { removeBookmark(cfi: cfi) }

        case "selection":
            let text = body["text"] as? String ?? ""
            state.selection = text.isEmpty ? nil
                : ReaderState.Selection(text: text, chapter: body["chapter"] as? String ?? "", page: body["page"] as? String)
            log.debug("selection: \(text.count) characters")

        case "searchResults":
            guard (body["query"] as? String) == activeSearchQuery else { break }
            let items = body["items"] as? [[String: Any]] ?? []
            var nextID = state.allHits.count
            let hits = items.map { item -> ReaderState.SearchHit in
                defer { nextID += 1 }
                return ReaderState.SearchHit(id: nextID, cfi: item["cfi"] as? String ?? "",
                                             pre: item["pre"] as? String ?? "", match: item["match"] as? String ?? "",
                                             post: item["post"] as? String ?? "")
            }
            state.searchGroups.append(.init(id: state.searchGroups.count, label: body["label"] as? String ?? "", hits: hits))

        case "searchProgress":
            if (body["query"] as? String) == activeSearchQuery {
                state.searchProgress = (body["progress"] as? NSNumber)?.doubleValue ?? 0
            }

        case "searchDone":
            if (body["query"] as? String) == activeSearchQuery {
                state.searchRunning = false
                state.searchDoneQuery = activeSearchQuery
            }

        case "relocate":
            state.fraction = (body["fraction"] as? NSNumber)?.doubleValue ?? state.fraction
            state.chapter = body["chapter"] as? String ?? ""
            state.printedPage = body["page"] as? String
            state.chapterHref = body["chapterHref"] as? String
            state.pagesLeftInChapter = (body["pagesLeft"] as? NSNumber)?.intValue
            state.columnsOnScreen = (body["columns"] as? NSNumber)?.intValue ?? 1
            reportLayoutToSettings()
            view.window?.subtitle = state.chapter
            if let cfi = body["cfi"] as? String, var record {
                record.lastCFI = cfi
                record.readingMode = state.flow.rawValue
                self.record = record
                PositionStore.shared.scheduleSave(record) // debounced
            }

        case "click":
            handleClick(zone: body["zone"] as? String ?? "centre")

        case "image":
            showImage(from: body)

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
            turn(.left)
        } else {
            turn(.right)
        }
    }

    /// Keys that are not menu shortcuts. Returns true if handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        // C shows or hides the controls (by character, so it follows the
        // keyboard layout).
        if !shift, event.charactersIgnoringModifiers?.lowercased() == "c" {
            setOverlay(visible: !overlayVisible)
            return true
        }
        switch event.keyCode {
        case 49: // space
            turn(shift ? .prev : .next)
        case 121: turn(.next) // page down
        case 116: turn(.prev) // page up
        case 123: previousPageLeft(nil) // ←
        case 124: nextPageRight(nil) // →
        case 125: if state.flow == .scrolled { js("platen.scrollLines(1)") } else { turn(.next) } // ↓
        case 126: if state.flow == .scrolled { js("platen.scrollLines(-1)") } else { turn(.prev) } // ↑
        case 53: // Esc: close the panel or overlay; exit full screen if neither is showing
            if imageZoom != nil {
                closeImage()
            } else if explainerHost != nil {
                dismissExplainer()
            } else if state.sidebarVisible {
                setSidebar(visible: false)
            } else if overlayVisible {
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
        // Popovers hang from the overlay, so they go with it.
        if !visible && state.sidebarVisible { state.sidebarVisible = false }
        overlayVisible = visible
        titleBarVisible = visible
        applyChromeVisibility(animated: true)
        if visible { restartHideTimer() } else { hideTimer?.invalidate() }
    }

    /// Hide the overlay after 4 s without pointer movement, unless the
    /// pointer is over it (it is being used).
    private func restartHideTimer() {
        hideTimer?.invalidate()
        guard overlayVisible else { return }
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

    private func applyChromeVisibility(animated: Bool) {
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
        // Keep VoiceOver from landing on invisible controls.
        overlayHost.setAccessibilityElement(overlayVisible)
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
    private var currentTheme: Theme {
        settings.theme(for: NSApp.effectiveAppearance)
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

    /// One page, two pages or scroll (⌘1, ⌘2, ⌘3). The page count is a
    /// global setting; paginated or scroll is remembered for this book.
    private func setLayout(_ layout: ReadingLayout) {
        if let pages = layout.pages, pages != settings.pageLayout {
            settings.pageLayout = pages // re-styles every open window
        }
        setFlow(layout.flow)
    }

    private func setFlow(_ flow: ReadingFlow) {
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
    private func showFirstRunExplainerIfNeeded() {
        let key = ReadingControlsExplainer.shownCountKey
        let count = UserDefaults.standard.integer(forKey: key)
        guard count < ReadingControlsExplainer.opensToShow else { return }
        UserDefaults.standard.set(count + 1, forKey: key)
        showExplainer(flash: false)
    }

    /// Shows the zones over the page. Any click dismisses them; a "flash"
    /// (after a mode switch) also goes away on its own.
    private func showExplainer(flash: Bool) {
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

    private func dismissExplainer() {
        guard let host = explainerHost else { return }
        explainerHost = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = reducedMotion ? 0 : 0.15; host.animator().alphaValue = 0 },
                                             completionHandler: { host.removeFromSuperview() })
        view.window?.makeFirstResponder(webView)
    }

    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - Contents, jumps and bookmarks

    /// A jump through the contents, a bookmark or the slider: reader.js
    /// remembers where the reader was, for the Back button.
    private func jump(to target: String, keepOrigin: Bool = false) {
        guard bookSentToShell else { return }
        webView.callAsyncJavaScript("platen.jumpTo(target, keep)", arguments: ["target": target, "keep": keepOrigin],
                                    in: nil, in: .page, completionHandler: nil)
        view.window?.makeFirstResponder(webView)
    }

    /// Opens or closes the contents popover. It hangs from the Contents
    /// button in the overlay, so the overlay is shown first.
    private func setSidebar(visible: Bool, tab: ReaderState.SidebarTab? = nil) {
        if let tab { state.sidebarTab = tab }
        guard visible != state.sidebarVisible else { return }
        if visible {
            let wasHidden = !overlayVisible
            setOverlay(visible: true)
            // The popover needs its button on screen to hang from.
            DispatchQueue.main.asyncAfter(deadline: .now() + (wasHidden ? 0.05 : 0)) { [weak self] in
                self?.state.sidebarVisible = true
            }
        } else {
            state.sidebarVisible = false
        }
    }

    /// The popover was closed (by us, Esc or a click outside it).
    private func sidebarDidClose() {
        view.window?.makeFirstResponder(webView)
        // Search highlights are temporary: they go when the panel closes.
        if state.sidebarTab == .search || !state.searchGroups.isEmpty { js("platen.clearSearch()") }
        restartHideTimer()
    }

    private func sendBookmarksToPage() {
        let list = state.bookmarks.map { ["cfi": $0.cfi] }
        guard bookSentToShell else { return }
        webView.callAsyncJavaScript("platen.setBookmarks(list)", arguments: ["list": list], in: nil, in: .page, completionHandler: nil)
    }

    private func addBookmark(from body: [String: Any]) {
        guard var record, let cfi = body["cfi"] as? String,
              !record.bookmarks.contains(where: { $0.cfi == cfi }) else { return }
        let bookmark = BookRecord.Bookmark(
            cfi: cfi,
            snippet: body["snippet"] as? String ?? "",
            chapter: (body["chapter"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            page: body["page"] as? String,
            fraction: (body["fraction"] as? NSNumber)?.doubleValue)
        record.bookmarks.append(bookmark)
        // Keep the list in reading order.
        record.bookmarks.sort { ($0.fraction ?? 0) < ($1.fraction ?? 0) }
        saveBookmarks(record)
        NSAccessibility.post(element: webView as Any, notification: .announcementRequested,
                             userInfo: [.announcement: String(localized: "Bookmark added"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func removeBookmark(cfi: String) {
        guard var record else { return }
        record.bookmarks.removeAll { $0.cfi == cfi }
        saveBookmarks(record)
    }

    private func saveBookmarks(_ record: BookRecord) {
        self.record = record
        state.bookmarks = record.bookmarks
        PositionStore.shared.saveNow(record) // bookmarks are saved at once
        sendBookmarksToPage()
    }

    // MARK: - Find in book

    private var activeSearchQuery = ""

    private func startSearch(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchQuery = query
        state.searchQuery = query
        state.searchGroups = []
        state.currentHitID = nil
        state.searchDoneQuery = nil
        state.searchProgress = 0
        state.searchRunning = !query.isEmpty
        guard bookSentToShell else { return }
        webView.callAsyncJavaScript("platen.search(q)", arguments: ["q": query], in: nil, in: .page, completionHandler: nil)
    }

    private func goToHit(_ hit: ReaderState.SearchHit) {
        let keep = state.currentHitID != nil // Back returns to before the first result
        state.currentHitID = hit.id
        jump(to: hit.cfi, keepOrigin: keep)
    }

    private func stepThroughHits(by step: Int) {
        let hits = state.allHits
        guard !hits.isEmpty else { return findInBook(nil) }
        let current = hits.firstIndex { $0.id == state.currentHitID }
        let next = current.map { ($0 + step + hits.count) % hits.count } ?? (step > 0 ? 0 : hits.count - 1)
        goToHit(hits[next])
    }

    // MARK: - Getting text out

    /// The selected text followed by a citation line: author, title,
    /// chapter, and printed page where available. Plain and rich text.
    private func copyWithCitation() {
        guard let selection = state.selection else { return }
        var parts: [String] = []
        if !state.author.isEmpty { parts.append(state.author) }
        let titleIndex = parts.count
        if !state.title.isEmpty { parts.append(state.title) }
        if !selection.chapter.isEmpty { parts.append(selection.chapter) }
        if let page = selection.page { parts.append(String(localized: "p. \(page)")) }

        let quote = "“\(selection.text)”"
        let plain = parts.isEmpty ? quote : "\(quote)\n— \(parts.joined(separator: ", "))"

        let rich = NSMutableAttributedString(string: quote)
        if !parts.isEmpty {
            let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            rich.append(NSAttributedString(string: "\n— "))
            for (i, part) in parts.enumerated() {
                if i > 0 { rich.append(NSAttributedString(string: ", ")) }
                let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                rich.append(NSAttributedString(string: part, attributes: i == titleIndex && !state.title.isEmpty ? [.font: italic] : [.font: base]))
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pasteboard.declareTypes([.string] + (rtf == nil ? [] : [.rtf]), owner: nil)
        pasteboard.setString(plain, forType: .string)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
    }

    /// Adds Platen's items to WebKit's context menu (which already has Look
    /// Up, Translate, Copy and Share) and removes browser-only items.
    private func customiseContextMenu(_ menu: NSMenu) {
        let browserOnly: Set<String> = [
            "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
            "WKMenuItemIdentifierOpenFrameInNewWindow", "WKMenuItemIdentifierOpenLinkInNewWindow",
            "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierOpenImageInNewWindow",
            "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierOpenMediaInNewWindow",
            "WKMenuItemIdentifierDownloadMedia",
        ]
        for item in menu.items where browserOnly.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }

        var items: [NSMenuItem] = []
        if let selection = state.selection {
            let copyIndex = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
            let cite = NSMenuItem(title: String(localized: "Copy with Citation"), action: #selector(copyWithCitation(_:)), keyEquivalent: "")
            cite.target = self
            if let copyIndex { menu.insertItem(cite, at: copyIndex + 1) } else { items.append(cite) }
            let short = selection.text.count > 24 ? String(selection.text.prefix(24)) + "…" : selection.text
            let find = NSMenuItem(title: String(localized: "Search Book for “\(short)”"), action: #selector(searchForSelection(_:)), keyEquivalent: "")
            find.target = self
            items.append(find)
        } else {
            let mark = NSMenuItem(title: state.isPageBookmarked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark This Page"),
                                  action: #selector(toggleBookmark(_:)), keyEquivalent: "")
            mark.target = self
            let contents = NSMenuItem(title: String(localized: "Show Contents"), action: #selector(showContentsFromMenu(_:)), keyEquivalent: "")
            contents.target = self
            items += [mark, contents]
        }
        if !items.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }
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

    @objc func previousPageLeft(_ sender: Any?) { turn(.left) }
    @objc func nextPageRight(_ sender: Any?) { turn(.right) }
    @objc func previousChapter(_ sender: Any?) { js("platen.prevSection()") }
    @objc func nextChapter(_ sender: Any?) { js("platen.nextSection()") }
    @objc func goBackInHistory(_ sender: Any?) { js("platen.goBack()") }
    @objc func toggleContents(_ sender: Any?) {
        setSidebar(visible: !(state.sidebarVisible && state.sidebarTab != .search),
                   tab: state.sidebarTab == .search ? .contents : nil)
    }
    @objc func showContentsFromMenu(_ sender: Any?) { setSidebar(visible: true, tab: .contents) }
    @objc func toggleBookmark(_ sender: Any?) { js("platen.toggleBookmark()") }
    @objc func findInBook(_ sender: Any?) {
        setSidebar(visible: true, tab: .search)
        state.searchFocusRequest += 1
    }
    @objc func findNext(_ sender: Any?) { stepThroughHits(by: 1) }
    @objc func findPrevious(_ sender: Any?) { stepThroughHits(by: -1) }
    @objc func searchForSelection(_ sender: Any?) {
        guard let text = state.selection?.text else { return }
        setSidebar(visible: true, tab: .search)
        startSearch(String(text.prefix(200)))
    }
    @objc func copyWithCitation(_ sender: Any?) { copyWithCitation() }
    @objc func shareSelection(_ sender: Any?) {
        guard let text = state.selection?.text else { return }
        let picker = NSSharingServicePicker(items: [text])
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
    @objc func showReadingControls(_ sender: Any?) { showExplainer(flash: false) }
    @objc func setLayoutFromMenu(_ sender: NSMenuItem) {
        if let layout = (sender.representedObject as? String).flatMap(ReadingLayout.init) { setLayout(layout) }
    }
    @objc func makeTextBigger(_ sender: Any?) { settings.biggerText() }
    @objc func makeTextSmaller(_ sender: Any?) { settings.smallerText() }
    @objc func makeTextDefaultSize(_ sender: Any?) { settings.defaultTextSize() }
    @objc func toggleReaderControls(_ sender: Any?) { setOverlay(visible: !overlayVisible) }


    @objc func setThemeFromMenu(_ sender: NSMenuItem) {
        if let choice = (sender.representedObject as? String).flatMap(AppearanceChoice.init) {
            settings.appearance = choice
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let ready = book != nil && failureHost == nil
        switch item.action {
        case #selector(setLayoutFromMenu(_:)):
            let layout = (item.representedObject as? String).flatMap(ReadingLayout.init)
            item.state = layout == ReadingLayout(flow: state.flow, pages: settings.pageLayout) ? .on : .off
            if layout == .scroll {
                item.toolTip = state.isFixedLayout ? String(localized: "Fixed-layout books are always paginated.") : nil
                return ready && !state.isFixedLayout
            }
            return ready
        case #selector(setThemeFromMenu(_:)):
            item.state = (item.representedObject as? String) == settings.appearance.rawValue ? .on : .off
            return true
        case #selector(makeTextBigger(_:)):
            return !state.isFixedLayout && settings.fontSizeIndex < ReaderSettings.fontSizes.count - 1
        case #selector(makeTextSmaller(_:)):
            return !state.isFixedLayout && settings.fontSizeIndex > 0
        case #selector(makeTextDefaultSize(_:)):
            return !state.isFixedLayout
        case #selector(goBackInHistory(_:)):
            return ready && state.backLabel != nil
        case #selector(toggleBookmark(_:)):
            item.title = state.isPageBookmarked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark This Page")
            return ready
        case #selector(toggleContents(_:)):
            item.title = state.sidebarVisible && state.sidebarTab != .search
                ? String(localized: "Hide Contents") : String(localized: "Show Contents")
            return ready
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return ready && !state.allHits.isEmpty
        case #selector(copyWithCitation(_:)), #selector(shareSelection(_:)), #selector(searchForSelection(_:)):
            return ready && state.selection != nil
        case #selector(toggleReaderControls(_:)):
            item.title = overlayVisible ? String(localized: "Hide Controls") : String(localized: "Show Controls")
            item.toolTip = String(localized: "Or press C.")
            return ready
        default:
            return ready
        }
    }
}

// MARK: - Trackpad and scroll wheel

extension ReaderViewController {
    /// Scroll events are read here rather than in the page because AppKit
    /// says when the fingers touch and lift (`phase`) and which events are
    /// momentum after they lift (`momentumPhase`). The web only sees a stream
    /// of wheel events, which is what made swipes unpredictable.
    fileprivate func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.view.window else { return event }
            return self.handleScroll(event) ? nil : event
        }
        // Reading keys (C, space, arrows, Esc…) are taken here, before
        // WebKit, which does not always pass key presses on to its view.
        // Only while the page itself has focus, so typing in a search field
        // or popover is never affected.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.view.window,
                  let responder = event.window?.firstResponder as? NSView,
                  responder === self.webView || responder.isDescendant(of: self.webView) else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Returns true if the event was used (and must not reach WebKit).
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard bookSentToShell, failureHost == nil else { return false }
        if imageZoom != nil { return true }
        // Scroll mode uses WebKit's own scrolling, unchanged.
        guard state.flow == .paginated || state.isFixedLayout else { return false }
        // Only over the page: the contents panel and overlay scroll normally.
        let point = view.convert(event.locationInWindow, from: nil)
        if overlayVisible && overlayHost.frame.contains(point) { return false }

        // Momentum after the fingers lift never turns another page: one
        // gesture is one page at most.
        if event.momentumPhase != [] { return true }

        // A mouse wheel (no phases): one page per notch, with a short pause
        // so a fast spin does not race through the book.
        if event.phase == [] {
            let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? -event.scrollingDeltaY : -event.scrollingDeltaX
            guard delta != 0, event.timestamp >= swipe.wheelQuietUntil else { return true }
            swipe.wheelQuietUntil = event.timestamp + 0.25
            turn(delta > 0 ? .next : .prev)
            return true
        }

        // Trackpad: content follows the fingers (`scrollingDelta` already
        // includes the natural-scrolling preference).
        let dx = -event.scrollingDeltaX, dy = -event.scrollingDeltaY
        switch event.phase {
        case .began, .mayBegin:
            swipe.reset()
            if event.phase == .began { swipe.active = true }
        case .changed:
            swipe.active = true
            if swipe.axis == nil {
                guard abs(dx) + abs(dy) > 1 else { return true }
                swipe.axis = abs(dx) > abs(dy) ? .horizontal : .vertical
            }
            if swipe.axis == .horizontal && !state.isFixedLayout {
                // The page moves with the fingers.
                swipe.add(dx, at: event.timestamp)
                js("platen.swipeMove(\(dx))")
            } else if !swipe.turned {
                // Vertical (or fixed layout): one page once past a threshold.
                swipe.total += swipe.axis == .horizontal ? dx : dy
                if abs(swipe.total) > 30 {
                    swipe.turned = true
                    let forward = swipe.total > 0
                    if swipe.axis == .horizontal { turn(forward ? .right : .left) }
                    else { turn(forward ? .next : .prev) }
                }
            }
        case .ended, .cancelled:
            if swipe.active && swipe.axis == .horizontal && !state.isFixedLayout {
                js("platen.swipeEnd(\(event.phase == .cancelled ? 0 : swipe.flickDirection(at: event.timestamp)))")
            }
            swipe.reset()
        default:
            break
        }
        return true
    }
}

/// State of one trackpad gesture.
struct SwipeTracker {
    enum Axis { case horizontal, vertical }
    var active = false
    var axis: Axis?
    var total: CGFloat = 0
    var turned = false
    /// Recent movement, for the speed when the fingers lift.
    private var recent: [(time: TimeInterval, dx: CGFloat)] = []
    var wheelQuietUntil: TimeInterval = 0

    mutating func reset() {
        active = false; axis = nil; total = 0; turned = false; recent = []
    }

    mutating func add(_ dx: CGFloat, at time: TimeInterval) {
        total += dx
        recent.append((time, dx))
        recent.removeAll { time - $0.time > 0.1 }
    }

    /// 1 or -1 if the fingers were moving quickly when they lifted (a flick,
    /// which turns the page however short it was), else 0: the page then
    /// settles on whichever page is mostly in view, so a short, slow drag
    /// springs back.
    func flickDirection(at time: TimeInterval) -> Int {
        let window = recent.filter { time - $0.time <= 0.08 }
        guard let first = window.first, abs(total) > 20 else { return 0 }
        let distance = window.reduce(0) { $0 + $1.dx }
        let duration = max(time - first.time, 0.016)
        let speed = distance / CGFloat(duration) // points per second
        guard abs(speed) > 350, (speed > 0) == (total > 0) else { return 0 }
        return speed > 0 ? 1 : -1
    }
}

// MARK: - Turning pages

/// A page turn: by the side of the window (left/right, as clicked or as the
/// arrow keys say) or in reading order (next/previous).
enum PageTurn: String {
    case left, right, next, prev
}

extension ReaderViewController {
    /// Turns a page, with the page curl when chosen (Settings > General >
    /// Page turn animation; not with Reduce Motion). Slide and None are
    /// foliate-js's own turn, animated or not. In scroll
    /// mode "next" and "previous" move by a screen instead.
    fileprivate func turn(_ command: PageTurn) {
        guard bookSentToShell else { return }
        let paginated = state.flow == .paginated || state.isFixedLayout
        guard paginated, settings.pageTurnStyle == .curl, !reducedMotion, imageZoom == nil else {
            return js(Self.turnScript[command]!)
        }
        // Which way the leaf travels on screen.
        let leafMovesLeft: Bool
        switch command {
        case .right: leafMovesLeft = true
        case .left: leafMovesLeft = false
        case .next: leafMovesLeft = !state.isRightToLeft
        case .prev: leafMovesLeft = state.isRightToLeft
        }

        // Pressing keys quickly (or holding one down) flips through pages:
        // while turns come faster than a curl takes, they are instant. The
        // curl returns as soon as the reader slows down.
        let now = ProcessInfo.processInfo.systemUptime
        let rapid = now - lastTurnRequest < 0.45
        lastTurnRequest = now
        if rapid {
            turnGeneration += 1
            if let previous = pageTurn {
                previous.finish()
                previous.removeFromSuperview()
                pageTurn = nil
            }
            return js(Self.turnScript[command]!)
        }

        // A turn already under way ends at once; this one starts afresh.
        if let previous = pageTurn {
            previous.finish()
            previous.removeFromSuperview()
            pageTurn = nil
        }
        turnGeneration += 1
        let generation = turnGeneration

        // 1. Snapshot the page as it is (A).
        webView.takeSnapshot(with: nil) { [weak self] before, _ in
            // Overtaken by a newer turn: that one has already moved the page.
            guard let self, generation == self.turnGeneration else { return }
            guard let a = before?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.js(Self.turnScript[command]!) // no snapshot: turn without the curl
                return
            }
            // 2. Cover the page with A, then turn the real page instantly.
            let overlay = PageTurnView(frame: self.webView.frame)
            overlay.autoresizingMask = [.width, .height]
            self.view.addSubview(overlay, positioned: .above, relativeTo: self.webView)
            overlay.cover(with: a)
            self.pageTurn = overlay
            let remove = { [weak self, weak overlay] in
                overlay?.removeFromSuperview()
                if self?.pageTurn === overlay { self?.pageTurn = nil }
            }
            self.webView.callAsyncJavaScript("return await platen.turnInstantly(d)", arguments: ["d": command.rawValue],
                                             in: nil, in: .page) { result in
                guard generation == self.turnGeneration,
                      case .success(let value) = result, let info = value as? [String: Any],
                      info["moved"] as? Bool == true else { return remove() }
                let twoPages = (info["columns"] as? NSNumber)?.intValue ?? 1 >= 2
                // 3. Snapshot the new page (B) and animate from A to B.
                self.webView.takeSnapshot(with: nil) { after, _ in
                    guard generation == self.turnGeneration,
                          let b = after?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return remove() }
                    log.debug("page turn: animating (\(twoPages ? "two pages" : "one page", privacy: .public))")
                    overlay.run(before: a, after: b, direction: leafMovesLeft ? .towardLeft : .towardRight,
                                twoPages: twoPages, completion: remove)
                }
            }
        }
    }

    private static let turnScript: [PageTurn: String] = [
        .left: "platen.goLeft()", .right: "platen.goRight()", .next: "platen.next()", .prev: "platen.prev()",
    ]
}

// MARK: - Pictures

extension ReaderViewController {
    /// A click on a picture in the book: show it full size, zooming from
    /// where it sits on the page.
    fileprivate func showImage(from body: [String: Any]) {
        guard imageZoom == nil,
              let base64 = body["data"] as? String, let data = Data(base64Encoded: base64),
              let image = NSImage(data: data) else { return }
        log.debug("Showing picture (\(data.count) bytes)")
        let rect = body["rect"] as? [String: Any] ?? [:]
        func number(_ key: String) -> CGFloat { CGFloat((rect[key] as? NSNumber)?.doubleValue ?? 0) }
        // Web coordinates have their origin at the top left; AppKit's at the
        // bottom left.
        let source = NSRect(x: number("x"), y: view.bounds.height - number("y") - number("height"),
                            width: number("width"), height: number("height"))
        let zoom = ImageZoomView(image: image, data: data, type: body["mimeType"] as? String ?? "",
                                 name: body["alt"] as? String ?? "", background: currentTheme.nsBackground)
        zoom.onClose = { [weak self] in self?.closeImage() }
        zoom.frame = view.bounds
        zoom.autoresizingMask = [.width, .height]
        view.addSubview(zoom, positioned: .below, relativeTo: titleBacking)
        imageZoom = zoom
        if overlayVisible { setOverlay(visible: false) }
        zoom.present(from: source, animated: !reducedMotion)
        view.window?.makeFirstResponder(zoom)
    }

    fileprivate func closeImage() {
        guard let zoom = imageZoom else { return }
        imageZoom = nil
        zoom.dismiss(animated: !reducedMotion) { zoom.removeFromSuperview() }
        view.window?.makeFirstResponder(webView)
    }
}

// MARK: - Supporting views

/// Lets the window be dragged by its top edge (and zoomed with a double
/// click, following the user's Dock setting), as a title bar would.
final class WindowDragView: NSView {
    // The drag is done explicitly in mouseDown. (Also letting AppKit move the
    // window by itself, through mouseDownCanMoveWindow, made two mechanisms
    // compete for the same click, so the drag only sometimes took.)
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.performMiniaturize(nil) }
            else if action != "None" { window.performZoom(nil) }
        } else {
            window.performDrag(with: event)
        }
    }
}

/// An invisible view that takes any click inside it.
final class ClickCatcherView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
}

/// A visual-effect view that never takes clicks, so the page underneath
/// still gets them.
final class PassThroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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
    var menuCustomiser: ((NSMenu) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menuCustomiser?(menu)
        super.willOpenMenu(menu, with: event)
    }

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

/// Hosts the click-zone explainer; any click dismisses it.
final class ExplainerHostView: NSHostingView<ReadingControlsExplainer> {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Take every click inside our bounds, rather than letting SwiftUI pass
        // clicks on empty areas through to the page.
        frame.contains(point) ? self : nil
    }
}
