import XCTest
@testable import PlatenCore

final class PositionStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("platen-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTrip() throws {
        let store = PositionStore(directory: directory, debounce: 0.01)
        var record = BookRecord(key: "abc", uniqueIdentifier: "urn:x", fingerprint: "1-ff")
        record.lastCFI = "epubcfi(/6/4!/4/2/1:0)"
        record.readingMode = "paginated"
        record.bookmarks = [.init(cfi: "epubcfi(/6/4!/4/10/1:0)", created: Date(timeIntervalSince1970: 0), snippet: "It was")]
        store.saveNow(record)
        XCTAssertEqual(store.load(key: "abc"), record)

        // The file is human-readable JSON.
        let json = try String(contentsOf: directory.appendingPathComponent("abc.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"lastCFI\" : \"epubcfi(/6/4!/4/2/1:0)\""))
        XCTAssertTrue(json.contains("\"schemaVersion\" : 1"))
    }

    func testDebouncedSaveKeepsLatest() {
        let store = PositionStore(directory: directory, debounce: 0.05)
        var record = BookRecord(key: "k", uniqueIdentifier: nil, fingerprint: "f")
        for i in 0..<10 {
            record.lastCFI = "epubcfi(/6/\(i))"
            store.scheduleSave(record)
        }
        XCTAssertNil(store.load(key: "k"))
        let done = expectation(description: "saved")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(store.load(key: "k")?.lastCFI, "epubcfi(/6/9)")
    }

    func testRemoveAll() throws {
        let store = PositionStore(directory: directory)
        store.saveNow(BookRecord(key: "a", uniqueIdentifier: nil, fingerprint: "f"))
        try store.removeAll()
        XCTAssertNil(store.load(key: "a"))
    }
}

final class BookmarkCompatibilityTests: XCTestCase {
    /// Files written before bookmarks gained chapter/page/fraction still load.
    func testOldBookmarkWithoutOptionalFieldsDecodes() throws {
        let json = """
        {"schemaVersion":1,"key":"k","fingerprint":"f","bookmarks":[
          {"cfi":"epubcfi(/6/2)","created":"2026-01-01T00:00:00Z","snippet":"Hi"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(BookRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.bookmarks.first?.snippet, "Hi")
        XCTAssertNil(record.bookmarks.first?.chapter)
    }
}
