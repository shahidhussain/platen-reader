import Compression
import Foundation

/// A minimal zip writer for building test fixtures in code, including
/// deliberately broken ones. Not used by the app.
struct ZipWriter {
    struct Options {
        var deflate = true
        /// Bytes written before the archive (self-extractor style).
        var prefix = Data()
        /// Omit the central directory entirely (simulates truncation).
        var omitCentralDirectory = false
        /// Force Zip64 records even for small archives.
        var zip64 = false
        /// Write sizes in a trailing data descriptor (flag bit 3).
        var dataDescriptor = false
    }

    private var files: [(name: String, data: Data, store: Bool)] = []

    mutating func add(_ name: String, _ data: Data, store: Bool = false) {
        files.append((name, data, store))
    }

    mutating func add(_ name: String, _ text: String, store: Bool = false) {
        add(name, Data(text.utf8), store: store)
    }

    func build(_ options: Options = Options()) -> Data {
        var out = options.prefix
        let base = UInt64(options.prefix.count)
        var central = Data()
        var count: UInt64 = 0

        for file in files {
            let useDeflate = options.deflate && !file.store
            let payload = useDeflate ? Self.deflate(file.data) : file.data
            let method: UInt16 = useDeflate ? 8 : 0
            let crc = Self.crc32(file.data)
            let name = Data(file.name.utf8)
            let offset = UInt64(out.count) - base
            var flags: UInt16 = 0x800
            if options.dataDescriptor { flags |= 0x8 }

            // Local header
            out.u32(0x0403_4B50); out.u16(options.zip64 ? 45 : 20); out.u16(flags); out.u16(method)
            out.u16(0); out.u16(0)
            if options.dataDescriptor {
                out.u32(0); out.u32(0); out.u32(0)
            } else {
                out.u32(crc)
                out.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(payload.count))
                out.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(file.data.count))
            }
            let localExtra = options.zip64 && !options.dataDescriptor
                ? Self.zip64Extra(usize: UInt64(file.data.count), csize: UInt64(payload.count), offset: nil) : Data()
            out.u16(UInt16(name.count)); out.u16(UInt16(localExtra.count))
            out.append(name); out.append(localExtra)
            out.append(payload)
            if options.dataDescriptor {
                out.u32(0x0807_4B50); out.u32(crc); out.u32(UInt32(payload.count)); out.u32(UInt32(file.data.count))
            }

            // Central directory record
            let centralExtra = options.zip64
                ? Self.zip64Extra(usize: UInt64(file.data.count), csize: UInt64(payload.count), offset: offset) : Data()
            central.u32(0x0201_4B50); central.u16(options.zip64 ? 45 : 20); central.u16(options.zip64 ? 45 : 20)
            central.u16(flags); central.u16(method); central.u16(0); central.u16(0)
            central.u32(crc)
            central.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(payload.count))
            central.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(file.data.count))
            central.u16(UInt16(name.count)); central.u16(UInt16(centralExtra.count)); central.u16(0)
            central.u16(0); central.u16(0); central.u32(0)
            central.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(offset))
            central.append(name); central.append(centralExtra)
            count += 1
        }
        if options.omitCentralDirectory { return out }

        let cdOffset = UInt64(out.count) - base
        out.append(central)
        if options.zip64 {
            let zip64EndOffset = UInt64(out.count) - base
            out.u32(0x0606_4B50); out.u64(44); out.u16(45); out.u16(45); out.u32(0); out.u32(0)
            out.u64(count); out.u64(count); out.u64(UInt64(central.count)); out.u64(cdOffset)
            out.u32(0x0706_4B50); out.u32(0); out.u64(zip64EndOffset); out.u32(1)
        }
        out.u32(0x0605_4B50); out.u16(0); out.u16(0)
        out.u16(options.zip64 ? 0xFFFF : UInt16(count)); out.u16(options.zip64 ? 0xFFFF : UInt16(count))
        out.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(central.count))
        out.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(cdOffset))
        out.u16(0)
        return out
    }

    private static func zip64Extra(usize: UInt64, csize: UInt64, offset: UInt64?) -> Data {
        var d = Data()
        d.u16(0x0001); d.u16(offset == nil ? 16 : 24)
        d.u64(usize); d.u64(csize)
        if let offset { d.u64(offset) }
        return d
    }

    static func deflate(_ data: Data) -> Data {
        if data.isEmpty { return Data([0x03, 0x00]) } // empty final block
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(written)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

/// Builds small EPUBs for tests.
enum EPUBFixture {
    static let container = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    static func opf(identifier: String = "urn:uuid:12345678-1234-1234-1234-1234567890ab",
                    title: String = "Test Book",
                    chapterHref: String = "chapter1.xhtml",
                    extraMeta: String = "",
                    extraManifest: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">\(identifier)</dc:identifier>
            <dc:identifier>isbn:9780000000000</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:creator>Ada Author</dc:creator>
            <dc:language>en</dc:language>
            \(extraMeta)
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="\(chapterHref)" media-type="application/xhtml+xml"/>
            \(extraManifest)
          </manifest>
          <spine page-progression-direction="ltr"><itemref idref="c1"/></spine>
        </package>
        """
    }

    static let chapter = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>
    <body><h1>Chapter One</h1><p>It was a bright cold day in April.</p></body></html>
    """

    static func basic(_ configure: (inout ZipWriter) -> Void = { _ in }) -> ZipWriter {
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", store: true)
        zip.add("META-INF/container.xml", container)
        zip.add("OEBPS/content.opf", opf())
        zip.add("OEBPS/nav.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><nav/></body></html>")
        zip.add("OEBPS/chapter1.xhtml", chapter)
        configure(&zip)
        return zip
    }
}
