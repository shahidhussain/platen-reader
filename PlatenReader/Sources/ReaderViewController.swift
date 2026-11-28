import AppKit
import Combine
import PlatenCore
import SwiftUI
import WebKit
import os

/// The reader for one book on the Mac: a web view running foliate-js, with
/// the controls, failure message and menu commands every book window has
/// (ReaderBaseViewController).
///
/// The book itself (reading the file, the saved position and bookmarks, the
/// conversation with reader.js) is a `BookSession`, shared with the iOS app.
/// This class is the session's host: it adds what is the Mac's own, split by
/// job across the `ReaderViewController+*.swift` files (input, page turn,
/// contents and citation, menu, pictures).
final class ReaderViewController: ReaderBaseViewController, BookSessionHost {
    let session: BookSession

    var webView: ReaderWebView!
    /// What VoiceOver reads: the text on screen (see BookPageAccessibilityView).
    let bookPage = BookPageAccessibilityView()
    var explainerHost: NSView?
    var imageZoom: ImageZoomView?
    var scrollMonitor: Any?
    var keyMonitor: Any?
    var swipe = SwipeTracker()
    var pageTurn: PageTurnView?
    /// Counts turns, so a turn that was overtaken by a newer one is dropped.
    var turnGeneration = 0
    /// When the last page turn was asked for, to spot rapid key presses.
    var lastTurnRequest: TimeInterval = 0
    private var voiceOverObservation: NSKeyValueObservation?
    /// Behind the page: a soft glow of its own colours (Ambient Light, as on
    /// iOS; ReaderViewController+Glow), with the page see-through.
    let ambient = PassThroughImageView()
    var ambientWork: DispatchWorkItem?
    /// The glow's edge mask, made for one window size.
    var ambientMask: (size: CGSize, image: CGImage)?
    /// The theme (its page colour) the glow on show was made in.
    var glowTheme: String?
    /// A page that is only a picture, shown full size over the page (as on
    /// iOS; the page hides its own, smaller copy).
    let lonePictureView = PassThroughImageView()
    /// A turn waiting for a picture-only page's picture (settleLonePicture).
    var lonePictureWaiter: (() -> Void)?

    init(document: BookDocument) {
        let state = ReaderState()
        // A document always has a file; without one, opening fails with the
        // usual message rather than leaving an empty window.
        session = BookSession(url: document.fileURL ?? URL(fileURLWithPath: ""), state: state)
        super.init(document: document, state: state)
        session.host = self
        session.onPageMovedByHand = { [weak self] in self?.readAloudStarter.pageMovedByHand() }
    }

    override var commands: ReaderCommands { session }
    // Read aloud: the speaker on the bar, reading through the session.
    override var offersReadAloud: Bool { true }
    override var readAloudSource: ReadAloudSource? { session }
    override var pageView: NSView { webView }
    override var isReady: Bool { session.book != nil }
    override var hasShownPage: Bool { session.hasRendered }

    // MARK: - View setup

    override func loadView() {
        let root = ReaderRootView()
        root.wantsLayer = true

        // The glow lies behind the page, filling the window.
        ambient.translatesAutoresizingMaskIntoConstraints = false
        ambient.imageScaling = .scaleAxesIndependently
        ambient.isHidden = true
        root.addSubview(ambient)

        webView = ReaderWebView(frame: .zero, configuration: session.makeConfiguration())
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground") // the page draws the theme colour
        webView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        webView.menuCustomiser = { [weak self] menu in self?.customiseContextMenu(menu) }
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)

        // A picture-only page's picture, full size, over the page.
        lonePictureView.translatesAutoresizingMaskIntoConstraints = false
        lonePictureView.imageScaling = .scaleProportionallyUpOrDown
        lonePictureView.wantsLayer = true
        lonePictureView.isHidden = true
        lonePictureView.setAccessibilityElement(false)
        root.addSubview(lonePictureView)

        // VoiceOver reads the book through this stand-in, not the web view.
        bookPage.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bookPage)
        root.hiddenFromAccessibility = webView
        webView.accessibilityStandIn = bookPage

        let pictureMargin: CGFloat = 16
        NSLayoutConstraint.activate([
            ambient.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ambient.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ambient.topAnchor.constraint(equalTo: root.topAnchor),
            ambient.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // Clear of the title bar at the top (the window's safe area).
            lonePictureView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pictureMargin),
            lonePictureView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pictureMargin),
            lonePictureView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: pictureMargin),
            lonePictureView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pictureMargin),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bookPage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bookPage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bookPage.topAnchor.constraint(equalTo: root.topAnchor),
            bookPage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        installChrome(in: root)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        session.start(in: webView)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installScrollMonitor()
        // VoiceOver turned on or off while a book is open.
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] workspace, _ in
            DispatchQueue.main.async { self?.session.setVoiceOver(workspace.isVoiceOverEnabled) }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        scrollMonitor = nil
        keyMonitor = nil
    }

    // MARK: - Settings and the window

    override func applySettings() {
        super.applySettings()
        session.pushSettings()
        updateAmbient()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateAmbient(layoutOnly: true) // the glow's edges follow the window's size
    }

    override func savePositionNow() { session.savePositionNow() }

    /// Settings shows a note when Two Pages is chosen but the front book
    /// window is too narrow for them.
    override func reportLayoutToSettings() {
        guard view.window?.isKeyWindow == true else { return }
        let narrow = state.twoPagesTooNarrow
        if FrontWindowLayout.shared.tooNarrowForTwoPages != narrow { FrontWindowLayout.shared.tooNarrowForTwoPages = narrow }
    }

    override func showFailure(_ error: Error) {
        webView.isHidden = true
        super.showFailure(error)
    }

    // MARK: - The session's host

    func sessionDidFail(_ error: Error) { showFailure(error) }

    func sessionDidRenderFirstPage() {
        spinner.stopAnimation(nil)
        firstPageShown()
        #if DEBUG
        DebugHooks.afterFirstRender(webView: webView, bookName: document.fileURL?.deletingPathExtension().lastPathComponent ?? "book",
                                    root: view) { [weak self] step in self?.runDebugStep(step) }
        #endif
    }

    /// The press's picture: the page as the web view draws it.
    override func pressPicture(_ done: @escaping (CGImage?) -> Void) {
        webView.takeSnapshot(with: nil) { image, _ in
            done(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    func sessionDidOpen() {
        view.window?.windowController?.synchronizeWindowTitleWithDocumentName()
        showFirstRunExplainerIfNeeded()
        // VoiceOver: name the page after the book, and let the page know
        // whether VoiceOver is on (it then follows page turns).
        bookPage.name = state.title
        session.setVoiceOver(NSWorkspace.shared.isVoiceOverEnabled)
    }

    func sessionDidRelocate() {
        #if DEBUG
        if let started = DebugHooks.resizeStarted {
            DebugHooks.resizeStarted = nil
            log.info("Re-laid out after resize in \((CFAbsoluteTimeGetCurrent() - started) * 1000, format: .fixed(precision: 0)) ms")
        }
        #endif
        reportLayoutToSettings()
        view.window?.subtitle = state.chapter
        updateAmbient()
    }

    func sessionDidJump() {
        view.window?.makeFirstResponder(webView)
    }

    func sessionDidChangeFlow() {
        // Briefly show the click zones for the new mode, for the first three
        // switches only.
        let count = AppDefaults.store.integer(forKey: ReadingControlsExplainer.switchCountKey)
        if count < 3 {
            AppDefaults.store.set(count + 1, forKey: ReadingControlsExplainer.switchCountKey)
            showExplainer(flash: true)
        }
    }

    func sessionClicked(_ zone: ClickZone) { handleClick(zone: zone) }

    func sessionShowPicture(_ picture: ReaderMessage.Picture) { showImage(picture) }

    /// The text on screen, for VoiceOver (see accessibility.js). It becomes
    /// the page VoiceOver reads, and is read out at once when the page has
    /// just turned (or R was pressed).
    func sessionPageText(_ text: String, speak: Bool) {
        bookPage.text = text
        if speak, !text.isEmpty, NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: view.window as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    func sessionAnnounce(_ text: String) {
        NSAccessibility.post(element: webView as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func sessionOpenExternalLink(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - Keys and menus only books have
    //
    // (Overrides have to be in the class itself, not in an extension.)

    /// R: VoiceOver reads the page on screen again.
    override func handleOwnKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "r",
              NSWorkspace.shared.isVoiceOverEnabled else { return false }
        session.readPage()
        return true
    }

    /// Scroll mode: the arrow keys move by a few lines.
    override func scrollByKey(lines: Int) -> Bool {
        session.scroll(lines: lines)
        return true
    }

    /// Esc closes whatever is on top first: a footnote, a zoomed picture or
    /// the click-zone explainer; then the panel and overlay, as in any book
    /// window.
    override func handleEscape() -> Bool {
        if state.noteOpen {
            session.closeNote()
        } else if imageZoom != nil {
            closeImage()
        } else if explainerHost != nil {
            dismissExplainer()
        } else {
            return super.handleEscape()
        }
        return true
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        // (Titled for text again: Home calls them Bigger and Smaller Covers.)
        case #selector(makeTextBigger(_:)):
            item.title = String(localized: "Larger Text")
            return !state.isFixedLayout && settings.fontSizeIndex < ReaderSettings.fontSizes.count - 1
        case #selector(makeTextSmaller(_:)):
            item.title = String(localized: "Smaller Text")
            return !state.isFixedLayout && settings.fontSizeIndex > 0
        case #selector(makeTextDefaultSize(_:)):
            item.title = String(localized: "Default Text Size")
            return !state.isFixedLayout
        case #selector(copyWithCitation(_:)), #selector(shareSelection(_:)), #selector(searchForSelection(_:)):
            return isReady && failureHost == nil && state.selection != nil
        default:
            return super.validateMenuItem(item)
        }
    }

    // MARK: - Click-zone explainer

    /// The click zones are shown over the page for the first few books
    /// opened, until the reader has had a chance to learn them. Any click
    /// dismisses them.
    func showFirstRunExplainerIfNeeded() {
        let key = ReadingControlsExplainer.shownCountKey
        let count = AppDefaults.store.integer(forKey: key)
        guard count < ReadingControlsExplainer.opensToShow else { return }
        AppDefaults.store.set(count + 1, forKey: key)
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
        view.addSubview(host, positioned: .below, relativeTo: chrome.overlayView)
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
}
