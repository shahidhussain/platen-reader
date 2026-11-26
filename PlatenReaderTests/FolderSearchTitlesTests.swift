import PlatenCore
import XCTest

/// A folder's search finds books by title and author even before their
/// covers are made (`FolderModel.readTitlesForSearch`): the first time a
/// large folder was seen, books whose covers were still to come were found
/// only by file name (reported 25 Nov 2026).
@MainActor
final class FolderSearchTitlesTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderSearchTitles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("books"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func waitFor(_ what: String, _ condition: () -> Bool) async {
        let start = Date()
        while !condition(), Date().timeIntervalSince(start) < 10 { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), what)
    }

    func testTitlesAreReadForASearchAheadOfTheCovers() async throws {
        // Fixture books under names that say nothing of their titles.
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/generated").standardizedFileURL
        let folder = root.appendingPathComponent("books")
        var expected: [URL: String] = [:]
        for (i, name) in ["novel.epub", "french.epub", "rtl.epub", "outline.pdf"].enumerated() {
            let copy = folder.appendingPathComponent("book \(i).\((name as NSString).pathExtension)")
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: copy)
            if let title = BookCover.info(from: copy).title { expected[copy.standardizedFileURL] = title }
        }
        XCTAssertGreaterThanOrEqual(expected.count, 3, "the fixtures have titles")

        let model = FolderModel(folder: folder, cache: CoverCache(directory: root.appendingPathComponent("covers"),
                                                                   maxPixelSize: 60))
        model.start()
        defer { model.stop() }
        await waitFor("the folder is read") { model.entries.count == 4 }
        model.readTitlesForSearch()
        await waitFor("every title is known") {
            model.titlesToRead == 0 && model.entries.allSatisfy { model.info(for: $0.url) != nil }
        }
        for entry in model.entries {
            guard let title = expected[entry.url.standardizedFileURL] else { continue }
            XCTAssertEqual(model.info(for: entry.url)?.title, title)
            // Found by its title, which its file name does not contain.
            let info = model.info(for: entry.url)
            XCTAssertTrue(FolderSearch.matches(title, name: entry.name, title: info?.title, authors: info?.authors ?? []))
            XCTAssertFalse(FolderSearch.matches(title, name: entry.name))
        }
    }
}
