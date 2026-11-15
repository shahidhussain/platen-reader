import XCTest

/// Tests of the folder view's shared logic (Shared/BookFolder.swift): what
/// a folder lists, iCloud's stand-ins for books not yet downloaded, and the
/// chosen folder kept across launches.
final class BookFolderTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func touch(_ folder: URL, _ name: String) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
    }

    func testListsBooksAndFoldersInFinderOrder() throws {
        let folder = try temporaryFolder()
        for name in ["Book 10.epub", "Book 2.epub", "notes.docx", "Report.PDF", "Tale.kepub.epub", "readme.txt", ".DS_Store"] {
            touch(folder, name)
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Series"), withIntermediateDirectories: false)

        let entries = FolderScanner.entries(in: folder)
        XCTAssertEqual(entries.map(\.name), ["Series", "Book 2", "Book 10", "readme", "Report", "Tale"])
        XCTAssertEqual(entries.first?.kind, .folder)
        XCTAssertTrue(entries.dropFirst().allSatisfy { $0.kind == .book && $0.isDownloaded })
    }

    func testICloudStandInsShowAsBooksNotDownloaded() throws {
        let folder = try temporaryFolder()
        touch(folder, ".Far Away.epub.icloud")
        touch(folder, ".notes.docx.icloud") // not a book
        touch(folder, ".icloud")            // nothing to name

        let entries = FolderScanner.entries(in: folder)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Far Away")
        XCTAssertEqual(entries[0].url.lastPathComponent, "Far Away.epub")
        XCTAssertFalse(entries[0].isDownloaded)
    }

    func testMissingFolderListsNothing() {
        XCTAssertEqual(FolderScanner.entries(in: URL(fileURLWithPath: "/no/such/folder")), [])
    }

    func testInsideTreatsPrivateVarAsVar() {
        let folder = URL(fileURLWithPath: "/var/mobile/Books")
        XCTAssertTrue(FolderScanner.isInside(URL(fileURLWithPath: "/private/var/mobile/Books/a/b.epub"), folder: folder))
        XCTAssertTrue(FolderScanner.isInside(folder, folder: folder))
        XCTAssertFalse(FolderScanner.isInside(URL(fileURLWithPath: "/var/mobile/Books2/b.epub"), folder: folder))
    }

    @MainActor
    func testChosenFolderAndLastFolderSurviveRelaunch() throws {
        let root = try temporaryFolder()
        let series = root.appendingPathComponent("Series/Part One", isDirectory: true)
        try FileManager.default.createDirectory(at: series, withIntermediateDirectories: true)
        let suiteName = "org.platenreader.tests.folder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let library = LibraryFolder(defaults: defaults)
        XCTAssertNil(library.root)
        library.choose(root)
        XCTAssertEqual(library.current, root)
        XCTAssertEqual(library.pathFromRoot, [])

        // A book opened from a folder inside the chosen one: that folder is
        // shown, with the folders above it on the navigation path.
        library.bookOpened(series.appendingPathComponent("book.epub"))
        XCTAssertEqual(library.pathFromRoot.map(\.lastPathComponent), ["Series", "Part One"])
        // One from elsewhere changes nothing.
        library.bookOpened(URL(fileURLWithPath: "/elsewhere/book.epub"))
        XCTAssertEqual(library.current.map(FolderScanner.canonicalPath), FolderScanner.canonicalPath(series))

        let relaunched = LibraryFolder(defaults: defaults)
        XCTAssertEqual(relaunched.root.map(FolderScanner.canonicalPath), FolderScanner.canonicalPath(root))
        XCTAssertEqual(relaunched.pathFromRoot.map(\.lastPathComponent), ["Series", "Part One"])

        // The last folder shown has gone: back to the chosen folder.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Series"))
        XCTAssertEqual(LibraryFolder(defaults: defaults).pathFromRoot, [])
    }
}

/// The opening stages behind the loading bar (Shared/OpeningProgress.swift).
final class OpeningStageTests: XCTestCase {
    func testStagesMoveTheBarForwardAndNeverFillIt() {
        let stages: [OpeningStage] = [.downloading, .reading, .preparing, .layingOut]
        XCTAssertEqual(stages, stages.sorted())
        let targets = stages.map(\.progress)
        XCTAssertEqual(targets, targets.sorted(), "each stage moves the bar on")
        XCTAssertLessThan(targets.last ?? 1, 1, "the bar fills only when the page is shown")
        XCTAssertTrue(stages.allSatisfy { !$0.label.isEmpty })
    }

    @MainActor
    func testANewReaderStartsOpening() {
        XCTAssertEqual(ReaderState().opening, .reading)
    }
}
