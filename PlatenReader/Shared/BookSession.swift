import Foundation
import PlatenCore
import WebKit

/// What the app's reader view does for a `BookSession`: the parts that
/// differ between the Mac and iOS (windows, VoiceOver, pictures, page-turn
/// animation). Everything else about an open book is the session's.
protocol BookSessionHost: AnyObject {
    /// The theme in use (each platform asks the system its own way).
    var currentTheme: Theme { get }
    /// A last chance to change the settings sent to the page (iOS adds
    /// its margins and switches on native taps and swipes).
    func adjust(_ settings: inout WebSettings)
    /// Turns the page with the platform's animation (curl, slide, swipe).
    func animateTurn(_ turn: PageTurn)

    /// The file has been read and checked; the page has not been drawn yet.
    func sessionDidLoadBook()
    /// The book cannot be shown: say why in place of the page.
    func sessionDidFail(_ error: Error)
    /// The first page is on screen.
    func sessionDidRenderFirstPage()
    /// The page has opened the book (title, direction and layout are known).
    func sessionDidOpen()
    /// The reader moved (a page turn, a jump or a re-layout).
    func sessionDidRelocate()
    /// A jump was asked for (the Mac gives the page keyboard focus again).
    func sessionDidJump()
    /// Paginated became Scroll or the reverse.
    func sessionDidChangeFlow()
    /// A plain click on the page.
    func sessionClicked(_ zone: ClickZone)
    /// A click on a picture: show it full size.
    func sessionShowPicture(_ picture: ReaderMessage.Picture)
    /// The page on screen is just one picture (its bytes), or nil when it
    /// no longer is (iOS shows it natively).
    func sessionShowLonePicture(_ data: Data?)
    /// The text on screen, for VoiceOver; `speak` when it should be read out.
    func sessionPageText(_ text: String, speak: Bool)
    /// Something to tell VoiceOver users ("Bookmark added").
    func sessionAnnounce(_ text: String)
    /// A bookmark was added: its ribbon is being laid onto the page (iOS
    /// taps lightly as it lands).
    func sessionBookmarkAdded()
    func sessionOpenExternalLink(_ url: URL)
    /// Whether the page can be seen now (iOS: the app is in front), so read
    /// aloud may stay a moment on a picture page; in the background it
    /// reads straight on.
    var sessionShowsPage: Bool { get }
}

// Most hooks are optional: a reader implements the ones it has a use for.
extension BookSessionHost {
    func adjust(_ settings: inout WebSettings) {}
    func sessionDidLoadBook() {}
    func sessionBookmarkAdded() {}
    func sessionDidRelocate() {}
    func sessionDidJump() {}
    func sessionDidChangeFlow() {}
    func sessionShowPicture(_ picture: ReaderMessage.Picture) {}
    func sessionShowLonePicture(_ data: Data?) {}
    func sessionPageText(_ text: String, speak: Bool) {}
    var sessionShowsPage: Bool { true }
}

/// One open book, for both apps: reading the file, the saved position and
/// bookmarks, the conversation with reader.js (see ReaderBridge.swift), and
/// the commands the overlay, menus and keyboard send.
///
/// Opening runs two things in parallel and joins them:
/// 1. the web view loads the reader shell (usually already warm), and
/// 2. the book file is read and checked on a background queue.
/// When both are ready, the book is handed to the shell.
///
/// The app's reader view makes the web view (with `makeConfiguration()`),
/// calls `start(in:)`, and acts as the session's `host`.
final class BookSession: NSObject, ReaderCommands, ReadAloudSource, WKScriptMessageHandler, WKNavigationDelegate {
    let url: URL
    let state: ReaderState
    let settings = ReaderSettings.shared
    let schemeHandler = ReaderSchemeHandler()
    weak var host: BookSessionHost?

    private(set) weak var webView: WKWebView?
    private(set) var book: Book?
    private(set) var record: BookRecord?
    /// The shell has loaded and is waiting for a book.
    private var shellReady = false
    /// The book has been handed to the page, so commands can be sent.
    private(set) var isOpenInPage = false
    /// The first page has been on screen.
    private(set) var hasRendered = false
    /// The last settings sent to the page, so unchanged ones are not resent:
    /// every new layout re-paginates the book, and doing that while it is
    /// still opening loses the place.
    private var lastSettings: WebSettings?
    private var openStarted = CFAbsoluteTimeGetCurrent()

    init(url: URL, state: ReaderState = ReaderState()) {
        self.url = url
        self.state = state
        super.init()
        state.flow = settings.defaultFlow
    }

    // MARK: - Opening

    /// The web view configuration every reader uses: book files come through
    /// the `platen://` scheme handler, messages come back through `post()`,
    /// and only the shell's own scripts run.
    func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: ReaderSchemeHandler.scheme)
        config.userContentController.add(WeakScriptMessageHandler(self), name: "platen")
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.isTextInteractionEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true // the shell's own scripts
        return config
    }

    /// Loads the shell into the web view and reads the book, side by side.
    func start(in webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        RemoteContentBlocker.load { [weak webView] list in
            guard let webView else { return }
            if let list { webView.configuration.userContentController.add(list) }
            webView.load(URLRequest(url: ReaderSchemeHandler.shellURL))
        }
        loadBook()
    }

    private func loadBook() {
        openStarted = CFAbsoluteTimeGetCurrent()
        let url = self.url
        // A book only in iCloud is downloaded first (by the coordinated read
        // below); say so, as that can take a while.
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status == .notDownloaded {
            state.opening = .downloading
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Coordinated, so offloaded iCloud files download first and file
            // providers (SMB, cloud apps) hand over a readable copy.
            let result = Result { try Book.open(url: url, coordinated: true) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let book):
                    if self.state.opening == .downloading { self.state.opening = .reading }
                    let elapsed = (CFAbsoluteTimeGetCurrent() - self.openStarted) * 1000
                    // The kind and size of book, which the diagnostics file
                    // keeps in place of its name ("Read <name> (epub, 2.1 MB)").
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                    let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                    log.info("Read \(url.lastPathComponent, privacy: .name) (\(book.format.rawValue, privacy: .public), \(size, privacy: .public)) in \(elapsed, format: .fixed(precision: 0)) ms")
                    for warning in book.warnings { log.notice("\(warning, privacy: .public)") }
                    if book.isRepaired { log.notice("Opened a damaged book using a rebuilt package") }
                    self.book = book
                    self.schemeHandler.book = book
                    self.state.title = book.title ?? ""
                    self.state.isFixedLayout = book.isFixedLayout
                    self.loadRecord(for: book)
                    self.host?.sessionDidLoadBook()
                    self.sendBookIfReady()
                case .failure(let error):
                    self.fail(error)
                }
            }
        }
    }

    /// The saved position and bookmarks. Books are identified by their own
    /// identifier and a fingerprint, never their path, so a book keeps its
    /// place wherever it is opened from.
    private func loadRecord(for book: Book) {
        var record = PositionStore.shared.load(key: book.key)
            ?? BookRecord(key: book.key, uniqueIdentifier: book.package?.uniqueIdentifier, fingerprint: book.fingerprint)
        record.lastKnownPath = url.path
        record.lastOpened = Date()
        self.record = record
        state.bookmarks = record.bookmarks
        // The reading mode is the same for every book (the setting, taken
        // in init); fixed-layout books always show pages.
        if book.isFixedLayout { state.flow = .paginated }
    }

    private func sendBookIfReady() {
        guard shellReady, let book, !isOpenInPage, let webView else { return }
        isOpenInPage = true
        state.opening = .preparing
        let settings = currentSettings
        lastSettings = settings
        var options: [String: Any] = [
            // Plain text arrives as a made-up EPUB, so the shell opens it as one.
            "format": book.format == .text ? BookFormat.epub.rawValue : book.format.rawValue,
            "settings": settings.payload,
        ]
        if book.format != .mobi {
            options["sizes"] = book.entrySizes.mapValues { Int(clamping: $0) }
        }
        if let cfi = record?.lastCFI { options["lastCFI"] = cfi }
        webView.callAsyncJavaScript("platen.open(options)", arguments: ["options": options], in: nil, in: .page) { result in
            if case .failure(let error) = result { log.error("open failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func fail(_ error: Error) {
        log.error("Could not open \(self.url.lastPathComponent, privacy: .name): \(String(describing: error), privacy: .public)")
        state.opening = nil
        host?.sessionDidFail(error)
    }

    // MARK: - Settings

    /// The settings for the page as they stand now.
    private var currentSettings: WebSettings {
        var web = settings.webSettings(theme: host?.currentTheme ?? .light, flow: state.flow)
        host?.adjust(&web)
        return web
    }

    /// Sends the settings to the page if anything in them changed (a global
    /// setting, the theme, this book's layout, or iOS's margins).
    func pushSettings() {
        guard isOpenInPage else { return }
        let settings = currentSettings
        guard settings != lastSettings else { return }
        lastSettings = settings
        call("setSettings", settings.payload)
    }

    /// One page, two pages or scroll (⌘1, ⌘2, ⌘3), chosen by the reader.
    /// Both parts are settings for every book: this changes them, and every
    /// open book follows (`followFlowSetting`, and the settings observer in
    /// each reader).
    func setLayout(_ layout: ReadingLayout) {
        if let pages = layout.pages, pages != settings.pageLayout {
            settings.pageLayout = pages // re-styles every open book
        }
        guard !state.isFixedLayout, layout.flow != state.flow else { return }
        settings.defaultFlow = layout.flow
        followFlowSetting(layout.flow) // at once, here; other books follow
        host?.sessionDidChangeFlow()
    }

    /// Applies the reading-mode setting to this book (fixed-layout books
    /// always show pages).
    func followFlowSetting(_ flow: ReadingFlow) {
        guard !state.isFixedLayout, flow != state.flow else { return }
        state.flow = flow
        pushSettings()
    }

    // MARK: - Saving

    func savePositionNow() {
        guard let record else { return }
        PositionStore.shared.saveNow(record)
    }

    // MARK: - Messages from JavaScript

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let message = ReaderMessage(message.body) else { return }
        // What the overlay and contents show (ReaderState+Messages.swift)…
        state.apply(message)
        // …then everything else.
        switch message {
        case .ready:
            shellReady = true
            sendBookIfReady()

        case .firstRender:
            hasRendered = true
            state.opening = nil
            let elapsed = (CFAbsoluteTimeGetCurrent() - openStarted) * 1000
            log.info("First page visible after \(elapsed, format: .fixed(precision: 0)) ms")
            host?.sessionDidRenderFirstPage()

        case .opened:
            sendRibbonMotionToPage()
            sendBookmarksToPage()
            host?.sessionDidOpen()

        case .contents(let contents):
            log.debug("contents: \(contents.toc.count) entries\(contents.synthesised ? " (built from headings)" : "", privacy: .public)")

        case .relocate(let place):
            // foliate has opened the book and placed the first page; its
            // chapter is now loading and being laid out (the long wait).
            if !hasRendered, state.opening == .preparing { state.opening = .layingOut }
            if let cfi = place.cfi, var record {
                record.lastCFI = cfi
                self.record = record
                PositionStore.shared.scheduleSave(record) // debounced
            }
            host?.sessionDidRelocate()

        case .addBookmark(let draft):
            guard var record, record.addBookmark(draft) else { break }
            saveBookmarks(record)
            host?.sessionAnnounce(String(localized: "Bookmark added"))
            host?.sessionBookmarkAdded()

        case .removeBookmark(let cfi):
            removeBookmark(cfi: cfi)

        case .click(let zone):
            host?.sessionClicked(zone)

        case .image(let picture):
            host?.sessionShowPicture(picture)

        case .lonePicture(let data):
            host?.sessionShowLonePicture(data)

        case .externalLink(let url):
            // Links to the web open in the browser, never in the reader.
            host?.sessionOpenExternalLink(url)

        case .failed(let text, let stack):
            log.error("reader error: \(text, privacy: .public)\n\(stack, privacy: .public)")
            fail(BookOpenError.unreadable(text))

        case .pageText(let text, let speak):
            lastPageText = text
            host?.sessionPageText(text, speak: speak)

        case .readAloudBlock(let block):
            #if DEBUG
            // Testing only (book text never goes in the diagnostics): where
            // reading begins, after a start or a turn by hand.
            if readAloudFirstBlock, let first = block.sentences.first(where: { !$0.isPicture }) {
                log.notice("step result: reads from: \(String(first.text.prefix(60)), privacy: .public)")
                readAloudFirstBlock = false
            }
            #endif
            readAloud?.receive(block)

        case .readAloudEnd:
            readAloud?.endReached()

        case .log(let text):
            log.notice("js: \(text, privacy: .public)")

        case .back, .note, .pageBookmarked, .selection, .searchResults, .searchProgress, .searchDone:
            break // only change what the overlay shows
        }
    }

    // MARK: - Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the shell and its blob: iframes may load. Anything else (a book
        // trying to navigate the window) is refused.
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["platen", "blob", "about", "data"].contains(scheme) ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WebKit's content process crashed, or (on iOS) was ended under
        // memory pressure, often while the app was in the background.
        // Reload and reopen at the last saved position rather than leaving
        // a blank page.
        log.error("Web content process terminated; reloading")
        shellReady = false
        isOpenInPage = false
        webView.load(URLRequest(url: ReaderSchemeHandler.shellURL))
    }

    // MARK: - Commands (ReaderCommands)

    /// Turns the page as the reader's view draws it (curl, slide or none).
    /// The reader moved the page themselves (a turn, a swipe, a jump, the
    /// slider, a chapter, Back), not read aloud: reading aloud starts again
    /// from there (iOS; the app sets it).
    var onPageMovedByHand: (() -> Void)?
    #if DEBUG
    /// The next block is the first of a reading (logged, for checks).
    private var readAloudFirstBlock = false
    #endif

    func turn(_ turn: PageTurn) {
        guard isOpenInPage else { return }
        onPageMovedByHand?()
        if let host { host.animateTurn(turn) } else { turnPlainly(turn) }
    }

    func jump(to target: String, keepOrigin: Bool = false) {
        onPageMovedByHand?()
        call("jumpTo", target, keepOrigin)
        host?.sessionDidJump()
    }

    func jump(toFraction fraction: Double) { onPageMovedByHand?(); call("jumpToFraction", fraction) }
    func goBack() { onPageMovedByHand?(); call("goBack") }
    func previousChapter() { onPageMovedByHand?(); call("prevSection") }
    func nextChapter() { onPageMovedByHand?(); call("nextSection") }
    func toggleBookmark() { call("toggleBookmark") }

    func removeBookmark(cfi: String) {
        guard var record else { return }
        record.bookmarks.removeAll { $0.cfi == cfi }
        saveBookmarks(record)
    }

    func search(_ query: String) {
        state.beginSearch(query)
        call("search", state.activeSearchQuery)
    }

    func goToHit(_ hit: ReaderState.SearchHit) {
        let keep = state.currentHitID != nil // Back returns to before the first result
        state.currentHitID = hit.id
        jump(to: hit.cfi, keepOrigin: keep)
    }

    func searchPanelClosed() {
        if state.sidebarTab == .search || !state.searchGroups.isEmpty { call("clearSearch") }
    }

    // MARK: - Commands only books have

    /// foliate-js's own turn: a slide if `animated` is set, else instant.
    func turnPlainly(_ turn: PageTurn) {
        switch turn {
        case .left: call("goLeft")
        case .right: call("goRight")
        case .next: call("next")
        case .prev: call("prev")
        }
    }

    /// For page turns drawn natively from pictures of the page: turns with
    /// no animation and calls back once the new page has been painted, saying
    /// whether the page changed (not at either end of the book) and how many
    /// pages are side by side.
    func turnInstantly(_ turn: PageTurn, completion: @escaping (_ moved: Bool, _ columns: Int) -> Void) {
        onPageMovedByHand?()
        guard isOpenInPage, let webView else { return completion(false, 1) }
        webView.callAsyncJavaScript("return await platen.turnInstantly(direction)", arguments: ["direction": turn.rawValue],
                                    in: nil, in: .page) { result in
            let info = (try? result.get()) as? [String: Any]
            completion(info?["moved"] as? Bool ?? false, (info?["columns"] as? NSNumber)?.intValue ?? 1)
        }
    }

    /// Scroll mode: the arrow keys move by a few lines.
    func scroll(lines: Int) { call("scrollLines", lines) }
    /// Esc closes an open footnote pop-up.
    func closeNote() { call("closeNote") }
    /// VoiceOver: read the page on screen again.
    func readPage() { call("readPage") }
    /// iOS: the controls are up (or not). Their location line covers the
    /// page number, so the page number steps aside meanwhile.
    /// The controls came up or went (iOS). `headerBottom`: where the top
    /// bar ends, in points, so a bookmark's ribbon can stand just below it
    /// while they are up (it would be hidden under the bar at the top).
    func setControlsVisible(_ visible: Bool, headerBottom: Double = 0) {
        call("setControlsVisible", visible, headerBottom)
    }
    /// Tells the page whether VoiceOver is on (it then follows page turns).
    func setVoiceOver(_ on: Bool) { call("setVoiceOver", on) }

    // MARK: - Read aloud (docs/read-aloud.md)

    /// The text on screen, as last sent for VoiceOver: read aloud's language
    /// comes from it when the book does not give one.
    private(set) var lastPageText = ""
    /// Reading aloud, while it is.
    private(set) var readAloud: ReadAloudController?

    /// Ready to read aloud: the first page is on screen.
    var canReadAloud: Bool { hasRendered }

    /// The language read aloud uses for this book.
    var readAloudLanguage: String {
        SpeechEngineChooser.language(book: state.language, text: lastPageText)
    }

    /// Starts reading aloud from the first sentence on the current page,
    /// with `engine`.
    func startReadAloud(engine: SpeechEngine) {
        stopReadAloud()
        #if DEBUG
        readAloudFirstBlock = true
        #endif
        let controller = ReadAloudController(engine: engine, language: readAloudLanguage)
        controller.onPhase = { [weak self] phase in
            self?.state.readAloud = phase
            if phase == .off { self?.readAloudEnded() }
        }
        controller.requestNext = { [weak self] in self?.call("readAloudMore") }
        controller.onNothingToRead = { [weak self] in self?.state.readAloudFoundNoText += 1 }
        controller.mark = { [weak self] name in self?.call("readAloudMark", name) }
        controller.markWord = { [weak self] name, start, length in self?.call("readAloudWord", name, start, length) }
        controller.showPicture = { [weak self] name, answer in self?.readAloudShowPicture(name, answer: answer) }
        readAloud = controller
        controller.start()
        state.readAloud = .starting
        call("readAloudStart")
    }

    func pauseReadAloud() { readAloud?.pause() }
    func skipReadAloud(by delta: Int) { readAloud?.skipParagraph(by: delta) }
    func holdReadAloudPage() { if readAloud != nil { call("readAloudHold") } }
    func resumeReadAloud() { readAloud?.resume() }

    func stopReadAloud() {
        guard let readAloud else { return }
        readAloud.stop()
    }

    /// Read aloud has reached a picture between the words: the page turns
    /// to it and says whether that page has no words (then reading stays a
    /// moment). Not while the page cannot be seen (`sessionShowsPage`): in the
    /// background reading goes straight on.
    private func readAloudShowPicture(_ cfi: String, answer: @escaping (Bool) -> Void) {
        guard isOpenInPage, let webView, host?.sessionShowsPage ?? true else { return answer(false) }
        webView.callAsyncJavaScript("return await platen.readAloudPicture(cfi)", arguments: ["cfi": cfi],
                                    in: nil, in: .page) { result in
            answer(((try? result.get()) as? Bool) ?? false)
        }
    }

    private func readAloudEnded() {
        readAloud = nil
        state.readAloud = .off
        call("readAloudStop")
    }
    /// Mac trackpad swipes: the page follows the fingers, then settles
    /// (`direction` 1 or -1 for a flick, 0 to settle on the nearest page).
    func swipeMove(by dx: Double) { call("swipeMove", dx) }
    func swipeEnd(direction: Int) { call("swipeEnd", direction) }

    /// What is under a point in the web view (see tapTarget in input.js).
    enum TapTarget: String {
        case page, control, link, image, selection
    }

    /// iOS: asks the page what is under a tap. Only `.page` is ours to act
    /// on; links, pictures and the bookmark ribbons handle their own taps.
    func tapTarget(at point: CGPoint, completion: @escaping (TapTarget) -> Void) {
        guard isOpenInPage, let webView else { return completion(.page) }
        webView.callAsyncJavaScript("return platen.tapTarget(x, y)", arguments: ["x": point.x, "y": point.y],
                                    in: nil, in: .page) { result in
            completion(((try? result.get()) as? String).flatMap(TapTarget.init) ?? .page)
        }
    }

    /// Asks the page for the picture under a held finger (iOS); if there is
    /// one, it arrives as an `image` message (`sessionShowPicture`).
    func pictureAt(_ point: CGPoint, completion: @escaping (Bool) -> Void) {
        guard isOpenInPage, let webView else { return completion(false) }
        webView.callAsyncJavaScript("return platen.pictureAt(x, y)", arguments: ["x": point.x, "y": point.y],
                                    in: nil, in: .page) { result in
            completion(((try? result.get()) as? Bool) ?? false)
        }
    }

    /// During a page turn (iOS): whether the page now on screen is a
    /// picture-only page whose picture the reader has ("same"), one about to
    /// be sent ("new"), or not one ("none").
    func lonePictureState(completion: @escaping (String) -> Void) {
        guard isOpenInPage, let webView else { return completion("none") }
        webView.callAsyncJavaScript("return platen.lonePictureState()", arguments: [:], in: nil, in: .page) { result in
            completion(((try? result.get()) as? String) ?? "none")
        }
    }

    /// Before a turn that the page animates itself (the Mac's Slide and
    /// None): the picture shown full size natively goes back to the page.
    func releaseLonePicture() {
        guard isOpenInPage, let webView else { return }
        webView.callAsyncJavaScript("platen.releaseLonePicture()", arguments: [:], in: nil, in: .page)
    }

    /// Where a fixed-layout book's pages are on screen (one, or two in a
    /// spread), in the web view's coordinates: the area the ambient glow is
    /// made from (iOS). Empty for other books.
    func fixedLayoutPageRects(completion: @escaping ([CGRect]) -> Void) {
        guard isOpenInPage, state.isFixedLayout, let webView else { return completion([]) }
        webView.callAsyncJavaScript("return platen.pageRects()", arguments: [:], in: nil, in: .page) { result in
            let rects = ((try? result.get()) as? [[Double]] ?? []).compactMap { r -> CGRect? in
                r.count == 4 ? CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) : nil
            }
            completion(rects)
        }
    }

    // MARK: - Helpers

    private func saveBookmarks(_ record: BookRecord) {
        self.record = record
        state.bookmarks = record.bookmarks
        PositionStore.shared.saveNow(record) // bookmarks are saved at once
        sendBookmarksToPage()
    }

    /// The ribbon's motions (PlatenMotion.Ribbon), so their numbers are
    /// kept with the press's.
    private func sendRibbonMotionToPage() {
        call("setRibbonMotion", PlatenMotion.Ribbon.payload)
    }

    private func sendBookmarksToPage() {
        call("setBookmarks", state.bookmarks.map { ["cfi": $0.cfi] })
    }

    /// Calls `platen.<function>(…)` in the reader page with values passed as
    /// real arguments (never pasted into the script), so any string is safe.
    private func call(_ function: String, _ arguments: Any...) {
        guard isOpenInPage, let webView else { return }
        var named: [String: Any] = [:]
        for (i, value) in arguments.enumerated() { named["a\(i)"] = value }
        let list = arguments.indices.map { "a\($0)" }.joined(separator: ", ")
        webView.callAsyncJavaScript("platen.\(function)(\(list))", arguments: named, in: nil, in: .page, completionHandler: nil)
    }
}
