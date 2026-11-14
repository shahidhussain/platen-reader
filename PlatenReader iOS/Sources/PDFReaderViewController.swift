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
final class PDFReaderViewController: UIViewController, UIGestureRecognizerDelegate {
    let url: URL
    let state = ReaderState()
    let settings = ReaderSettings.shared
    var onClose: (() -> Void)?

    private var pdfView: PDFView!
    /// Behind the pages: their own colours, softened (PDFAmbientBackground).
    private var ambient: UIImageView!
    /// What the ambient background was last made for (pages and theme), so
    /// it is only remade when that changes.
    private var ambientKey: String?
    private var spinner: UIActivityIndicatorView!
    private var ribbon: UIImageView!
    private var failureHost: UIViewController?
    private(set) var chrome: ReaderChrome?
    private var model: PDFReaderModel?
    private var cancellables: Set<AnyCancellable> = []
    private var accessingSecurityScope = false
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
            let forward = request == .next || request == .right
            if forward { self.pdfView.goToNextPage(nil) } else { self.pdfView.goToPreviousPage(nil) }
            self.pdfView.layoutIfNeeded()
            // PDFKit draws the new page a moment later; wait for it, so the
            // picture of the new page (for a curl) is not blank.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done(self.currentIndex != before) }
        })

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
        // Stretched to the frame: a little wider than the symbol's own shape.
        ribbon.contentMode = .scaleToFill
        ribbon.isHidden = true
        ribbon.isAccessibilityElement = false
        root.addSubview(ribbon)

        spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)

        let chrome = ReaderChrome(owner: self, state: state, actions: overlayActions, sidebarActions: contentsActions,
                                  close: { [weak self] in self?.close() },
                                  sidebarClosed: { [weak self] in
                                      // Search highlights are temporary.
                                      self?.pdfView.highlightedSelections = nil
                                      self?.model?.cancelSearch()
                                  })
        chrome.onVisibilityChanged = { [weak self] _ in self?.updateRibbon() }
        // Pages (one or a spread, by orientation) or Scroll; never "Two
        // Pages" as a choice of its own.
        state.allowsTwoPages = false
        chrome.install(in: root)
        chrome.setInterfaceStyle(.light)
        self.chrome = chrome
        configurePageTurner()

        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            ambient.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ambient.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ambient.topAnchor.constraint(equalTo: root.topAnchor),
            ambient.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: root.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ribbon.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            ribbon.topAnchor.constraint(equalTo: safe.topAnchor, constant: 2),
            ribbon.widthAnchor.constraint(equalToConstant: 22),
            ribbon.heightAnchor.constraint(equalToConstant: 26),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyTheme()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyTheme() }
            .store(in: &cancellables)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.applyTheme() }
        settings.$defaultFlow
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] flow in self?.followFlowSetting(flow) }
            .store(in: &cancellables)
        state.$isPageBookmarked
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateRibbon() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.model?.saveNow() }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.model == nil, self.failureHost == nil else { return }
            self.spinner.startAnimating()
        }
    }

    override var prefersStatusBarHidden: Bool { !(chrome?.isVisible ?? false) }
    override var prefersHomeIndicatorAutoHidden: Bool { !(chrome?.isVisible ?? false) }
    override var preferredStatusBarStyle: UIStatusBarStyle { currentTheme.isDark ? .lightContent : .darkContent }

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
                    self.showFailure(error)
                }
            }
        }
    }

    private func showFailure(_ error: Error) {
        log.error("Could not open \(self.url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        spinner.stopAnimating()
        let title = (error as? LocalizedError)?.errorDescription ?? String(localized: "This PDF could not be opened.")
        let detail = (error as? LocalizedError)?.recoverySuggestion
        let host = UIHostingController(rootView: OpenFailureView(title: title, detail: detail))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.insertSubview(host.view, belowSubview: chrome?.top.view ?? pdfView)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            host.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
        ])
        host.didMove(toParent: self)
        failureHost = host
        if state.title.isEmpty { state.title = url.deletingPathExtension().lastPathComponent }
        chrome?.showCloseOnly()
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

    /// Pages or Scroll, from the overlay's Layout button. It changes the
    /// setting (one reading mode for every book and PDF); this reader, and
    /// any other open one, follows (`followFlowSetting`).
    private func setLayout(_ layout: ReadingLayout) {
        settings.defaultFlow = layout.flow
    }

    private func followFlowSetting(_ flow: ReadingFlow) {
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
        let side = width * 0.38
        // The top-right corner bookmarks the page, as for books.
        if point.x > width - 64, point.y < view.safeAreaInsets.top + 48 {
            toggleBookmark()
        } else if state.flow == .scrolled {
            chrome?.toggle() // in Scroll, any tap shows or hides the controls
        } else if point.x < side {
            turn(forward: false)
        } else if point.x > width - side {
            turn(forward: true)
        } else {
            chrome?.toggle()
        }
    }

    @objc private func swiped(_ recogniser: UISwipeGestureRecognizer) {
        turn(forward: recogniser.direction == .left)
    }

    private func configurePageTurner() {
        // A turn past the first or last page says so, rather than just not
        // moving.
        pageTurner.onEdge = { [weak self] request in
            self?.chrome?.showNotice(request == .next ? String(localized: "End of document")
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
    private func turn(forward: Bool) {
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
        updateAmbient()
    }

    private func updateRibbon() {
        // Only on a bookmarked page. (No faint outline while the controls
        // are up: their Bookmark button does that job.)
        ribbon.isHidden = model == nil || !state.isPageBookmarked
        ribbon.image = UIImage(systemName: "bookmark.fill")
        ribbon.tintColor = UIColor(red: 0.82, green: 0.2, blue: 0.17, alpha: 1)
    }

    // MARK: - Overlay actions

    private var currentIndex: Int {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return document.index(for: page)
    }

    /// A jump (contents, bookmark, search result, slider): remembered, so the
    /// overlay offers "Back to p. N".
    private func jump(toPage index: Int, keepOrigin: Bool = false) {
        guard let model, let page = pdfView.document?.page(at: index) else { return }
        model.noteJump(from: currentIndex, to: index, keepOrigin: keepOrigin)
        pdfView.go(to: page)
    }

    private var overlayActions: OverlayActions {
        OverlayActions(
            previousPage: { [weak self] in self?.turn(forward: false) },
            nextPage: { [weak self] in self?.turn(forward: true) },
            goToFraction: { [weak self] f in
                guard let self, let model = self.model else { return }
                self.jump(toPage: model.page(atFraction: f))
            },
            goBack: { [weak self] in
                guard let self, let target = self.model?.takeBackTarget(),
                      let page = self.pdfView.document?.page(at: target) else { return }
                self.pdfView.go(to: page)
            },
            toggleContents: { [weak self] in
                self?.state.sidebarVisible.toggle()
                self?.chrome?.restartHideTimer()
            },
            setLayout: { [weak self] layout in self?.setLayout(layout) },
            toggleBookmark: { [weak self] in self?.toggleBookmark() },
            interacted: { [weak self] in self?.chrome?.restartHideTimer() },
            settingsContent: { AnyView(ReaderSettingsView(isFixedLayout: true)) }
        )
    }

    private var contentsActions: ContentsActions {
        ContentsActions(
            goToTOCItem: { [weak self] item in
                guard let self, let index = self.model?.pageIndex(for: item.href) else { return }
                self.jump(toPage: index)
                self.state.sidebarVisible = false
            },
            goToBookmark: { [weak self] bookmark in
                guard let self, let index = self.model?.pageIndex(for: bookmark.cfi) else { return }
                self.jump(toPage: index)
                self.state.sidebarVisible = false
            },
            removeBookmark: { [weak self] bookmark in
                guard let self else { return }
                self.model?.removeBookmark(cfi: bookmark.cfi, visible: self.visiblePages)
            },
            search: { [weak self] query in
                self?.model?.search(query)
                self?.pdfView.highlightedSelections = nil
            },
            goToHit: { [weak self] hit in
                guard let self, let model = self.model else { return }
                let keep = self.state.currentHitID != nil // Back returns to before the first result
                self.state.currentHitID = hit.id
                if let selection = model.hitSelections[hit.id] {
                    model.noteJump(from: self.currentIndex, to: model.pageIndex(for: hit.cfi) ?? 0, keepOrigin: keep)
                    self.pdfView.highlightedSelections = Array(model.hitSelections.values)
                    selection.color = .systemYellow
                    self.pdfView.go(to: selection)
                    self.pdfView.setCurrentSelection(selection, animate: true)
                } else if let index = model.pageIndex(for: hit.cfi) {
                    self.jump(toPage: index, keepOrigin: keep)
                }
            },
            close: { [weak self] in self?.state.sidebarVisible = false }
        )
    }

    private func toggleBookmark() {
        model?.toggleBookmark(visible: visiblePages)
        updateRibbon()
        if state.isPageBookmarked {
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Bookmark added"))
        }
    }

    private func close() {
        model?.saveNow()
        onClose?()
    }

    func savePositionNow() { model?.saveNow() }

    // MARK: - Theme

    private var currentTheme: Theme { settings.theme(for: traitCollection) }

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
    private func applyTheme() {
        let theme = currentTheme
        view.backgroundColor = theme.uiBackground
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
        overrideUserInterfaceStyle = theme.interfaceStyle
        setNeedsStatusBarAppearanceUpdate()
    }
}
