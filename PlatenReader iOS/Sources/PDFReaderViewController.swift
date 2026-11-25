import Combine
import PDFKit
import PlatenCore
import SwiftUI
import UIKit

/// The reader for a PDF on iOS and iPadOS (spec, "PDF"). PDFKit draws the
/// pages; the overlay, contents, bookmarks and search are the same as for
/// books (ReaderChrome, and the shared PDFReaderModel).
///
/// Three layouts, chosen with the overlay's Layout button (the same settings
/// as for books, on iPhone and iPad alike):
/// - **One Page:** one page at a time in either orientation, fitted to the
///   screen, for PDFs whose pages are pictures in landscape (or portrait); a
///   swipe follows the finger (PageTurnAnimator, as in books).
/// - **Two Pages:** one page in portrait, as above; in landscape, two pages
///   side by side, touching, so a scanned spread reads as one. The pairing
///   starts at the page the reader was on when they rotated, and holds: each
///   turn moves two pages, and a curl turns one page about the spine. If the pairs look wrong (some PDFs have an extra
///   cover page), rotating back, turning one page and rotating again fixes
///   them. Rotating back shows the pair's left page.
/// - **Scroll:** one long column of pages, scrolled up and down.
final class PDFReaderViewController: ReaderBaseViewController, ReaderCommands, UIGestureRecognizerDelegate {
    private(set) var pdfView: PDFView!
    /// Behind the pages: their own colours, softened (PDFAmbientBackground).
    private var ambient: AmbientGlowView!
    /// What the ambient background was last made for (pages and theme), so
    /// it is only remade when that changes.
    private var ambientKey: String?
    private var ribbon: BookmarkRibbonView!
    /// Watches the PDF view's scrolling (Scroll layout, zoom), so the ribbon
    /// moves with its page.
    private var scrollObservation: NSKeyValueObservation?
    private var model: PDFReaderModel?
    /// Read aloud, made the first time the speaker is tapped (PDFReadAloud).
    private var pdfReadAloud: PDFReadAloud?
    /// The glow's wait for a zoom or move to settle (`ambientAfterZoom`).
    private var ambientZoomWait: DispatchWorkItem?
    /// Read aloud is turning the page (so it is not a turn by hand).
    private var movingForReadAloud = false
    /// Read aloud's underline: annotations on the pages (never saved).
    private var readAloudAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []

    // Read aloud: the speaker button (ReaderBaseViewController+ReadAloud),
    // reading through PDFReadAloud, with this reader as its page.
    override var offersReadAloud: Bool { true }
    override var readAloudSource: ReadAloudSource? {
        if pdfReadAloud == nil, let model { pdfReadAloud = PDFReadAloud(model: model, host: self) }
        return pdfReadAloud
    }
    /// Landscape: whether the pairs start at an odd page (see the type's
    /// notes). Decided when the reader rotates to landscape.
    private var spreadsStartOdd = false
    private var isLandscape = false
    /// Two pages side by side on screen now (Two Pages, in landscape).
    private var isSpread = false
    /// The scale at which the pages on show fill the screen (`fillScreen`);
    /// nil in Scroll, where PDFKit fits the pages to the width.
    private var fitScale: CGFloat?
    /// Text was selected before the latest tap; that tap only clears it.
    private var hadSelection = false
    /// Holds the pages and the ribbon, so a slide or a swipe moves them
    /// together: a new page arrives with its ribbon rather than having it
    /// change after it. The ambient background stays behind, and fades from
    /// one page's to the next in step with the slide (AmbientGlowView).
    private var pageArea: UIView!
    /// Invert Colours: white, laid over the pages with a difference blend,
    /// which turns every colour beneath it into its opposite (white paper
    /// dark, black text light). The background behind the pages is set to
    /// the opposite of the theme's colour, so it comes out as the theme's.
    private var inverter: UIView!
    /// Ambient backgrounds already made, by pages and theme, so the next and
    /// previous pages' are ready before they are turned to.
    private var ambientCache: [String: UIImage] = [:]
    private var ambientCacheOrder: [String] = []
    /// True while opening, until the saved page is on screen: PDFKit reports
    /// the first page meanwhile, which must not overwrite the saved place.
    private var restoring = true
    /// Draws tap turns as a slide or a page curl (Settings > Page Turn),
    /// the same as in the book reader.
    private lazy var pageTurner = PageTurnAnimator(
        host: self, pageView: pageArea,
        snapshot: { [weak self] _, done in
            guard let self else { return done(nil) }
            let view: UIView = self.pageArea
            // See-through around the pages, so a slide shows the glow
            // behind (a curl takes only the page itself, `curlRegion`).
            let format = UIGraphicsImageRendererFormat.preferred()
            format.opaque = false
            done(UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            })
        },
        turnUnderneath: { [weak self] request, done in
            guard let self else { return done(false) }
            let before = self.currentIndex
            let forward = request.isForward
            if forward { self.pdfView.goToNextPage(nil) } else { self.pdfView.goToPreviousPage(nil) }
            self.pdfView.layoutIfNeeded()
            // PDFKit draws the new page a moment later; wait for it, so the
            // picture of the new page (for a curl) is not blank.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                // PDFKit can drop the page to its own, smaller fit as it
                // turns (a swipe let go part-way turns underneath and back,
                // and the page came back slightly zoomed out): fill again.
                self.refitIfShrunk()
                done(self.currentIndex != before)
            }
        })

    init(url: URL) {
        super.init(url: url, state: ReaderState())
    }

    override var commands: ReaderCommands { self }
    override var pageView: UIView { pdfView }
    override var hasShownPage: Bool { model != nil }
    override var failureFallbackTitle: String { String(localized: "This PDF could not be opened.") }

    // MARK: - View setup

    override func loadView() {
        let root = UIView()
        // The ambient background, stretched across the whole screen behind
        // the PDF view (which is see-through around its pages).
        ambient = AmbientGlowView()
        ambient.glowChanged = { [weak self] glow in self?.glowChanged(glow) }
        ambient.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(ambient)
        pageArea = UIView()
        pageArea.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pageArea)

        pdfView = PDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayDirection = .horizontal
        pdfView.pageShadowsEnabled = false
        pdfView.isHidden = true
        pageArea.addSubview(pdfView)

        // Taps are recognised alongside PDFKit's own gestures (selection,
        // links, double-tap zoom), as in the book reader.
        let tap = UITapGestureRecognizer(target: self, action: #selector(pageTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        pdfView.addGestureRecognizer(tap)

        // A long press on a picture offers to save or share it
        // (PDFReaderViewController+Pictures). Elsewhere it selects text, as
        // PDFKit does.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.delegate = self
        pdfView.addGestureRecognizer(press)

        // Swipes turn the page, which follows the finger (PageTurnAnimator,
        // as in the book reader), already at its fitted size. PDFKit's own
        // page view drew each new page at its own fit and then jumped.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pagePanned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = self
        pdfView.addGestureRecognizer(pan)
        swipeRecogniser = pan

        // The bookmark ribbon over the top edge of a bookmarked page, near
        // its right corner (placed by placeRibbon, as the page moves).
        ribbon = BookmarkRibbonView(frame: CGRect(origin: .zero, size: BookmarkRibbonView.size))
        inverter = UIView()
        inverter.translatesAutoresizingMaskIntoConstraints = false
        inverter.backgroundColor = .white
        inverter.isUserInteractionEnabled = false
        inverter.layer.compositingFilter = "differenceBlendMode"
        inverter.isHidden = true
        pageArea.addSubview(inverter)

        ribbon.isHidden = true
        pageArea.addSubview(ribbon)

        // One Page, Two Pages (a spread in landscape only) or Scroll, on
        // iPhone too (books there always show one page).
        state.allowsTwoPages = true
        installChrome(in: root)
        chrome.onVisibilityChanged = { [weak self] visible in
            self?.updateRibbon()
            if visible { self?.scheduleBandCheck(after: 0) }
        }
        configurePageTurner()

        var constraints: [NSLayoutConstraint] = []
        for (inner, outer) in [(pageArea!, root), (ambient!, root), (pdfView!, pageArea!), (inverter!, pageArea!)] as [(UIView, UIView)] {
            constraints += [
                inner.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
                inner.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
                inner.topAnchor.constraint(equalTo: outer.topAnchor),
                inner.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.$isPageBookmarked
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateRibbon() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .PDFViewPageChanged)
            .sink { [weak self] note in
                guard let self, note.object as? PDFView === self.pdfView else { return }
                self.reportPage()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .PDFViewSelectionChanged)
            .sink { [weak self] _ in
                guard let self else { return }
                // Remembered a moment later, so the tap that clears a
                // selection still knows there was one.
                let has = !(self.pdfView.currentSelection?.string ?? "").isEmpty
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.hadSelection = has }
            }
            .store(in: &cancellables)
        // The page moved or was zoomed: the ribbon goes with it.
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewVisiblePagesChanged] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] note in
                    guard let self, note.object as? PDFView === self.pdfView else { return }
                    self.placeRibbon()
                }
                .store(in: &cancellables)
        }
        // Invert Colours turned on or off.
        settings.$invertPDF
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyInversion() } }
            .store(in: &cancellables)
        // One Page or Two Pages changed (here or in another reader).
        settings.$pageLayout
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.model != nil else { return }
                self.layoutForOrientation(force: true, keepPage: self.currentIndex)
            }
            .store(in: &cancellables)

        load()
    }

    // MARK: - Opening

    private func load() {
        let started = CFAbsoluteTimeGetCurrent()
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try PDFReaderModel.load(url: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let loaded):
                    self.state.opening = nil // PDFKit draws the page at once
                    let model = PDFReaderModel(loaded: loaded, url: url, state: self.state)
                    self.model = model
                    // One reading mode for every book and PDF (the setting).
                    self.state.flow = self.settings.defaultFlow
                    self.pdfView.document = loaded.document
                    self.layoutForOrientation(force: true, keepPage: model.startPage)
                    // Once PDFKit has laid the document out, go to the saved
                    // page (and zoom), then start reporting the page.
                    DispatchQueue.main.async {
                        if let page = loaded.document.page(at: model.startPage) { self.pdfView.go(to: page) }
                        if let zoom = model.savedZoom {
                            self.readerZoom = CGFloat(zoom)
                            self.pdfView.scaleFactor = self.pdfView.scaleFactorForSizeToFit * zoom
                        }
                        self.restoring = false
                        self.pdfView.isHidden = false
                        self.reportPage()
                        self.firstPageShown()
                        #if DEBUG
                        self.runDebugStepsIfAny()
                        #endif
                    }
                    self.spinner.stopAnimating()
                    let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
                    log.info("PDF: \(model.pageCount) pages, \(self.state.toc.count) contents entries")
                    log.info("First page visible after \(elapsed, format: .fixed(precision: 0)) ms")
                case .failure(let error):
                    self.state.opening = nil
                    log.error("Could not open \(url.lastPathComponent, privacy: .name): \(String(describing: error), privacy: .public)")
                    self.showFailure(error)
                }
            }
        }
    }

    // MARK: - Layout (Scroll; or pages: one, or a spread in landscape)

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutForOrientation(force: false, keepPage: nil)
        // The window may have changed size without turning (iPad Split View).
        if fitScale != nil, lastFittedSize != pdfView.bounds.size {
            lastFittedSize = pdfView.bounds.size
            fillScreen(resetZoom: true)
        }
        placeRibbon()
    }
    /// The PDF view's size, and the pages on show, when the pages were last
    /// fitted.
    private var lastFittedSize: CGSize = .zero
    private var lastFittedPages: [Int] = []
    /// True until the first fit after opening, which keeps the zoom saved
    /// with the PDF. Every later fit (a turn, a rotation, a new layout)
    /// starts from the screen's fit: the scale left from the old layout is
    /// not a zoom the reader chose.
    private var keepsSavedZoom = true
    /// The reader's zoom as a share of the fit (1: fitted), and whether the
    /// scale is being set here (not by the reader).
    private var readerZoom: CGFloat = 1
    private var settingScale = false
    /// PDFKit's pinch recognisers already followed (they are new after each
    /// change of layout).
    private var followedPinches: Set<ObjectIdentifier> = []
    /// A centre tap waiting to see whether a second follows (centreTapped).
    private var pendingCentreTap: DispatchWorkItem?
    /// The next fit starts from the screen's fit (after a change of layout)
    /// rather than keeping the reader's zoom (after a page turn).
    private var nextFitResets = false

    private func layoutForOrientation(force: Bool, keepPage: Int?) {
        guard let document = pdfView.document else { return }
        let landscape = view.bounds.width > view.bounds.height
        guard force || landscape != isLandscape else { return }
        // The PDF view sits inside pageArea, which lays it out after this
        // view's own layout: give it its new size now, so the fit below is
        // worked out for the new shape, not the old one.
        pageArea.layoutIfNeeded()
        let wasSpread = isSpread
        isLandscape = landscape
        // The page to keep in view: the one being read (in a spread, its
        // left page, which PDFKit reports as the current page).
        let current = keepPage ?? pdfView.currentPage.map { document.index(for: $0) } ?? 0
        // pageLayout is read when the setting has already changed (the
        // observer runs after the change), so this is the new choice. Pages
        // are paired only if they are taller than wide, or about square: a
        // PDF whose pages are already spreads (many picture books) shows one
        // at a time.
        let spread = landscape && state.flow == .paginated && settings.pageLayout == .two
            && pagesArePortrait(around: current, in: document)
        isSpread = spread
        state.pagesAreSpreads = landscape && state.flow == .paginated && settings.pageLayout == .two && !spread

        if state.flow == .scrolled {
            // One long column of pages, in either orientation.
            pdfView.usePageViewController(false)
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
            pdfView.displaysAsBook = false
            // Pages fill the width, with a small gap between them.
            pdfView.displaysPageBreaks = true
            pdfView.pageBreakMargins = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        } else if spread {
            pdfView.displayDirection = .horizontal
            if !wasSpread || force { spreadsStartOdd = current % 2 == 1 }
            pdfView.usePageViewController(false)
            pdfView.displayMode = .twoUp
            // displaysAsBook puts the first page on its own, so pairs start
            // at odd pages; without it they start at even ones.
            pdfView.displaysAsBook = spreadsStartOdd
            pdfView.displaysPageBreaks = false // the two pages touch
            pdfView.pageBreakMargins = .zero
        } else {
            pdfView.displayDirection = .horizontal
            pdfView.usePageViewController(false)
            pdfView.displayMode = .singlePage
            pdfView.displaysAsBook = false
            // No margin round the page, so it fills the screen's width or
            // height.
            pdfView.displaysPageBreaks = false
            pdfView.pageBreakMargins = .zero
        }
        state.columnsOnScreen = spread ? 2 : 1
        pdfView.autoScales = true
        fitScale = nil
        lastFittedPages = []
        nextFitResets = true
        if let page = document.page(at: current) { pdfView.go(to: page) }
        // Switching modes gives PDFKit's inner views their own (grey)
        // background and scroll bars; the theme colour goes back on. They
        // are new views, so the ribbon watches the new scroll view.
        DispatchQueue.main.async {
            self.applyTheme()
            self.ignoreSafeAreaInScrolling()
            self.fillScreen()
            self.watchScrolling()
            self.placeRibbon()
        }
        reportPage()
    }

    /// One Page, Two Pages or Scroll, from the overlay's Layout button. Both
    /// parts are settings for every book and PDF; this reader, and any other
    /// open one, follows (`followFlowSetting` and the page layout observer).
    func setLayout(_ layout: ReadingLayout) {
        if let pages = layout.pages, pages != settings.pageLayout { settings.pageLayout = pages }
        settings.defaultFlow = layout.flow
    }

    func followFlowSetting(_ flow: ReadingFlow) {
        guard model != nil, flow != state.flow else { return }
        let current = currentIndex
        state.flow = flow
        layoutForOrientation(force: true, keepPage: current)
    }

    // MARK: - Taps and turns

    /// A tap in the centre shows or hides the controls; two in quick
    /// succession bring a zoomed page back to its fitted size instead. So
    /// the first waits a moment for a second (taps at the sides do not).
    private func centreTapped() {
        if let pending = pendingCentreTap {
            pending.cancel()
            pendingCentreTap = nil
            zoomToFit()
            return
        }
        let toggle = DispatchWorkItem { [weak self] in
            self?.pendingCentreTap = nil
            self?.chrome.toggle()
        }
        pendingCentreTap = toggle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: toggle)
    }

    /// The reader pinched: their zoom, as a share of the fit, is kept for the
    /// pages that follow.
    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        // Zooming in: the page can be moved about again (see
        // updatePDFScrolling); back at the fit, it cannot.
        if pinch.state == .began { setPDFScrolling(true) }
        guard pinch.state == .ended || pinch.state == .changed, let fit = fitScale, fit > 0 else { return }
        readerZoom = max(1, pdfView.scaleFactor / fit)
        if pinch.state == .ended {
            updatePDFScrolling()
            ambientAfterZoom() // the glow follows, once the zoom settles
        } else {
            ambientZoomWait?.cancel() // not while the fingers are still moving
        }
    }

    /// PDFKit's own scroll views, inside the PDF view (new ones after each
    /// change of layout).
    private var pdfScrollViews: [UIScrollView] {
        func scrollViews(in view: UIView) -> [UIScrollView] {
            view.subviews.flatMap { sub in ((sub as? UIScrollView).map { [$0] } ?? []) + scrollViews(in: sub) }
        }
        return scrollViews(in: pdfView)
    }

    /// At the fitted size (One Page or Two Pages, not zoomed in) the page
    /// needs no scrolling of PDFKit's own: a sideways drag turns the page,
    /// which PageTurnAnimator moves with the finger. Left on, PDFKit's scroll
    /// view moved the new page as well (by the finger's distance again, in
    /// PDFs whose page is a hair wider than its view), so it outran the
    /// finger and slid over the old page, then sprang back as the finger
    /// lifted. Zoomed in, or in Scroll, the pages scroll as usual. (Pinches
    /// still zoom with scrolling off.)
    private func updatePDFScrolling() {
        let zoomed = fitScale.map { pdfView.scaleFactor > $0 * 1.01 } ?? true
        setPDFScrolling(state.flow == .scrolled || zoomed)
    }

    private func setPDFScrolling(_ on: Bool) {
        for scroll in pdfScrollViews where scroll.isScrollEnabled != on { scroll.isScrollEnabled = on }
    }

    /// Back to the page's fitted size (the "1×" of a PDF here: the page or
    /// spread touching the screen's sides or its top and bottom).
    func zoomToFit() {
        readerZoom = 1
        guard let fit = fitScale, pdfView.scaleFactor > fit * 1.01 else { return }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) {
            self.pdfView.scaleFactor = fit
        } completion: { _ in
            self.updatePDFScrolling()
        }
    }

    @objc private func pageTapped(_ recogniser: UITapGestureRecognizer) {
        guard recogniser.state == .ended, model != nil else { return }
        if hadSelection { hadSelection = false; return } // the tap cleared it
        let point = recogniser.location(in: pdfView)
        // Links in the PDF handle their own taps.
        if let page = pdfView.page(for: point, nearest: false),
           page.annotation(at: pdfView.convert(point, to: page))?.type == "Link" { return }
        let width = pdfView.bounds.width
        // The ribbon's place (the page's top-right corner), or the screen's
        // top-right corner, bookmarks the page, as for books.
        let ribbonTarget = ribbonFrame().map { pageArea.convert($0, to: pdfView).insetBy(dx: -16, dy: -12) }
        if ribbonTarget?.contains(point) == true || (point.x > width - 64 && point.y < view.safeAreaInsets.top + 48) {
            toggleBookmark()
        } else if state.flow == .scrolled {
            chrome.toggle() // in Scroll, any tap shows or hides the controls
        } else {
            switch ClickZone(x: point.x, width: width) {
            case .left: turn(.left)
            case .right: turn(.right)
            case .centre: centreTapped()
            }
        }
    }

    #if DEBUG
    /// One scripted step (see DebugHooks.swift).
    override func runDebugStep(_ step: String) {
        if step.hasPrefix("@turn:"), let turn = PageTurn(rawValue: String(step.dropFirst(6))) {
            self.turn(turn)
        } else if step.hasPrefix("@doubleturn:"), let turn = PageTurn(rawValue: String(step.dropFirst(12))) {
            self.turn(turn)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.turn(turn) }
        } else if step.hasPrefix("@zoom:"), let factor = Double(step.dropFirst(6)), let fit = fitScale {
            pdfView.scaleFactor = fit * factor // as a pinch would
            readerZoom = CGFloat(factor)
            reportPage()
            ambientAfterZoom()
        } else if step == "@fit" {
            zoomToFit()
        } else if step == "@readAloudPreview:" {
            // The first sentences read aloud from the start (corpus checks:
            // no headers, footers or page numbers in them).
            if let document = pdfView.document {
                log.notice("step result: read aloud: \(PDFReadAloud.preview(of: document), privacy: .public)")
            }
        } else if step.hasPrefix("@swipeback:") {
            // A swipe let go part of the way across, which springs back to
            // the same page ("@swipeback:left").
            let towardsLeft = step.hasSuffix("left")
            let request: PageTurn = towardsLeft ? .right : .left
            let distance = pdfView.bounds.width * 0.15 * (towardsLeft ? -1 : 1)
            pageTurner.beginSwipe(request, leafMovesLeft: towardsLeft)
            for i in 1...10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i)) { [weak self] in
                    self?.pageTurner.moveSwipe(translation: distance * Double(i) / 10)
                    if i == 10 { self?.pageTurner.endSwipe(velocity: 0, cancelled: false) }
                }
            }
        } else if step == "@ambient" {
            // What the glow is made from now.
            log.notice("step result: ambient \(self.ambientKey ?? "", privacy: .public)")
        } else if step == "@scale" {
            // The PDF's scale against the fit for the pages on show.
            log.notice("step result: scale \(self.pdfView.scaleFactor, format: .fixed(precision: 4)) fit \(self.fitScale ?? 0, format: .fixed(precision: 4)) pages \(self.visiblePages.map(String.init).joined(separator: ","), privacy: .public)")
        } else if step.hasPrefix("@swipe:") {
            // A finger drawn across the page: left brings the next page.
            let towardsLeft = step.hasSuffix("left")
            let request: PageTurn = towardsLeft ? .right : .left
            let distance = pdfView.bounds.width * 0.6 * (towardsLeft ? -1 : 1)
            pageTurner.beginSwipe(request, leafMovesLeft: towardsLeft)
            for i in 1...10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i)) { [weak self] in
                    self?.pageTurner.moveSwipe(translation: distance * Double(i) / 10)
                    if i == 10 { self?.pageTurner.endSwipe(velocity: distance * 3, cancelled: false) }
                }
            }
        } else {
            super.runDebugStep(step)
        }
    }
    #endif

    // MARK: - Swipes

    /// The swipe recogniser (a one-finger pan), set up in loadView.
    private(set) var swipeRecogniser: UIPanGestureRecognizer?

    /// Whether a pan may turn the page: a sideways drag on a page shown
    /// whole (Pages, not zoomed in), not one selecting text. Zoomed in, a
    /// pan moves around the page instead (PDFKit's own scrolling).
    private func swipeShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard model != nil, state.flow == .paginated else { return false }
        if let fitScale, pdfView.scaleFactor > fitScale * 1.01 { return false }
        if !(pdfView.currentSelection?.string ?? "").isEmpty { return false }
        let velocity = pan.velocity(in: pdfView)
        return abs(velocity.x) > abs(velocity.y) * 1.2
    }

    @objc private func pagePanned(_ pan: UIPanGestureRecognizer) {
        let dx = pan.translation(in: pdfView).x
        switch pan.state {
        case .began:
            // The finger moving left brings in the next page (PDFs read left
            // to right).
            let request: PageTurn = (dx != 0 ? dx : pan.velocity(in: pdfView).x) < 0 ? .right : .left
            pageTurner.beginSwipe(request, leafMovesLeft: request == .right)
            pageTurner.moveSwipe(translation: dx)
        case .changed:
            pageTurner.moveSwipe(translation: dx)
        case .ended:
            pageMovedByHand()
            pageTurner.endSwipe(velocity: pan.velocity(in: pdfView).x, cancelled: false)
        case .cancelled, .failed:
            pageTurner.endSwipe(velocity: 0, cancelled: true)
        default:
            break
        }
    }

    /// A finger touched the page: PDFKit's own double tap (which zooms in,
    /// or back out) may only work in the centre. At the sides taps turn the
    /// page, and quick taps there were taken as double taps, zooming in
    /// midway through the turns. Switching it off resets it, so a tap at a
    /// side followed by one in the centre is not a double tap either.
    func gestureRecognizer(_ recogniser: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let x = touch.location(in: pdfView).x
        let allowed = state.flow == .scrolled || ClickZone(x: x, width: pdfView.bounds.width) == .centre
        for zoom in pdfView.gestureRecognizers ?? [] {
            if let tap = zoom as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2, tap.isEnabled != allowed {
                tap.isEnabled = allowed
            }
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        if recogniser === swipeRecogniser, let pan = recogniser as? UIPanGestureRecognizer {
            return swipeShouldBegin(pan)
        }
        return true
    }

    /// PDFKit can drop the page to its own, slightly smaller fit while a
    /// swipe moves it (turning underneath and back when the swipe is let go
    /// part-way, or at the first or last page): the page came back slightly
    /// zoomed out (the reader saw it in landscape, 24 Nov 2026). Fills the
    /// screen again if so; a zoom the reader chose is above the fit, so it
    /// is kept.
    private func refitIfShrunk() {
        if let fit = fitScale, pdfView.scaleFactor < fit * 0.995 { fillScreen() }
    }

    /// The same, once PDFKit has finished moving.
    private func refitSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.refitIfShrunk() }
    }

    private func configurePageTurner() {
        // A turn past the first or last page says so, rather than just not
        // moving. (Swipes ask for .left or .right, not .next or .prev, so
        // the direction is read from isForward.)
        pageTurner.onEdge = { [weak self] request in
            self?.refitSoon()
            self?.chrome.showNotice(request.isForward ? String(localized: "End of document")
                                                      : String(localized: "Start of document"))
        }
        // Slides and swipes fade the glow behind the pages in step with them.
        pageTurner.slideProgress = { [weak self] progress in self?.ambient.slide(to: progress) }
        pageTurner.slideEnded = { [weak self] turned in
            self?.ambient.endSlide(turned: turned)
            self?.refitSoon()
        }
        // Only the page curls (or the spread, in landscape), not the
        // background around it; its back is paper, whatever the theme.
        pageTurner.curlRegion = { [weak self] in self?.pageRegion }
        pageTurner.curlBackColour = { UIColor(white: 0.94, alpha: 1) }
        // In a spread, the curl turns one page about the spine, as in a book.
        // A wide page alone in landscape (a picture book's spread on one PDF
        // page) curls the same way, about its middle.
        pageTurner.curlSpine = { [weak self] in
            guard let self, let document = self.pdfView.document else { return nil }
            let pages = self.visiblePages.compactMap { document.page(at: $0) }
            let rects = pages.map { self.pdfView.convert($0.bounds(for: self.pdfView.displayBox), from: $0) }
            if self.isSpread, rects.count == 2 { return rects[0].maxX }
            if self.isLandscape, self.state.flow == .paginated, rects.count == 1, rects[0].width > rects[0].height {
                return rects[0].midX
            }
            return nil
        }
    }

    /// Where the pages on screen are, in the PDF view's coordinates.
    private var pageRegion: CGRect? {
        let rects = pdfView.visiblePages.map { pdfView.convert($0.bounds(for: pdfView.displayBox), from: $0) }
        guard var region = rects.first else { return nil }
        for rect in rects.dropFirst() { region = region.union(rect) }
        return region
    }

    /// Turns a page (PDFs are always left to right), drawn in the Page Turn
    /// style: none in Scroll layout or under Reduce Motion.
    func turn(_ turn: PageTurn) {
        if !movingForReadAloud { pageMovedByHand() }
        let forward = turn.isForward
        var style: PageTurnAnimator.Style
        switch settings.pageTurnStyle {
        case .none: style = .none
        case .slide: style = .slide
        case .curl: style = .curl
        }
        if UIAccessibility.isReduceMotionEnabled || state.flow == .scrolled { style = .none }
        pageTurner.turn(forward ? .next : .prev, leafMovesLeft: forward, style: style)
    }

    func gestureRecognizer(_ recogniser: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: - Where the reader is

    private var visiblePages: [Int] {
        guard let document = pdfView.document else { return [] }
        // One page unless it is a spread: the current one. (PDFKit's page
        // view keeps the neighbouring pages loaded, and lists them as
        // visible, so the first visible page may not be the one on screen.)
        guard isSpread else { return pdfView.currentPage.map { [document.index(for: $0)] } ?? [] }
        let pages = pdfView.visiblePages.map { document.index(for: $0) }.sorted()
        if pages.isEmpty, let current = pdfView.currentPage { return [document.index(for: current)] }
        return Array(pages.prefix(2))
    }

    private func reportPage() {
        guard !restoring, let model, let document = pdfView.document, let current = pdfView.currentPage else { return }
        let fit = fitScale ?? pdfView.scaleFactorForSizeToFit
        let zoom = fit > 0 ? Double(pdfView.scaleFactor / fit) : 1
        let index = document.index(for: current)
        var visible = visiblePages
        if !visible.contains(index) { visible.insert(index, at: 0) }
        model.pageChanged(to: visible.first ?? index, visible: visible, zoom: zoom > 1.05 ? zoom : nil)
        // Two Pages in landscape pairs pages only while they are taller than
        // wide; turning from a wide page to tall ones (or back) changes the
        // layout. (It was decided only on rotating, so a PDF reopened on a
        // wide page stayed single for the tall pages before it.)
        if isLandscape, state.flow == .paginated, settings.pageLayout == .two,
           pagesArePortrait(around: index, in: document) != isSpread {
            DispatchQueue.main.async { self.layoutForOrientation(force: true, keepPage: index) }
            return
        }
        // New pages on show: fit them (dropping a pinch zoom, except the
        // saved one at opening).
        if state.flow == .paginated, visible != lastFittedPages {
            lastFittedPages = visible
            // A turn keeps the zoom; a new layout (rotating, Layout) starts
            // fitted, except the zoom saved with the PDF at opening.
            fillScreen(resetZoom: nextFitResets && !keepsSavedZoom)
            nextFitResets = false
            keepsSavedZoom = false
        }
        updateRibbon()
        updateAmbient()
        #if DEBUG
        // Testing: how the pages fill the screen (PLATEN_LOG_PAGE_FIT).
        if ProcessInfo.processInfo.environment["PLATEN_LOG_PAGE_FIT", default: ""].isEmpty == false,
           let region = pageRegion {
            let r = view.convert(region, from: pdfView)
            log.notice("page fit: pages \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)) in \(Int(self.view.bounds.width))×\(Int(self.view.bounds.height)), scale \(self.pdfView.scaleFactor, format: .fixed(precision: 3)), fit \(self.pdfView.scaleFactorForSizeToFit, format: .fixed(precision: 3))")
        }
        #endif
    }

    private func updateRibbon() {
        // Only on a bookmarked page. (No faint outline while the controls
        // are up: their Bookmark button does that job.)
        ribbon.isHidden = model == nil || !state.isPageBookmarked
        ribbon.isDark = currentTheme.isDark
        if ribbon.isHidden { ribbon.finishMotion() }
        placeRibbon()
    }

    /// Where the ribbon goes, in this view's coordinates: over the top edge
    /// of the bookmarked page (in a spread, the right-hand page if both are,
    /// or neither yet), a little in from its right corner, starting just
    /// at the edge. Kept on screen when
    /// the page is zoomed or scrolled past.
    private func ribbonFrame() -> CGRect? {
        let visible = visiblePages
        let index = visible.last { model?.isBookmarked(page: $0) == true } ?? visible.last
        guard let document = pdfView.document, let page = index.flatMap({ document.page(at: $0) }) else { return nil }
        let pageRect = pageArea.convert(pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), from: pdfView)
        let size = BookmarkRibbonView.size
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let x = min(pageRect.maxX - 18 - size.width, safe.maxX - 12 - size.width)
        // From the page's top edge, not above it: a curl turns only the
        // page, so a ribbon reaching above it showed its top before the
        // rest of it curled in (device testing, 25 Nov 2026).
        var y = max(pageRect.minY, 0)
        if state.flow == .scrolled { y = max(y, safe.minY) }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func placeRibbon() {
        guard !ribbon.isHidden, let frame = ribbonFrame() else { return }
        if ribbon.frame != frame { ribbon.frame = frame }
    }

    /// Whether the page being read and the next are taller than wide, so a
    /// pair of them makes a book's spread.
    /// Whether a page of this shape goes beside another in Two Pages. A
    /// single page is taller than wide, or about square: picture books are
    /// often square, and were shown alone, one to a landscape screen
    /// (device testing, 21 Nov 2026). A page clearly wider than tall (a
    /// fifth or more) is already a spread of two, and shows alone.
    nonisolated static func pairs(pageSize size: CGSize) -> Bool {
        size.width < size.height * 1.2
    }

    private func pagesArePortrait(around index: Int, in document: PDFDocument) -> Bool {
        [index, index + 1].compactMap { document.page(at: $0) }.allSatisfy { page in
            let box = page.bounds(for: pdfView.displayBox).size
            let size = page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
            return Self.pairs(pageSize: size)
        }
    }

    /// PDFKit's own scroll views allow for the safe areas (the home
    /// indicator, the Dynamic Island) when they centre a page, which put a
    /// page that fills the height 10 points too high in landscape: cut at
    /// the top, a strip showing at the bottom. The page should use the
    /// whole screen (the controls float over it), so they do not. They are
    /// new views after each change of layout, so this runs then.
    private func ignoreSafeAreaInScrolling() {
        let scrollViews = pdfScrollViews
        for scroll in scrollViews where scroll.contentInsetAdjustmentBehavior != .never {
            scroll.contentInsetAdjustmentBehavior = .never
        }
        updatePDFScrolling()
        // The reader's pinches are followed (pinched), so their zoom is kept
        // as the page turns: PDFKit resets the scale when the page changes.
        for scroll in scrollViews {
            if let pinch = scroll.pinchGestureRecognizer, !followedPinches.contains(ObjectIdentifier(pinch)) {
                followedPinches.insert(ObjectIdentifier(pinch))
                pinch.addTarget(self, action: #selector(pinched(_:)))
            }
        }
        // The PDF view's own double tap zooms in and out, in the centre only
        // (see gestureRecognizer(_:shouldReceive:)); a centre double tap also
        // brings a zoomed page back to its fitted size (centreTapped). The
        // double taps of PDFKit's inner views are off.
        func allViews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(allViews) }
        for view in allViews(pdfView) {
            for recogniser in view.gestureRecognizers ?? [] {
                if let tap = recogniser as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2,
                   tap.view !== pdfView { tap.isEnabled = false }
            }
        }
    }

    /// Pages as large as the screen allows: in One Page and Two Pages, the
    /// page (or the pair) touches the screen's sides or its top and bottom,
    /// keeping its shape. PDFKit's own fit (autoScales) leaves the safe areas
    /// free (the Dynamic Island, the home indicator), which put a margin
    /// round every page; the controls float over the page anyway, so the
    /// fit is worked out here against the whole screen. A zoom of the
    /// reader's own (pinching in, or the one saved with the PDF) is kept,
    /// as a share of the fit, unless `resetZoom` (a new layout or window
    /// size).
    ///
    /// Scroll keeps PDFKit's fit: pages as wide as the screen.
    private func fillScreen(resetZoom: Bool = false) {
        guard state.flow == .paginated, let document = pdfView.document,
              pdfView.bounds.width > 0, pdfView.bounds.height > 0 else {
            pdfView.minScaleFactor = 0.05
            pdfView.autoScales = true
            fitScale = nil
            updatePDFScrolling()
            return
        }
        // The pages on show, and the space they take side by side.
        let pages = visiblePages.compactMap { document.page(at: $0) }
        guard !pages.isEmpty else { return }
        let sizes = pages.map { page -> CGSize in
            let box = page.bounds(for: pdfView.displayBox).size
            return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
        }
        let width = sizes.reduce(0) { $0 + $1.width }
        let height = sizes.map(\.height).max() ?? 0
        guard width > 0, height > 0 else { return }
        let fit = min(pdfView.bounds.width / width, pdfView.bounds.height / height)
        // The reader's zoom, as a share of the fit (readerZoom): kept when
        // the page turns, so text they made bigger stays that size on the
        // next page.
        if resetZoom { readerZoom = 1 }
        fitScale = fit
        defer { updatePDFScrolling() }
        lastFittedSize = pdfView.bounds.size
        settingScale = true
        pdfView.autoScales = false
        pdfView.maxScaleFactor = fit * 8
        pdfView.minScaleFactor = fit
        pdfView.scaleFactor = readerZoom < 1.01 ? fit : min(fit * readerZoom, fit * 8)
        settingScale = false
    }

    /// Follows the PDF view's scroll view (found inside it), so the ribbon
    /// moves with the page while scrolling or zooming.
    private func watchScrolling() {
        func firstScrollView(in view: UIView) -> UIScrollView? {
            for sub in view.subviews {
                if let scroll = sub as? UIScrollView { return scroll }
                if let found = firstScrollView(in: sub) { return found }
            }
            return nil
        }
        scrollObservation = firstScrollView(in: pdfView)?.observe(\.contentOffset, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.placeRibbon()
                // Zooming and moving about change what is on screen: the
                // glow follows once they stop.
                self?.ambientAfterZoom()
            }
        }
    }

    // MARK: - Overlay actions

    private var currentIndex: Int {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return document.index(for: page)
    }

    // MARK: - Commands (ReaderCommands)

    /// A jump (contents, bookmark, search result, slider): remembered, so the
    /// overlay offers "Back to p. N".
    private func jump(toPage index: Int, keepOrigin: Bool = false) {
        pageMovedByHand()
        guard let model, let page = pdfView.document?.page(at: index) else { return }
        model.noteJump(from: currentIndex, to: index, keepOrigin: keepOrigin)
        pdfView.go(to: page)
    }

    func jump(to href: String, keepOrigin: Bool) {
        if let index = model?.pageIndex(for: href) { jump(toPage: index, keepOrigin: keepOrigin) }
    }

    func jump(toFraction fraction: Double) {
        if let model { jump(toPage: model.page(atFraction: fraction)) }
    }

    func goBack() {
        guard let target = model?.takeBackTarget(), let page = pdfView.document?.page(at: target) else { return }
        pageMovedByHand()
        pdfView.go(to: page)
    }

    /// Previous and next chapter: the outline's entries.
    func previousChapter() {
        if let target = outlinePages.last(where: { $0 < currentIndex }) { jump(toPage: target) }
    }

    func nextChapter() {
        if let target = outlinePages.first(where: { $0 > currentIndex }) { jump(toPage: target) }
    }

    private var outlinePages: [Int] {
        state.toc.compactMap { model?.pageIndex(for: $0.href) }.sorted()
    }

    func toggleBookmark() {
        let wasMarked = state.isPageBookmarked
        if wasMarked { ribbon.liftOff() } // a copy folds away as it hides
        model?.toggleBookmark(visible: visiblePages)
        updateRibbon()
        if state.isPageBookmarked, !wasMarked {
            // Laid onto the page, from its outer side: the left of the
            // left-hand page of a spread.
            ribbon.layDown(outerIsLeft: visiblePages.count > 1 && ribbon.frame.midX < view.bounds.midX)
        }
        if state.isPageBookmarked {
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Bookmark added"))
        }
    }

    func removeBookmark(cfi: String) { model?.removeBookmark(cfi: cfi, visible: visiblePages) }

    func search(_ query: String) {
        model?.search(query)
        pdfView.highlightedSelections = nil
    }

    func goToHit(_ hit: ReaderState.SearchHit) {
        guard let model else { return }
        let keep = state.currentHitID != nil // Back returns to before the first result
        state.currentHitID = hit.id
        if let selection = model.hitSelections[hit.id] {
            model.noteJump(from: currentIndex, to: model.pageIndex(for: hit.cfi) ?? 0, keepOrigin: keep)
            pdfView.highlightedSelections = Array(model.hitSelections.values)
            selection.color = .systemYellow
            pdfView.go(to: selection)
            pdfView.setCurrentSelection(selection, animate: true)
        } else {
            jump(to: hit.cfi, keepOrigin: keep)
        }
    }

    /// Search highlights are temporary: they go when the panel closes.
    func searchPanelClosed() {
        pdfView.highlightedSelections = nil
        model?.cancelSearch()
    }

    override func savePositionNow() { model?.saveNow() }

    // MARK: - The press

    /// The press's picture: the pages on the theme's colour. The glow is
    /// made a moment later, so it is kept out of sight until the page has
    /// landed and then fades in, as it does after any open; drawn into the
    /// picture, it would have jumped in at the hand-over.
    override func pressPicture(_ done: @escaping (UIImage?, UIImage?) -> Void) {
        ambient.alpha = 0
        // Taken a couple of frames after the page is shown, once PDFKit has
        // fitted it (at once, the page was still half-size). With Ambient
        // Light, the glow (made in the background as the page is shown) is
        // waited for, briefly, so the press can bring it in with the page.
        let glowing = !ambient.isHidden
        let started = CACurrentMediaTime()
        func take() {
            guard ambient.image == nil, glowing, CACurrentMediaTime() - started < 0.4 else {
                let glow = glowing ? ambient.image : nil
                return done(drawPagesOnScreen(clearAround: glow != nil), glow)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard self != nil else { return done(nil, nil) }
                take()
            }
        }
        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard self != nil else { return done(nil, nil) }
                take()
            }
        }
    }

    /// The pages on screen, drawn from the PDF itself where PDFKit shows
    /// them, on the theme's colour (inverted, with Invert Colours, as the
    /// page area is). Not a picture of PDFKit's views: those draw the room
    /// round the pages solid black.
    /// `clearAround`: see-through round the pages, over the glow.
    private func drawPagesOnScreen(clearAround: Bool = false) -> UIImage? {
        let bounds = view.bounds
        guard bounds.width > 0, let document = pdfView.document else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = !clearAround
        let box = pdfView.displayBox
        let pages: [(PDFPage, CGRect)] = visiblePages.compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let rect = view.convert(pdfView.convert(page.bounds(for: box), from: page), from: pdfView)
            return (page, rect)
        }
        let inverted = !inverter.isHidden
        let around = inverted ? (pageArea.backgroundColor ?? currentTheme.uiBackground) : currentTheme.uiBackground
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            let cg = context.cgContext
            if !clearAround {
                around.setFill()
                UIRectFill(bounds)
            }
            for (page, rect) in pages {
                UIColor.white.setFill()
                UIRectFill(rect)
                let media = page.bounds(for: box)
                cg.saveGState()
                cg.clip(to: rect)
                // PDF space has y up: flipped into the page's place.
                cg.translateBy(x: rect.minX, y: rect.maxY)
                cg.scaleBy(x: rect.width / media.width, y: -rect.height / media.height)
                cg.translateBy(x: -media.minX, y: -media.minY)
                page.draw(with: box, to: cg)
                cg.restoreGState()
            }
            if inverted {
                cg.setBlendMode(.difference)
                UIColor.white.setFill()
                UIRectFill(bounds)
            }
        }
    }

    override func endPress() {
        let glowShown = pressShowedGlow
        super.endPress()
        guard ambient.alpha < 1 else { return }
        // Already on screen in the press: simply there. Else faded in.
        let fade = glowShown || UIAccessibility.isReduceMotionEnabled ? 0 : 0.35
        UIView.animate(withDuration: fade) { self.ambient.alpha = 1 }
    }

    // MARK: - Theme

    /// Behind the controls: the glow and the pages, drawn small.
    override func backdropSnapshot(width: CGFloat, done: @escaping (UIImage?) -> Void) {
        let bounds = view.bounds
        guard bounds.width > 0 else { return done(nil) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = width / bounds.width
        done(UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            (view.backgroundColor ?? .black).setFill()
            UIRectFill(bounds)
            if !ambient.isHidden { ambient.drawHierarchy(in: ambient.frame, afterScreenUpdates: false) }
            pageArea.drawHierarchy(in: pageArea.frame, afterScreenUpdates: false)
        })
    }

    /// The ambient background for the pages on screen, faded in over the
    /// last one. Remade only when the pages or the theme change.
    /// The parts of the pages on screen while the reader is zoomed in (each
    /// page and the region of it showing, in the page's own coordinates);
    /// nil when the pages are shown whole.
    private var zoomedParts: [(page: PDFPage, region: CGRect)]? {
        guard let fit = fitScale, pdfView.scaleFactor > fit * 1.01, let document = pdfView.document else { return nil }
        let parts = visiblePages.compactMap { index -> (page: PDFPage, region: CGRect)? in
            guard let page = document.page(at: index) else { return nil }
            let shown = pdfView.convert(pdfView.bounds, to: page).intersection(page.bounds(for: pdfView.displayBox))
            return shown.isNull || shown.isEmpty ? nil : (page, shown)
        }
        return parts.isEmpty ? nil : parts
    }

    /// The glow follows a zoom (spec: it reflects what is on screen): left
    /// as it is while the reader pinches or moves about, then, once the
    /// view has been still for a moment, made from the part now on screen
    /// and faded in from the old one.
    private func ambientAfterZoom() {
        ambientZoomWait?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateAmbient(fade: true) }
        ambientZoomWait = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func updateAmbient(fade: Bool = false) {
        // New pages or a new glow: do the controls need bands?
        scheduleBandCheck()
        // Off (Aa > Ambient Light): the theme's plain colour shows through.
        // Also off with Invert Colours: the glow is of the page's own colours,
        // which would not match the inverted page.
        let glow = settings.ambientLight && !settings.invertPDF
        ambient.isHidden = !glow
        guard glow, let document = pdfView.document else { return }
        let indexes = visiblePages
        let theme = currentTheme.uiBackground
        // Zoomed in: the glow of the part on screen (its region, to the
        // nearest few points, is part of the key).
        let zoomed = zoomedParts
        let regions = zoomed.map { parts in
            parts.map { p in "\(Int(p.region.minX / 8)),\(Int(p.region.minY / 8)),\(Int(p.region.width / 8)),\(Int(p.region.height / 8))" }
                .joined(separator: ";")
        }
        let key = ambientKey(indexes, theme) + (regions.map { " zoom " + $0 } ?? "")
        guard key != ambientKey, !indexes.isEmpty else { return }
        ambientKey = key
        if let zoomed {
            PDFAmbientBackground.make(for: zoomed, theme: theme) { [weak self] image in
                guard let self, self.ambientKey == key, let image else { return }
                self.ambient.show(image, fade: UIAccessibility.isReduceMotionEnabled ? 0 : 0.5)
            }
            return
        }
        if let ready = ambientCache[key], fade {
            // Zoomed back out: the whole pages' glow, faded in.
            ambient.show(ready, fade: UIAccessibility.isReduceMotionEnabled ? 0 : 0.5)
        } else if let ready = ambientCache[key] {
            if pageTurner.isCurling && !UIAccessibility.isReduceMotionEnabled {
                // A curl: only the page curls, while the glow behind it
                // stays. It fades from the old page's to the new over the
                // curl, landing as the page does.
                ambient.show(ready, fade: PageTurnAnimator.curlDuration, curve: .curveEaseInOut)
            } else {
                // Made ahead: on at once, or during a slide or swipe, fading
                // in step with it (AmbientGlowView).
                ambient.show(ready)
            }
        } else {
            makeAmbient(indexes, theme: theme, document: document) { [weak self] image in
                guard let self, self.ambientKey == key, let image else { return }
                self.ambient.show(image, fade: UIAccessibility.isReduceMotionEnabled ? 0 : 0.35)
            }
        }
        // Make the next and previous pages' backgrounds now, so they are
        // ready when the reader turns to them.
        let step = indexes.count
        for neighbour in [indexes.map { $0 + step }, indexes.map { $0 - step }]
        where neighbour.allSatisfy({ $0 >= 0 && $0 < document.pageCount }) {
            let neighbourKey = ambientKey(neighbour, theme)
            if ambientCache[neighbourKey] == nil {
                makeAmbient(neighbour, theme: theme, document: document) { _ in }
            }
        }
    }

    private func ambientKey(_ pages: [Int], _ theme: UIColor) -> String { "\(pages) \(theme)" }

    /// Makes the background for these pages (off the main thread) and keeps
    /// it in the cache, which holds the last dozen.
    private func makeAmbient(_ indexes: [Int], theme: UIColor, document: PDFDocument, done: @escaping (UIImage?) -> Void) {
        let key = ambientKey(indexes, theme)
        let pages = indexes.compactMap { document.page(at: $0) }
        PDFAmbientBackground.make(for: pages, theme: theme) { [weak self] image in
            if let self, let image {
                if self.ambientCache.updateValue(image, forKey: key) == nil { self.ambientCacheOrder.append(key) }
                while self.ambientCacheOrder.count > 12 {
                    self.ambientCache[self.ambientCacheOrder.removeFirst()] = nil
                }
            }
            done(image)
        }
    }

    /// Invert Colours on or off (see `inverter`).
    private func applyInversion() {
        let inverted = settings.invertPDF
        inverter.isHidden = !inverted
        if inverted {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            currentTheme.uiBackground.getRed(&r, green: &g, blue: &b, alpha: &a)
            pageArea.backgroundColor = UIColor(red: 1 - r, green: 1 - g, blue: 1 - b, alpha: 1)
        } else {
            pageArea.backgroundColor = .clear
        }
        updateAmbient()
    }

    /// Themes colour the background around the page (spec, "PDF"), here
    /// mixed with the page's own colours (updateAmbient), so the PDF view
    /// and its inner views are see-through.
    override func applyTheme() {
        super.applyTheme()
        if pageArea != nil { applyInversion() } // its background follows the theme
        if pdfView?.document != nil { updateAmbient() }
        if let pdfView {
            pdfView.backgroundColor = .clear
            // PDFKit's own scroll and page views, inside the PDFView.
            var queue: [UIView] = pdfView.subviews
            while let next = queue.popLast() {
                if let scroll = next as? UIScrollView {
                    scroll.showsHorizontalScrollIndicator = false
                    scroll.showsVerticalScrollIndicator = false
                    scroll.backgroundColor = .clear
                } else if next.backgroundColor != nil, !(next is UIImageView),
                          next.bounds.width >= pdfView.bounds.width * 0.9 {
                    // Full-width containers only, never the pages themselves.
                    next.backgroundColor = .clear
                }
                queue.append(contentsOf: next.subviews)
            }
        }
    }
}

// MARK: - Read aloud (PDFReadAloud; the speaker button is ReaderBaseViewController's)

extension PDFReaderViewController: PDFReadAloudHost {
    var readAloudStartPage: Int { visiblePages.first ?? 0 }

    /// Turns to `index` when the voice reaches it: with the page-turn
    /// animation when it is the next page, else straight there.
    func readAloudShow(page index: Int) {
        guard let document = pdfView.document, let page = document.page(at: index) else { return }
        if state.flow == .scrolled {
            if !pdfView.visiblePages.contains(page) { pdfView.go(to: page) }
            return
        }
        let visible = visiblePages
        guard !visible.contains(index) else { return }
        movingForReadAloud = true
        defer { movingForReadAloud = false }
        if let last = visible.last, index == last + 1, !pageTurner.isBusy {
            turn(.next)
        } else {
            pdfView.go(to: page)
        }
    }

    /// A thin underline in the accent colour under each line of the words,
    /// as an underline annotation on the page in memory (Platen never
    /// writes PDFs, so it is never saved).
    func readAloudUnderline(_ ranges: [(page: Int, range: NSRange)]) {
        for (page, annotation) in readAloudAnnotations { page.removeAnnotation(annotation) }
        readAloudAnnotations.removeAll()
        guard let document = pdfView.document else { return }
        for item in ranges {
            guard let page = document.page(at: item.page), let selection = page.selection(for: item.range) else { continue }
            for line in selection.selectionsByLine() {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .underline, withProperties: nil)
                annotation.color = view.tintColor
                // The underline runs along the bottom of the bounds (the
                // points are relative to them).
                annotation.quadrilateralPoints = [
                    CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height),
                    CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0),
                ].map { NSValue(cgPoint: $0) }
                let border = PDFBorder()
                border.lineWidth = 1.5
                annotation.border = border
                page.addAnnotation(annotation)
                readAloudAnnotations.append((page, annotation))
            }
        }
    }
}
