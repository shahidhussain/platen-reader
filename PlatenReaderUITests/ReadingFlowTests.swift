import XCTest

/// End-to-end tests of the main reading flows, driving the real Mac app the
/// way a person would: opening a book, turning pages, switching layout and
/// bookmarking, then reopening the book.
///
/// They read the page through the accessibility tree. VoiceOver meets the
/// book as one "page" element holding exactly the text on screen (see
/// `BookPageAccessibilityView`), so a test can tell what is showing without
/// looking at pixels.
///
/// The app runs with `PLATEN_TEST_HOME` set, so its settings, positions and
/// bookmarks go to a throwaway location and the tester's own are untouched.
/// The books come from `scripts/make-fixtures.py`; run it first.
final class ReadingFlowTests: XCTestCase {
    /// A folder for this test's positions and bookmarks.
    private var home: URL!
    private var app: XCUIApplication!

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let novel = repository.appendingPathComponent("Fixtures/generated/novel.epub")
    private static let novelTitle = "A Synthetic Novel"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.novel.path),
                          "Run scripts/make-fixtures.py to generate the test books first.")
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("platen-ui-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        app?.terminate()
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    // MARK: Helpers

    /// Launches the app with a book, as double-clicking it would.
    private func launch(_ book: URL = novel) {
        app = XCUIApplication()
        app.launchArguments = [book.path, "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["PLATEN_TEST_HOME"] = home.path
        app.launch()
    }

    /// The book's page as VoiceOver sees it: named after the book, with the
    /// visible text as its value.
    private var page: XCUIElement {
        app.windows.staticTexts.matching(NSPredicate(format: "label == %@", Self.novelTitle)).firstMatch
    }

    /// The text on screen, once there is some.
    private func pageText(timeout: TimeInterval = 15) -> String {
        XCTAssertTrue(page.waitForExistence(timeout: timeout), "The book's page never appeared")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = page.value as? String, !text.isEmpty, text != "No text on this page" { return text }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("The page never showed any text")
        return ""
    }

    /// Waits until the text on screen satisfies a condition, and returns it.
    ///
    /// The page may not exist yet (just after a launch, the window is still
    /// opening): reading a missing element's value fails the test outright,
    /// so it is read only once it exists. Without this check the reopening
    /// test failed whenever the window was slower to appear than the first
    /// look, which on CI machines was some runs and not others.
    @discardableResult
    private func waitForPage(_ description: String, timeout: TimeInterval = 10,
                             until condition: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = ""
        while Date() < deadline {
            if page.exists {
                text = (page.value as? String) ?? ""
                if !text.isEmpty, condition(text) { return text }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("Timed out waiting for the page: \(description)")
        return text
    }

    /// The title the Go menu gives the bookmark command (it says "Remove
    /// Bookmark" when the page is bookmarked).
    private func bookmarkMenuTitle() -> String {
        let go = app.menuBars.menuBarItems["Go"]
        go.click()
        defer { app.typeKey(.escape, modifierFlags: []) }
        if app.menuItems["Remove Bookmark"].waitForExistence(timeout: 1) { return "Remove Bookmark" }
        if app.menuItems["Bookmark This Page"].exists { return "Bookmark This Page" }
        return ""
    }

    // MARK: Tests

    func testOpeningABookShowsItsFirstPage() {
        launch()
        let text = pageText()
        XCTAssertTrue(app.windows.firstMatch.title.contains(Self.novelTitle), "Window title: \(app.windows.firstMatch.title)")
        XCTAssertGreaterThan(text.count, 200, "Too little text on the first page: \(text)")
    }

    func testTurningForwardAndBackReturnsToTheSamePage() {
        launch()
        let first = pageText()
        app.typeKey(.rightArrow, modifierFlags: [])
        let second = waitForPage("the next page") { $0 != first }
        XCTAssertNotEqual(first, second)
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForPage("back on the first page") { $0 == first }
    }

    func testTwoPagesShowMoreTextThanOne() {
        launch()
        _ = pageText()
        // Two pages need room for a readable line in each half of the
        // window. Make the window as large as the screen and the text small
        // (these settings are the test's own), so they fit even on the small
        // screens of CI machines.
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Zoom"].click()
        for _ in 0..<6 { app.typeKey("-", modifierFlags: .command) }
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.5)
        let one = waitForPage("one page") { _ in true }
        app.typeKey("2", modifierFlags: .command)
        let width = app.windows.firstMatch.frame.width
        let two = waitForPage("two pages (window \(Int(width)) points wide)") { $0.count > one.count * 3 / 2 }
        XCTAssertTrue(two.hasPrefix(String(one.prefix(40))), "Two pages should start where one page did")
    }

    func testBookmarkAndPositionSurviveReopening() {
        launch()
        _ = pageText()
        // Move a few pages in, then bookmark that page.
        for _ in 0..<3 {
            let before = (page.value as? String) ?? ""
            app.typeKey(.rightArrow, modifierFlags: [])
            waitForPage("the next page") { $0 != before }
        }
        let bookmarked = (page.value as? String) ?? ""
        XCTAssertEqual(bookmarkMenuTitle(), "Bookmark This Page")
        app.typeKey("d", modifierFlags: .command)
        XCTAssertEqual(bookmarkMenuTitle(), "Remove Bookmark")

        // Positions are saved shortly after the last turn; give it time.
        Thread.sleep(forTimeInterval: 2)
        app.terminate()

        // Reopen: the same page, still bookmarked.
        launch()
        waitForPage("the saved page", timeout: 15) { $0 == bookmarked }
        XCTAssertEqual(bookmarkMenuTitle(), "Remove Bookmark")
    }
}
