import XCTest

/// Tests of the log lines (`LogMessage`, Shared/Log.swift) and the
/// diagnostics file a reader can share (`DiagnosticLog`).
final class DiagnosticLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testNumbersArePublicAndTextPrivateByDefault() {
        let secret = "secret"
        let message: LogMessage = "took \(42) ms, \(1.5, format: .fixed(precision: 0)) s, \(secret)"
        XCTAssertEqual(message.system, "took 42 ms, 2 s, <private>")
        XCTAssertEqual(message.file, "took 42 ms, 2 s, <private>")
    }

    func testNamesShowInTheDeviceLogButNotTheFile() {
        let name = "Moby Dick.epub"
        let message: LogMessage = "Read \(name, privacy: .name) in \(120) ms"
        XCTAssertEqual(message.system, "Read Moby Dick.epub in 120 ms")
        XCTAssertEqual(message.file, "Read <name> in 120 ms")
    }

    func testQuotedNamesInErrorsAreLeftOutOfTheFile() {
        let error = "The file \u{201C}Moby Dick.epub\u{201D} couldn\u{2019}t be opened."
        let message: LogMessage = "Could not open: \(error, privacy: .public)"
        XCTAssertEqual(message.system, "Could not open: \(error)")
        XCTAssertEqual(message.file, "Could not open: The file \u{201C}…\u{201D} couldn\u{2019}t be opened.")
    }

    func testLinesAreKeptOnlyOnceTurnedOn() throws {
        let diagnostics = DiagnosticLog(directory: directory)
        diagnostics.add("before", level: "")
        diagnostics.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostics.fileURL.path))

        diagnostics.enableForTesting()
        diagnostics.add("main thread busy for 420 ms", level: "")
        diagnostics.add("reader error: boom\nat line 3", level: "error: ")
        diagnostics.flush()
        let text = try String(contentsOf: diagnostics.fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("before"))
        XCTAssertTrue(text.contains(" main thread busy for 420 ms\n"))
        // A second line of a message is indented under the first.
        XCTAssertTrue(text.contains(" error: reader error: boom\n    at line 3\n"))
    }

    func testRepeatedLinesAreKeptOnceWithACount() throws {
        let diagnostics = DiagnosticLog(directory: directory)
        diagnostics.enableForTesting()
        for _ in 0..<5 { diagnostics.add("relocate epubcfi(/6/4)", level: "") }
        diagnostics.add("page curl took 410 ms", level: "")
        diagnostics.flush()
        let text = try String(contentsOf: diagnostics.fileURL, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "relocate").count, 2)
        XCTAssertTrue(text.contains("relocate epubcfi(/6/4)\n    (and 4 more the same)\n"))
        XCTAssertTrue(text.contains("page curl took 410 ms"))
    }

    func testTheFileKeepsToItsLimitDroppingTheOldest() throws {
        let diagnostics = DiagnosticLog(directory: directory)
        diagnostics.enableForTesting()
        let line = String(repeating: "x", count: 1000)
        for index in 0..<700 { diagnostics.add("\(index) \(line)", level: "") }
        diagnostics.flush()
        let text = try String(contentsOf: diagnostics.fileURL, encoding: .utf8)
        XCTAssertLessThanOrEqual(text.utf8.count, DiagnosticLog.limit)
        XCTAssertTrue(text.contains(" 699 x"))
        XCTAssertFalse(text.contains(" 0 x"))
        // Cut at the start of a line: each line begins with its date.
        XCTAssertTrue(text.hasPrefix("20"))
    }

    func testTheSharedCopyIsNamedForTheMomentItWasMade() throws {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 11, 22, 10, 41, 14)
        let date = try XCTUnwrap(Calendar.current.date(from: parts))
        XCTAssertEqual(DiagnosticLog.fileName(at: date), "Platen Reader Diagnostics 2026-11-22 at 10.41.14.txt")
    }

    func testTheSharedCopySaysWhatItIs() throws {
        let diagnostics = DiagnosticLog(directory: directory)
        diagnostics.enableForTesting()
        diagnostics.add("home: books tab", level: "")
        let copy = try diagnostics.export(now: Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertEqual(copy.lastPathComponent, DiagnosticLog.fileName(at: Date(timeIntervalSince1970: 1_795_000_000)))
        let text = try String(contentsOf: copy, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Platen Reader diagnostics, made 2026-"))
        XCTAssertTrue(text.contains("left out"))
        XCTAssertTrue(text.contains("home: books tab"))
    }
}
