import Foundation
import XCTest
@testable import PlatenCore

/// What a problem report says about a book (`BookFacts`): its kind, EPUB
/// version and the program that made it, read even from books that do not
/// open.
final class BookFactsTests: XCTestCase {
    func testAnEPUBsVersionAndGenerator() throws {
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>A Book</dc:title>
            <meta name="generator" content="Pages Publishing 14.1"/>
          </metadata>
          <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c"/></spine>
        </package>
        """
        let facts = BookFacts.read(source: MemoryByteSource(data: try epub(opf: opf)))
        XCTAssertEqual(facts.kind, "EPUB")
        XCTAssertEqual(facts.epubVersion, "3.0")
        XCTAssertEqual(facts.generator, "Pages Publishing 14.1")
        // Never the title.
        XCTAssertFalse(facts.lines.joined().contains("A Book"))
    }

    func testCalibresBookProducerIsTheGenerator() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:contributor opf:role="bkp">calibre (7.2.0) [https://calibre-ebook.com]</dc:contributor>
          </metadata>
          <manifest/><spine/>
        </package>
        """
        let facts = BookFacts.read(source: MemoryByteSource(data: try epub(opf: opf)))
        XCTAssertEqual(facts.epubVersion, "2.0")
        XCTAssertEqual(facts.generator, "calibre (7.2.0) [https://calibre-ebook.com]")
    }

    func testOtherKinds() {
        XCTAssertEqual(BookFacts.read(source: MemoryByteSource(data: Data("%PDF-1.7\n%âãÏÓ\n".utf8))).kind, "PDF 1.7")
        XCTAssertEqual(BookFacts.read(source: MemoryByteSource(data: Data("Once upon a time.\n".utf8))).kind, "plain text")
        XCTAssertEqual(BookFacts.read(source: MemoryByteSource(data: Data([0, 1, 2, 3, 0xFF, 0xFE]))).kind, "unrecognised")
    }

    /// A stored (uncompressed) zip with the container and `opf`.
    private func epub(opf: String) throws -> Data {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", store: true)
        zip.add("META-INF/container.xml", container)
        zip.add("OEBPS/content.opf", opf)
        return zip.build()
    }
}
