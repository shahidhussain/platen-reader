import Combine
import PlatenCore
import SwiftUI
import UIKit
import WebKit

/// The reader for one book on iOS and iPadOS: a web view running the same
/// shell and foliate-js as the Mac, served through the same `platen://`
/// scheme handler, with the same Content-Security-Policy and remote-load
/// blocker (see PlatenReader/Shared/ReaderSchemeHandler.swift).
///
/// It opens the book in place, restores and saves the reading position,
/// turns pages on side taps, and shows the overlay (the Mac's bar, plus a
/// floating Close button) on a centre tap; see ReaderViewController+Overlay.
/// The remaining phases are in docs/m3-ios-plan.md.
///
/// Opening runs two things in parallel and joins them, as on the Mac:
/// 1. the web view loads the reader shell, and
/// 2. the book file is read and checked on a background queue.
/// When both are ready, the book is handed to the shell.
final class ReaderViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate,
                                  UIGestureRecognizerDelegate {
    let url: URL
    let schemeHandler = ReaderSchemeHandler()
    let settings = ReaderSettings.shared
    let state = ReaderState()

    /// Called when the reader taps Close; the document browser dismisses us.
    var onClose: (() -> Void)?

    var webView: WKWebView!
    var spinner: UIActivityIndicatorView!
    var failureHost: UIViewController?
    /// The overlay: the bar at the bottom and the Close button at the top.
    var chrome: ReaderChrome?

    var book: Book?
    var record: BookRecord?
    var shellReady = false
    var bookSentToShell = false
    var hasRendered = false
    var openStarted = CFAbsoluteTimeGetCurrent()
    var overlayVisible: Bool { chrome?.isVisible ?? false }
    /// Whether text was selected just before the latest tap (reported by
    /// reader.js). A tap then only dismisses the selection.
    var hasSelection = false
    /// Draws page turns and swipes (ReaderViewController+PageTurn).
    lazy var pageTurner = makePageTurnAnimator()
    var swipeRecogniser: UIPanGestureRecognizer?
    /// When the latest finger touched down (a swipe after a long hold is
    /// text selection, not a page turn).
    var touchDownTime: CFTimeInterval?
    /// The last settings sent to the page, so unchanged ones are not resent.
    var lastPayload: [String: Any]?
    /// See `webPayload`.
    var largestVerticalInset: CGFloat = 0
    var cancellables: Set<AnyCancellable> = []

    /// True while we hold access to a file outside our sandbox (a book in
    /// Files, iCloud Drive or a file provider). Released when the reader
    /// goes away. Large books are read lazily, so access must last as long
    /// as the book is open, not just while it opens.
    private var accessingSecurityScope = false

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        accessingSecurityScope = url.startAccessingSecurityScopedResource()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if accessingSecurityScope { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: - View setup

    override func loadView() {
        let root = UIView()

        // Web view, configured exactly as on the Mac.
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: ReaderSchemeHandler.scheme)
        config.userContentController.add(WeakScriptMessageHandler(self), name: "platen")
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsInlineMediaPlayback = true // audio and video play in the page
        config.preferences.isTextInteractionEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true // the shell's own scripts

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        // The page draws the theme colour itself, and lays itself out to the
        // whole screen: foliate-js paginates, so the scroll view must not.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        #if DEBUG
        webView.isInspectable = true // Safari > Develop can inspect the shell
        #endif
        root.addSubview(webView)

        // Taps on the page are recognised here, natively, rather than from
        // the page's click events: WebKit does not turn every tap into a
        // click (taps in quick succession are merged or dropped), and the
        // zone is worked out from the finger's place on screen, not from
        // coordinates inside foliate's very wide chapter frame. The recogniser
        // watches alongside WebKit's own gestures, so links, selection and
        // long presses still work as usual.
        let tap = UITapGestureRecognizer(target: self, action: #selector(pageTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        webView.addGestureRecognizer(tap)
        installSwipeRecogniser()

        installOverlay(in: root)

        // Quiet progress indicator, shown only if opening takes > 500 ms.
        spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)

        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.flow = settings.defaultFlow
        state.allowsTwoPages = UIDevice.current.userInterfaceIdiom != .phone
        applyTheme()

        // Re-style whenever a global setting changes.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.pushSettings() }
            .store(in: &cancellables)
        // Scroll or pages is one setting for every book (spec, "Reading
        // modes and layout"): the Layout button changes it, and this book
        // follows (fixed-layout books always show pages).
        settings.$defaultFlow
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] flow in
                guard let self, !self.state.isFixedLayout, flow != self.state.flow else { return }
                self.state.flow = flow
                self.pushSettings()
            }
            .store(in: &cancellables)

        // Follow the system's Light and Dark switch (Automatic appearance).
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.pushSettings()
        }

        // Save when the app leaves the screen; it may be ended after that.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.savePositionNow() }
            .store(in: &cancellables)

        RemoteContentBlocker.load { [weak self] list in
            guard let self else { return }
            if let list { self.webView.configuration.userContentController.add(list) }
            self.webView.load(URLRequest(url: ReaderSchemeHandler.shellURL))
        }
        loadBook()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.hasRendered, self.failureHost == nil else { return }
            self.spinner.startAnimating()
        }
    }

    // The status bar and home indicator are hidden while reading and come
    // back with the controls (spec, "Layout").
    override var prefersStatusBarHidden: Bool { !overlayVisible }
    override var prefersHomeIndicatorAutoHidden: Bool { !overlayVisible }
    override var preferredStatusBarStyle: UIStatusBarStyle { currentTheme.isDark ? .lightContent : .darkContent }

    // MARK: - Opening

    private func loadBook() {
        openStarted = CFAbsoluteTimeGetCurrent()
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Coordinated, so offloaded iCloud files download first and file
            // providers (SMB, cloud apps) hand over a readable copy.
            let result = Result { try Book.open(url: url, coordinated: true) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let book):
                    let elapsed = (CFAbsoluteTimeGetCurrent() - self.openStarted) * 1000
                    log.info("Read \(url.lastPathComponent, privacy: .public) in \(elapsed, format: .fixed(precision: 0)) ms")
                    for warning in book.warnings { log.notice("\(warning, privacy: .public)") }
                    self.book = book
                    self.schemeHandler.book = book
                    self.state.title = book.title ?? ""
                    self.state.isFixedLayout = book.isFixedLayout
                    self.loadRecord(for: book)
                    self.sendBookIfReady()
                case .failure(let error):
                    self.showFailure(error)
                }
            }
        }
    }

    /// The saved position and bookmarks. Books are identified by their own
    /// identifier and a fingerprint, never their path, so a book keeps its
    /// place wherever it is opened from.
    private func loadRecord(for book: Book) {
        var record = PositionStore.shared.load(key: book.key)
            ?? BookRecord(key: book.key, uniqueIdentifier: book.package?.uniqueIdentifier, fingerprint: book.fingerprint)
        record.lastKnownPath = url.path
        record.lastOpened = Date()
        self.record = record
        state.bookmarks = record.bookmarks
        if state.title.isEmpty { state.title = url.deletingPathExtension().lastPathComponent }
        // The reading mode is the same for every book (the setting, applied
        // in viewDidLoad); fixed-layout books always show pages.
        if book.isFixedLayout { state.flow = .paginated }
    }

    private func sendBookIfReady() {
        guard shellReady, let book, !bookSentToShell else { return }
        bookSentToShell = true
        let payload = webPayload
        lastPayload = payload
        var options: [String: Any] = [
            // Plain text arrives as a made-up EPUB, so the shell opens it as one.
            "format": book.format == .text ? BookFormat.epub.rawValue : book.format.rawValue,
            "settings": payload,
        ]
        if book.format != .mobi {
            options["sizes"] = book.entrySizes.mapValues { Int(clamping: $0) }
        }
        if let cfi = record?.lastCFI { options["lastCFI"] = cfi }
        webView.callAsyncJavaScript("platen.open(options)", arguments: ["options": options], in: nil, in: .page) { result in
            if case .failure(let error) = result { log.error("open failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func showFailure(_ error: Error) {
        log.error("Could not open \(self.url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        spinner.stopAnimating()
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
        let host = UIHostingController(rootView: OpenFailureView(title: title, detail: detail))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.insertSubview(host.view, belowSubview: chrome?.top.view ?? webView)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            host.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
        ])
        host.didMove(toParent: self)
        failureHost = host
        // With no page to read, keep Close on screen (and nothing else).
        if state.title.isEmpty { state.title = url.deletingPathExtension().lastPathComponent }
        chrome?.showCloseOnly()
    }

    // MARK: - Taps

    /// The fraction of the width on each side that turns pages, as on the
    /// Mac (input.js): the side zones are wider than the centre, because most
    /// taps are page turns.
    private static let sideZoneFraction: CGFloat = 0.38

    @objc private func pageTapped(_ recogniser: UITapGestureRecognizer) {
        guard recogniser.state == .ended, hasRendered, failureHost == nil else { return }
        // A tap on selected text only dismisses the selection (WebKit does
        // that itself).
        if hasSelection { return }
        let point = recogniser.location(in: webView)
        // Ask the page what is under the finger: links, pictures and the
        // bookmark ribbons handle their own taps.
        webView.callAsyncJavaScript("return platen.tapTarget(x, y)", arguments: ["x": point.x, "y": point.y],
                                    in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            let target = (try? result.get()) as? String ?? "page"
            log.info("tap at \(Int(point.x)),\(Int(point.y)): \(target, privacy: .public)")
            guard target == "page" else { return }
            let side = self.webView.bounds.width * Self.sideZoneFraction
            let zone = point.x < side ? "left" : point.x > self.webView.bounds.width - side ? "right" : "centre"
            self.handleTap(zone: zone)
        }
    }

    // Recognise taps and swipes alongside WebKit's own gesture recognisers.
    func gestureRecognizer(_ recogniser: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizer(_ recogniser: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if recogniser === swipeRecogniser { touchDownTime = CACurrentMediaTime() }
        return true
    }

    func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        if let pan = recogniser as? UIPanGestureRecognizer, pan === swipeRecogniser { return swipeShouldBegin(pan) }
        return true
    }

    /// What a tap in each zone does (spec, "Touch"): in paginated mode the
    /// sides turn the page and the centre shows the controls; in scroll mode
    /// any tap shows them. "Left" and "right" are sides of the screen;
    /// goLeft and goRight turn the right way for right-to-left books.
    private func handleTap(zone: String) {
        if state.flow == .scrolled || zone == "centre" {
            setOverlay(visible: !overlayVisible)
        } else if zone == "left" {
            turn(.left)
        } else {
            turn(.right)
        }
    }

    func close() {
        savePositionNow()
        onClose?()
    }

    // MARK: - Settings and theme

    var currentTheme: Theme { settings.theme(for: traitCollection) }

    func pushSettings() {
        applyTheme()
        guard bookSentToShell else { return }
        // Only when something changed: every new layout re-paginates the
        // book, and doing that while it is still opening loses the place.
        let payload = webPayload
        guard !(payload as NSDictionary).isEqual(to: lastPayload ?? [:]) else { return }
        lastPayload = payload
        callPlaten("setSettings", payload)
    }

    /// The settings for reader.js, with what differs on iOS:
    /// - `touch`: taps are recognised here (see `pageTapped`), so the page
    ///   reports no click zones of its own;
    /// - `animated` is off and `nativeSwipe` on: slides, curls and swipes
    ///   are all drawn natively (ReaderViewController+PageTurn), so the page
    ///   itself only ever turns instantly;
    /// - `sideMargin` and `verticalMargin`, in points: room at the sides (see
    ///   `sideMargin(compact:)`), and
    ///   above and below the text so it stays clear of the Dynamic Island,
    ///   the status bar and the home indicator.
    var webPayload: [String: Any] {
        var payload = settings.webPayload(theme: currentTheme, flow: state.flow)
        payload["touch"] = true
        // iPhone: one page always, in either orientation (spec, "Layout").
        // iPad: the Two Pages rule decides by width, as on the Mac, so two
        // pages appear in landscape and in wide Split View windows.
        if UIDevice.current.userInterfaceIdiom == .phone { payload["pageLayout"] = PageLayout.one.rawValue }
        payload["animated"] = false
        payload["nativeSwipe"] = true
        let insets = view.safeAreaInsets
        let compact = traitCollection.horizontalSizeClass == .compact
        payload["sideMargin"] = max(insets.left, insets.right) + sideMargin(compact: compact)
        // The status bar comes and goes with the controls, which changes the
        // top inset on some iPhones; the text must not move when it does, so
        // the largest inset seen in this window shape is kept.
        largestVerticalInset = max(largestVerticalInset, insets.top, insets.bottom)
        payload["verticalMargin"] = largestVerticalInset + (compact ? 12 : 24)
        return payload
    }

    /// Room at each side of the text. Line width (Narrow, Medium, Wide)
    /// caps a line at about 55, 66 or 80 characters, which on a phone are all
    /// wider than the screen; there it sets the margins instead, so the
    /// setting still visibly changes the line. Medium is the Books-like 24.
    private func sideMargin(compact: Bool) -> CGFloat {
        guard compact else { return 44 }
        switch settings.lineWidth {
        case .narrow: return 44
        case .medium: return 24
        case .wide: return 12
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        pushSettings() // margins follow the notch, rotation and Split View
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        largestVerticalInset = 0 // a new window shape: measure afresh
    }

    private func applyTheme() {
        let theme = currentTheme
        view.backgroundColor = theme.uiBackground
        // Our own controls follow the page's lightness, not the system's.
        overrideUserInterfaceStyle = theme.interfaceStyle
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - Saving

    func savePositionNow() {
        guard let record else { return }
        PositionStore.shared.saveNow(record)
    }

    // MARK: - Messages from JavaScript

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Every message is { type, body } (see post() in bridge.js).
        guard let envelope = message.body as? [String: Any], let type = envelope["type"] as? String else { return }
        let body = envelope["body"] as? [String: Any] ?? [:]
        // What the overlay and contents show is decoded in one place for
        // both apps (Shared/ReaderState+Messages.swift); the cases below add
        // the iOS app's own work.
        state.apply(message: type, body: body)
        switch type {
        case "ready":
            shellReady = true
            sendBookIfReady()

        case "firstRender":
            hasRendered = true
            spinner.stopAnimating()
            let elapsed = (CFAbsoluteTimeGetCurrent() - openStarted) * 1000
            log.info("First page visible after \(elapsed, format: .fixed(precision: 0)) ms")
            #if DEBUG
            runDebugStepsIfAny()
            #endif

        case "opened":
            sendBookmarksToPage()

        case "addBookmark":
            addBookmark(from: body)

        case "removeBookmark":
            if let cfi = body["cfi"] as? String { removeBookmark(cfi: cfi) }

        case "relocate":
            if let cfi = body["cfi"] as? String, var record {
                record.lastCFI = cfi
                self.record = record
                PositionStore.shared.scheduleSave(record) // debounced
                log.info("relocate \(cfi, privacy: .public)")
            }

        case "click":
            // Not sent on iOS (taps are recognised natively); kept so a
            // click from the page is never silently lost.
            handleTap(zone: body["zone"] as? String ?? "centre")

        case "selection":
            hasSelection = state.selection != nil

        case "externalLink":
            // Links to the web open in Safari (or Mail), never in the reader.
            if let href = body["href"] as? String, let link = URL(string: href),
               ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(link)
            }

        case "error":
            log.error("reader error: \(body["message"] as? String ?? "", privacy: .public)\n\(body["stack"] as? String ?? "", privacy: .public)")
            showFailure(BookOpenError.unreadable(body["message"] as? String ?? ""))

        case "log":
            log.notice("js: \(body["message"] as? String ?? "", privacy: .public)")

        default:
            // Contents, bookmarks, search and the rest arrive with the
            // shared reader session in phase 2.
            break
        }
    }

    // MARK: - Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the shell and its blob: iframes may load. Anything else (a book
        // trying to navigate the window) is refused.
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["platen", "blob", "about", "data"].contains(scheme) ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS ends web content processes under memory pressure, often while
        // the app is in the background. Reload and reopen at the last saved
        // position rather than leaving a blank page.
        log.error("Web content process terminated; reloading")
        shellReady = false
        bookSentToShell = false
        webView.load(URLRequest(url: ReaderSchemeHandler.shellURL))
    }

    #if DEBUG
    /// One scripted step (see DebugHooks.swift).
    func runDebugStep(_ step: String) {
        if step.hasPrefix("@tap:") {
            handleTap(zone: String(step.dropFirst(5)))
        } else if step == "@close" {
            close()
        } else if step == "@snapshot" {
            webView.takeSnapshot(with: nil) { image, _ in log.notice("snapshot \(image == nil ? "failed" : "taken")") }
        } else if step.hasPrefix("@turn:"), let request = PageTurnRequest(rawValue: String(step.dropFirst(6))) {
            turn(request)
        } else {
            webView.evaluateJavaScript(step) { result, _ in
                if let result = result as? String { log.notice("step result: \(result, privacy: .public)") }
            }
        }
    }
    #endif

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
