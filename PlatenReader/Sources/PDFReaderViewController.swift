import AppKit
import Combine
import PDFKit
import PlatenCore
import SwiftUI
import os

/// The reader for a PDF on the Mac (spec, "PDF"). PDFKit draws the pages;
/// the overlay, contents, bookmarks, search and window chrome behave as for
/// books, through the shared PDFReaderModel and OverlayBar.
///
/// - A click in the left or right third turns the page, in the centre shows
///   the controls; click-drag selects text (PDFKit), and links work.
/// - The Layout setting maps to PDFKit's display modes: One Page is single
///   page, Two Pages is two-up, Scroll is continuous.
/// - Two Pages: the pages touch, with no gap between them (as on iOS). The
///   page on show when Two Pages is chosen (or the book opens in it) becomes
///   the left page of its spread, except the first page, which is the cover
///   and stands alone on the right; turning back to the cover puts it on
///   its own again (`pairSpreads`).
/// - Page Curl (Layout or Settings › Page turn): a turn by click or key is
///   drawn as a leaf of paper (PageTurnView, as for books). Only the page
///   turns, not the ambient light around it, which fades to the new page's
///   colours as it turns. Two pages turn one leaf about the spine, and so
///   does a page wider than tall in One Page, about its middle (as on iOS).
///   Slide pushes the new page in.
final class PDFReaderViewController: ReaderBaseViewController, ReaderCommands {
    private var pdfView: PlatenPDFView!
    private var model: PDFReaderModel?
    /// While opening, until the saved page is on screen (PDFKit reports the
    /// first page meanwhile, which must not overwrite the saved place).
    private var restoring = true
    /// The scale that shows whole pages in the window (see `fitToWindow`),
    /// and whether the reader has zoomed away from it.
    private var fitScale: CGFloat = 1
    private var userZoomed = false
    private var applyingScale = false
    /// Behind the pages: their own colours, softened and stretched to fill
    /// whatever room the window leaves around them (Ambient Light, as on
    /// iOS; `AmbientGlow`).
    private let ambient = NSImageView()
    /// What the glow was last made for (pages and theme), so it is made only
    /// when that changes.
    private var ambientKey: String?
    /// The bookmark ribbon over the top edge of a bookmarked page, as on
    /// iOS (PDFRibbonView; placed by placeRibbon as the page moves).
    private let ribbon = PDFRibbonView(frame: CGRect(origin: .zero, size: PDFRibbonView.size))
    /// The page curl under way, if any, and the turn it belongs to (a newer
    /// turn ends it), and when the last turn was asked for (quick turns are
    /// instant, as for books).
    private var pageTurn: PageTurnView?
    private var turnGeneration = 0
    private var lastTurnRequest: TimeInterval = 0

    init(document: BookDocument) {
        super.init(document: document, state: ReaderState())
    }

    /// Read aloud, made the first time it is asked for (PDFReadAloud).
    private var pdfReadAloud: PDFReadAloud?
    /// Read aloud is turning the page (so it is not a turn by hand).
    private var movingForReadAloud = false
    /// Read aloud's underline: annotations on the pages (never saved).
    private var readAloudAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []

    override var commands: ReaderCommands { self }
    // Read aloud: the speaker on the bar, reading through PDFReadAloud, with
    // this reader as its page.
    override var offersReadAloud: Bool { true }
    override var readAloudSource: ReadAloudSource? {
        if pdfReadAloud == nil, let model { pdfReadAloud = PDFReadAloud(model: model, host: self) }
        return pdfReadAloud
    }
    override var pageView: NSView { pdfView }
    override var isReady: Bool { model != nil }
    override var hasShownPage: Bool { model != nil }
    override var failureFallbackTitle: String { String(localized: "This PDF could not be opened.") }

    // MARK: - View setup

    override func loadView() {
        let root = ReaderRootView()

        // The glow fills the window behind the pages (stretched: it is only
        // colours, so proportions do not matter).
        ambient.translatesAutoresizingMaskIntoConstraints = false
        ambient.imageScaling = .scaleAxesIndependently
        ambient.isHidden = true
        ambient.wantsLayer = true
        root.addSubview(ambient)
        NSLayoutConstraint.activate([
            ambient.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ambient.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ambient.topAnchor.constraint(equalTo: root.topAnchor),
            ambient.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        pdfView = PlatenPDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.pageShadowsEnabled = false
        pdfView.isHidden = true
        pdfView.onClick = { [weak self] point in
            guard let self, self.model != nil else { return }
            self.handleClick(zone: ClickZone(x: point.x, width: self.pdfView.bounds.width))
        }
        pdfView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        root.addSubview(pdfView)
        ribbon.isHidden = true
        root.addSubview(ribbon)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: root.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        installChrome(in: root)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.publisher(for: .PDFViewPageChanged)
            .sink { [weak self] note in
                guard let self, note.object as? PDFView === self.pdfView else { return }
                self.reportPage()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .PDFViewScaleChanged)
            .sink { [weak self] note in
                guard let self, note.object as? PDFView === self.pdfView else { return }
                // A pinch or ⌘+ (not our own fitting): keep the reader's zoom
                // until the layout changes.
                if !self.applyingScale, !self.restoring, self.state.flow != .scrolled {
                    self.userZoomed = abs(self.pdfView.scaleFactor / self.fitScale - 1) > 0.02
                    self.updateScrollers()
                }
                self.reportPage()
                self.placeRibbon()
            }
            .store(in: &cancellables)
        load()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The window was resized: fit the pages again (unless zoomed in).
        if !userZoomed { fitToWindow() }
        placeRibbon()
    }

    // MARK: - Opening

    /// The press's picture: the pages as PDFKit draws them.
    override func pressPicture(_ done: @escaping (CGImage?) -> Void) {
        pdfView.layoutSubtreeIfNeeded()
        guard pdfView.bounds.width > 0,
              let rep = pdfView.bitmapImageRepForCachingDisplay(in: pdfView.bounds) else { return done(nil) }
        pdfView.cacheDisplay(in: pdfView.bounds, to: rep)
        done(rep.cgImage)
    }

    private func load() {
        guard let url = document.fileURL else { return }
        let started = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try PDFReaderModel.load(url: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let loaded):
                    let model = PDFReaderModel(loaded: loaded, url: url, state: self.state)
                    self.model = model
                    // One reading mode for every book and PDF (the setting).
                    self.state.flow = self.settings.defaultFlow
                    self.pdfView.document = loaded.document
                    self.applySettings()
                    self.view.window?.windowController?.synchronizeWindowTitleWithDocumentName()
                    // Once PDFKit has laid the document out, go to the saved
                    // page and zoom, then start reporting the page.
                    DispatchQueue.main.async {
                        self.pairSpreads(from: model.startPage)
                        if let page = loaded.document.page(at: model.startPage) { self.pdfView.go(to: page) }
                        self.fitToWindow()
                        if let zoom = model.savedZoom, self.state.flow != .scrolled {
                            self.userZoomed = true
                            self.setScale(self.fitScale * CGFloat(zoom))
                            self.updateScrollers()
                        }
                        self.restoring = false
                        self.pdfView.isHidden = false
                        self.spinner.stopAnimation(nil)
                        self.reportPage()
                        self.firstPageShown()
                        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
                        log.info("PDF: \(model.pageCount) pages, \(self.state.toc.count) contents entries")
                        log.info("First page visible after \(elapsed, format: .fixed(precision: 0)) ms")
                        #if DEBUG
                        self.runDebugSteps(bookName: url.deletingPathExtension().lastPathComponent)
                        #endif
                    }
                case .failure(let error):
                    log.error("Could not open \(url.lastPathComponent, privacy: .name): \(String(describing: error), privacy: .public)")
                    self.showFailure(error)
                }
            }
        }
    }

    // MARK: - Layout, theme and settings

    /// The Layout setting as PDFKit display modes, and the theme around the
    /// page (themes do not recolour the PDF itself).
    override func applySettings() {
        super.applySettings()
        updateAmbient()
        updateRibbon()
        guard pdfView.document != nil else { return }
        let mode: PDFDisplayMode = state.flow == .scrolled ? .singlePageContinuous
            : settings.pageLayout == .two ? .twoUp : .singlePage
        // Pages touch in Two Pages, as on iOS; elsewhere PDFKit's own margin.
        pdfView.displaysPageBreaks = mode != .twoUp
        if pdfView.displayMode != mode {
            let page = pdfView.currentPage
            if mode == .twoUp, let page, let document = pdfView.document { pairSpreads(from: document.index(for: page)) }
            pdfView.displayMode = mode
            userZoomed = false
            fitToWindow()
            if let page { pdfView.go(to: page) }
        }
        state.columnsOnScreen = mode == .twoUp ? 2 : 1
    }

    /// Each page (or two-page spread) shown whole, scaled to fit the window
    /// with a little room around it, as fixed-layout books are (spec,
    /// "Reading modes and layout"). PDFKit's own "fit" fits the width only,
    /// which left spreads taller than the window. Scroll mode fits the width.
    private func fitToWindow() {
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
        if state.flow == .scrolled {
            applyingScale = true
            pdfView.autoScales = true
            applyingScale = false
            fitScale = pdfView.scaleFactor
            updateScrollers()
            return
        }
        var size = page.bounds(for: pdfView.displayBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let across: CGFloat = pdfView.displayMode == .twoUp ? 2 : 1
        let margin: CGFloat = 16
        // The room the pages really have: less what the window's title bar
        // covers (the scroll view is inset under it), and PDFKit's own
        // margins around each page (in the page's units, so they scale with
        // it). Without these a single page in a tall window was cut off at
        // the bottom, with a scroll bar (reported 28 Nov 2026).
        let insets = pdfView.documentView?.enclosingScrollView?.contentInsets ?? NSEdgeInsetsZero
        let breaks = pdfView.displaysPageBreaks ? pdfView.pageBreakMargins : NSEdgeInsetsZero
        let available = CGSize(width: max(pdfView.bounds.width - insets.left - insets.right - 2 * margin, 1),
                               height: max(pdfView.bounds.height - insets.top - insets.bottom - 2 * margin, 1))
        guard size.width > 0, size.height > 0 else { return }
        let pageWidth = (size.width + breaks.left + breaks.right) * across
        let pageHeight = size.height + breaks.top + breaks.bottom
        fitScale = min(available.width / pageWidth, available.height / pageHeight)
        setScale(fitScale)
        updateScrollers()
        #if DEBUG
        log.debug("pdf fit: view \(Int(self.pdfView.bounds.width))x\(Int(self.pdfView.bounds.height)), insets \(Int(insets.top)) \(Int(insets.bottom)), page \(Int(size.width))x\(Int(size.height)), scale \(self.fitScale)")
        #endif
    }

    /// Which pages make the spreads in Two Pages: the page `index` is a left
    /// page, unless it is the first, the cover, which stands alone (on the
    /// right, as in a printed book). PDFKit pairs pages two ways: as a book
    /// (`displaysAsBook`: the first page alone, then 2–3, 4–5…) or from the
    /// first page (1–2, 3–4…), so the choice is by whether the page is odd
    /// or even. (On iOS the page on show when the device turns does the
    /// same.)
    private func pairSpreads(from index: Int) {
        pdfView.displaysAsBook = Self.pairsAsBook(from: index)
    }

    /// Pairs as a book (the first page alone) from page `index` (counted from
    /// 0): for the cover itself, and for pages 2, 4… (indices 1, 3…), which
    /// are then the left pages.
    static func pairsAsBook(from index: Int) -> Bool { index == 0 || index % 2 == 1 }

    private func setScale(_ scale: CGFloat) {
        applyingScale = true
        pdfView.autoScales = false
        pdfView.scaleFactor = scale
        applyingScale = false
    }

    /// No scroll bars while whole pages fit; back when zoomed in, or in
    /// Scroll mode, where there is somewhere to scroll to.
    private func updateScrollers() {
        guard let scrollView = pdfView.documentView?.enclosingScrollView else { return }
        let scrolls = userZoomed || state.flow == .scrolled
        scrollView.hasVerticalScroller = scrolls
        scrollView.hasHorizontalScroller = userZoomed
    }

    /// The Layout choice changes the settings (one reading mode for every
    /// book and PDF); every open reader follows (`followFlowSetting`).
    func setLayout(_ layout: ReadingLayout) {
        if let pages = layout.pages, pages != settings.pageLayout { settings.pageLayout = pages }
        settings.defaultFlow = layout.flow
    }

    func followFlowSetting(_ flow: ReadingFlow) {
        guard flow != state.flow else { return }
        state.flow = flow
        applySettings()
        reportPage()
    }

    // MARK: - Where the reader is

    private var visiblePages: [Int] {
        guard let document = pdfView.document else { return [] }
        if pdfView.displayMode == .twoUp {
            return pdfView.visiblePages.map { document.index(for: $0) }.sorted().prefix(2).map { $0 }
        }
        return pdfView.currentPage.map { [document.index(for: $0)] } ?? []
    }

    private var currentIndex: Int {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return document.index(for: page)
    }

    private func reportPage() {
        guard !restoring, let model, pdfView.currentPage != nil else { return }
        // Back at the cover in spreads paired from the first page (1–2): the
        // cover stands alone again, and the spreads after it start at page 2.
        // (PDFKit reports a spread's right page as the current one.)
        if pdfView.displayMode == .twoUp, !pdfView.displaysAsBook, visiblePages.first == 0 {
            pdfView.displaysAsBook = true
            if let first = pdfView.document?.page(at: 0) { pdfView.go(to: first) }
        }
        // The zoom is saved relative to the fitted size, and only if the
        // reader zoomed.
        let zoom: Double? = userZoomed && fitScale > 0 ? Double(pdfView.scaleFactor / fitScale) : nil
        var visible = visiblePages
        if !visible.contains(currentIndex) { visible.insert(currentIndex, at: 0) }
        model.pageChanged(to: visible.first ?? currentIndex, visible: visible, zoom: zoom)
        view.window?.subtitle = state.chapter
        updateAmbient()
        updateRibbon()
    }

    // MARK: - The bookmark ribbon

    /// Shown on a bookmarked page (no outline while the controls are up:
    /// their Bookmark button does that job).
    private func updateRibbon() {
        ribbon.isHidden = model == nil || !state.isPageBookmarked
        ribbon.isDark = currentTheme.isDark
        if ribbon.isHidden { ribbon.finishMotion() }
        placeRibbon()
    }

    /// Over the top edge of the bookmarked page (in a spread, the
    /// right-hand page if both are, or neither yet), a little in from its
    /// right corner, kept on screen when the page is zoomed or scrolled past.
    private func placeRibbon() {
        guard !ribbon.isHidden, let frame = ribbonFrame(), ribbon.frame != frame else { return }
        ribbon.frame = frame
    }

    private func ribbonFrame() -> CGRect? {
        let visible = visiblePages
        let index = visible.last { model?.isBookmarked(page: $0) == true } ?? visible.last
        guard let document = pdfView.document, let page = index.flatMap({ document.page(at: $0) }) else { return nil }
        let pageRect = view.convert(pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), from: pdfView)
        let size = PDFRibbonView.size
        let x = min(pageRect.maxX - 18 - size.width, view.bounds.maxX - 12 - size.width)
        // From the page's top edge (the root counts up from the bottom), or
        // the window's top when the page runs above it.
        let flipped = view.isFlipped
        if flipped {
            let top = max(pageRect.minY, 0)
            return CGRect(x: x, y: top, width: size.width, height: size.height)
        }
        let top = min(pageRect.maxY, view.bounds.maxY)
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    // MARK: - Ambient light

    /// The colour an inverting filter turns into `colour`. Core Image
    /// inverts in linear light, not in the screen's sRGB, so the opposite is
    /// taken there (an sRGB opposite came out grey round a dark theme).
    private static func opposite(of colour: NSColor) -> NSColor {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return colour }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func srgb(_ c: CGFloat) -> CGFloat { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        func flip(_ c: CGFloat) -> CGFloat { srgb(1 - linear(c)) }
        return NSColor(srgbRed: flip(rgb.redComponent), green: flip(rgb.greenComponent), blue: flip(rgb.blueComponent), alpha: 1)
    }

    /// The glow behind the pages on screen, made again when they or the theme
    /// change. Off (Aa › Ambient Light), the theme's plain colour shows.
    private func updateAmbient() {
        // Invert Colours (Aa, as on iOS): the PDF view drawn through a
        // colour-inverting filter, white paper dark and black text light.
        // Its background is the theme's opposite, so it comes out as the
        // theme's. No glow then: it is of the page's own colours, which
        // would not match the inverted page.
        let inverted = settings.invertPDF
        pdfView.wantsLayer = true
        pdfView.contentFilters = inverted ? [CIFilter(name: "CIColorInvert")].compactMap { $0 } : []
        let glow = settings.ambientLight && !inverted
        ambient.isHidden = !glow
        // The pages' own background lets the glow show through.
        pdfView.backgroundColor = glow ? .clear : inverted ? Self.opposite(of: currentTheme.nsBackground) : currentTheme.nsBackground
        // (PDFKit's scroll view paints a background of its own too.)
        if let scrollView = pdfView.documentView?.enclosingScrollView {
            scrollView.drawsBackground = !glow
            scrollView.contentView.drawsBackground = !glow
        }
        ambient.layer?.backgroundColor = currentTheme.nsBackground.cgColor
        guard glow, let document = pdfView.document else { ambientKey = nil; return }
        let indexes = visiblePages
        let theme = currentTheme.background
        let key = indexes.map(String.init).joined(separator: ",") + " " + theme
        guard key != ambientKey, !indexes.isEmpty else { return }
        ambientKey = key
        let refs = indexes.compactMap { document.page(at: $0)?.pageRef }.map { ($0, $0.getBoxRect(.cropBox)) }
        let brightness = AmbientGlow.brightness(ofHex: theme)
        AmbientGlow.queue.async { [weak self] in
            let image = AmbientGlow.picture(of: refs, themeBrightness: brightness)
            DispatchQueue.main.async {
                guard let self, self.ambientKey == key, let image else { return }
                // A soft fade from one page's glow to the next.
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = 0.35
                    self.ambient.layer?.add(fade, forKey: "fade")
                }
                self.ambient.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                #if DEBUG
                log.debug("pdf ambient: \(key, privacy: .public), \(image.width)x\(image.height), hidden \(self.ambient.isHidden), frame \(Int(self.ambient.frame.width))x\(Int(self.ambient.frame.height))")
                #endif
            }
        }
    }

    override func savePositionNow() { model?.saveNow() }

    // MARK: - Commands (ReaderCommands)

    /// PDFs are always left to right, so "left" is back and "right" forward.
    func turn(_ turn: PageTurn) {
        if !movingForReadAloud { readAloudStarter.pageMovedByHand() }
        let paginated = state.flow != .scrolled && !userZoomed
        guard paginated, !reducedMotion, !movingForReadAloud else { return turnInstantly(turn) }
        switch settings.pageTurnStyle {
        case .curl: curl(turn)
        case .slide: slide(turn)
        case .none: turnInstantly(turn)
        }
    }

    /// Whether there is a page to turn to (a turn past either end does
    /// nothing, and must not draw a curl).
    private func canTurn(_ turn: PageTurn) -> Bool {
        turn.isForward ? pdfView.canGoToNextPage : pdfView.canGoToPreviousPage
    }

    private func turnInstantly(_ turn: PageTurn) {
        if turn.isForward { pdfView.goToNextPage(nil) } else { pdfView.goToPreviousPage(nil) }
    }

    /// Slide: the new page pushed in from the side it comes from.
    private func slide(_ turn: PageTurn) {
        guard canTurn(turn) else { return }
        let push = CATransition()
        push.type = .push
        push.subtype = turn.isForward ? .fromRight : .fromLeft
        push.duration = 0.25
        push.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pdfView.layer?.add(push, forKey: "turn")
        turnInstantly(turn)
    }

    /// Page Curl: as for books (ReaderViewController+PageTurn). A picture of
    /// the pages as they are covers them, the PDF turns underneath, and the
    /// leaf is drawn swinging from the old picture to a picture of the new
    /// pages. Quick turns, one after another, are instant.
    private func curl(_ turn: PageTurn) {
        guard canTurn(turn) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let rapid = now - lastTurnRequest < 0.45
        lastTurnRequest = now
        turnGeneration += 1
        if let previous = pageTurn {
            previous.finish()
            previous.removeFromSuperview()
            pageTurn = nil
        }
        guard !rapid, let before = pagesPicture() else {
            log.debug("pdf page turn: no curl (rapid \(rapid))")
            return turnInstantly(turn)
        }
        // Only the pages curl, not the light around them (as on iOS): the
        // leaf is the page (or the spread), and round it the live glow fades
        // from the old pages' colours to the new ones' as the leaf turns.
        let rectsBefore = pageRects()
        guard let start = curlGeometry(rectsBefore) else { return turnInstantly(turn) }
        let overlay = PageTurnView(frame: start.frame)
        // Over the pages and the ribbon, under the controls.
        view.addSubview(overlay, positioned: .above, relativeTo: ribbon)
        guard let cover = crop(before, to: start.frame) else {
            overlay.removeFromSuperview()
            return turnInstantly(turn)
        }
        overlay.cover(with: cover)
        pageTurn = overlay
        let generation = turnGeneration
        turnInstantly(turn)
        // PDFKit draws the new pages on its next pass.
        DispatchQueue.main.async { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            let remove = { [weak self, weak overlay] in
                overlay?.removeFromSuperview()
                if self?.pageTurn === overlay { self?.pageTurn = nil }
            }
            // Both pictures cut to the region of the pages that were on show
            // (as on iOS: the same region, unless the pages differ in size).
            guard generation == self.turnGeneration, let after = self.pagesPicture(),
                  let a = self.crop(before, to: start.frame), let b = self.crop(after, to: start.frame)
            else { return remove() }
            log.debug("pdf page turn: curl (\(start.spread ? "about a spine" : "one page", privacy: .public)) in \(String(describing: start.frame), privacy: .public), pages \(String(describing: rectsBefore), privacy: .public)")
            overlay.run(before: a, after: b, direction: turn.isForward ? .towardLeft : .towardRight,
                        twoPages: start.spread, completion: remove)
        }
    }

    /// The pages on screen, in the root view's coordinates, left to right.
    private func pageRects() -> [CGRect] {
        guard let document = pdfView.document else { return [] }
        return visiblePages.compactMap { document.page(at: $0) }
            .map { view.convert(pdfView.convert($0.bounds(for: pdfView.displayBox), from: $0), from: pdfView) }
            .sorted { $0.minX < $1.minX }
    }

    /// Where a curl turns (in the root view's coordinates), from the pages
    /// on show as it begins, and whether it turns about a spine, as on iOS:
    /// - Two pages side by side: one leaf about the spine between them.
    /// - A page alone wider than tall (a book's spread on one PDF page):
    ///   about its middle, as two pages would.
    /// - Any other page alone (One Page, or the cover or last page alone in
    ///   Two Pages, which PDFKit centres): the page swings about its left edge.
    /// The region is on whole pixels, inwards, so no hairline of the
    /// background shows down the fold or along the edges (as on iOS).
    private func curlGeometry(_ rects: [CGRect]) -> (frame: CGRect, spread: Bool)? {
        guard let first = rects.first else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat, _ rule: FloatingPointRoundingRule) -> CGFloat { (value * scale).rounded(rule) / scale }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }.intersection(pdfView.frame)
        guard !union.isEmpty else { return nil }
        let region = CGRect(x: snap(union.minX, .up), y: snap(union.minY, .up),
                            width: snap(union.maxX, .down) - snap(union.minX, .up),
                            height: snap(union.maxY, .down) - snap(union.minY, .up))
        var spine: CGFloat?
        if rects.count == 2 {
            spine = rects[0].maxX // the pages touch
        } else if first.width > first.height {
            spine = union.midX
        }
        guard let spine else { return (region, false) }
        // Two halves of equal width either side of the spine (PageTurnView
        // turns about its middle). Pages a pixel or two apart in width are
        // taken at the narrower, so no leaf takes in what is beyond its page.
        let middle = snap(spine, .toNearestOrAwayFromZero)
        let left = middle - region.minX, right = region.maxX - middle
        let half = abs(left - right) <= 2 / scale ? min(left, right) : max(left, right)
        guard half > 0 else { return (region, false) }
        return (CGRect(x: middle - half, y: region.minY, width: half * 2, height: region.height), true)
    }

    /// Part of a picture of the PDF view (`pagesPicture`), by a rect in the
    /// root view's coordinates.
    private func crop(_ picture: CGImage, to rect: CGRect) -> CGImage? {
        let frame = pdfView.frame
        let scale = CGFloat(picture.width) / max(frame.width, 1)
        var local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        // Pictures count rows from the top.
        if !view.isFlipped { local.origin.y = frame.height - local.maxY }
        let pixels = CGRect(x: local.minX * scale, y: local.minY * scale,
                            width: local.width * scale, height: local.height * scale).integral
        return picture.cropping(to: pixels)
    }

    /// The pages as the reader sees them, the glow and the ribbon included,
    /// the size of the PDF view.
    private func pagesPicture() -> CGImage? {
        view.layoutSubtreeIfNeeded()
        let rect = pdfView.frame
        guard rect.width > 0, rect.height > 0 else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // The theme's colour, then each layer of what is on screen.
        context.setFillColor(currentTheme.nsBackground.cgColor)
        context.fill(CGRect(origin: .zero, size: rect.size))
        for part in [ambient, pdfView, ribbon] as [NSView] where !part.isHidden {
            guard let rep = part.bitmapImageRepForCachingDisplay(in: part.bounds) else { continue }
            part.cacheDisplay(in: part.bounds, to: rep)
            guard var image = rep.cgImage else { continue }
            // Invert Colours is a filter on the PDF view's layer, which a
            // cached drawing leaves out: applied here too.
            if part === pdfView, settings.invertPDF, let inverted = Self.inverted(image) { image = inverted }
            // The part's place within the PDF view's frame (both in the root's
            // coordinates, which count up from the bottom as the context does).
            var frame = view.convert(part.bounds, from: part)
            frame.origin.x -= rect.minX
            frame.origin.y -= rect.minY
            if view.isFlipped { frame.origin.y = rect.height - frame.maxY }
            context.draw(image, in: frame)
        }
        return context.makeImage()
    }

    private static func inverted(_ image: CGImage) -> CGImage? {
        guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    func jump(to href: String, keepOrigin: Bool) {
        guard let model, let index = model.pageIndex(for: href), let page = pdfView.document?.page(at: index) else { return }
        model.noteJump(from: currentIndex, to: index, keepOrigin: keepOrigin)
        readAloudStarter.pageMovedByHand()
        pdfView.go(to: page)
    }

    func jump(toFraction fraction: Double) {
        guard let model else { return }
        jump(to: PDFReaderModel.href(page: model.page(atFraction: fraction)), keepOrigin: false)
    }

    func goBack() {
        guard let target = model?.takeBackTarget(), let page = pdfView.document?.page(at: target) else { return }
        readAloudStarter.pageMovedByHand()
        pdfView.go(to: page)
    }

    /// Previous and next chapter: the outline's entries.
    func previousChapter() {
        if let target = outlinePages.last(where: { $0 < currentIndex }) {
            jump(to: PDFReaderModel.href(page: target), keepOrigin: false)
        }
    }

    func nextChapter() {
        if let target = outlinePages.first(where: { $0 > currentIndex }) {
            jump(to: PDFReaderModel.href(page: target), keepOrigin: false)
        }
    }

    private var outlinePages: [Int] {
        state.toc.compactMap { model?.pageIndex(for: $0.href) }.sorted()
    }

    func toggleBookmark() {
        let wasMarked = state.isPageBookmarked
        // Which side it swings from: the page's outer side.
        let outerIsLeft = visiblePages.count > 1 && ribbon.frame.midX < view.bounds.midX
        if wasMarked {
            // Lifted off, then gone.
            ribbon.liftOff(outerIsLeft: outerIsLeft) { [weak self] in self?.updateRibbon() }
            model?.toggleBookmark(visible: visiblePages)
            ribbon.isHidden = false // until the lift is over
            return
        }
        model?.toggleBookmark(visible: visiblePages)
        updateRibbon()
        if !ribbon.isHidden { ribbon.layDown(outerIsLeft: outerIsLeft) }
    }
    func removeBookmark(cfi: String) { model?.removeBookmark(cfi: cfi, visible: visiblePages) }

    func search(_ query: String) {
        pdfView.highlightedSelections = nil
        model?.search(query)
    }

    func goToHit(_ hit: ReaderState.SearchHit) {
        guard let model else { return }
        let keep = state.currentHitID != nil // Back returns to before the first result
        state.currentHitID = hit.id
        guard let selection = model.hitSelections[hit.id] else { return jump(to: hit.cfi, keepOrigin: keep) }
        model.noteJump(from: currentIndex, to: model.pageIndex(for: hit.cfi) ?? 0, keepOrigin: keep)
        readAloudStarter.pageMovedByHand()
        pdfView.highlightedSelections = Array(model.hitSelections.values)
        selection.color = .systemYellow
        pdfView.go(to: selection)
        pdfView.setCurrentSelection(selection, animate: true)
    }

    func searchPanelClosed() {
        pdfView.highlightedSelections = nil
        model?.cancelSearch()
    }

    #if DEBUG
    /// "@readAloudPreview:": the first sentences read aloud from the start
    /// (corpus checks: no headers, footers or page numbers in them).
    @objc func readAloudPreview(_ sender: Any?) {
        guard let document = pdfView.document else { return }
        log.info("step result: read aloud: \(PDFReadAloud.preview(of: document), privacy: .public)")
    }

    /// The same PLATEN_SNAPSHOT_DIR / PLATEN_STEPS hooks as the book window
    /// (see DebugHooks.swift), for "@<selector>" steps.
    private func runDebugSteps(bookName: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["PLATEN_SNAPSHOT_DIR"] != nil else { return }
        let steps = (env["PLATEN_STEPS"] ?? "").split(separator: ";").map(String.init)
        func step(_ i: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                DebugHooks.snapshotView(self.view, name: "\(bookName)-\(i)-native", suffix: "")
                guard i < steps.count else { return }
                let s = steps[i]
                if self.runReadAloudDebugStep(s) {
                    // Read aloud's steps (DebugHooks.swift).
                } else if s == "@snappage" {
                    // The page on screen as PDFKit draws it, annotations (read
                    // aloud's underline) included, which a snapshot of the
                    // view can miss: "<book>-<n>-page.png".
                    if let page = self.pdfView.currentPage, let dir = env["PLATEN_SNAPSHOT_DIR"],
                       let tiff = page.thumbnail(of: NSSize(width: 1200, height: 1600), for: .mediaBox).tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(bookName)-\(i)-page.png"))
                    }
                } else if s == "@snapwindows" {
                    // The windows as the window server draws them (pages
                    // and the light around them as the reader sees them).
                    DebugHooks.snapshotWindows(name: "\(bookName)-\(i)")
                } else if s.hasPrefix("@layout:"), let layout = ReadingLayout(rawValue: String(s.dropFirst("@layout:".count))) {
                    // "@layout:twoPages": the Layout choice (onePage, twoPages, scroll).
                    self.setLayout(layout)
                } else if s.hasPrefix("@resize:") {
                    // "@resize:900x700": the window's content size, as for books.
                    let parts = s.dropFirst("@resize:".count).split(separator: "x").compactMap { Double($0) }
                    if parts.count == 2 { self.view.window?.setContentSize(NSSize(width: parts[0], height: parts[1])) }
                } else if s.hasPrefix("@") {
                    // To this reader directly: the app may not be frontmost
                    // during checks, so the responder chain may not reach it.
                    // Only an action this reader has: a book-only step
                    // ("@settings:1", "@snapwindows") sent here was passed
                    // on as an unknown selector and crashed the run (24 Nov
                    // 2026), so it is now logged and skipped.
                    let action = Selector(String(s.dropFirst()))
                    if self.responds(to: action) {
                        NSApp.sendAction(action, to: self, from: nil)
                    } else {
                        log.notice("step not understood by the PDF reader: \(s, privacy: .public)")
                    }
                }
                log.info("step: \(s, privacy: .public) page \(self.currentIndex + 1), on screen \(self.visiblePages.map { $0 + 1 }, privacy: .public), as book \(self.pdfView.displaysAsBook)")
                step(i + 1)
            }
        }
        step(0)
    }
    #endif
}

// MARK: - Read aloud (PDFReadAloud; the speaker is ReaderBaseViewController's)

extension PDFReaderViewController: PDFReadAloudHost {
    var readAloudStartPage: Int { visiblePages.first ?? currentIndex }

    /// Turns to `index` when the voice reaches it, if it is not on screen.
    func readAloudShow(page index: Int) {
        guard let document = pdfView.document, let page = document.page(at: index) else { return }
        if state.flow == .scrolled {
            if !pdfView.visiblePages.contains(page) { pdfView.go(to: page) }
            return
        }
        guard !visiblePages.contains(index) else { return }
        movingForReadAloud = true
        defer { movingForReadAloud = false }
        pdfView.go(to: page)
    }

    /// A thin underline in the accent colour under each line of the words,
    /// as an underline annotation on the page in memory (Platen never
    /// writes PDFs, so it is never saved).
    func readAloudUnderline(_ ranges: [(page: Int, range: NSRange)]) {
        // The pages whose underline changes are redrawn (on the Mac, PDFView
        // does not notice annotations added to a page on its own).
        var changed = Set(readAloudAnnotations.map { ObjectIdentifier($0.page) })
        var pages = readAloudAnnotations.map(\.page)
        defer {
            for page in pages where changed.remove(ObjectIdentifier(page)) != nil { pdfView.annotationsChanged(on: page) }
        }
        for (page, annotation) in readAloudAnnotations { page.removeAnnotation(annotation) }
        readAloudAnnotations.removeAll()
        guard let document = pdfView.document else { return }
        for item in ranges {
            guard let page = document.page(at: item.page), let selection = page.selection(for: item.range) else { continue }
            for line in selection.selectionsByLine() {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .underline, withProperties: nil)
                annotation.color = NSColor(Color.platenAccent)
                // The underline runs along the bottom of the bounds (the
                // points are relative to them).
                annotation.quadrilateralPoints = [
                    NSPoint(x: 0, y: bounds.height), NSPoint(x: bounds.width, y: bounds.height),
                    NSPoint(x: 0, y: 0), NSPoint(x: bounds.width, y: 0),
                ].map { NSValue(point: $0) }
                let border = PDFBorder()
                border.lineWidth = 1.5
                annotation.border = border
                page.addAnnotation(annotation)
                readAloudAnnotations.append((page, annotation))
                if changed.insert(ObjectIdentifier(page)).inserted { pages.append(page) }
            }
        }
        #if DEBUG
        if !ranges.isEmpty { log.debug("read aloud: underline on \(self.readAloudAnnotations.count) line(s)") }
        #endif
    }
}

/// PDFView with Platen's clicks and keys: a plain click (no drag, no
/// selection made, not on a link) is reported, and keys go to the reader
/// first. Everything else (selection, links, Look Up, copying) is PDFKit's.
final class PlatenPDFView: PDFView {
    var onClick: ((NSPoint) -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    private var down: (point: NSPoint, time: TimeInterval)?

    override func mouseDown(with event: NSEvent) {
        down = (convert(event.locationInWindow, from: nil), event.timestamp)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let down, event.clickCount == 1,
              hypot(point.x - down.point.x, point.y - down.point.y) < 4,
              event.timestamp - down.time < 0.45 else { return }
        self.down = nil
        // A click that selected nothing and was not on a link.
        if let selection = currentSelection, !(selection.string ?? "").isEmpty { return }
        if let page = page(for: point, nearest: false),
           page.annotation(at: convert(point, to: page))?.type == "Link" { return }
        onClick?(point)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}
