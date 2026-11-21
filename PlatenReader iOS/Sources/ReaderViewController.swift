import AVFoundation
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
    /// The page view and the native picture together (what page turns move).
    private(set) var pageArea: UIView!
    /// A page that is just one picture, shown as large as the screen
    /// allows, touching its sides or its top and bottom, with no bars.
    private(set) var lonePictureView: UIImageView!
    /// The glow behind the page (ambient light), and its next renewal.
    private(set) var ambient: AmbientGlowView!
    private var ambientWork: DispatchWorkItem?
    private var ambientMaskSize: CGSize = .zero
    private var ambientMask: UIImage?
    /// A turn waiting for a picture-only page's picture (settleLonePicture).
    private var lonePictureWaiter: (() -> Void)?
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
        // The page and, over it, a page that is just one picture shown
        // natively (sessionShowLonePicture): together, so page turns move
        // and photograph them as one.
        // Ambient light: a soft glow of the page's own colours behind the
        // book, whose page is then see-through (`usesAmbientLight`). It is
        // behind the page area, not in it: pages slide over it while it
        // fades from one page's glow to the next (AmbientGlowView); a curl
        // carries the old page's glow in its picture.
        ambient = AmbientGlowView()
        ambient.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(ambient)
        pageArea = UIView()
        pageArea.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pageArea)
        pageArea.addSubview(webView)
        lonePictureView = UIImageView()
        lonePictureView.translatesAutoresizingMaskIntoConstraints = false
        lonePictureView.contentMode = .scaleAspectFit
        lonePictureView.isUserInteractionEnabled = false // taps reach the page
        lonePictureView.isAccessibilityElement = false
        lonePictureView.isHidden = true
        pageArea.addSubview(lonePictureView)

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
        // A finger held on a picture offers to save or share it.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pagePressed(_:)))
        press.delegate = self
        webView.addGestureRecognizer(press)
        installSwipeRecogniser()

        NSLayoutConstraint.activate([
            ambient.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ambient.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ambient.topAnchor.constraint(equalTo: root.topAnchor),
            ambient.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pageArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageArea.topAnchor.constraint(equalTo: root.topAnchor),
            pageArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            webView.topAnchor.constraint(equalTo: pageArea.topAnchor),
            webView.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor),
            lonePictureView.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            lonePictureView.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            lonePictureView.topAnchor.constraint(equalTo: pageArea.topAnchor),
            lonePictureView.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor),
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

    /// A finger held on the page: if it is on a picture, the page sends it
    /// (sessionShowPicture), which offers Save and Share. Elsewhere, WebKit
    /// selects text as usual.
    @objc private func pagePressed(_ recogniser: UILongPressGestureRecognizer) {
        guard recogniser.state == .began, session.hasRendered else { return }
        session.pictureAt(recogniser.location(in: webView)) { _ in }
    }

    /// The page on screen is just one picture: shown natively over the page
    /// (whose own, smaller copy the page hides), or taken away. The room
    /// around it (above and below a cover on a tall phone) is the page's
    /// own colour, plain, so the picture sits on the page rather than in a
    /// strip of glow (design review, 21 Nov 2026).
    func sessionShowLonePicture(_ data: Data?) {
        let image = data.flatMap(UIImage.init(data:))
        lonePictureView.backgroundColor = currentTheme.uiBackground
        lonePictureView.image = image
        lonePictureView.isHidden = image == nil
        if let waiting = lonePictureWaiter {
            lonePictureWaiter = nil
            waiting()
        } else {
            updateAmbient()
        }
    }

    /// Before a turned page is drawn: the native picture brought in line
    /// with it (hidden if the new page is not a picture-only page; if it is
    /// a new one, its picture waited for, briefly), so the page and its glow
    /// arrive as they will stay.
    func settleLonePicture(_ done: @escaping () -> Void) {
        session.lonePictureState { [weak self] state in
            guard let self else { return done() }
            switch state {
            case "same":
                done()
            case "new":
                var finished = false
                let finish = { if !finished { finished = true; done() } }
                self.lonePictureWaiter = finish
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.lonePictureWaiter = nil
                    finish()
                }
            default:
                self.lonePictureView.image = nil
                self.lonePictureView.isHidden = true
                done()
            }
        }
    }

    /// A picture of the page area as it is: the web view's snapshot, with
    /// the native picture drawn over it when it is showing. A curl asks for
    /// the glow under it too (`withGlow`), so the old page curls away with
    /// its own glow; a slide's picture is the page alone, over the glow that
    /// stays; the glow itself is made from a picture without one.
    func pageSnapshot(_ configuration: WKSnapshotConfiguration?, withGlow: Bool = false,
                      done: @escaping (UIImage?) -> Void) {
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, let image else { return done(image) }
            let picture = self.lonePictureView.isHidden ? nil : self.lonePictureView.image
            let glow = withGlow && !self.ambient.isHidden ? self.ambient.image : nil
            guard picture != nil || glow != nil else { return done(image) }
            let bounds = CGRect(origin: .zero, size: image.size)
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            done(UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                if let glow {
                    self.currentTheme.uiBackground.setFill()
                    UIRectFill(bounds)
                    glow.draw(in: bounds)
                }
                image.draw(in: bounds)
                if let picture { picture.draw(in: AVMakeRect(aspectRatio: picture.size, insideRect: bounds)) }
            })
        }
    }

    func sessionShowPicture(_ picture: ReaderMessage.Picture) {
        guard let image = UIImage(data: picture.data) else { return }
        // A picture, not text: drop any selection WebKit's own long press
        // began.
        webView.evaluateJavaScript("for (const { doc } of platen.view.renderer.getContents()) doc.getSelection()?.removeAllRanges()")
        let ext = picture.mimeType.split(separator: "/").last.map { $0 == "jpeg" ? "jpg" : String($0) } ?? "png"
        let base = state.title.isEmpty ? url.deletingPathExtension().lastPathComponent : state.title
        let name = picture.alt.isEmpty ? String(localized: "\(base), picture") : picture.alt
        offerPicture(image, file: (picture.data, ext), name: String(name.prefix(80)),
                     from: picture.rect.intersection(webView.bounds), in: webView)
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
        updateAmbient()
    }

    // MARK: - Ambient light

    /// Ambient light (Aa > Ambient Light) in every theme but Black, whose
    /// point is a black screen: the page is see-through, and a glow of what
    /// is on it (its pictures; text pages stay near the theme's colour)
    /// lies behind it, as for PDFs.
    var usesAmbientLight: Bool { settings.ambientLight && currentTheme != .black }

    /// The glow shows only towards the screen's edges, as light spilling
    /// from behind a television: strongest at the edge, gone some way in,
    /// so the text sits on the theme's own colour.
    func updateAmbientMask() {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0, ambientMaskSize != size else { return }
        ambientMaskSize = size
        let edge: CGFloat = 70
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let colours = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours,
                                            locations: [0, 1]) else { return }
            // Four edges, each fading inwards; corners get both.
            let w = size.width, h = size.height
            for (start, end) in [(CGPoint(x: 0, y: 0), CGPoint(x: edge, y: 0)),
                                 (CGPoint(x: w, y: 0), CGPoint(x: w - edge, y: 0)),
                                 (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: edge)),
                                 (CGPoint(x: 0, y: h), CGPoint(x: 0, y: h - edge))] {
                cg.drawLinearGradient(gradient, start: start, end: end, options: [])
            }
        }
        ambientMask = image
    }

    /// The glow, stretched to the screen and faded towards the middle (the
    /// edge mask drawn in): ready to show, and to draw into page pictures.
    private func maskedGlow(_ glow: UIImage) -> UIImage? {
        guard let mask = ambientMask else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // a blur: points are plenty
        return UIGraphicsImageRenderer(size: mask.size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: mask.size)
            glow.draw(in: bounds)
            mask.draw(in: bounds, blendMode: .destinationIn, alpha: 1)
        }
    }

    /// Makes the glow for the page now on screen and shows it at once, then
    /// calls `done`: page turns call this after turning underneath and
    /// before animating, so the new page arrives with its glow.
    func makeGlowNow(_ done: @escaping () -> Void) {
        guard usesAmbientLight, session.hasRendered else { return done() }
        ambientWork?.cancel()
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 48
        let theme = currentTheme.uiBackground
        pageSnapshot(config) { [weak self] image in
            guard let self, let image else { return done() }
            PDFAmbientBackground.make(from: image, theme: theme) { [weak self] glow in
                // During a slide this is the page sliding in: it fades in
                // with the slide (AmbientGlowView).
                if let self, let glow, let masked = self.maskedGlow(glow) { self.ambient.show(masked) }
                done()
            }
        }
    }

    /// Makes the glow from a small picture of the page as it is now, after a
    /// moment (turns come in runs), and fades it in.
    func updateAmbient() {
        ambient.isHidden = !usesAmbientLight
        updateAmbientMask()
        // During a turn the turn itself brings the new glow (makeGlowNow).
        guard usesAmbientLight, session.hasRendered, !pageTurner.isBusy else { return }
        ambientWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 48
            let theme = self.currentTheme.uiBackground
            self.pageSnapshot(config) { [weak self] image in
                guard let self, let image else { return }
                PDFAmbientBackground.make(from: image, theme: theme) { [weak self] glow in
                    guard let self, let glow, self.usesAmbientLight, !self.pageTurner.isBusy,
                          let masked = self.maskedGlow(glow) else { return }
                    // The first glow is there from the start; later ones
                    // (a jump, a new setting) fade from the old.
                    let fade = self.ambient.image == nil || UIAccessibility.isReduceMotionEnabled ? 0 : 0.35
                    self.ambient.show(masked, fade: fade)
                }
            }
        }
        ambientWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
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
        web.transparent = usesAmbientLight
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
    /// caps a line at about 58, 68 or 80 characters, which on a phone are all
    /// wider than the screen; there it sets the margins instead, so the
    /// setting still visibly changes the line. Medium is 30, a little more
    /// than Apple Books, so the text does not crowd the screen's edges.
    private func sideMargin(compact: Bool) -> CGFloat {
        guard compact else { return 44 }
        switch settings.lineWidth {
        case .narrow: return 46
        case .medium: return 30
        case .wide: return 18
        }
    }

    override func applyTheme() {
        super.applyTheme()
        lonePictureView?.backgroundColor = currentTheme.uiBackground
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateAmbientMask() // the glow's edges follow the window's size
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
        updateAmbient()
        spinner.stopAnimating()
        #if DEBUG
        runDebugStepsIfAny()
        #endif
    }

    func sessionDidOpen() {}

    func sessionDidRelocate() {
        updateAmbient()
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
    // delivers what they need (`sessionPageText`). A held picture offers
    // Save and Share (`sessionShowPicture`, above).

    #if DEBUG
    /// One scripted step (see DebugHooks.swift).
    override func runDebugStep(_ step: String) {
        if step.hasPrefix("@tap:"), let zone = ClickZone(rawValue: String(step.dropFirst(5))) {
            handleTap(zone: zone)
        } else if step == "@close" || step == "@orientation" || step.hasPrefix("@theme:") {
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
