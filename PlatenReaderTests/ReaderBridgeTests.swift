import PlatenCore
import XCTest

/// Tests of the code the Mac and iOS apps share (PlatenReader/Shared): how
/// messages from reader.js are decoded, what they do to the state the
/// overlay shows, the settings sent to the page, and the commands.
///
/// The test bundle compiles the Shared folder itself, so the tests run on
/// their own, without launching the app (`xcodebuild test -scheme
/// PlatenReader -only-testing:PlatenReaderTests`), and touch no window, file
/// or setting.
final class ReaderMessageTests: XCTestCase {
    /// A message as WebKit hands it over: `{ type, body }`.
    private func message(_ type: String, _ body: [String: Any] = [:]) -> ReaderMessage? {
        ReaderMessage(["type": type, "body": body] as [String: Any])
    }

    func testMessagesWithoutABody() {
        XCTAssertEqual(ReaderMessage(["type": "ready"]), .ready)
        XCTAssertEqual(message("firstRender"), .firstRender)
    }

    func testUnknownOrMalformedMessagesAreDropped() {
        XCTAssertNil(message("somethingNew"))
        XCTAssertNil(ReaderMessage("not a dictionary"))
        XCTAssertNil(ReaderMessage(["body": [:]]))
        XCTAssertNil(message("addBookmark", ["snippet": "no place given"]))
        XCTAssertNil(message("image", ["data": "not base64 !!"]))
    }

    func testOpened() {
        let decoded = message("opened", ["title": "Emma", "author": "Jane Austen", "dir": "rtl",
                                         "fixedLayout": true, "sectionFractions": [0, 0.5, 1]])
        XCTAssertEqual(decoded, .opened(.init(title: "Emma", author: "Jane Austen", isFixedLayout: true,
                                              isRightToLeft: true, sectionFractions: [0, 0.5, 1])))
    }

    func testRelocate() {
        let decoded = message("relocate", ["cfi": "epubcfi(/6/4)", "fraction": 0.25, "chapter": "One",
                                           "chapterHref": "one.xhtml", "pagesLeft": 3, "columns": 2])
        XCTAssertEqual(decoded, .relocate(.init(cfi: "epubcfi(/6/4)", fraction: 0.25, chapter: "One",
                                                chapterHref: "one.xhtml", pagesLeft: 3, columns: 2)))
    }

    func testRelocateBeforeAChapterHasLoaded() {
        // foliate can report no place and a fraction that is not a number.
        let decoded = message("relocate", ["fraction": Double.nan, "chapter": "", "pagesLeft": NSNull()])
        XCTAssertEqual(decoded, .relocate(.init(cfi: nil, fraction: nil, chapter: "", chapterHref: nil,
                                                pagesLeft: nil, columns: 1)))
    }

    func testContents() {
        let decoded = message("contents", ["toc": [["label": "One", "href": "a.xhtml", "depth": 0],
                                                   ["label": "Two", "href": "b.xhtml", "depth": 1]],
                                           "sectionLabels": ["One", "Two"], "synthesised": true])
        guard case .contents(let contents) = decoded else { return XCTFail("not contents") }
        XCTAssertEqual(contents.toc.map(\.label), ["One", "Two"])
        XCTAssertEqual(contents.toc.map(\.id), [0, 1])
        XCTAssertEqual(contents.toc[1].depth, 1)
        XCTAssertTrue(contents.synthesised)
    }

    func testSelection() {
        XCTAssertEqual(message("selection", ["text": ""]), .selection(nil))
        XCTAssertEqual(message("selection", ["text": "a word", "chapter": "One", "page": "12"]),
                       .selection(.init(text: "a word", chapter: "One", page: "12")))
    }

    func testClickZones() {
        XCTAssertEqual(message("click", ["zone": "left"]), .click(.left))
        XCTAssertEqual(message("click", ["zone": "nonsense"]), .click(.centre))
        XCTAssertEqual(ClickZone(x: 10, width: 100), .left)
        XCTAssertEqual(ClickZone(x: 50, width: 100), .centre)
        XCTAssertEqual(ClickZone(x: 90, width: 100), .right)
    }

    func testOnlyWebAndMailLinksAreOpened() {
        XCTAssertEqual(message("externalLink", ["href": "https://example.org/a"]),
                       .externalLink(URL(string: "https://example.org/a")!))
        XCTAssertNil(message("externalLink", ["href": "file:///etc/passwd"]))
        XCTAssertNil(message("externalLink", ["href": "javascript:alert(1)"]))
    }

    func testPicture() {
        let data = Data([1, 2, 3])
        let decoded = message("image", ["data": data.base64EncodedString(), "mimeType": "image/png", "alt": "A map",
                                        "rect": ["x": 10, "y": 20, "width": 30, "height": 40]])
        XCTAssertEqual(decoded, .image(.init(data: data, mimeType: "image/png", alt: "A map",
                                             rect: CGRect(x: 10, y: 20, width: 30, height: 40))))
    }
}

final class ReaderStateTests: XCTestCase {
    func testOpenedKeepsTheTitleFromTheFileWhenThePageHasNone() {
        let state = ReaderState()
        state.title = "From the package"
        state.apply(.opened(.init(title: "", author: "Someone", isRightToLeft: true)))
        XCTAssertEqual(state.title, "From the package")
        XCTAssertEqual(state.author, "Someone")
        XCTAssertTrue(state.isRightToLeft)
    }

    func testRelocateWithoutAFractionKeepsTheOldOne() {
        let state = ReaderState()
        state.apply(.relocate(.init(fraction: 0.4, chapter: "One", columns: 2)))
        state.apply(.relocate(.init(fraction: nil, chapter: "Two")))
        XCTAssertEqual(state.fraction, 0.4)
        XCTAssertEqual(state.chapter, "Two")
        XCTAssertEqual(state.columnsOnScreen, 1)
    }

    func testSearchResultsOfAnOlderSearchAreDropped() {
        let state = ReaderState()
        state.beginSearch("  whale ")
        XCTAssertEqual(state.activeSearchQuery, "whale")
        XCTAssertTrue(state.searchRunning)

        let hit = ReaderMessage.SearchResults.Hit(cfi: "a", pre: "the ", match: "whale", post: " rose")
        state.apply(.searchResults(.init(query: "ship", label: "Old", hits: [hit])))
        XCTAssertTrue(state.searchGroups.isEmpty)

        state.apply(.searchResults(.init(query: "whale", label: "One", hits: [hit, hit])))
        state.apply(.searchResults(.init(query: "whale", label: "Two", hits: [hit])))
        XCTAssertEqual(state.searchGroups.map(\.label), ["One", "Two"])
        // Every hit has its own number, across chapters.
        XCTAssertEqual(state.allHits.map(\.id), [0, 1, 2])

        state.apply(.searchDone(query: "ship"))
        XCTAssertTrue(state.searchRunning)
        state.apply(.searchDone(query: "whale"))
        XCTAssertFalse(state.searchRunning)
        XCTAssertEqual(state.searchDoneQuery, "whale")
    }

    func testLocationLine() {
        let state = ReaderState()
        state.apply(.relocate(.init(fraction: 0.37, chapter: "Chapter 4", pagesLeft: 0)))
        XCTAssertEqual(state.locationLine(showPagesLeft: false), "Chapter 4 · 37%")
        XCTAssertTrue(state.locationLine(showPagesLeft: true).hasSuffix("last page in chapter"))
    }
}

final class BridgeTypesTests: XCTestCase {
    func testPageTurnDirections() {
        XCTAssertTrue(PageTurn.next.leafMovesLeft(rightToLeft: false))
        XCTAssertFalse(PageTurn.next.leafMovesLeft(rightToLeft: true))
        XCTAssertTrue(PageTurn.right.leafMovesLeft(rightToLeft: true)) // sides of the screen never flip
        XCTAssertEqual(PageTurn.left.opposite, .right)
        XCTAssertEqual(PageTurn.prev.opposite, .next)
        XCTAssertTrue(PageTurn.right.isForward)
        XCTAssertFalse(PageTurn.prev.isForward)
    }

    func testWebSettingsPayload() {
        var web = WebSettings(flow: .scrolled, pageLayout: .two, animated: true, fontSize: 18, lineHeight: 1.5,
                              lineWidth: .wide, fontFamily: "Georgia", hyphenate: false, theme: .sepia)
        var payload = web.payload
        XCTAssertEqual(payload["flow"] as? String, "scrolled")
        XCTAssertEqual(payload["pageLayout"] as? String, "two")
        XCTAssertEqual(payload["lineWidth"] as? String, "wide")
        XCTAssertEqual((payload["theme"] as? [String: Any])?["background"] as? String, Theme.sepia.background)
        // The Mac sends none of the touch settings.
        XCTAssertNil(payload["touch"])
        XCTAssertNil(payload["sideMargin"])

        let macSettings = web
        web.touch = true
        web.nativeSwipe = true
        web.sideMargin = 24
        web.verticalMargin = 59
        payload = web.payload
        XCTAssertEqual(payload["touch"] as? Bool, true)
        XCTAssertEqual(payload["nativeSwipe"] as? Bool, true)
        XCTAssertEqual(payload["sideMargin"] as? Double, 24)
        XCTAssertEqual(payload["verticalMargin"] as? Double, 59)
        // Unchanged settings compare equal, so they are not sent twice.
        XCTAssertNotEqual(web, macSettings)
        XCTAssertEqual(macSettings, macSettings)
    }

    func testBookmarksStayInReadingOrderAndAreNotDuplicated() {
        var record = BookRecord(key: "k", uniqueIdentifier: nil, fingerprint: "f")
        XCTAssertTrue(record.addBookmark(.init(cfi: "late", snippet: "Later", fraction: 0.8)))
        XCTAssertTrue(record.addBookmark(.init(cfi: "early", snippet: "Earlier", chapter: "One", page: "4", fraction: 0.1)))
        XCTAssertFalse(record.addBookmark(.init(cfi: "late", snippet: "Again", fraction: 0.8)))
        XCTAssertEqual(record.bookmarks.map(\.cfi), ["early", "late"])
        XCTAssertEqual(record.bookmarks[0].page, "4")
    }

    func testCitation() {
        let selection = ReaderState.Selection(text: "Call me Ishmael.", chapter: "Loomings", page: "1")
        let full = Citation(selection: selection, author: "Herman Melville", title: "Moby-Dick")
        XCTAssertEqual(full.plainText, "“Call me Ishmael.”\n— Herman Melville, Moby-Dick, Loomings, p. 1")
        XCTAssertEqual(full.titleIndex, 1)

        let bare = Citation(selection: .init(text: "Words", chapter: "", page: nil), author: "", title: "")
        XCTAssertEqual(bare.plainText, "“Words”")
        XCTAssertNil(bare.titleIndex)
    }
}

/// A stand-in reader that records what it was asked to do.
private final class RecordingReader: ReaderCommands {
    let state = ReaderState()
    var log: [String] = []

    func turn(_ turn: PageTurn) { log.append("turn \(turn.rawValue)") }
    func jump(to target: String, keepOrigin: Bool) { log.append("jump \(target)") }
    func jump(toFraction fraction: Double) { log.append("fraction \(fraction)") }
    func goBack() { log.append("back") }
    func previousChapter() { log.append("previous chapter") }
    func nextChapter() { log.append("next chapter") }
    func toggleBookmark() { log.append("bookmark") }
    func removeBookmark(cfi: String) { log.append("remove \(cfi)") }
    func search(_ query: String) { log.append("search \(query)") }
    func goToHit(_ hit: ReaderState.SearchHit) {
        state.currentHitID = hit.id
        log.append("hit \(hit.id)")
    }
    func searchPanelClosed() { log.append("search closed") }
    func setLayout(_ layout: ReadingLayout) { log.append("layout \(layout.rawValue)") }
}

final class ReaderCommandsTests: XCTestCase {
    func testFindNextAndPreviousWrapRound() {
        let reader = RecordingReader()
        XCTAssertFalse(reader.stepThroughHits(by: 1), "no results: the caller opens the search panel")

        reader.state.beginSearch("x")
        let hit = ReaderMessage.SearchResults.Hit(cfi: "c", pre: "", match: "x", post: "")
        reader.state.apply(.searchResults(.init(query: "x", label: "One", hits: [hit, hit, hit])))

        XCTAssertTrue(reader.stepThroughHits(by: -1)) // nothing current: Previous starts at the last
        XCTAssertTrue(reader.stepThroughHits(by: 1))  // and wraps to the first
        XCTAssertTrue(reader.stepThroughHits(by: 1))
        XCTAssertEqual(reader.log, ["hit 2", "hit 0", "hit 1"])
    }

    func testOverlayAndContentsActionsReachTheReader() {
        let reader = RecordingReader()
        var contentsToggled = false
        let overlay = OverlayActions(commands: reader, toggleContents: { contentsToggled = true }, interacted: {})
        overlay.nextPage()
        overlay.previousPage()
        overlay.goToFraction(0.5)
        overlay.goBack()
        overlay.toggleBookmark()
        overlay.setLayout(.scroll)
        overlay.toggleContents()
        XCTAssertTrue(contentsToggled)
        XCTAssertEqual(reader.log, ["turn next", "turn prev", "fraction 0.5", "back", "bookmark", "layout scroll"])

        reader.log = []
        reader.state.sidebarVisible = true
        let contents = ContentsActions(commands: reader)
        contents.search("whale")
        XCTAssertTrue(reader.state.sidebarVisible, "searching keeps the panel open")
        contents.goToTOCItem(.init(id: 0, label: "One", href: "one.xhtml", depth: 0))
        XCTAssertFalse(reader.state.sidebarVisible, "choosing a chapter closes the panel")
        contents.removeBookmark(.init(cfi: "b", snippet: ""))
        XCTAssertEqual(reader.log, ["search whale", "jump one.xhtml", "remove b"])
    }
}
