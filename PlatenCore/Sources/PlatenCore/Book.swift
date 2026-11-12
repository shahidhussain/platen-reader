import CryptoKit
import Foundation

/// The book formats Platen recognises by content (not by file extension,
/// which is often wrong).
public enum BookFormat: String, Sendable, Codable {
    /// EPUB 2/3 and KEPUB (a Kobo-flavoured EPUB).
    case epub
    /// MOBI, AZW and AZW3 (KF8); foliate-js reads all three.
    case mobi
    /// Plain text, shown as a made-up EPUB (see `TextBook`).
    case text
}

/// Why a book could not be opened, phrased for the person reading it.
public enum BookOpenError: Error, LocalizedError, Equatable {
    case drm(DRMScheme)
    case kfx
    case unsupportedFormat
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .drm(scheme):
            return String(localized: "This book is protected by \(scheme.displayName).", bundle: .module)
        case .kfx:
            return String(localized: "This is a Kindle KFX book, which Platen cannot open.", bundle: .module)
        case .unsupportedFormat:
            return String(localized: "Platen does not recognise this file as an ebook.", bundle: .module)
        case .unreadable:
            return String(localized: "This book is damaged and could not be opened.", bundle: .module)
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .drm:
            return String(localized: "Platen opens DRM-free books only. Open it in the app or store it was bought from.", bundle: .module)
        case .kfx:
            return String(localized: "KFX is a proprietary Amazon format. If you have the book in EPUB, AZW3 or MOBI, open that instead.", bundle: .module)
        case .unsupportedFormat:
            return String(localized: "Platen reads EPUB, KEPUB, MOBI, AZW, AZW3 and plain text files.", bundle: .module)
        case let .unreadable(detail):
            return detail
        }
    }
}

/// A book that has been read and checked, ready to be served to the renderer.
///
/// Creating one does the minimum needed to show the first page: read the
/// bytes, read the zip directory and the package document, and check for DRM.
/// Everything else (table of contents, search, length) happens later, in the
/// web view, after the first page is visible.
public final class Book: @unchecked Sendable {
    /// Books at or below this size are read into memory in one go.
    public static let inMemoryLimit: UInt64 = 50 * 1024 * 1024

    public let format: BookFormat
    public let source: ByteSource
    /// The zip archive, for EPUBs.
    public let archive: ZipArchive?
    /// The parsed package, for EPUBs.
    public let package: EPUBPackage?
    /// Size plus a hash of the first and last 64 KB (see `BookIdentity`).
    public let fingerprint: String
    /// Stable key for this book's saved data.
    public let key: String
    /// Non-fatal problems, for diagnostics.
    public let warnings: [String]

    let resolver: PathResolver?
    /// Font paths needing de-obfuscation, mapped to their algorithm.
    let obfuscatedFonts: [String: String]
    /// Files Platen made up to repair a damaged book (served before the zip).
    let syntheticFiles: [String: Data]
    /// True if the package document had to be rebuilt from surviving files.
    public var isRepaired: Bool { !syntheticFiles.isEmpty }

    public var title: String? { package?.title }
    public var authors: [String] { package?.creators ?? [] }
    public var isFixedLayout: Bool { package?.isFixedLayout ?? false }

    /// Entry paths and their uncompressed sizes, which foliate-js uses to
    /// estimate how long each section is.
    public var entrySizes: [String: UInt64] {
        var sizes: [String: UInt64] = [:]
        for entry in archive?.entries ?? [] where !entry.isDirectory {
            sizes[entry.path] = entry.uncompressedSize
        }
        for (path, data) in syntheticFiles { sizes[path] = UInt64(data.count) }
        return sizes
    }

    // MARK: Opening

    /// Opens a book file.
    ///
    /// - Parameters:
    ///   - url: Location on disk, iCloud Drive or a network share.
    ///   - coordinated: Wrap the read in `NSFileCoordinator`, so iCloud
    ///     downloads offloaded files and other apps' writes are respected.
    ///     Pass false when the caller (e.g. `NSDocument`) already coordinates.
    public static func open(url: URL, coordinated: Bool = true) throws -> Book {
        if coordinated {
            var coordinationError: NSError?
            var result: Result<Book, Error> = .failure(BookOpenError.unsupportedFormat)
            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: url, options: [.withoutChanges], error: &coordinationError
            ) { readURL in
                result = Result { try openUncoordinated(url: readURL) }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }
        return try openUncoordinated(url: url)
    }

    private static func openUncoordinated(url: URL) throws -> Book {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let source: ByteSource
        if size <= inMemoryLimit {
            // One sequential read; never touch the file again. Explicitly not
            // memory-mapped: a mapping over SMB would fault later and could
            // fail if the share goes away.
            source = MemoryByteSource(data: try Data(contentsOf: url, options: []))
        } else {
            source = try FileByteSource(url: url)
        }
        return try open(source: source, fileName: url.lastPathComponent)
    }

    /// Plain-text files are converted whole, so they have their own limit.
    public static let textLimit: UInt64 = 64 * 1024 * 1024

    /// Opens a book from bytes already available. Used by tests and by
    /// `open(url:)`.
    /// - Parameter fileName: used as the title of a plain-text file that
    ///   names none itself.
    public static func open(source: ByteSource, fileName: String? = nil) throws -> Book {
        let head = try source.read(offset: 0, length: 4096)
        let fingerprint = try BookIdentity.fingerprint(of: source)

        // KFX: either a bare container or the "DRMION" wrapper. A container
        // starts "CONT" then a two-byte version (1 or 2, so a zero byte); the
        // version check stops a text file starting "CONTENTS" matching.
        let kfxContainer = head.starts(with: Array("CONT".utf8)) && head.count > 5 && head[head.startIndex + 5] == 0
        if kfxContainer || head.starts(with: [0xEA] + Array("DRMION".utf8)) {
            throw BookOpenError.kfx
        }

        // Palm database type/creator at 60: BOOKMOBI for MOBI/AZW/AZW3.
        if head.count >= 68, String(data: head.subdata(in: 60..<68), encoding: .ascii) == "BOOKMOBI" {
            if let drm = DRMDetector.detectMOBI(header: head) { throw BookOpenError.drm(drm) }
            return Book(format: .mobi, source: source, archive: nil, package: nil,
                        fingerprint: fingerprint, key: BookIdentity.key(uniqueIdentifier: nil, fingerprint: fingerprint),
                        warnings: [], resolver: nil, obfuscatedFonts: [:], syntheticFiles: [:])
        }

        let archive: ZipArchive
        do {
            archive = try ZipArchive(source: source)
        } catch ZipError.notAZip {
            // Not a zip: plain text, if it looks like text.
            guard TextBook.looksLikeText(head), source.size <= textLimit else {
                throw BookOpenError.unsupportedFormat
            }
            return try openText(source: source, fingerprint: fingerprint, fileName: fileName)
        } catch {
            throw BookOpenError.unreadable(error.localizedDescription)
        }
        return try openEPUB(archive: archive, fingerprint: fingerprint)
    }

    private static func openText(source: ByteSource, fingerprint: String, fileName: String?) throws -> Book {
        let data = try source.read(offset: 0, length: Int(source.size))
        let text = TextBook.make(data: data, fileName: fileName)
        let package = EPUBPackageParser.parsePackage(text.files[TextBook.opfPath] ?? Data(), path: TextBook.opfPath)
        return Book(format: .text, source: source, archive: nil, package: package,
                    fingerprint: fingerprint, key: BookIdentity.key(uniqueIdentifier: nil, fingerprint: fingerprint),
                    warnings: package.warnings, resolver: nil, obfuscatedFonts: [:], syntheticFiles: text.files)
    }

    private static func openEPUB(archive: ZipArchive, fingerprint: String) throws -> Book {
        let paths = archive.entries.filter { !$0.isDirectory }.map(\.path)
        let resolver = PathResolver(paths: paths)
        var warnings = archive.problems

        func read(_ path: String) -> Data? {
            guard let actual = resolver.resolve(path), let entry = archive.entry(at: actual) else { return nil }
            return try? archive.data(for: entry, allowPartial: true)
        }

        // A zip containing a .kfx file is a KFX-ZIP, not an EPUB.
        if paths.contains(where: { $0.lowercased().hasSuffix(".kfx") }),
           read("META-INF/container.xml") == nil {
            throw BookOpenError.kfx
        }

        // DRM first: an encrypted book would otherwise render as noise.
        let encryption = read("META-INF/encryption.xml").map(DRMDetector.encryptedResources) ?? []
        if let drm = DRMDetector.detectEPUB(entryPaths: Set(paths), encryption: encryption) {
            throw BookOpenError.drm(drm)
        }

        // Normal path: container.xml → package document. If either is
        // missing (typically a truncated download, where the package file
        // was near the end of the zip), synthesise a package from whatever
        // chapters survive, so the reader still gets what can be read.
        var synthetic: [String: Data] = [:]
        let package: EPUBPackage
        if let container = read("META-INF/container.xml"),
           let opfPath = try? EPUBPackageParser.packagePath(fromContainer: container),
           let opfData = read(opfPath) {
            package = EPUBPackageParser.parsePackage(opfData, path: resolver.resolve(opfPath) ?? opfPath)
        } else {
            guard let opfData = SyntheticPackage.make(entries: archive.entries, bookName: nil) else {
                throw BookOpenError.unreadable(EPUBParseError.missingContainer.localizedDescription)
            }
            warnings.append("Package document missing or unreadable; built one from \(archive.entries.count) surviving entries.")
            synthetic["META-INF/container.xml"] = SyntheticPackage.container
            synthetic[SyntheticPackage.opfPath] = opfData
            package = EPUBPackageParser.parsePackage(opfData, path: SyntheticPackage.opfPath)
        }
        warnings += package.warnings

        var fonts: [String: String] = [:]
        for resource in encryption where resource.isFontObfuscation {
            if let actual = resolver.resolve(resource.path) { fonts[actual] = resource.algorithm }
        }

        return Book(
            format: .epub, source: archive.source, archive: archive, package: package,
            fingerprint: fingerprint,
            key: BookIdentity.key(uniqueIdentifier: package.uniqueIdentifier, fingerprint: fingerprint),
            warnings: warnings, resolver: resolver, obfuscatedFonts: fonts, syntheticFiles: synthetic
        )
    }

    private init(format: BookFormat, source: ByteSource, archive: ZipArchive?, package: EPUBPackage?,
                 fingerprint: String, key: String, warnings: [String],
                 resolver: PathResolver?, obfuscatedFonts: [String: String], syntheticFiles: [String: Data]) {
        self.syntheticFiles = syntheticFiles
        self.format = format
        self.source = source
        self.archive = archive
        self.package = package
        self.fingerprint = fingerprint
        self.key = key
        self.warnings = warnings
        self.resolver = resolver
        self.obfuscatedFonts = obfuscatedFonts
    }
}

/// How Platen recognises the same book again after it is renamed or moved.
public enum BookIdentity {
    static let sampleLength = 64 * 1024

    /// File size plus a SHA-256 of the first and last 64 KB. Cheap even over
    /// a network share, because it never reads the whole file.
    public static func fingerprint(of source: ByteSource) throws -> String {
        var hasher = SHA256()
        let size = source.size
        hasher.update(data: try source.read(offset: 0, length: sampleLength))
        if size > UInt64(sampleLength) {
            let tailStart = size > UInt64(2 * sampleLength) ? size - UInt64(sampleLength) : UInt64(sampleLength)
            hasher.update(data: try source.read(offset: tailStart, length: sampleLength))
        }
        let digest = hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(size)-\(digest)"
    }

    /// The file-name-safe key used for the per-book JSON file. Combines the
    /// OPF unique identifier (stable across editions of the same file) with
    /// the fingerprint (distinguishes different files that share a careless
    /// identifier, which is common).
    public static func key(uniqueIdentifier: String?, fingerprint: String) -> String {
        let input = "\(uniqueIdentifier ?? "")|\(fingerprint)"
        return SHA256.hash(data: Data(input.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Builds a stand-in package document for books whose own is missing.
enum SyntheticPackage {
    static let opfPath = "platen-recovered.opf"
    static let container = Data("""
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """.utf8)

    /// Every file goes in the manifest (so styles and images still resolve);
    /// HTML files form the spine, in archive order, which is almost always
    /// reading order.
    static func make(entries: [ZipEntry], bookName: String?) -> Data? {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
        }
        func href(_ path: String) -> String {
            path.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0)
            }.joined(separator: "/")
        }
        let files = entries.filter { !$0.isDirectory && $0.path != "mimetype" && !$0.path.hasPrefix("META-INF/") }
        let documents = files.filter { ["xhtml", "html", "htm", "xht"].contains(($0.path as NSString).pathExtension.lowercased()) }
        guard !documents.isEmpty else { return nil }
        var manifest = ""
        var spine = ""
        for (i, entry) in files.enumerated() {
            manifest += "<item id=\"i\(i)\" href=\"\(escape(href(entry.path)))\" media-type=\"\(escape(MIMEType.forPath(entry.path)))\"/>\n"
            if documents.contains(entry) { spine += "<itemref idref=\"i\(i)\"/>\n" }
        }
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">platen-recovered</dc:identifier>
            <dc:title>\(escape(bookName ?? ""))</dc:title>
          </metadata>
          <manifest>\(manifest)</manifest>
          <spine>\(spine)</spine>
        </package>
        """.utf8)
    }
}
