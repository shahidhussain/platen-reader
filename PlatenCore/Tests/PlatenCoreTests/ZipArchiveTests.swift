import XCTest
@testable import PlatenCore

final class ZipArchiveTests: XCTestCase {
    private func archive(_ data: Data) throws -> ZipArchive {
        try ZipArchive(source: MemoryByteSource(data: data))
    }

    func testReadsStoredAndDeflatedEntries() throws {
        var zip = ZipWriter()
        let long = String(repeating: "The quick brown fox. ", count: 2000)
        zip.add("stored.txt", "hello", store: true)
        zip.add("deflated.txt", long)
        let a = try archive(zip.build())
        XCTAssertEqual(a.entries.map(\.path), ["stored.txt", "deflated.txt"])
        XCTAssertEqual(String(decoding: try a.data(at: "stored.txt"), as: UTF8.self), "hello")
        XCTAssertEqual(String(decoding: try a.data(at: "deflated.txt"), as: UTF8.self), long)
        XCTAssertEqual(a.entry(at: "deflated.txt")?.method, 8)
        XCTAssertFalse(a.wasRecovered)
    }

    func testZip64() throws {
        var zip = ZipWriter()
        zip.add("a.txt", "alpha")
        zip.add("b.txt", "beta", store: true)
        let a = try archive(zip.build(.init(zip64: true)))
        XCTAssertEqual(a.entries.count, 2)
        XCTAssertEqual(String(decoding: try a.data(at: "a.txt"), as: UTF8.self), "alpha")
        XCTAssertEqual(String(decoding: try a.data(at: "b.txt"), as: UTF8.self), "beta")
    }

    func testPrefixedExtraDataIsCorrected() throws {
        var zip = ZipWriter()
        zip.add("a.txt", "alpha")
        let a = try archive(zip.build(.init(prefix: Data(repeating: 0x41, count: 1234))))
        XCTAssertEqual(String(decoding: try a.data(at: "a.txt"), as: UTF8.self), "alpha")
        XCTAssertTrue(a.problems.contains { $0.contains("shifted") })
    }

    func testRecoversWhenCentralDirectoryMissing() throws {
        var zip = ZipWriter()
        zip.add("a.txt", "alpha")
        zip.add("b.txt", String(repeating: "beta ", count: 100))
        let a = try archive(zip.build(.init(omitCentralDirectory: true)))
        XCTAssertTrue(a.wasRecovered)
        XCTAssertEqual(a.entries.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(String(decoding: try a.data(at: "a.txt"), as: UTF8.self), "alpha")
        XCTAssertEqual(String(decoding: try a.data(at: "b.txt"), as: UTF8.self), String(repeating: "beta ", count: 100))
    }

    func testRecoversDataDescriptorEntriesWithoutDirectory() throws {
        var zip = ZipWriter()
        zip.add("a.txt", "alpha")
        zip.add("s.txt", "stored", store: true)
        let a = try archive(zip.build(.init(omitCentralDirectory: true, dataDescriptor: true)))
        XCTAssertEqual(String(decoding: try a.data(at: "a.txt"), as: UTF8.self), "alpha")
        XCTAssertEqual(String(decoding: try a.data(at: "s.txt"), as: UTF8.self), "stored")
    }

    func testTruncatedEntryReturnsPartialData() throws {
        var zip = ZipWriter()
        let text = String(repeating: "abcdefghij", count: 5000)
        zip.add("big.txt", text, store: true)
        let full = zip.build(.init(omitCentralDirectory: true))
        let truncated = full.prefix(full.count - 1000)
        let a = try archive(Data(truncated))
        let partial = try a.data(for: a.entries[0], allowPartial: true)
        XCTAssertGreaterThan(partial.count, 1000)
        XCTAssertTrue(text.hasPrefix(String(decoding: partial, as: UTF8.self)))
    }

    func testNotAZip() {
        XCTAssertThrowsError(try archive(Data("just some text, definitely not a zip".utf8))) { error in
            XCTAssertEqual(error as? ZipError, .notAZip)
        }
    }

    func testFileByteSourceReadsLazily() throws {
        var zip = ZipWriter()
        zip.add("a.txt", "alpha")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try zip.build().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try ZipArchive(source: try FileByteSource(url: url))
        XCTAssertEqual(String(decoding: try a.data(at: "a.txt"), as: UTF8.self), "alpha")
    }
}
