import Combine
import PlatenCore
import SwiftUI
import UIKit
import WebKit

/// The reader for one book on iOS and iPadOS: a web view running the same
/// shell and foliate-js as the Mac, with the controls, failure message and
/// Close button every reader screen has (ReaderBaseViewController).
///
/// The book itself (reading the file in place, the saved position and
/// bookmarks, the conversation with reader.js) is a `BookSession`, shared
/// with the Mac app. This class is the session's host: it adds what is
/// touch's own. Taps and the page's margins are here; page turns and swipes
/// are in ReaderViewController+PageTurn, hardware keys in +Keys.
final class ReaderViewController: ReaderBaseViewController, BookSessionHost, UIGestureRecognizerDelegate {
    let session: BookSession

    var webView: WKWebView!
    /// Whether text was selected just before the latest tap (reported by
    /// reader.js). A tap then only dismisses the selection.
    var hasSelection: Bool { state.selection != nil }
    /// Draws page turns and swipes (ReaderViewController+PageTurn).
    lazy var pageTurner = makePageTurnAnimator()
    var swipeRecogniser: UIPanGestureRecognizer?
    /// When the latest finger touched down (a swipe after a long hold is
    /// text selection, not a page turn).
    var touchDownTime: CFTimeInterval?
    /// See `adjust(_:)`.
    private var largestVerticalInset: CGFloat = 0

    init(url: URL) {
        let state = ReaderState()
        session = BookSession(url: url, state: state)
        super.init(url: url, state: state)
        session.host = self
    }

    override var commands: ReaderCommands { session }
    override var pageView: UIView { webView }
    override var hasShownPage: Bool { session.hasRendered }

    // MARK: - View setup

    override func loadView() {
        let root = UIView()

        // Web view, configured as on the Mac (BookSession.makeConfiguration).
        let config = session.makeConfiguration()
        config.allowsInlineMediaPlayback = true // audio and video play in the page

        webView = WKWebView(frame: .zero, configuration: config)
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

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        installChrome(in: root)
        // While the controls are up, the page number steps aside for their
        // location line, which sits in the same place.
        chrome.onVisibilityChanged = { [weak self] visible in self?.session.setControlsVisible(visible) }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.allowsTwoPages = UIDevice.current.userInterfaceIdiom != .phone
        session.start(in: webView)
    }

    // MARK: - Taps

    @objc private func pageTapped(_ recogniser: UITapGestureRecognizer) {
        guard recogniser.state == .ended, session.hasRendered, failureHost == nil else { return }
        // A tap on selected text only dismisses the selection (WebKit does
        // that itself).
        if hasSelection { return }
        let point = recogniser.location(in: webView)
        // Ask the page what is under the finger: links, pictures and the
        // bookmark ribbons handle their own taps.
        session.tapTarget(at: point) { [weak self] target in
            guard let self else { return }
            log.info("tap at \(Int(point.x)),\(Int(point.y)): \(target.rawValue, privacy: .public)")
            guard target == .page else { return }
            self.handleTap(zone: ClickZone(x: point.x, width: self.webView.bounds.width))
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
    /// any tap shows them. "Left" and "right" are sides of the screen; the
    /// page turns the right way for right-to-left books.
    func handleTap(zone: ClickZone) {
        if state.flow == .scrolled || zone == .centre {
            chrome.toggle()
        } else {
            session.turn(zone == .left ? .left : .right)
        }
    }

    // MARK: - Settings

    override func applySettings() {
        super.applySettings()
        session.pushSettings()
    }

    override func savePositionNow() { session.savePositionNow() }

    /// What differs in the page's settings on iOS:
    /// - `touch`: taps are recognised here (see `pageTapped`), so the page
    ///   reports no click zones of its own;
    /// - `animated` is off and `nativeSwipe` on: slides, curls and swipes
    ///   are all drawn natively (ReaderViewController+PageTurn), so the page
    ///   itself only ever turns instantly;
    /// - `sideMargin` and `verticalMargin`, in points: room at the sides (see
    ///   `sideMargin(compact:)`), and above and below the text so it stays
    ///   clear of the Dynamic Island, the status bar and the home indicator.
    func adjust(_ web: inout WebSettings) {
        web.touch = true
        // iPhone: one page always, in either orientation (spec, "Layout").
        // iPad: the Two Pages rule decides by width, as on the Mac, so two
        // pages appear in landscape and in wide Split View windows.
        if UIDevice.current.userInterfaceIdiom == .phone { web.pageLayout = .one }
        web.animated = false
        web.nativeSwipe = true
        let insets = view.safeAreaInsets
        let compact = traitCollection.horizontalSizeClass == .compact
        web.sideMargin = Double(max(insets.left, insets.right) + sideMargin(compact: compact))
        // The status bar comes and goes with the controls, which changes the
        // top inset on some iPhones; the text must not move when it does, so
        // the largest inset seen in this window shape is kept.
        largestVerticalInset = max(largestVerticalInset, insets.top, insets.bottom)
        web.verticalMargin = Double(largestVerticalInset + (compact ? 12 : 24))
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
        session.pushSettings() // margins follow the notch, rotation and Split View
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        largestVerticalInset = 0 // a new window shape: measure afresh
    }

    // MARK: - The session's host

    func sessionDidLoadBook() {
        // A book with no title of its own is called by its file name.
        if state.title.isEmpty { state.title = url.deletingPathExtension().lastPathComponent }
    }

    func sessionDidFail(_ error: Error) {
        webView.isHidden = true
        showFailure(error)
    }

    func sessionDidRenderFirstPage() {
        spinner.stopAnimating()
        #if DEBUG
        runDebugStepsIfAny()
        #endif
    }

    func sessionDidOpen() {}

    func sessionDidRelocate() {
        log.info("relocate \(self.session.record?.lastCFI ?? "", privacy: .public)")
    }

    /// Not sent on iOS (taps are recognised natively); handled so a click
    /// from the page is never silently lost.
    func sessionClicked(_ zone: ClickZone) { handleTap(zone: zone) }

    func sessionAnnounce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Links to the web open in Safari (or Mail), never in the reader.
    func sessionOpenExternalLink(_ url: URL) {
        UIApplication.shared.open(url)
    }

    // Picture zoom, the click-zone explainer and VoiceOver's page text are
    // still to come on iOS (docs/m3-ios-plan.md); the session already
    // delivers what they need (`sessionShowPicture`, `sessionPageText`).

    #if DEBUG
    /// One scripted step (see DebugHooks.swift).
    override func runDebugStep(_ step: String) {
        if step.hasPrefix("@tap:"), let zone = ClickZone(rawValue: String(step.dropFirst(5))) {
            handleTap(zone: zone)
        } else if step == "@close" || step == "@orientation" {
            super.runDebugStep(step)
        } else if step == "@snapshot" {
            webView.takeSnapshot(with: nil) { image, _ in log.notice("snapshot \(image == nil ? "failed" : "taken")") }
        } else if step.hasPrefix("@turn:"), let turn = PageTurn(rawValue: String(step.dropFirst(6))) {
            session.turn(turn)
        } else if step.hasPrefix("@doubleturn:"), let turn = PageTurn(rawValue: String(step.dropFirst(12))) {
            // A second turn while the first is still drawn (fast taps).
            session.turn(turn)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.session.turn(turn) }
        } else {
            webView.evaluateJavaScript(step) { result, _ in
                if let result = result as? String { log.notice("step result: \(result, privacy: .public)") }
            }
        }
    }
    #endif
}
