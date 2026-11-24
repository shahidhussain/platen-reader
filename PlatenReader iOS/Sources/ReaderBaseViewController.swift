import Combine
import PlatenCore
import SwiftUI
import UIKit

/// What every reader screen has on iOS, whatever it shows: access to the
/// file, the controls over the page (ReaderChrome), the quiet progress
/// indicator, the failure message, the theme, and Close.
///
/// `ReaderViewController` (books, drawn by the web view) and
/// `PDFReaderViewController` (PDFs, drawn by PDFKit) are its two subclasses.
/// Each adds its page view and says how to carry out the commands
/// (`commands`). The Mac app has a class of the same name and shape.
class ReaderBaseViewController: UIViewController {
    let url: URL
    let state: ReaderState
    let settings = ReaderSettings.shared

    /// Called when the reader taps Close; the home screen dismisses us.
    var onClose: (() -> Void)?

    private(set) var chrome: ReaderChrome!
    private(set) var spinner: UIActivityIndicatorView!
    private(set) var failureHost: UIViewController?
    var cancellables: Set<AnyCancellable> = []

    /// True while we hold access to a file outside our sandbox (a book in
    /// Files, iCloud Drive or a file provider). Released when the reader
    /// goes away. Large books are read lazily, so access must last as long
    /// as the book is open, not just while it opens.
    private var accessingSecurityScope = false

    init(url: URL, state: ReaderState) {
        self.url = url
        self.state = state
        // "Opening “Sense and Sensibility”…" from the start, with the title
        // Recent Books knows, until the book's own is read.
        state.openingTitle = RecentList.books.item(at: url)?.displayName ?? FolderScanner.displayName(url)
        super.init(nibName: nil, bundle: nil)
        accessingSecurityScope = url.startAccessingSecurityScopedResource()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if accessingSecurityScope { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: - For subclasses

    /// Carries out the commands: the book's session, or the PDF reader.
    var commands: ReaderCommands { fatalError("subclasses say how commands are carried out") }
    /// The view that draws the page.
    var pageView: UIView { fatalError("subclasses provide the page view") }
    /// A page is on screen (until then, a slow open shows the spinner).
    var hasShownPage: Bool { false }
    /// The title when nothing could be opened and no better one is known.
    var failureFallbackTitle: String { String(localized: "This book could not be opened.") }

    /// A setting or the system's appearance changed: re-style.
    func applySettings() { applyTheme() }
    func savePositionNow() {}

    // MARK: - View setup

    /// Call at the end of `loadView`, once the page view is in `root`: adds
    /// the controls and the progress indicator above it.
    func installChrome(in root: UIView) {
        let actions = OverlayActions(
            commands: commands,
            toggleContents: { [weak self] in
                self?.state.sidebarVisible.toggle()
                self?.chrome.restartHideTimer()
            },
            interacted: { [weak self] in self?.chrome.restartHideTimer() })
        let chrome = ReaderChrome(owner: self, state: state, actions: actions,
                                  sidebarActions: ContentsActions(commands: commands),
                                  close: { [weak self] in self?.close() },
                                  readAloud: offersReadAloud ? ReadAloudButtonActions(
                                      tap: { [weak self] in self?.readAloudTapped() },
                                      stop: { [weak self] in self?.stopReadingAloud() }) : nil,
                                  // Search highlights are temporary: they go
                                  // when the panel closes.
                                  sidebarClosed: { [weak self] in self?.commands.searchPanelClosed() })
        chrome.install(in: root)
        self.chrome = chrome

        // Quiet progress indicator, shown only if opening takes > 500 ms.
        spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyTheme()

        // Re-style whenever a global setting changes.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applySettings() }
            .store(in: &cancellables)

        // Follow the system's Light and Dark switch (Automatic appearance).
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (reader: ReaderBaseViewController, _) in
            reader.applySettings()
        }

        // Scroll or pages is one setting for every book and PDF (spec,
        // "Reading modes and layout"): the Layout button changes it, and
        // this reader follows.
        settings.$defaultFlow
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] flow in self?.commands.followFlowSetting(flow) }
            .store(in: &cancellables)

        // Save when the app leaves the screen; it may be ended after that.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.savePositionNow() }
            .store(in: &cancellables)

        // A loading bar and a line saying what is happening, if opening
        // takes more than a moment (so quick opens show nothing).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.state.opening != nil, self.failureHost == nil else { return }
            self.showOpeningProgress()
        }
    }

    // The status bar and home indicator are hidden while reading and come
    // back with the controls (spec, "Layout").
    override var prefersStatusBarHidden: Bool { !(chrome?.isVisible ?? false) }
    override var prefersHomeIndicatorAutoHidden: Bool { !(chrome?.isVisible ?? false) }
    override var preferredStatusBarStyle: UIStatusBarStyle { currentTheme.isDark ? .lightContent : .darkContent }

    // MARK: - Opening progress

    private var openingHost: UIViewController?

    private func showOpeningProgress() {
        let host = UIHostingController(rootView: OpeningProgressView(state: state))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.isUserInteractionEnabled = false
        host.view.alpha = 0
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        host.didMove(toParent: self)
        openingHost = host
        UIView.animate(withDuration: 0.2) { host.view.alpha = 1 }
        // Gone once the first page is on screen (or the book failed).
        state.$opening
            .filter { $0 == nil }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.hideOpeningProgress() }
            .store(in: &cancellables)
    }

    private func hideOpeningProgress() {
        guard let host = openingHost else { return }
        openingHost = nil
        // Gone as the page appears: a quick fade, no pause (a pause left
        // the bar over the book).
        UIView.animate(withDuration: 0.12) { host.view.alpha = 0 } completion: { _ in
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }

    // MARK: - Failure and closing

    /// Shows why the book could not be opened, in place of the page.
    func showFailure(_ error: Error) {
        spinner.stopAnimating()
        guard failureHost == nil else { return }
        let host = UIHostingController(rootView: OpenFailureView(error: error, fallback: failureFallbackTitle))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.insertSubview(host.view, belowSubview: chrome.top.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            host.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
        ])
        host.didMove(toParent: self)
        failureHost = host
        // With no page to read, keep Close on screen (and nothing else).
        if state.title.isEmpty { state.title = url.deletingPathExtension().lastPathComponent }
        chrome.showCloseOnly()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The controls' margins follow the screen's shape (ReaderChrome).
        chrome?.updateEdges(in: view)
    }

    #if DEBUG
    /// One scripted step (see DebugHooks.swift): the steps both readers
    /// take. Subclasses handle their own and pass the rest here.
    /// More for "@report", from each reader (the native picture-only page).
    func debugReport() -> [String: Any] { [:] }

    func runDebugStep(_ step: String) {
        if step == "@close" {
            close()
        } else if step == "@readaloud" {
            // "@readaloud": the speaker button's tap. "@readaloud:stop": stop.
            // (The once-only note about better voices is taken as read, so
            // a scripted tap reads at once.)
            if let source = readAloudSource {
                let base = AppleVoices.baseLanguage(source.readAloudLanguage)
                AppDefaults.store.set(true, forKey: "readAloudVoiceNoteShown.\(base)")
            }
            toggleReadAloud()
        } else if step.hasPrefix("@voice:"), let choice = ReadAloudVoiceChoice(rawValue: String(step.dropFirst(7))) {
            // "@voice:kokoro|apple|undecided": the choice for English books.
            ReadAloudSettings.shared.choice = choice
        } else if step == "@readaloud:stop" {
            readAloudSource?.stopReadAloud()
        } else if step == "@downloadvoice" {
            // The natural voice's download, as from the first-tap dialog.
            downloadNaturalVoice()
        } else if step == "@removevoice" {
            Task { await KokoroDownload.remove() }
        } else if step == "@outputchanged" {
            // As when Bluetooth headphones come or go (the natural voice).
            KokoroSpeechEngine.latest?.simulateOutputChange()
        } else if step.hasPrefix("@skip:"), let delta = Int(step.dropFirst(6)) {
            // "@skip:1" / "@skip:-1": the lock screen's next and previous.
            readAloudSource?.skipReadAloud(by: delta)
        } else if step.hasPrefix("@theme:"), let choice = AppearanceChoice(rawValue: String(step.dropFirst(7))) {
            // "@theme:sepia": the page theme, as the Aa popover would set it.
            settings.appearance = choice
        } else if step.hasPrefix("@ambient:") {
            // "@ambient:on" / "@ambient:off": Aa > Ambient Light.
            settings.ambientLight = step.hasSuffix(":on")
        } else if step.hasPrefix("@layout:") {
            // "@layout:one|two|scroll", as the Layout popover sets it.
            switch step.dropFirst(8) {
            case "scroll": settings.defaultFlow = .scrolled
            case "two": settings.defaultFlow = .paginated; settings.pageLayout = .two
            default: settings.defaultFlow = .paginated; settings.pageLayout = .one
            }
        } else if step.hasPrefix("@rotate:") {
            // "@rotate:landscape" / "@rotate:portrait": turns the app's
            // interface as turning the phone would (the Simulator's own
            // device stays put; the app follows this request).
            let landscape = step.hasSuffix(":landscape")
            view.window?.windowScene?.requestGeometryUpdate(
                .iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { error in
                    log.notice("rotate failed: \(error.localizedDescription, privacy: .public)")
                }
        } else if step.hasPrefix("@controls:") {
            // "@controls:show" / "@controls:hide".
            chrome.setVisible(step.hasSuffix(":show"))
        } else if step.hasPrefix("@shot:") {
            // "@shot:<name>": a picture of the window as it is now, saved as
            // tmp/shots/<name>.png in the app's container, for
            // scripts/ios-matrix.py (taken by the app itself, so it shows
            // exactly the state after the steps before it).
            let name = String(step.dropFirst(6))
            guard let window = view.window else { return }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shots", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: folder.appendingPathComponent("\(name).png"))
            log.notice("shot: \(name, privacy: .public)")
        } else if step == "@newwindow" {
            // "@newwindow": opens this book in a new window, as "Open in New
            // Window" does (iPad; BookWindows).
            BookWindows.open(url: url, title: state.title)
            log.notice("new window asked for")
        } else if step == "@wait" {
            // Nothing: a pause of one step, for something to settle.
        } else if step == "@report" {
            // The reader's state for scripts/ios-matrix.py to check against
            // its screenshot: one line, "report: <base64 of the JSON>". In
            // base64 because the log viewer re-escapes characters of a book's
            // text (backslashes, some non-ASCII) and so broke the JSON.
            let report: [String: Any] = [
                "theme": currentTheme.background, "dark": currentTheme.isDark,
                "ambient": settings.ambientLight, "flow": state.flow.rawValue,
                "pageLayout": settings.pageLayout.rawValue, "columns": state.columnsOnScreen,
                "isPDF": state.isPDF, "spreads": state.pagesAreSpreads, "fixedLayout": state.isFixedLayout,
                "landscape": view.bounds.width > view.bounds.height,
                "controls": chrome.isVisible,
                "topBand": state.topBandColour ?? "", "bottomBand": state.bottomBandColour ?? "",
                "topBandNeeded": state.topBandNeeded, "bottomBandNeeded": state.bottomBandNeeded,
                "width": view.bounds.width, "height": view.bounds.height,
            ].merging(debugReport()) { _, new in new }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                log.notice("report: \(data.base64EncodedString(), privacy: .public)")
            }
        } else if step == "@orientation" {
            // The device's orientation against the app's: different (with
            // the device in a supported orientation) means rotation is held.
            let device = UIDevice.current.orientation
            let app = view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .unknown
            log.notice("orientation: device \(device.isLandscape ? "landscape" : device.isPortrait ? "portrait" : "other", privacy: .public), app \(app.isLandscape ? "landscape" : "portrait", privacy: .public)")
        } else {
            log.notice("step not understood: \(step, privacy: .public)")
        }
    }
    #endif

    func close() {
        stopReadingAloud()
        savePositionNow()
        onClose?()
    }

    // MARK: - Read aloud (ReaderBaseViewController+ReadAloud.swift)

    /// Follows read aloud for Now Playing.
    var readAloudWatch: AnyCancellable?
    /// Reading aloud starts again on the page the reader moved to, once they
    /// have settled there (`pageMovedByHand`).
    var handMoveRestart: DispatchWorkItem?

    /// Whether this reader has the speaker button.
    var offersReadAloud: Bool { false }
    /// What reads aloud here (the book's session, the PDF's reader), once
    /// it is ready.
    var readAloudSource: ReadAloudSource? { nil }
    func readAloudTapped() { toggleReadAloud() }
    func stopReadingAloud() { readAloudSource?.stopReadAloud() }

    /// VoiceOver's two-finger scrub (the "back" gesture): closes the book,
    /// as Close does.
    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }

    // MARK: - Theme

    var currentTheme: Theme { settings.theme(for: traitCollection) }

    /// The colour around the page, and our own controls following the page's
    /// lightness rather than the system's.
    func applyTheme() {
        let theme = currentTheme
        view.backgroundColor = theme.uiBackground
        state.pageColour = theme.background
        overrideUserInterfaceStyle = theme.interfaceStyle
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - Whether the controls need bands

    private var bandCheck: DispatchWorkItem?
    private static let bandQueue = DispatchQueue(label: "org.platenreader.band-check", qos: .utility)

    /// A small picture of what lies behind the controls: the page, its
    /// picture and the glow, without the controls themselves. Each reader
    /// makes its own; nil if it cannot.
    func backdropSnapshot(width: CGFloat, done: @escaping (UIImage?) -> Void) { done(nil) }

    /// Works out, a moment after the page settles (a turn, a scroll, a new
    /// glow, a new theme), whether the title and the bottom controls need a
    /// band behind them (`GlowBand.needsBand`), so the answer is ready
    /// before they are next shown.
    func scheduleBandCheck(after delay: TimeInterval = 0.4) {
        bandCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkBands() }
        bandCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func checkBands() {
        guard let chrome, view.bounds.width > 0 else { return }
        let bounds = view.bounds
        // Where the controls' text and buttons are: the top bar from the top
        // of the screen (the status bar too) to its last line, and the
        // bottom bar from its first line to the bottom (each without the
        // room left for the band's fade).
        let topArea = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, chrome.top.view.frame.maxY - 20))
        let bottomFrame = chrome.bottom.view.frame
        let bottomArea = CGRect(x: 0, y: bottomFrame.minY + 24, width: bounds.width,
                                height: max(0, bounds.maxY - bottomFrame.minY - 24))
        let dark = currentTheme.isDark
        // Sharp enough to see lines of text (each about two pixels tall).
        backdropSnapshot(width: 180) { [weak self] image in
            guard let cg = image?.cgImage else { return }
            // Measured off the main thread: a few hundred thousand pixels
            // would hold up taps for a noticeable moment (profiled: about
            // 170 ms on the main thread in the Simulator).
            Self.bandQueue.async {
                let scale = CGFloat(cg.width) / bounds.width
                let pixels = Self.pixels(of: cg)
                func sample(_ area: CGRect) -> [GlowBand.RGB] {
                    let rows = max(0, Int(area.minY * scale))..<min(cg.height, Int(area.maxY * scale))
                    return rows.flatMap { y in pixels[(y * cg.width)..<((y + 1) * cg.width)] }
                }
                let top = GlowBand.needsBand(behind: sample(topArea), width: cg.width, darkTheme: dark)
                let bottom = GlowBand.needsBand(behind: sample(bottomArea), width: cg.width, darkTheme: dark)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.state.topBandNeeded != top { self.state.topBandNeeded = top }
                    if self.state.bottomBandNeeded != bottom { self.state.bottomBandNeeded = bottom }
                }
            }
        }
    }

    /// Every pixel of a (small) picture, as colours.
    private static func pixels(of image: CGImage) -> [GlowBand.RGB] {
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map {
            GlowBand.RGB(r: Double(bytes[$0]) / 255, g: Double(bytes[$0 + 1]) / 255, b: Double(bytes[$0 + 2]) / 255)
        }
    }

    // MARK: - Bands over the ambient glow

    /// The ambient glow on show changed (nil: none): the bands behind the
    /// controls take its colours at the top and bottom of the screen
    /// (GlowBand), or go back to the page's colour.
    func glowChanged(_ glow: UIImage?) {
        // The glow fades in over about a third of a second: look after.
        scheduleBandCheck(after: 0.5)
        guard let glow else {
            state.topBandColour = nil
            state.bottomBandColour = nil
            return
        }
        let theme = currentTheme
        let page = GlowBand.RGB(hex: theme.background)
        func band(_ edge: VerticalEdge) -> String? {
            guard let colour = Self.edgeColour(of: glow, edge, over: theme.uiBackground) else { return nil }
            return GlowBand.colour(edge: colour, page: page, darkTheme: theme.isDark).hex
        }
        state.topBandColour = band(.top)
        state.bottomBandColour = band(.bottom)
    }

    /// The average colour of a thin strip along the top or bottom of a glow
    /// (where it is strongest), as it shows over the page's colour.
    private static func edgeColour(of glow: UIImage, _ edge: VerticalEdge, over backdrop: UIColor) -> GlowBand.RGB? {
        guard let cg = glow.cgImage, cg.height > 0 else { return nil }
        let strip = max(1, cg.height / 25)
        let rect = CGRect(x: 0, y: edge == .top ? 0 : cg.height - strip, width: cg.width, height: strip)
        guard let part = cg.cropping(to: rect) else { return nil }
        // Drawn small (16 × 2) and averaged: a fair mean of the strip.
        let (width, height) = (16, 2)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let all = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(backdrop.cgColor)
        context.fill(all)
        context.interpolationQuality = .medium
        context.draw(part, in: all)
        var sum = (0.0, 0.0, 0.0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum.0 += Double(pixels[i]); sum.1 += Double(pixels[i + 1]); sum.2 += Double(pixels[i + 2])
        }
        let count = Double(width * height) * 255
        return GlowBand.RGB(r: sum.0 / count, g: sum.1 / count, b: sum.2 / count)
    }
}
