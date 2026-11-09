import XCTest
@testable import PlatenCore

final class BookTests: XCTestCase {
    private func open(_ zip: ZipWriter, _ options: ZipWriter.Options = .init()) throws -> Book {
        try Book.open(source: MemoryByteSource(data: zip.build(options)))
    }

    // MARK: Package parsing

    func testParsesPackageMetadata() throws {
        let book = try open(EPUBFixture.basic())
        XCTAssertEqual(book.format, .epub)
        XCTAssertEqual(book.title, "Test Book")
        XCTAssertEqual(book.authors, ["Ada Author"])
        XCTAssertEqual(book.package?.uniqueIdentifier, "urn:uuid:12345678-1234-1234-1234-1234567890ab")
        XCTAssertEqual(book.package?.spine, ["OEBPS/chapter1.xhtml"])
        XCTAssertEqual(book.package?.opfPath, "OEBPS/content.opf")
        XCTAssertFalse(book.isFixedLayout)
    }

    func testFixedLayoutDetected() throws {
        let zip = EPUBFixture.basic { zip in
            zip.add("OEBPS/content.opf", EPUBFixture.opf(extraMeta: "<meta property=\"rendition:layout\">pre-paginated</meta>"))
        }
        XCTAssertTrue(try open(zip).isFixedLayout)
    }

    func testMalformedPackageStillYieldsWhatItCan() throws {
        let broken = EPUBFixture.opf().replacingOccurrences(of: "</package>", with: "<oops &bad; </package>")
        let zip = EPUBFixture.basic { $0.add("OEBPS/content.opf", broken) }
        let book = try open(zip)
        XCTAssertEqual(book.title, "Test Book")
        XCTAssertEqual(book.package?.spine.count, 1)
        XCTAssertFalse(book.warnings.isEmpty)
    }

    func testMissingContainerIsReported() throws {
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", store: true)
        zip.add("OEBPS/content.opf", EPUBFixture.opf())
        XCTAssertThrowsError(try open(zip)) { error in
            guard case .unreadable = error as? BookOpenError else { return XCTFail("\(error)") }
        }
    }

    // MARK: Path fix-ups

    func testCaseMismatchResolves() throws {
        // OPF says chapter1.xhtml but the zip holds Chapter1.xhtml.
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", store: true)
        zip.add("META-INF/container.xml", EPUBFixture.container)
        zip.add("OEBPS/content.opf", EPUBFixture.opf())
        zip.add("OEBPS/Chapter1.xhtml", EPUBFixture.chapter)
        let book = try open(zip)
        let resource = try book.resource(at: "OEBPS/chapter1.xhtml")
        XCTAssertTrue(String(decoding: resource.data, as: UTF8.self).contains("bright cold day"))
        XCTAssertEqual(resource.mimeType, "application/xhtml+xml")
    }

    func testPercentEncodedAndUnicodeNamesResolve() throws {
        let zip = EPUBFixture.basic { zip in
            zip.add("OEBPS/My Chapter.xhtml", EPUBFixture.chapter)
            // Stored decomposed (NFD), as macOS tools often write it.
            zip.add("OEBPS/Cafe\u{0301}.xhtml", EPUBFixture.chapter)
        }
        let book = try open(zip)
        XCTAssertNoThrow(try book.resource(at: "OEBPS/My%20Chapter.xhtml"))
        XCTAssertNoThrow(try book.resource(at: "OEBPS/Caf\u{00E9}.xhtml"))
        XCTAssertNoThrow(try book.resource(at: "OEBPS/Caf%C3%A9.xhtml"))
        XCTAssertNoThrow(try book.resource(at: "/OEBPS/./images/../chapter1.xhtml"))
        XCTAssertThrowsError(try book.resource(at: "OEBPS/nope.xhtml"))
    }

    func testPathJoin() {
        XCTAssertEqual(PathResolver.join(base: "OEBPS/Text", href: "../Images/a.png#x"), "OEBPS/Images/a.png")
        XCTAssertEqual(PathResolver.join(base: "", href: "a.xhtml"), "a.xhtml")
        XCTAssertEqual(PathResolver.join(base: "OEBPS", href: "/root.css"), "root.css")
    }

    // MARK: DRM

    private let adeptEncryption = """
    <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
      <enc:EncryptedData>
        <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
        <enc:CipherData><enc:CipherReference URI="OEBPS/chapter1.xhtml"/></enc:CipherData>
      </enc:EncryptedData>
    </encryption>
    """

    func testDetectsAdobeADEPT() {
        let zip = EPUBFixture.basic { zip in
            zip.add("META-INF/encryption.xml", self.adeptEncryption)
            zip.add("META-INF/rights.xml", "<adept:rights xmlns:adept=\"http://ns.adobe.com/adept\"/>")
        }
        XCTAssertThrowsError(try open(zip)) { XCTAssertEqual($0 as? BookOpenError, .drm(.adobeADEPT)) }
    }

    func testDetectsLCPAndFairPlay() {
        let lcp = EPUBFixture.basic { $0.add("META-INF/license.lcpl", "{}") }
        XCTAssertThrowsError(try open(lcp)) { XCTAssertEqual($0 as? BookOpenError, .drm(.readiumLCP)) }
        let fairplay = EPUBFixture.basic { $0.add("META-INF/sinf.xml", "<fairplay/>") }
        XCTAssertThrowsError(try open(fairplay)) { XCTAssertEqual($0 as? BookOpenError, .drm(.appleFairPlay)) }
    }

    func testUnknownEncryptionIsDRM() {
        let zip = EPUBFixture.basic { $0.add("META-INF/encryption.xml", self.adeptEncryption) }
        XCTAssertThrowsError(try open(zip)) { XCTAssertEqual($0 as? BookOpenError, .drm(.unknown)) }
    }

    func testDetectsKindleDRMInMOBI() throws {
        XCTAssertThrowsError(try Book.open(source: MemoryByteSource(data: Self.mobiHeader(encryption: 2)))) {
            XCTAssertEqual($0 as? BookOpenError, .drm(.kindle))
        }
        let ok = try Book.open(source: MemoryByteSource(data: Self.mobiHeader(encryption: 0)))
        XCTAssertEqual(ok.format, .mobi)
    }

    func testKFXIsRejectedClearly() {
        let kfx = Data("CONT".utf8) + Data(repeating: 0, count: 200)
        XCTAssertThrowsError(try Book.open(source: MemoryByteSource(data: kfx))) {
            XCTAssertEqual($0 as? BookOpenError, .kfx)
        }
    }

    func testPlainTextIsUnsupported() {
        let text = Data(String(repeating: "hello ", count: 100).utf8)
        XCTAssertThrowsError(try Book.open(source: MemoryByteSource(data: text))) {
            XCTAssertEqual($0 as? BookOpenError, .unsupportedFormat)
        }
    }

    /// A minimal Palm database with one record holding a PalmDOC header.
    static func mobiHeader(encryption: UInt16) -> Data {
        var d = Data(count: 78 + 8 + 2)
        d.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8))
        d[76] = 0; d[77] = 1 // one record
        let record0 = UInt32(d.count)
        d[78] = UInt8(record0 >> 24); d[79] = UInt8(record0 >> 16 & 0xFF)
        d[80] = UInt8(record0 >> 8 & 0xFF); d[81] = UInt8(record0 & 0xFF)
        var record = Data(count: 16)
        record[0] = 0; record[1] = 2 // compression
        record[12] = UInt8(encryption >> 8); record[13] = UInt8(encryption & 0xFF)
        d.append(record)
        d.append(Data("MOBI".utf8))
        return d
    }

    // MARK: Fonts

    func testIDPFFontDeobfuscation() throws {
        let font = Data((0..<3000).map { UInt8($0 % 251) })
        let uid = "urn:uuid:12345678-1234-1234-1234-1234567890ab"
        let key = FontDeobfuscator.idpfKey(uniqueIdentifier: " \(uid)\n")
        let obfuscated = FontDeobfuscator.apply(key: key, length: 1040, to: font)
        XCTAssertNotEqual(obfuscated, font)
        XCTAssertEqual(obfuscated.suffix(from: 1040), font.suffix(from: 1040))

        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/f.otf"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let zip = EPUBFixture.basic { zip in
            zip.add("META-INF/encryption.xml", encryption)
            zip.add("OEBPS/fonts/f.otf", obfuscated)
        }
        let book = try open(zip) // font obfuscation is not DRM
        XCTAssertEqual(try book.resource(at: "OEBPS/fonts/f.otf").data, font)
        // encryption.xml is hidden so foliate-js does not undo it twice.
        XCTAssertThrowsError(try book.resource(at: "META-INF/encryption.xml"))
    }

    func testAdobeFontDeobfuscation() throws {
        let font = Data((0..<2000).map { UInt8($0 % 13) })
        let key = try XCTUnwrap(FontDeobfuscator.adobeKey(uuidIdentifier: "urn:uuid:12345678-1234-1234-1234-1234567890ab"))
        XCTAssertEqual(key.count, 16)
        let obfuscated = FontDeobfuscator.apply(key: key, length: 1024, to: font)
        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://ns.adobe.com/pdf/enc#RC"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/f.ttf"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let zip = EPUBFixture.basic { zip in
            zip.add("META-INF/encryption.xml", encryption)
            zip.add("OEBPS/f.ttf", obfuscated)
        }
        XCTAssertEqual(try open(zip).resource(at: "OEBPS/f.ttf").data, font)
    }

    // MARK: Identity

    func testKeySurvivesRenameButNotContentChange() throws {
        let data = EPUBFixture.basic().build()
        let a = try Book.open(source: MemoryByteSource(data: data))
        let b = try Book.open(source: MemoryByteSource(data: data))
        XCTAssertEqual(a.key, b.key)
        let other = EPUBFixture.basic { $0.add("OEBPS/extra.txt", "x") }.build()
        XCTAssertNotEqual(a.key, try Book.open(source: MemoryByteSource(data: other)).key)
    }

    func testFingerprintSamplesLargeFiles() throws {
        var big = Data(repeating: 7, count: 300_000)
        let f1 = try BookIdentity.fingerprint(of: MemoryByteSource(data: big))
        big[150_000] = 8 // middle: not sampled, by design
        XCTAssertEqual(f1, try BookIdentity.fingerprint(of: MemoryByteSource(data: big)))
        big[299_999] = 9 // tail: sampled
        XCTAssertNotEqual(f1, try BookIdentity.fingerprint(of: MemoryByteSource(data: big)))
    }
}

final class RecoveryTests: XCTestCase {
    func testMissingPackageIsSynthesisedFromSurvivingChapters() throws {
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", store: true)
        zip.add("META-INF/container.xml", EPUBFixture.container)
        zip.add("OEBPS/a b.xhtml", EPUBFixture.chapter)
        zip.add("OEBPS/c2.xhtml", EPUBFixture.chapter)
        // No OEBPS/content.opf: it was lost.
        let book = try Book.open(source: MemoryByteSource(data: zip.build()))
        XCTAssertTrue(book.isRepaired)
        XCTAssertEqual(book.package?.spine, ["OEBPS/a%20b.xhtml", "OEBPS/c2.xhtml"])
        // The reader is pointed at the synthetic package, which resolves.
        let container = String(decoding: try book.resource(at: "META-INF/container.xml").data, as: UTF8.self)
        XCTAssertTrue(container.contains(SyntheticPackage.opfPath))
        XCTAssertNoThrow(try book.resource(at: SyntheticPackage.opfPath))
        XCTAssertNoThrow(try book.resource(at: "OEBPS/a%20b.xhtml"))
    }
}
