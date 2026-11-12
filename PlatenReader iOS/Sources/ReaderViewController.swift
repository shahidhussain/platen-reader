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
/// This is the M3 phase 1 reader: it opens the book in place, restores and
/// saves the reading position, turns pages on side taps and shows a simple
/// top bar with Close on a centre tap. The full overlay, contents, swipes
/// and settings follow in later phases (docs/m3-ios-plan.md); the shared
/// `ReaderSession` of phase 2 will take over most of the bookkeeping here.
///
/// Opening runs two things in parallel and joins them, as on the Mac:
/// 1. the web view loads the reader shell, and
/// 2. the book file is read and checked on a background queue.
/// When both are ready, the book is handed to the shell.
final class ReaderViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    let url: URL
    let schemeHandler = ReaderSchemeHandler()
    let settings = ReaderSettings.shared
    let state = ReaderState()

    /// Called when the reader taps Close; the document browser dismisses us.
    var onClose: (() -> Void)?

    private var webView: WKWebView!
    private var spinner: UIActivityIndicatorView!
    private var topBar: UIVisualEffectView!
    private var titleLabel: UILabel!
    private var failureHost: UIViewController?

    private var book: Book?
    private var record: BookRecord?
    private var shellReady = false
    private var bookSentToShell = false
    private var hasRendered = false
    private var openStarted = CFAbsoluteTimeGetCurrent()
    private var overlayVisible = false
    private var cancellables: Set<AnyCancellable> = []

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

        // Temporary top bar (phase 1): the book's title and a Close button.
        // The shared overlay replaces it in phase 3.
        topBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.alpha = 0
        topBar.isHidden = true
        root.addSubview(topBar)

        let close = UIButton(type: .system, primaryAction: UIAction(title: String(localized: "Close")) { [weak self] _ in
            self?.close()
        })
        close.translatesAutoresizingMaskIntoConstraints = false
        titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(close)
        topBar.contentView.addSubview(titleLabel)

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

            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.bottomAnchor.constraint(equalTo: safe.topAnchor, constant: 44),

            close.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            close.centerYAnchor.constraint(equalTo: safe.topAnchor, constant: 22),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: close.trailingAnchor, constant: 12),

            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.flow = settings.defaultFlow
        applyTheme()

        // Re-style whenever a global setting changes.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.pushSettings() }
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
                    self.titleLabel.text = book.title ?? url.deletingPathExtension().lastPathComponent
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
        view.insertSubview(host.view, belowSubview: topBar)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            host.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
        ])
        host.didMove(toParent: self)
        failureHost = host
        // With no page to read, keep Close on screen.
        titleLabel.text = url.deletingPathExtension().lastPathComponent
        setOverlay(visible: true)
    }

    // MARK: - Overlay

    private func setOverlay(visible: Bool) {
        overlayVisible = visible
        if visible { topBar.isHidden = false }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduceMotion ? 0 : 0.15, animations: {
            self.topBar.alpha = visible ? 1 : 0
            self.setNeedsStatusBarAppearanceUpdate()
        }, completion: { _ in
            // Hidden views take no taps, so the page underneath gets them.
            self.topBar.isHidden = !self.overlayVisible
        })
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    /// What a tap in each zone does (spec, "Touch"): in paginated mode the
    /// sides turn the page and the centre shows the controls; in scroll mode
    /// any tap shows them. The zone comes from input.js, which already
    /// mirrors it for right-to-left books.
    private func handleTap(zone: String) {
        if state.flow == .scrolled || zone == "centre" {
            setOverlay(visible: !overlayVisible)
        } else if zone == "left" {
            js("platen.goLeft()")
        } else {
            js("platen.goRight()")
        }
    }

    private func close() {
        savePositionNow()
        onClose?()
    }

    // MARK: - Settings and theme

    private var currentTheme: Theme { settings.theme(for: traitCollection) }

    private func pushSettings() {
        applyTheme()
        guard bookSentToShell else { return }
        callPlaten("setSettings", settings.webPayload(theme: currentTheme, flow: state.flow))
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
        guard var record else { return }
        record.readingMode = state.flow.rawValue
        PositionStore.shared.saveNow(record)
    }

    // MARK: - Messages from JavaScript

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Every message is { type, body } (see post() in bridge.js).
        guard let envelope = message.body as? [String: Any], let type = envelope["type"] as? String else { return }
        let body = envelope["body"] as? [String: Any] ?? [:]
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
            if let title = body["title"] as? String, !title.isEmpty {
                state.title = title
                titleLabel.text = title
            }
            state.author = body["author"] as? String ?? ""
            state.isFixedLayout = body["fixedLayout"] as? Bool ?? false
            state.isRightToLeft = (body["dir"] as? String) == "rtl"
            callPlaten("setBookmarks", state.bookmarks.map { ["cfi": $0.cfi] })

        case "relocate":
            state.fraction = (body["fraction"] as? NSNumber)?.doubleValue ?? state.fraction
            state.chapter = body["chapter"] as? String ?? ""
            if let cfi = body["cfi"] as? String, var record {
                record.lastCFI = cfi
                record.readingMode = state.flow.rawValue
                self.record = record
                PositionStore.shared.scheduleSave(record) // debounced
                log.info("relocate \(cfi, privacy: .public)")
            }

        case "click":
            handleTap(zone: body["zone"] as? String ?? "centre")

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
    private func js(_ script: String) {
        guard bookSentToShell else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Calls `platen.<function>(…)` in the reader page with values passed as
    /// real arguments (never pasted into the script), so any string is safe.
    private func callPlaten(_ function: String, _ arguments: Any...) {
        guard bookSentToShell else { return }
        var named: [String: Any] = [:]
        for (i, value) in arguments.enumerated() { named["a\(i)"] = value }
        let list = arguments.indices.map { "a\($0)" }.joined(separator: ", ")
        webView.callAsyncJavaScript("platen.\(function)(\(list))", arguments: named, in: nil, in: .page, completionHandler: nil)
    }
}
