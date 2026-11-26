import CoreGraphics
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

    /// A one-page PDF with `title` in its document information.
    private static func pdf(title: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let info = [kCGPDFContextTitle: title] as CFDictionary
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, info)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func testTitlesAreReadForASearchAheadOfTheCovers() async throws {
        // Books under names that say nothing of their titles: small PDFs
        // with a title in their document information, made here (the
        // generated fixtures are not there when CI runs these tests).
        let folder = root.appendingPathComponent("books")
        var expected: [URL: String] = [:]
        for (i, title) in ["Middlemarch", "The Tunnel Under the World", "Persuasion", "Kokoro"].enumerated() {
            let copy = folder.appendingPathComponent("book \(i).pdf")
            try Self.pdf(title: title).write(to: copy)
            expected[copy.standardizedFileURL] = title
        }
        XCTAssertEqual(BookCover.info(from: folder.appendingPathComponent("book 0.pdf")).title, "Middlemarch")

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
