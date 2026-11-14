import Combine
import PlatenCore
import SwiftUI
import UIKit

/// What every reader screen has on iOS, whatever it shows: access to the
/// file, the controls over the page (ReaderChrome), the quiet progress
/// indicator, the failure message, the theme, and Close.
///
/// `ReaderViewController` (books, drawn by the web view) and
/// `PDFReaderViewController` (PDFs, drawn by PDFKit) are its two subclasses.
/// Each adds its page view and says how to carry out the commands
/// (`commands`). The Mac app has a class of the same name and shape.
class ReaderBaseViewController: UIViewController {
    let url: URL
    let state: ReaderState
    let settings = ReaderSettings.shared

    /// Called when the reader taps Close; the document browser dismisses us.
    var onClose: (() -> Void)?

    private(set) var chrome: ReaderChrome!
    private(set) var spinner: UIActivityIndicatorView!
    private(set) var failureHost: UIViewController?
    var cancellables: Set<AnyCancellable> = []

    /// True while we hold access to a file outside our sandbox (a book in
    /// Files, iCloud Drive or a file provider). Released when the reader
    /// goes away. Large books are read lazily, so access must last as long
    /// as the book is open, not just while it opens.
    private var accessingSecurityScope = false

    init(url: URL, state: ReaderState) {
        self.url = url
        self.state = state
        super.init(nibName: nil, bundle: nil)
        accessingSecurityScope = url.startAccessingSecurityScopedResource()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if accessingSecurityScope { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: - For subclasses

    /// Carries out the commands: the book's session, or the PDF reader.
    var commands: ReaderCommands { fatalError("subclasses say how commands are carried out") }
    /// The view that draws the page.
    var pageView: UIView { fatalError("subclasses provide the page view") }
    /// A page is on screen (until then, a slow open shows the spinner).
    var hasShownPage: Bool { false }
    /// The title when nothing could be opened and no better one is known.
    var failureFallbackTitle: String { String(localized: "This book could not be opened.") }
    /// Whether the settings sheet leaves out the text controls.
    var hidesTextSettings: Bool { state.isFixedLayout }

    /// A setting or the system's appearance changed: re-style.
    func applySettings() { applyTheme() }
    func savePositionNow() {}

    // MARK: - View setup

    /// Call at the end of `loadView`, once the page view is in `root`: adds
    /// the controls and the progress indicator above it.
    func installChrome(in root: UIView) {
        let actions = OverlayActions(
            commands: commands,
            toggleContents: { [weak self] in
                self?.state.sidebarVisible.toggle()
                self?.chrome.restartHideTimer()
            },
            interacted: { [weak self] in self?.chrome.restartHideTimer() },
            openSettings: { [weak self] in
                guard let self else { return }
                self.presentReaderSettings(isFixedLayout: self.hidesTextSettings, chrome: self.chrome)
            })
        let chrome = ReaderChrome(owner: self, state: state, actions: actions,
                                  sidebarActions: ContentsActions(commands: commands),
                                  close: { [weak self] in self?.close() },
                                  // Search highlights are temporary: they go
                                  // when the panel closes.
                                  sidebarClosed: { [weak self] in self?.commands.searchPanelClosed() })
        chrome.install(in: root)
        self.chrome = chrome

        // Quiet progress indicator, shown only if opening takes > 500 ms.
        spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyTheme()

        // Re-style whenever a global setting changes.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applySettings() }
            .store(in: &cancellables)

        // Follow the system's Light and Dark switch (Automatic appearance).
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (reader: ReaderBaseViewController, _) in
            reader.applySettings()
        }

        // Save when the app leaves the screen; it may be ended after that.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.savePositionNow() }
            .store(in: &cancellables)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.hasShownPage, self.failureHost == nil else { return }
            self.spinner.startAnimating()
        }
    }

    // The status bar and home indicator are hidden while reading and come
    // back with the controls (spec, "Layout").
    override var prefersStatusBarHidden: Bool { !(chrome?.isVisible ?? false) }
    override var prefersHomeIndicatorAutoHidden: Bool { !(chrome?.isVisible ?? false) }
    override var preferredStatusBarStyle: UIStatusBarStyle { currentTheme.isDark ? .lightContent : .darkContent }

    // MARK: - Failure and closing

    /// Shows why the book could not be opened, in place of the page.
    func showFailure(_ error: Error) {
        spinner.stopAnimating()
        guard failureHost == nil else { return }
        let host = UIHostingController(rootView: OpenFailureView(error: error, fallback: failureFallbackTitle))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.insertSubview(host.view, belowSubview: chrome.top.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            host.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
        ])
        host.didMove(toParent: self)
        failureHost = host
        // With no page to read, keep Close on screen (and nothing else).
        if state.title.isEmpty { state.title = url.deletingPathExtension().lastPathComponent }
        chrome.showCloseOnly()
    }

    func close() {
        savePositionNow()
        onClose?()
    }

    // MARK: - Theme

    var currentTheme: Theme { settings.theme(for: traitCollection) }

    /// The colour around the page, and our own controls following the page's
    /// lightness rather than the system's.
    func applyTheme() {
        let theme = currentTheme
        view.backgroundColor = theme.uiBackground
        overrideUserInterfaceStyle = theme.interfaceStyle
        setNeedsStatusBarAppearanceUpdate()
    }
}
