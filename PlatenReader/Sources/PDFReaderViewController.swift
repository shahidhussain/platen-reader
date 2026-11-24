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
            }
            .store(in: &cancellables)
        load()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The window was resized: fit the pages again (unless zoomed in).
        if !userZoomed { fitToWindow() }
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
        pdfView.backgroundColor = currentTheme.nsBackground
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
        // The zoom is saved relative to the fitted size, and only if the
        // reader zoomed.
        let zoom: Double? = userZoomed && fitScale > 0 ? Double(pdfView.scaleFactor / fitScale) : nil
        var visible = visiblePages
        if !visible.contains(currentIndex) { visible.insert(currentIndex, at: 0) }
        model.pageChanged(to: visible.first ?? currentIndex, visible: visible, zoom: zoom)
        view.window?.subtitle = state.chapter
    }

    override func savePositionNow() { model?.saveNow() }

    // MARK: - Commands (ReaderCommands)

    /// PDFs are always left to right, so "left" is back and "right" forward.
    func turn(_ turn: PageTurn) {
        if !movingForReadAloud { readAloudStarter.pageMovedByHand() }
        if turn.isForward { pdfView.goToNextPage(nil) } else { pdfView.goToPreviousPage(nil) }
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

    func toggleBookmark() { model?.toggleBookmark(visible: visiblePages) }
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
                log.info("step: \(s, privacy: .public) page \(self.currentIndex + 1)")
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
