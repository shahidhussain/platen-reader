import CoreGraphics
import PlatenCore
import XCTest

/// Pulling to refresh a folder waits until the folder has been read again,
/// and shows a book added since it was last read (a pulled refresh on a
/// network share seemed to do nothing, reported 26 Nov 2026).
@MainActor
final class FolderRefreshTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderRefresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("books"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func testPullToRefreshWaitsForTheNewListing() async throws {
        let folder = root.appendingPathComponent("books")
        try Self.pdf().write(to: folder.appendingPathComponent("first.pdf"))
        let model = FolderModel(folder: folder, cache: CoverCache(directory: root.appendingPathComponent("covers"),
                                                                   maxPixelSize: 40))
        await model.refreshByReader()
        XCTAssertEqual(model.entries.map(\.name), ["first"])

        // Added behind the model's back (no presenter: as from another
        // computer on a share), then pulled to refresh: there as soon as
        // the pull returns, with no waiting.
        try Self.pdf().write(to: folder.appendingPathComponent("second.pdf"))
        await model.refreshByReader()
        XCTAssertEqual(model.entries.map(\.name), ["first", "second"])
    }

    func testPullsDuringARead() async throws {
        let folder = root.appendingPathComponent("books")
        try Self.pdf().write(to: folder.appendingPathComponent("first.pdf"))
        let model = FolderModel(folder: folder, cache: CoverCache(directory: root.appendingPathComponent("covers"),
                                                                   maxPixelSize: 40))
        // A read under way when the reader pulls: the pull waits for the
        // read after it, which sees the book added in between.
        model.refresh()
        try Self.pdf().write(to: folder.appendingPathComponent("second.pdf"))
        await model.refreshByReader()
        XCTAssertEqual(model.entries.map(\.name), ["first", "second"])
    }
}
