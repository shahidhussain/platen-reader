import Combine
import CoreGraphics
import PlatenCore
import XCTest

/// A folder's covers are made in the order its grid shows the books
/// (`FolderModel.showOrder`), so a grid in Random order fills in from the
/// top rather than scattered (reported 26 Nov 2026).
@MainActor
final class FolderCoverOrderTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderCoverOrder-\(UUID().uuidString)")
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

    func testCoversAreMadeInTheOrderShown() async throws {
        let folder = root.appendingPathComponent("books")
        let names = (0..<6).map { "book \($0).pdf" }
        for name in names { try Self.pdf().write(to: folder.appendingPathComponent(name)) }
        let model = FolderModel(folder: folder, cache: CoverCache(directory: root.appendingPathComponent("covers"),
                                                                   maxPixelSize: 40))
        // The grid's order, as a shuffle would give: not the folder's own.
        let shown = [3, 0, 5, 1, 4, 2].map { folder.appendingPathComponent(names[$0]) }
        model.showOrder(shown)

        var made: [URL] = []
        let watch = model.$covers.sink { covers in
            for url in covers.keys where !made.contains(url) { made.append(url) }
        }
        defer { watch.cancel() }
        model.start()
        defer { model.stop() }
        let start = Date()
        while made.count < names.count, Date().timeIntervalSince(start) < 10 { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(made.count, names.count, "every cover made")
        // The first one may have begun before the order was known (the view
        // says it as it appears); the rest follow the grid.
        let order = made.map(\.lastPathComponent)
        XCTAssertEqual(Array(order.dropFirst()), shown.map(\.lastPathComponent).filter { $0 != order.first })
    }
}
