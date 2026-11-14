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
///   swipe follows the finger.
/// - **Two Pages:** one page in portrait, as above; in landscape, two pages
///   side by side, touching, so a scanned spread reads as one. The pairing
///   starts at the page the reader was on when they rotated, and holds: each
///   turn moves two pages. If the pairs look wrong (some PDFs have an extra
///   cover page), rotating back, turning one page and rotating again fixes
///   them. Rotating back shows the pair's left page.
/// - **Scroll:** one long column of pages, scrolled up and down.
final class PDFReaderViewController: ReaderBaseViewController, ReaderCommands, UIGestureRecognizerDelegate {
    private(set) var pdfView: PDFView!
    /// Behind the pages: their own colours, softened (PDFAmbientBackground).
    private var ambient: UIImageView!
    /// What the ambient background was last made for (pages and theme), so
    /// it is only remade when that changes.
    private var ambientKey: String?
    private var ribbon: BookmarkRibbonView!
    /// Watches the PDF view's scrolling (Scroll layout, zoom), so the ribbon
    /// moves with its page.
    private var scrollObservation: NSKeyValueObservation?
    private var model: PDFReaderModel?
    /// Landscape: whether the pairs start at an odd page (see the type's
    /// notes). Decided when the reader rotates to landscape.
    private var spreadsStartOdd = false
    private var isLandscape = false
    /// Two pages side by side on screen now (Two Pages, in landscape).
    private var isSpread = false
    /// Text was selected before the latest tap; that tap only clears it.
    private var hadSelection = false
    private var swipes: [UISwipeGestureRecognizer] = []
    /// True while opening, until the saved page is on screen: PDFKit reports
    /// the first page meanwhile, which must not overwrite the saved place.
    private var restoring = true
    /// Draws tap turns as a slide or a page curl (Settings > Page Turn),
    /// the same as in the book reader.
    private lazy var pageTurner = PageTurnAnimator(
        host: self, pageView: pdfView,
        snapshot: { [weak self] done in
            guard let self else { return done(nil) }
            let view: UIView = self.pdfView
            let format = UIGraphicsImageRendererFormat.preferred()
            format.opaque = true
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done(self.currentIndex != before) }
        })

    init(url: URL) {
        super.init(url: url, state: ReaderState())
    }

    override var commands: ReaderCommands { self }
    override var pageView: UIView { pdfView }
    override var hasShownPage: Bool { model != nil }
    override var failureFallbackTitle: String { String(localized: "This PDF could not be opened.") }
    override var hidesTextSettings: Bool { true }

    // MARK: - View setup

    override func loadView() {
        let root = UIView()

        // The ambient background, stretched across the whole screen behind
        // the PDF view (which is see-through around its pages).
        ambient = UIImageView()
        ambient.translatesAutoresizingMaskIntoConstraints = false
        ambient.contentMode = .scaleToFill
        ambient.isAccessibilityElement = false
        root.addSubview(ambient)

        pdfView = PDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayDirection = .horizontal
        pdfView.pageShadowsEnabled = false
        pdfView.isHidden = true
        root.addSubview(pdfView)

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

        // Landscape spreads are not paged by PDFKit's page view controller,
        // so swipes there turn the spread.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            swipe.isEnabled = false
            pdfView.addGestureRecognizer(swipe)
            swipes.append(swipe)
        }

        // The bookmark ribbon over the top edge of a bookmarked page, near
        // its right corner (placed by placeRibbon, as the page moves).
        ribbon = BookmarkRibbonView(frame: CGRect(origin: .zero, size: BookmarkRibbonView.size))
        ribbon.isHidden = true
        root.addSubview(ribbon)

        // One Page, Two Pages (a spread in landscape only) or Scroll, on
        // iPhone too (books there always show one page).
        state.allowsTwoPages = true
        installChrome(in: root)
        chrome.onVisibilityChanged = { [weak self] _ in self?.updateRibbon() }
        chrome.setInterfaceStyle(.light)
        configurePageTurner()

        NSLayoutConstraint.activate([
            ambient.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ambient.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ambient.topAnchor.constraint(equalTo: root.topAnchor),
            ambient.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: root.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
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
                            self.pdfView.scaleFactor = self.pdfView.scaleFactorForSizeToFit * zoom
                        }
                        self.restoring = false
                        self.pdfView.isHidden = false
                        self.reportPage()
                    }
                    self.spinner.stopAnimating()
                    let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
                    log.info("PDF: \(model.pageCount) pages, \(self.state.toc.count) contents entries")
                    log.info("First page visible after \(elapsed, format: .fixed(precision: 0)) ms")
                case .failure(let error):
                    log.error("Could not open \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                    self.showFailure(error)
                }
            }
        }
    }

    // MARK: - Layout (Scroll; or pages: one, or a spread in landscape)

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutForOrientation(force: false, keepPage: nil)
        placeRibbon()
    }

    private func layoutForOrientation(force: Bool, keepPage: Int?) {
        guard let document = pdfView.document else { return }
        let landscape = view.bounds.width > view.bounds.height
        guard force || landscape != isLandscape else { return }
        let wasSpread = isSpread
        isLandscape = landscape
        // pageLayout is read when the setting has already changed (the
        // observer runs after the change), so this is the new choice.
        let spread = landscape && state.flow == .paginated && settings.pageLayout == .two
        isSpread = spread
        // The page to keep in view: the one being read (in a spread, its
        // left page, which PDFKit reports as the current page).
        let current = keepPage ?? pdfView.currentPage.map { document.index(for: $0) } ?? 0

        if state.flow == .scrolled {
            // One long column of pages, in either orientation.
            pdfView.usePageViewController(false)
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
            pdfView.displaysAsBook = false
            pdfView.displaysPageBreaks = true
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
            pdfView.displayMode = .singlePage
            pdfView.displaysAsBook = false
            pdfView.displaysPageBreaks = true
            // Paging by PDFKit's page view controller: a swipe follows the
            // finger, as for books.
            pdfView.usePageViewController(true, withViewOptions: [UIPageViewController.OptionsKey.interPageSpacing: 12])
        }
        swipes.forEach { $0.isEnabled = spread }
        state.columnsOnScreen = spread ? 2 : 1
        pdfView.autoScales = true
        if let page = document.page(at: current) { pdfView.go(to: page) }
        // Switching modes gives PDFKit's inner views their own (grey)
        // background and scroll bars; the theme colour goes back on. They
        // are new views, so the ribbon watches the new scroll view.
        DispatchQueue.main.async {
            self.applyTheme()
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
        let ribbonTarget = ribbonFrame().map { view.convert($0, to: pdfView).insetBy(dx: -16, dy: -12) }
        if ribbonTarget?.contains(point) == true || (point.x > width - 64 && point.y < view.safeAreaInsets.top + 48) {
            toggleBookmark()
        } else if state.flow == .scrolled {
            chrome.toggle() // in Scroll, any tap shows or hides the controls
        } else {
            switch ClickZone(x: point.x, width: width) {
            case .left: turn(.left)
            case .right: turn(.right)
            case .centre: chrome.toggle()
            }
        }
    }

    @objc private func swiped(_ recogniser: UISwipeGestureRecognizer) {
        turn(recogniser.direction == .left ? .right : .left)
    }

    private func configurePageTurner() {
        // A turn past the first or last page says so, rather than just not
        // moving.
        pageTurner.onEdge = { [weak self] request in
            self?.chrome.showNotice(request == .next ? String(localized: "End of document")
                                                      : String(localized: "Start of document"))
        }
        // Only the page curls (or the spread, in landscape), not the
        // background around it; its back is paper, whatever the theme.
        pageTurner.curlRegion = { [weak self] in self?.pageRegion }
        pageTurner.curlBackColour = { UIColor(white: 0.94, alpha: 1) }
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
        let fit = pdfView.scaleFactorForSizeToFit
        let zoom = fit > 0 ? Double(pdfView.scaleFactor / fit) : 1
        let index = document.index(for: current)
        var visible = visiblePages
        if !visible.contains(index) { visible.insert(index, at: 0) }
        model.pageChanged(to: visible.first ?? index, visible: visible, zoom: zoom > 1.05 ? zoom : nil)
        updateRibbon()
        updateAmbient()
    }

    private func updateRibbon() {
        // Only on a bookmarked page. (No faint outline while the controls
        // are up: their Bookmark button does that job.)
        ribbon.isHidden = model == nil || !state.isPageBookmarked
        placeRibbon()
    }

    /// Where the ribbon goes, in this view's coordinates: over the top edge
    /// of the bookmarked page (in a spread, the right-hand page if both are,
    /// or neither yet), a little in from its right corner, starting just
    /// above the edge as if it came from the binding. Kept on screen when
    /// the page is zoomed or scrolled past.
    private func ribbonFrame() -> CGRect? {
        let visible = visiblePages
        let index = visible.last { model?.isBookmarked(page: $0) == true } ?? visible.last
        guard let document = pdfView.document, let page = index.flatMap({ document.page(at: $0) }) else { return nil }
        let pageRect = view.convert(pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), from: pdfView)
        let size = BookmarkRibbonView.size
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let x = min(pageRect.maxX - 18 - size.width, safe.maxX - 12 - size.width)
        var y = max(pageRect.minY - 4, 0)
        if state.flow == .scrolled { y = max(y, safe.minY) }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func placeRibbon() {
        guard !ribbon.isHidden, let frame = ribbonFrame() else { return }
        if ribbon.frame != frame { ribbon.frame = frame }
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
            MainActor.assumeIsolated { self?.placeRibbon() }
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
        model?.toggleBookmark(visible: visiblePages)
        updateRibbon()
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

    // MARK: - Theme

    /// The ambient background for the pages on screen, faded in over the
    /// last one. Remade only when the pages or the theme change.
    private func updateAmbient() {
        guard let document = pdfView.document else { return }
        let pages = visiblePages.compactMap { document.page(at: $0) }
        let theme = currentTheme.uiBackground
        let key = "\(visiblePages) \(theme)"
        guard key != ambientKey, !pages.isEmpty else { return }
        ambientKey = key
        PDFAmbientBackground.make(for: pages, theme: theme) { [weak self] image in
            guard let self, self.ambientKey == key, let image else { return }
            let fade = UIAccessibility.isReduceMotionEnabled ? 0 : 0.35
            UIView.transition(with: self.ambient, duration: fade, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.ambient.image = image
            }
        }
    }

    /// Themes colour the background around the page (spec, "PDF"), here
    /// mixed with the page's own colours (updateAmbient), so the PDF view
    /// and its inner views are see-through.
    override func applyTheme() {
        super.applyTheme()
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
