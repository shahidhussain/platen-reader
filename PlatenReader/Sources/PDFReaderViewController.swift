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
final class PDFReaderViewController: NSViewController, NSMenuItemValidation {
    let document: BookDocument
    let state = ReaderState()
    let settings = ReaderSettings.shared

    private var pdfView: PlatenPDFView!
    private var overlayHost: NSHostingView<OverlayBar>!
    private var titleBacking: PassThroughEffectView!
    private var titleBackingHeight: NSLayoutConstraint!
    private var dragStrip: WindowDragView!
    private var spinner: NSProgressIndicator!
    private var failureHost: NSView?
    private var model: PDFReaderModel?
    private var cancellables: Set<AnyCancellable> = []
    private var hideTimer: Timer?
    private var overlayVisible = false
    private var titleBarVisible = false
    private var appearanceObservation: NSKeyValueObservation?
    /// While opening, until the saved page is on screen (PDFKit reports the
    /// first page meanwhile, which must not overwrite the saved place).
    private var restoring = true
    /// The scale that shows whole pages in the window (see `fitToWindow`),
    /// and whether the reader has zoomed away from it.
    private var fitScale: CGFloat = 1
    private var userZoomed = false
    private var applyingScale = false

    var bookTitle: String? { state.title.isEmpty ? nil : state.title }

    init(document: BookDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - View setup

    override func loadView() {
        let root = ReaderRootView()
        root.onMouseMoved = { [weak self] point in self?.mouseMoved(to: point) }

        pdfView = PlatenPDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.pageShadowsEnabled = false
        pdfView.isHidden = true
        pdfView.onClick = { [weak self] point in self?.handleClick(at: point) }
        pdfView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        root.addSubview(pdfView)

        let sidebarActions = ContentsActions(
            goToTOCItem: { [weak self] item in self?.jump(to: item.href); self?.state.sidebarVisible = false },
            goToBookmark: { [weak self] bookmark in self?.jump(to: bookmark.cfi); self?.state.sidebarVisible = false },
            removeBookmark: { [weak self] bookmark in
                guard let self else { return }
                self.model?.removeBookmark(cfi: bookmark.cfi, visible: self.visiblePages)
            },
            search: { [weak self] query in self?.search(query) },
            goToHit: { [weak self] hit in self?.goToHit(hit) },
            close: { [weak self] in self?.state.sidebarVisible = false }
        )
        let actions = OverlayActions(
            previousPage: { [weak self] in self?.pdfView.goToPreviousPage(nil) },
            nextPage: { [weak self] in self?.pdfView.goToNextPage(nil) },
            goToFraction: { [weak self] f in
                guard let self, let model = self.model else { return }
                self.jump(to: PDFReaderModel.href(page: model.page(atFraction: f)))
            },
            goBack: { [weak self] in self?.goBackInHistory(nil) },
            toggleContents: { [weak self] in self?.toggleContents(nil) },
            setLayout: { [weak self] layout in self?.setLayout(layout) },
            toggleBookmark: { [weak self] in self?.toggleBookmark(nil) },
            interacted: { [weak self] in self?.restartHideTimer() }
        )
        overlayHost = NSHostingView(rootView: OverlayBar(state: state, actions: actions, sidebarActions: sidebarActions))
        overlayHost.translatesAutoresizingMaskIntoConstraints = false
        overlayHost.alphaValue = 0
        overlayHost.isHidden = true
        root.addSubview(overlayHost)

        // As in the book window: the title bar floats over the page on a
        // backing of our own, and a strip at the top drags the window.
        titleBacking = PassThroughEffectView()
        titleBacking.material = .titlebar
        titleBacking.blendingMode = .withinWindow
        titleBacking.alphaValue = 0
        titleBacking.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleBacking)
        titleBackingHeight = titleBacking.heightAnchor.constraint(equalToConstant: 28)
        dragStrip = WindowDragView()
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(dragStrip)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: root.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            overlayHost.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            overlayHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            overlayHost.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            overlayHost.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            overlayHost.widthAnchor.constraint(equalToConstant: 720).withPriority(.defaultHigh),

            titleBacking.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBacking.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBacking.topAnchor.constraint(equalTo: root.topAnchor),
            titleBackingHeight,
            dragStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dragStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dragStrip.topAnchor.constraint(equalTo: root.topAnchor),
            dragStrip.heightAnchor.constraint(equalTo: titleBacking.heightAnchor),

            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.applySettings() } }
            .store(in: &cancellables)
        // Scroll or pages, chosen in any window, applies to every book and PDF.
        settings.$defaultFlow
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] flow in self?.followFlowSetting(flow) }
            .store(in: &cancellables)
        state.$sidebarVisible
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] open in
                guard let self, !open else { return }
                DispatchQueue.main.async {
                    // Search highlights are temporary: they go when the panel closes.
                    self.pdfView.highlightedSelections = nil
                    self.model?.cancelSearch()
                    self.view.window?.makeFirstResponder(self.pdfView)
                    self.restartHideTimer()
                }
            }
            .store(in: &cancellables)
        state.$overlayPopoverOpen
            .removeDuplicates()
            .sink { [weak self] open in if !open { self?.restartHideTimer() } }
            .store(in: &cancellables)
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
            }
            .store(in: &cancellables)
        load()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.model == nil, self.failureHost == nil else { return }
            self.spinner.startAnimation(nil)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The window was resized: fit the pages again (unless zoomed in).
        if !userZoomed { fitToWindow() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(pdfView)
        applyChromeVisibility(animated: false)
        applySettings()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applySettings() }
        }
    }

    // MARK: - Opening

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
                        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
                        log.info("PDF: \(model.pageCount) pages, \(self.state.toc.count) contents entries")
                        log.info("First page visible after \(elapsed, format: .fixed(precision: 0)) ms")
                        #if DEBUG
                        self.runDebugSteps(bookName: url.deletingPathExtension().lastPathComponent)
                        #endif
                    }
                case .failure(let error):
                    self.showFailure(error)
                }
            }
        }
    }

    private func showFailure(_ error: Error) {
        log.error("Could not open \(self.document.fileURL?.lastPathComponent ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
        spinner.stopAnimation(nil)
        let title = (error as? LocalizedError)?.errorDescription ?? String(localized: "This PDF could not be opened.")
        let host = NSHostingView(rootView: OpenFailureView(title: title, detail: (error as? LocalizedError)?.recoverySuggestion))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        failureHost = host
        titleBarVisible = true
        applyChromeVisibility(animated: false)
    }

    // MARK: - Layout, theme and settings

    private var currentTheme: Theme { settings.theme(for: NSApp.effectiveAppearance) }

    /// The Layout setting as PDFKit display modes, and the theme around the
    /// page (themes do not recolour the PDF itself).
    private func applySettings() {
        let theme = currentTheme
        view.window?.backgroundColor = theme.nsBackground
        view.window?.appearance = theme.appearance
        pdfView.backgroundColor = theme.nsBackground
        guard pdfView.document != nil else { return }
        let mode: PDFDisplayMode = state.flow == .scrolled ? .singlePageContinuous
            : settings.pageLayout == .two ? .twoUp : .singlePage
        if pdfView.displayMode != mode {
            let page = pdfView.currentPage
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
        let available = CGSize(width: max(pdfView.bounds.width - 2 * margin, 1),
                               height: max(pdfView.bounds.height - 2 * margin, 1))
        guard size.width > 0, size.height > 0 else { return }
        fitScale = min(available.width / (size.width * across), available.height / size.height)
        setScale(fitScale)
        updateScrollers()
    }

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
    private func setLayout(_ layout: ReadingLayout) {
        if let pages = layout.pages, pages != settings.pageLayout { settings.pageLayout = pages }
        settings.defaultFlow = layout.flow
    }

    private func followFlowSetting(_ flow: ReadingFlow) {
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
        // The zoom is saved relative to the fitted size, and only if the
        // reader zoomed.
        let zoom: Double? = userZoomed && fitScale > 0 ? Double(pdfView.scaleFactor / fitScale) : nil
        var visible = visiblePages
        if !visible.contains(currentIndex) { visible.insert(currentIndex, at: 0) }
        model.pageChanged(to: visible.first ?? currentIndex, visible: visible, zoom: zoom)
        view.window?.subtitle = state.chapter
    }

    func savePositionNow() { model?.saveNow() }
    func reportLayoutToSettings() {}
    func fullScreenChanged() { applyChromeVisibility(animated: false) }

    // MARK: - Clicks and keys

    private func handleClick(at point: NSPoint) {
        guard model != nil else { return }
        let width = pdfView.bounds.width
        let side = width * 0.38
        if state.flow == .scrolled || (point.x >= side && point.x <= width - side) {
            setOverlay(visible: !overlayVisible)
        } else if point.x < side {
            pdfView.goToPreviousPage(nil)
        } else {
            pdfView.goToNextPage(nil)
        }
    }

    /// Keys that are not menu shortcuts. Returns true if handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        if !shift, event.charactersIgnoringModifiers?.lowercased() == "c" {
            setOverlay(visible: !overlayVisible)
            return true
        }
        let paginated = state.flow != .scrolled
        switch event.keyCode {
        case 49: shift ? pdfView.goToPreviousPage(nil) : pdfView.goToNextPage(nil) // space
        case 121: pdfView.goToNextPage(nil) // page down
        case 116: pdfView.goToPreviousPage(nil) // page up
        case 123: pdfView.goToPreviousPage(nil) // ←
        case 124: pdfView.goToNextPage(nil) // →
        case 125 where paginated: pdfView.goToNextPage(nil) // ↓
        case 126 where paginated: pdfView.goToPreviousPage(nil) // ↑
        case 53: // Esc
            if state.sidebarVisible { state.sidebarVisible = false }
            else if overlayVisible { setOverlay(visible: false) }
            else if view.window?.styleMask.contains(.fullScreen) == true { view.window?.toggleFullScreen(nil) }
            else { return false }
        default:
            return false
        }
        return true
    }

    private func mouseMoved(to point: NSPoint) {
        let nearTop = point.y > view.bounds.height - 36
        if nearTop != titleBarVisible && !overlayVisible {
            titleBarVisible = nearTop
            applyChromeVisibility(animated: true)
        }
        if overlayVisible { restartHideTimer() }
    }

    // MARK: - Overlay and chrome

    private func setOverlay(visible: Bool) {
        if !visible && state.sidebarVisible { state.sidebarVisible = false }
        overlayVisible = visible
        titleBarVisible = visible
        applyChromeVisibility(animated: true)
        if visible { restartHideTimer() } else { hideTimer?.invalidate() }
    }

    private func restartHideTimer() {
        hideTimer?.invalidate()
        guard overlayVisible, !NSWorkspace.shared.isVoiceOverEnabled else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, self.overlayVisible else { return }
            if self.state.overlayPopoverOpen || self.state.sidebarVisible { return }
            if let window = self.view.window {
                let point = self.overlayHost.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.overlayHost.bounds.contains(point) { return self.restartHideTimer() }
            }
            self.setOverlay(visible: false)
        }
    }

    /// As in the book window (see ReaderViewController.applyChromeVisibility):
    /// the title bar stays transparent and floats over the page on our own
    /// backing, fading in with the overlay.
    private func applyChromeVisibility(animated: Bool) {
        guard let window = view.window else { return }
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0
        let titleBar = window.standardWindowButton(.closeButton)?.superview?.superview
        window.titleVisibility = titleBarVisible ? .visible : .hidden
        window.titlebarAppearsTransparent = true
        let fullScreen = window.styleMask.contains(.fullScreen)
        titleBackingHeight.constant = max(0, view.bounds.height - window.contentLayoutRect.height)
        if overlayVisible { overlayHost.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            titleBar?.animator().alphaValue = titleBarVisible || fullScreen ? 1 : 0
            titleBacking.animator().alphaValue = titleBarVisible && !fullScreen ? 0.55 : 0
            overlayHost.animator().alphaValue = overlayVisible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.overlayHost.isHidden = !self.overlayVisible
        })
    }

    // MARK: - Jumps, bookmarks, search

    private func jump(to href: String, keepOrigin: Bool = false) {
        guard let model, let index = model.pageIndex(for: href), let page = pdfView.document?.page(at: index) else { return }
        model.noteJump(from: currentIndex, to: index, keepOrigin: keepOrigin)
        pdfView.go(to: page)
    }

    private func search(_ query: String) {
        pdfView.highlightedSelections = nil
        model?.search(query)
    }

    private func goToHit(_ hit: ReaderState.SearchHit) {
        guard let model else { return }
        let keep = state.currentHitID != nil
        state.currentHitID = hit.id
        guard let selection = model.hitSelections[hit.id] else { return jump(to: hit.cfi, keepOrigin: keep) }
        model.noteJump(from: currentIndex, to: model.pageIndex(for: hit.cfi) ?? 0, keepOrigin: keep)
        pdfView.highlightedSelections = Array(model.hitSelections.values)
        selection.color = .systemYellow
        pdfView.go(to: selection)
        pdfView.setCurrentSelection(selection, animate: true)
    }

    private func stepThroughHits(by step: Int) {
        let hits = state.allHits
        guard !hits.isEmpty else { return findInBook(nil) }
        let current = hits.firstIndex { $0.id == state.currentHitID }
        let next = current.map { ($0 + step + hits.count) % hits.count } ?? (step > 0 ? 0 : hits.count - 1)
        goToHit(hits[next])
    }

    // MARK: - Menu actions (the same commands as the book window)

    @objc func previousPageLeft(_ sender: Any?) { pdfView.goToPreviousPage(nil) }
    @objc func nextPageRight(_ sender: Any?) { pdfView.goToNextPage(nil) }
    /// Previous and next chapter: the outline's entries.
    @objc func previousChapter(_ sender: Any?) {
        let starts = outlinePages
        if let target = starts.last(where: { $0 < currentIndex }) { jump(to: PDFReaderModel.href(page: target)) }
    }
    @objc func nextChapter(_ sender: Any?) {
        if let target = outlinePages.first(where: { $0 > currentIndex }) { jump(to: PDFReaderModel.href(page: target)) }
    }
    @objc func goBackInHistory(_ sender: Any?) {
        guard let target = model?.takeBackTarget(), let page = pdfView.document?.page(at: target) else { return }
        pdfView.go(to: page)
    }
    @objc func toggleContents(_ sender: Any?) {
        if state.sidebarVisible && state.sidebarTab != .search {
            state.sidebarVisible = false
        } else {
            if state.sidebarTab == .search { state.sidebarTab = .contents }
            showSidebar()
        }
    }
    @objc func showContentsFromMenu(_ sender: Any?) {
        state.sidebarTab = .contents
        showSidebar()
    }
    @objc func toggleBookmark(_ sender: Any?) { model?.toggleBookmark(visible: visiblePages) }
    @objc func findInBook(_ sender: Any?) {
        state.sidebarTab = .search
        showSidebar()
        state.searchFocusRequest += 1
    }
    @objc func findNext(_ sender: Any?) { stepThroughHits(by: 1) }
    @objc func findPrevious(_ sender: Any?) { stepThroughHits(by: -1) }
    @objc func setLayoutFromMenu(_ sender: NSMenuItem) {
        if let layout = (sender.representedObject as? String).flatMap(ReadingLayout.init) { setLayout(layout) }
    }
    @objc func toggleReaderControls(_ sender: Any?) { setOverlay(visible: !overlayVisible) }
    @objc func setThemeFromMenu(_ sender: NSMenuItem) {
        if let choice = (sender.representedObject as? String).flatMap(AppearanceChoice.init) { settings.appearance = choice }
    }

    private var outlinePages: [Int] {
        state.toc.compactMap { model?.pageIndex(for: $0.href) }.sorted()
    }

    /// The contents popover hangs from the overlay's button, so the overlay
    /// is shown first.
    private func showSidebar() {
        let wasHidden = !overlayVisible
        setOverlay(visible: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasHidden ? 0.05 : 0)) { [weak self] in
            self?.state.sidebarVisible = true
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let ready = model != nil && failureHost == nil
        switch item.action {
        case #selector(setLayoutFromMenu(_:)):
            let layout = (item.representedObject as? String).flatMap(ReadingLayout.init)
            item.state = layout == ReadingLayout(flow: state.flow, pages: settings.pageLayout) ? .on : .off
            item.toolTip = nil
            return ready
        case #selector(setThemeFromMenu(_:)):
            item.state = (item.representedObject as? String) == settings.appearance.rawValue ? .on : .off
            return true
        case #selector(goBackInHistory(_:)):
            return ready && state.backLabel != nil
        case #selector(toggleBookmark(_:)):
            item.title = state.isPageBookmarked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark This Page")
            return ready
        case #selector(toggleContents(_:)):
            item.title = state.sidebarVisible && state.sidebarTab != .search
                ? String(localized: "Hide Contents") : String(localized: "Show Contents")
            return ready
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return ready && !state.allHits.isEmpty
        case #selector(previousChapter(_:)), #selector(nextChapter(_:)):
            return ready && !state.toc.isEmpty
        case #selector(toggleReaderControls(_:)):
            item.title = overlayVisible ? String(localized: "Hide Controls") : String(localized: "Show Controls")
            return ready
        default:
            return ready
        }
    }

    // Commands that only apply to books (text size, Copy with Citation,
    // the click-zone explainer) are not implemented here, so the menu
    // disables them while a PDF is in front.

    #if DEBUG
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
                if s.hasPrefix("@") {
                    NSApp.sendAction(Selector(String(s.dropFirst())), to: nil, from: nil)
                }
                log.info("step: \(s, privacy: .public) page \(self.currentIndex + 1)")
                step(i + 1)
            }
        }
        step(0)
    }
    #endif
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
