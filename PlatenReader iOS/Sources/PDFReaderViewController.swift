import Combine
import PDFKit
import PlatenCore
import SwiftUI
import UIKit

/// The reader for a PDF on iOS and iPadOS (spec, "PDF"). PDFKit draws the
/// pages; the overlay, contents, bookmarks and search are the same as for
/// books (ReaderChrome, and the shared PDFReaderModel).
///
/// Layout follows the orientation, on iPhone and iPad alike:
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
        chrome.install(in: root)
        self.chrome = chrome

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

    // MARK: - Layout (portrait: one page; landscape: a spread)

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

        if landscape {
            if !wasLandscape || force { spreadsStartOdd = current % 2 == 1 }
            pdfView.usePageViewController(false)
            pdfView.displayMode = .twoUp
            // displaysAsBook puts the first page on its own, so pairs start
            // at odd pages; without it they start at even ones.
            pdfView.displaysAsBook = spreadsStartOdd
            pdfView.displaysPageBreaks = false // the two pages touch
            pdfView.pageBreakMargins = .zero
        } else {
            pdfView.displayMode = .singlePage
            pdfView.displaysAsBook = false
            pdfView.displaysPageBreaks = true
            // Paging by PDFKit's page view controller: a swipe follows the
            // finger, as for books.
            pdfView.usePageViewController(true, withViewOptions: [UIPageViewController.OptionsKey.interPageSpacing: 12])
        }
        swipes.forEach { $0.isEnabled = landscape }
        pdfView.autoScales = true
        if let page = document.page(at: current) { pdfView.go(to: page) }
        // Switching modes gives PDFKit's inner views their own (grey)
        // background and scroll bars; the theme colour goes back on.
        DispatchQueue.main.async { self.applyTheme() }
        reportPage()
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

    private func turn(forward: Bool) {
        // Not while zoomed in: then the reader is panning around the page.
        if forward { pdfView.goToNextPage(nil) } else { pdfView.goToPreviousPage(nil) }
    }

    func gestureRecognizer(_ recogniser: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: - Where the reader is

    private var visiblePages: [Int] {
        guard let document = pdfView.document else { return [] }
        let pages = pdfView.visiblePages.map { document.index(for: $0) }.sorted()
        if pages.isEmpty, let current = pdfView.currentPage { return [document.index(for: current)] }
        return isLandscape ? Array(pages.prefix(2)) : Array(pages.prefix(1))
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
        let visible = chrome?.isVisible ?? false
        ribbon.isHidden = model == nil || !(state.isPageBookmarked || visible)
        ribbon.image = UIImage(systemName: state.isPageBookmarked ? "bookmark.fill" : "bookmark")
        ribbon.tintColor = state.isPageBookmarked ? UIColor(red: 0.82, green: 0.2, blue: 0.17, alpha: 1)
            : UIColor.secondaryLabel.withAlphaComponent(0.5)
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
            setLayout: { _ in }, // a PDF's layout follows the orientation
            toggleBookmark: { [weak self] in self?.toggleBookmark() },
            interacted: { [weak self] in self?.chrome?.restartHideTimer() },
            openSettings: { [weak self] in
                guard let self else { return }
                self.presentReaderSettings(isFixedLayout: true, chrome: self.chrome)
            }
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

    /// Themes colour only the background around the page (spec, "PDF").
    private func applyTheme() {
        let theme = currentTheme
        view.backgroundColor = theme.uiBackground
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
        overrideUserInterfaceStyle = theme.interfaceStyle
        setNeedsStatusBarAppearanceUpdate()
    }
}
