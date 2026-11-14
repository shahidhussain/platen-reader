import CoreGraphics
import ImageIO
import XCTest
@testable import PlatenCore

final class BookCoverTests: XCTestCase {
    // MARK: Helpers

    /// A PNG of one colour (alpha 0 for transparent).
    private func png(width: Int, height: Int, red: CGFloat, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func image(_ jpeg: Data?) throws -> CGImage {
        let data = try XCTUnwrap(jpeg, "no cover picture")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The colour of the picture's centre pixel, as 0–255 RGB.
    private func centreColour(_ image: CGImage) -> [Int] {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
        return [Int(pixel[0]), Int(pixel[1]), Int(pixel[2])]
    }

    private func assertRoughly(_ colour: [Int], _ expected: [Int], file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(colour, expected) {
            XCTAssertLessThan(abs(a - b), 24, "colour \(colour), expected about \(expected)", file: file, line: line)
        }
    }

    private func cover(_ zip: ZipWriter, maxPixelSize: Int = 300) -> BookCover.Result {
        BookCover.extract(source: MemoryByteSource(data: zip.build()), maxPixelSize: maxPixelSize)
    }

    // MARK: EPUB

    func testEPUB3CoverImageProperty() throws {
        let zip = EPUBFixture.basic { zip in
            zip.add("OEBPS/content.opf", EPUBFixture.opf(extraManifest: """
            <item id="pic" href="images/front.png" media-type="image/png" properties="cover-image"/>
            <item id="other" href="images/cover-other.png" media-type="image/png"/>
            """))
            zip.add("OEBPS/images/front.png", png(width: 600, height: 900, red: 1), store: true)
            zip.add("OEBPS/images/cover-other.png", png(width: 10, height: 10, red: 0, blue: 1), store: true)
        }
        let result = cover(zip)
        XCTAssertEqual(result.info.title, "Test Book")
        XCTAssertEqual(result.info.authors, ["Ada Author"])
        let picture = try image(result.jpeg)
        // Made small, keeping its shape: 300 on the longest side.
        XCTAssertEqual(picture.height, 300)
        XCTAssertEqual(picture.width, 200)
        assertRoughly(centreColour(picture), [255, 0, 0])
    }

    func testEPUB2MetaCover() throws {
        let zip = EPUBFixture.basic { zip in
            zip.add("OEBPS/content.opf", EPUBFixture.opf(extraMeta: "<meta name=\"cover\" content=\"pic\"/>",
                                                        extraManifest: "<item id=\"pic\" href=\"art.png\" media-type=\"image/png\"/>"))
            zip.add("OEBPS/art.png", png(width: 40, height: 60, red: 0, green: 1))
        }
        assertRoughly(centreColour(try image(cover(zip).jpeg)), [0, 255, 0])
    }

    func testMetaCoverNamingAPageUsesItsPicture() throws {
        let zip = EPUBFixture.basic { zip in
            zip.add("OEBPS/content.opf", EPUBFixture.opf(extraMeta: "<meta name=\"cover\" content=\"cpage\"/>",
                                                        extraManifest: """
            <item id="cpage" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="pic" href="images/c%20one.png" media-type="image/png"/>
            """))
            zip.add("OEBPS/text/cover.xhtml", "<html><body><div><img alt='' src=\"../images/c%20one.png\"/></div></body></html>")
            zip.add("OEBPS/images/c one.png", png(width: 40, height: 60, red: 0, blue: 1))
        }
        assertRoughly(centreColour(try image(cover(zip).jpeg)), [0, 0, 255])
    }

    func testGuideCoverPageWithSVGImage() throws {
        let opf = EPUBFixture.opf(extraManifest: """
        <item id="titlepage" href="titlepage.xhtml" media-type="application/xhtml+xml"/>
        <item id="pic" href="front.jpeg" media-type="image/jpeg"/>
        """).replacingOccurrences(of: "</package>", with: """
        <guide><reference type="cover" title="Cover" href="titlepage.xhtml#start"/></guide></package>
        """)
        let zip = EPUBFixture.basic { zip in
            zip.add("OEBPS/content.opf", opf)
            zip.add("OEBPS/titlepage.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml"><body><svg xmlns:xlink="http://www.w3.org/1999/xlink">
            <image width="600" height="800" xlink:href="front.jpeg"/></svg></body></html>
            """)
            zip.add("OEBPS/front.jpeg", png(width: 30, height: 40, red: 1, green: 1))
        }
        assertRoughly(centreColour(try image(cover(zip).jpeg)), [255, 255, 0])
    }

    func testImageNamedCoverIsAGoodGuess() throws {
        let zip = EPUBFixture.basic { zip in
            zip.add("OEBPS/content.opf", EPUBFixture.opf(extraManifest: """
            <item id="i1" href="figure1.png" media-type="image/png"/>
            <item id="i2" href="Cover.png" media-type="image/png"/>
            """))
            zip.add("OEBPS/figure1.png", png(width: 10, height: 10, red: 0, blue: 1))
            zip.add("OEBPS/Cover.png", png(width: 10, height: 10, red: 1))
        }
        assertRoughly(centreColour(try image(cover(zip).jpeg)), [255, 0, 0])
    }

    func testFirstPageThatIsJustAPicture() throws {
        let zip = EPUBFixture.basic { zip in
            zip.add("OEBPS/content.opf", EPUBFixture.opf(extraManifest: "<item id=\"p\" href=\"p.png\" media-type=\"image/png\"/>"))
            zip.add("OEBPS/chapter1.xhtml", "<html><body><p>Front</p><img src=\"p.png\"/></body></html>")
            zip.add("OEBPS/p.png", png(width: 10, height: 10, red: 0, green: 1))
        }
        assertRoughly(centreColour(try image(cover(zip).jpeg)), [0, 255, 0])
    }

    func testFirstPageFullOfTextIsNotACover() {
        let text = String(repeating: "It was a bright cold day in April. ", count: 20)
        let zip = EPUBFixture.basic { zip in
            zip.add("OEBPS/content.opf", EPUBFixture.opf(extraManifest: "<item id=\"f\" href=\"fig.png\" media-type=\"image/png\"/>"))
            zip.add("OEBPS/chapter1.xhtml", "<html><body><p>\(text)</p><img src=\"fig.png\"/></body></html>")
            zip.add("OEBPS/fig.png", png(width: 10, height: 10, red: 1))
        }
        XCTAssertNil(cover(zip).jpeg)
    }

    func testNoCoverStillGivesTheTitle() {
        let result = cover(EPUBFixture.basic())
        XCTAssertNil(result.jpeg)
        XCTAssertEqual(result.info.title, "Test Book")
    }

    func testTransparentCoverComesOutWhite() throws {
        let zip = EPUBFixture.basic { zip in
            zip.add("OEBPS/content.opf", EPUBFixture.opf(extraManifest: "<item id=\"c\" href=\"c.png\" media-type=\"image/png\" properties=\"cover-image\"/>"))
            zip.add("OEBPS/c.png", png(width: 20, height: 20, red: 0, alpha: 0))
        }
        assertRoughly(centreColour(try image(cover(zip).jpeg)), [255, 255, 255])
    }

    func testBrokenCoverPictureGivesNoPicture() {
        let zip = EPUBFixture.basic { zip in
            zip.add("OEBPS/content.opf", EPUBFixture.opf(extraManifest: "<item id=\"c\" href=\"c.png\" media-type=\"image/png\" properties=\"cover-image\"/>"))
            zip.add("OEBPS/c.png", "not a picture")
        }
        let result = cover(zip)
        XCTAssertNil(result.jpeg)
        XCTAssertEqual(result.info.title, "Test Book")
    }

    func testNotABookGivesNothing() {
        let result = BookCover.extract(source: MemoryByteSource(data: Data("just some text".utf8)), maxPixelSize: 100)
        XCTAssertNil(result.jpeg)
        XCTAssertNil(result.info.title)
    }

    // MARK: PDF

    private func pdfData(width: CGFloat, height: CGFloat, title: String? = nil) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, info as CFDictionary)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.beginPDFPage(nil) // a second page, which must not matter
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func testPDFFirstPage() throws {
        let data = pdfData(width: 400, height: 600, title: "A Report")
        let result = BookCover.pdf(provider: CGDataProvider(data: data as CFData)!, maxPixelSize: 300)
        XCTAssertEqual(result.info.title, "A Report")
        let picture = try image(result.jpeg)
        XCTAssertEqual(picture.height, 300)
        XCTAssertEqual(picture.width, 200)
        assertRoughly(centreColour(picture), [0, 0, 255])
    }

    func testPDFFromFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdfData(width: 600, height: 400).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = BookCover.extract(from: url, maxPixelSize: 120)
        XCTAssertNil(result.info.title)
        let picture = try image(result.jpeg)
        XCTAssertEqual(picture.width, 120)
        XCTAssertEqual(picture.height, 80)
    }

    // MARK: Cache

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCacheMakesThenReusesACover() throws {
        let folder = try temporaryFolder()
        let book = folder.appendingPathComponent("book.epub")
        try EPUBFixture.basic { zip in
            zip.add("OEBPS/content.opf", EPUBFixture.opf(extraManifest: "<item id=\"c\" href=\"c.png\" media-type=\"image/png\" properties=\"cover-image\"/>"))
            zip.add("OEBPS/c.png", png(width: 200, height: 300, red: 1))
        }.build().write(to: book)
        let cache = CoverCache(directory: folder.appendingPathComponent("Covers"), maxPixelSize: 90)

        let key = try XCTUnwrap(CoverCache.key(for: book))
        XCTAssertNil(cache.cached(key: key))
        let made = cache.cover(for: book)
        XCTAssertEqual(made.info.title, "Test Book")
        let imageURL = try XCTUnwrap(made.imageURL)
        XCTAssertEqual(try image(Data(contentsOf: imageURL)).height, 90)
        XCTAssertEqual(cache.cached(key: key), made)
        // Pictures are never made larger than they are.
        XCTAssertEqual(try image(BookCover.thumbnail(imageData: png(width: 20, height: 30, red: 1), maxPixelSize: 90)).height, 30)

        // Editing the book (a new modification date) gives it a new key.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: book.path)
        XCTAssertNotEqual(CoverCache.key(for: book), key)
    }

    func testCacheRemembersBooksWithoutAPicture() throws {
        let cache = CoverCache(directory: try temporaryFolder())
        cache.store(BookCover.Result(info: BookCoverInfo(title: "Plain", authors: ["A"]), jpeg: nil), key: "k")
        XCTAssertEqual(cache.cached(key: "k"), CoverCache.Entry(info: BookCoverInfo(title: "Plain", authors: ["A"]), imageURL: nil))
    }

    func testCacheIgnoresEntriesFromAnOlderVersion() throws {
        let folder = try temporaryFolder()
        let cache = CoverCache(directory: folder)
        let old = #"{"version":0,"info":{"title":"Old","authors":[]},"hasImage":false}"#
        try Data(old.utf8).write(to: folder.appendingPathComponent("k.json"))
        XCTAssertNil(cache.cached(key: "k"))
    }

    func testKeyDependsOnPathSizeAndDate() {
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        let key = CoverCache.key(path: "/a/b.epub", size: 10, modified: date)
        XCTAssertEqual(key, CoverCache.key(path: "/a/b.epub", size: 10, modified: date))
        XCTAssertNotEqual(key, CoverCache.key(path: "/a/c.epub", size: 10, modified: date))
        XCTAssertNotEqual(key, CoverCache.key(path: "/a/b.epub", size: 11, modified: date))
        XCTAssertNotEqual(key, CoverCache.key(path: "/a/b.epub", size: 10, modified: date.addingTimeInterval(1)))
    }
}
