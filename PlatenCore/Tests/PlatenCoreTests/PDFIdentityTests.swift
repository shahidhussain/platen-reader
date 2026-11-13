import XCTest
@testable import PlatenCore

final class PDFIdentityTests: XCTestCase {
    private func pdf(trailer: String) -> Data {
        Data("%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\nxref\n0 1\n\(trailer)\nstartxref\n0\n%%EOF\n".utf8)
    }

    func testRecognisesPDFHeader() {
        XCTAssertTrue(PDFIdentity.looksLikePDF(Data("%PDF-1.4\n".utf8)))
        XCTAssertTrue(PDFIdentity.looksLikePDF(Data("\u{0}\u{0}junk%PDF-1.4\n".utf8)))
        XCTAssertFalse(PDFIdentity.looksLikePDF(Data("PK\u{3}\u{4}".utf8)))
    }

    func testReadsFirstPartOfDocumentID() throws {
        let data = pdf(trailer: "trailer << /Size 1 /ID [<0A1B2C3D> <FFEE>] >>")
        let id = try PDFIdentity.identify(source: MemoryByteSource(data: data))
        XCTAssertEqual(id.documentID, "0a1b2c3d")
    }

    func testLatestRevisionWins() throws {
        let data = pdf(trailer: "trailer << /ID [<AAAA><BBBB>] >>\ntrailer << /ID[ <CCCC> <DDDD> ] >>")
        XCTAssertEqual(try PDFIdentity.identify(source: MemoryByteSource(data: data)).documentID, "cccc")
    }

    func testNoDocumentIDStillGivesAKey() throws {
        let data = pdf(trailer: "trailer << /Size 1 >>")
        let id = try PDFIdentity.identify(source: MemoryByteSource(data: data))
        XCTAssertNil(id.documentID)
        XCTAssertEqual(id.key.count, 32)
    }

    func testKeyDiffersFromEPUBWithSameIdentifier() throws {
        let data = pdf(trailer: "trailer << /ID [<ABCD><EF01>] >>")
        let id = try PDFIdentity.identify(source: MemoryByteSource(data: data))
        XCTAssertNotEqual(id.key, BookIdentity.key(uniqueIdentifier: "abcd", fingerprint: id.fingerprint))
    }

    func testRecordWithPDFFieldsRoundTrips() throws {
        var record = BookRecord(key: "k", uniqueIdentifier: "pdf:abcd", fingerprint: "1-2")
        record.lastPage = 12
        record.lastZoom = 1.5
        let decoded = try JSONDecoder().decode(BookRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.lastPage, 12)
        XCTAssertEqual(decoded.lastZoom, 1.5)
    }
}
