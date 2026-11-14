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

/// Finding the pictures on a PDF page (PDFPictures), for long-press save and
/// share.
final class PDFPicturesTests: XCTestCase {
    private func image(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A one-page PDF (612 × 792) drawn by `draw`.
    private func page(_ draw: (CGContext) -> Void) -> CGPDFPage {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return CGPDFDocument(CGDataProvider(data: data as CFData)!)!.page(at: 1)!
    }

    func testFindsPicturesWhereTheyAreDrawn() {
        let page = page { context in
            context.draw(image(40, 30), in: CGRect(x: 100, y: 500, width: 200, height: 150))
            context.saveGState()
            context.translateBy(x: 300, y: 100)
            context.scaleBy(x: 2, y: 2)
            context.draw(image(10, 10), in: CGRect(x: 10, y: 10, width: 50, height: 40))
            context.restoreGState()
            // Text and shapes are not pictures.
            context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        }
        let rects = PDFPictures.rects(on: page)
        XCTAssertEqual(rects.count, 2)
        assertClose(rects[0], CGRect(x: 100, y: 500, width: 200, height: 150))
        assertClose(rects[1], CGRect(x: 320, y: 120, width: 100, height: 80))
    }

    func testPictureUnderAPointPrefersTheSmallest() {
        let page = page { context in
            context.draw(image(20, 20), in: CGRect(x: 0, y: 0, width: 612, height: 792)) // a scanned page
            context.draw(image(20, 20), in: CGRect(x: 200, y: 200, width: 100, height: 100))
        }
        assertClose(PDFPictures.picture(at: CGPoint(x: 250, y: 250), on: page), CGRect(x: 200, y: 200, width: 100, height: 100))
        assertClose(PDFPictures.picture(at: CGPoint(x: 50, y: 50), on: page), CGRect(x: 0, y: 0, width: 612, height: 792))
    }

    func testPageWithoutPicturesHasNone() {
        let page = page { context in context.fill(CGRect(x: 10, y: 10, width: 100, height: 100)) }
        XCTAssertEqual(PDFPictures.rects(on: page), [])
        XCTAssertNil(PDFPictures.picture(at: CGPoint(x: 50, y: 50), on: page))
    }

    func testTinyPicturesAreLeftOut() {
        let page = page { context in context.draw(image(2, 2), in: CGRect(x: 10, y: 10, width: 4, height: 300)) }
        XCTAssertEqual(PDFPictures.rects(on: page), [])
    }

    private func assertClose(_ a: CGRect?, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("no picture", file: file, line: line) }
        for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] {
            XCTAssertEqual(x, y, accuracy: 0.5, "\(a) is not \(b)", file: file, line: line)
        }
    }
}
