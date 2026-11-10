import XCTest
@testable import PlatenCore

/// Guards the Swift share of the open-time budget (spec: warm open of a
/// typical 2 MB novel to text visible in under 400 ms). Swift's part is
/// reading the zip directory, the package and the first chapter; the rest is
/// WebKit's. The limits are generous so CI machines do not flake, but a
/// regression of an order of magnitude will fail.
final class TimingTests: XCTestCase {
    /// A ~2 MB (uncompressed) EPUB with 30 chapters, built in memory.
    private static let novel: Data = {
        var zip = EPUBFixture.basic()
        let paragraph = "<p>" + String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40) + "</p>\n"
        for i in 1...30 {
            zip.add("OEBPS/ch\(i).xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>"
                    + String(repeating: paragraph, count: 40) + "</body></html>")
        }
        return zip.build()
    }()

    func testOpeningANovelIsFast() throws {
        let data = Self.novel
        let start = CFAbsoluteTimeGetCurrent()
        let book = try Book.open(source: MemoryByteSource(data: data))
        _ = try book.resource(at: "OEBPS/ch1.xhtml")
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 100, "Opening took \(Int(elapsed)) ms")
    }

    func testOpenPerformance() throws {
        let data = Self.novel
        measure {
            _ = try? Book.open(source: MemoryByteSource(data: data)).resource(at: "OEBPS/ch15.xhtml")
        }
    }
}
