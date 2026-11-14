import Combine
import PDFKit
import PlatenCore
import SwiftUI
import UIKit

/// The reader for a PDF on iOS and iPadOS (spec, "PDF"). PDFKit draws the
/// pages; the overlay, contents, bookmarks and search are the same as for
/// books (ReaderChrome, and the shared PDFReaderModel).
///
/// Two layouts, chosen with the overlay's Layout button (and remembered per
/// PDF): **Pages** and **Scroll** (one long column of pages, scrolled up and
/// down). In Pages, the number of pages follows the orientation, on iPhone
/// and iPad alike:
/// - **Portrait:** one page at a time; a swipe follows the finger.
/// - **Landscape:** two pages side by side, touching, so a scanned spread
///   reads as one. The pairing starts at the page the reader was on when they
///   rotated, and holds: each turn moves two pages. If the pairs look wrong
///   (some PDFs have an extra cover page), rotating back, turning one page
///   and rotating again fixes them. Rotating back shows the pair's left page.
final class PDFReaderViewController: ReaderBaseViewController, ReaderCommands, UIGestureRecognizerDelegate {
    private var pdfView: PDFView!
    private var ribbon: UIImageView!
    private var model: PDFReaderModel?
    /// Landscape: whether the pairs start at an odd page (see the type's
    /// notes). Decided when the reader rotates to landscape.
    private var spreadsStartOdd = false
    private var isLandscape = false
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

        // The bookmark ribbon in the top-right corner of a bookmarked page;
        // a faint outline while the controls are up.
        ribbon = UIImageView(image: UIImage(systemName: "bookmark.fill"))
        ribbon.translatesAutoresizingMaskIntoConstraints = false
        ribbon.contentMode = .scaleAspectFit
        ribbon.isHidden = true
        ribbon.isAccessibilityElement = false
        root.addSubview(ribbon)

        // Pages (one or a spread, by orientation) or Scroll; never "Two
        // Pages" as a choice of its own.
        state.allowsTwoPages = false
        installChrome(in: root)
        chrome.onVisibilityChanged = { [weak self] _ in self?.updateRibbon() }
        chrome.setInterfaceStyle(.light)

        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: root.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ribbon.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            ribbon.topAnchor.constraint(equalTo: safe.topAnchor, constant: 2),
            ribbon.widthAnchor.constraint(equalToConstant: 18),
            ribbon.heightAnchor.constraint(equalToConstant: 26),
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
                    if model.record.readingMode.flatMap(ReadingFlow.init) == .scrolled { self.state.flow = .scrolled }
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

    // MARK: - Layout (Scroll; or pages: one in portrait, a spread in landscape)

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutForOrientation(force: false, keepPage: nil)
    }

    private func layoutForOrientation(force: Bool, keepPage: Int?) {
        guard let document = pdfView.document else { return }
        let landscape = view.bounds.width > view.bounds.height
        guard force || landscape != isLandscape else { return }
        let wasLandscape = isLandscape
        isLandscape = landscape
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
        } else if landscape {
            pdfView.displayDirection = .horizontal
            if !wasLandscape || force { spreadsStartOdd = current % 2 == 1 }
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
        swipes.forEach { $0.isEnabled = landscape && state.flow == .paginated }
        pdfView.autoScales = true
        if let page = document.page(at: current) { pdfView.go(to: page) }
        // Switching modes gives PDFKit's inner views their own (grey)
        // background and scroll bars; the theme colour goes back on.
        DispatchQueue.main.async { self.applyTheme() }
        reportPage()
    }

    /// Pages or Scroll, from the overlay's Layout button.
    func setLayout(_ layout: ReadingLayout) {
        guard layout.flow != state.flow else { return }
        let current = currentIndex
        state.flow = layout.flow
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
        // The top-right corner bookmarks the page, as for books.
        if point.x > width - 64, point.y < view.safeAreaInsets.top + 48 {
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
        let pages = pdfView.visiblePages.map { document.index(for: $0) }.sorted()
        if pages.isEmpty, let current = pdfView.currentPage { return [document.index(for: current)] }
        return isLandscape && state.flow == .paginated ? Array(pages.prefix(2)) : Array(pages.prefix(1))
    }

    private func reportPage() {
        guard !restoring, let model, let document = pdfView.document, let current = pdfView.currentPage else { return }
        let fit = pdfView.scaleFactorForSizeToFit
        let zoom = fit > 0 ? Double(pdfView.scaleFactor / fit) : 1
        var visible = visiblePages
        let index = document.index(for: current)
        if !visible.contains(index) { visible.insert(index, at: 0) }
        model.pageChanged(to: visible.first ?? index, visible: visible, zoom: zoom > 1.05 ? zoom : nil)
        updateRibbon()
    }

    private func updateRibbon() {
        // Hidden while the controls are up: their buttons sit over this
        // corner, and the Bookmark button there shows the same thing.
        let visible = chrome.isVisible
        ribbon.isHidden = model == nil || !state.isPageBookmarked || visible
        ribbon.image = UIImage(systemName: "bookmark.fill")
        ribbon.tintColor = UIColor(red: 0.82, green: 0.2, blue: 0.17, alpha: 1)
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

    /// Themes colour only the background around the page (spec, "PDF").
    override func applyTheme() {
        super.applyTheme()
        let theme = currentTheme
        if let pdfView {
            pdfView.backgroundColor = theme.uiBackground
            // PDFKit's own scroll and page views, inside the PDFView.
            var queue: [UIView] = pdfView.subviews
            while let next = queue.popLast() {
                if let scroll = next as? UIScrollView {
                    scroll.showsHorizontalScrollIndicator = false
                    scroll.showsVerticalScrollIndicator = false
                    scroll.backgroundColor = theme.uiBackground
                } else if next.backgroundColor != nil, !(next is UIImageView),
                          next.bounds.width >= pdfView.bounds.width * 0.9 {
                    // Full-width containers only, never the pages themselves.
                    next.backgroundColor = theme.uiBackground
                }
                queue.append(contentsOf: next.subviews)
            }
        }
    }
}
