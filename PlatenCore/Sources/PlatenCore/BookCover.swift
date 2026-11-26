import CoreGraphics
import Foundation
import ImageIO

/// What the folder view shows for a book: its cover picture, made small, and
/// the title and authors to print on a plain cover when there is no picture.
public struct BookCoverInfo: Codable, Sendable, Equatable {
    public var title: String?
    public var authors: [String]

    public init(title: String? = nil, authors: [String] = []) {
        self.title = title
        self.authors = authors
    }
}

/// Finds a book's cover and makes a small JPEG of it, for the folder view's
/// grid. Platform-neutral (Core Graphics and ImageIO only), so both apps and
/// the tests share it.
///
/// - EPUB (and KEPUB): the picture the package marks as the cover, found the
///   way reading apps do (see `epubCoverPath`).
/// - PDF: the first page, drawn.
/// - MOBI, AZW, AZW3 and plain text: no picture yet (the title is shown
///   instead). MOBI covers come later.
///
/// Only what is needed is read: for an EPUB, the zip directory, the package
/// and the picture, never the whole book.
public enum BookCover {
    /// Bump when extraction improves, so covers cached by an older version
    /// (or books cached as having none) are looked at again.
    public static let version = 1

    public struct Result: Sendable {
        public var info: BookCoverInfo
        /// A JPEG no larger than the size asked for on its longest side.
        public var jpeg: Data?

        /// Also made by the apps, for a picture from elsewhere (iCloud's
        /// stored thumbnail of a book not yet downloaded).
        public init(info: BookCoverInfo, jpeg: Data? = nil) {
            self.info = info
            self.jpeg = jpeg
        }
    }

    /// Reads the cover of the book at `url`.
    ///
    /// - Parameters:
    ///   - maxPixelSize: the longest side of the picture made, in pixels.
    ///   - coordinated: read through `NSFileCoordinator`, as other apps and
    ///     file providers expect. Callers should not ask for books whose
    ///     contents are not on the device yet (iCloud), since coordinating
    ///     would download them.
    public static func extract(from url: URL, maxPixelSize: Int, coordinated: Bool = true) -> Result {
        guard coordinated else { return extractUncoordinated(url: url, maxPixelSize: maxPixelSize) }
        var result = Result(info: BookCoverInfo())
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { readURL in
            result = extractUncoordinated(url: readURL, maxPixelSize: maxPixelSize)
        }
        return result
    }

    /// Only a book's title and authors, without making its picture: for an
    /// EPUB the zip directory and the package, for a PDF its document
    /// information. Much quicker than `extract`, so a folder's search can
    /// know every book's title well before every cover is made.
    public static func info(from url: URL, coordinated: Bool = true) -> BookCoverInfo {
        extract(from: url, maxPixelSize: 0, coordinated: coordinated).info
    }

    private static func extractUncoordinated(url: URL, maxPixelSize: Int) -> Result {
        guard let source = try? FileByteSource(url: url) else { return Result(info: BookCoverInfo()) }
        if let head = try? source.read(offset: 0, length: 1024), PDFIdentity.looksLikePDF(head) {
            // Core Graphics reads the PDF itself, lazily, from the file.
            guard let provider = CGDataProvider(url: url as CFURL) else { return Result(info: BookCoverInfo()) }
            return pdf(provider: provider, maxPixelSize: maxPixelSize)
        }
        return extract(source: source, maxPixelSize: maxPixelSize)
    }

    /// Reads the cover of a book already open as bytes (EPUB; anything else
    /// gives no picture). PDFs go through `pdf(provider:maxPixelSize:)`.
    public static func extract(source: ByteSource, maxPixelSize: Int) -> Result {
        guard let archive = try? ZipArchive(source: source) else { return Result(info: BookCoverInfo()) }
        let resolver = PathResolver(paths: archive.entries.filter { !$0.isDirectory }.map(\.path))
        func read(_ path: String) -> Data? {
            guard let actual = resolver.resolve(path), let entry = archive.entry(at: actual) else { return nil }
            return try? archive.data(for: entry)
        }
        guard let container = read("META-INF/container.xml"),
              let opfPath = try? EPUBPackageParser.packagePath(fromContainer: container),
              let opf = read(opfPath) else { return Result(info: BookCoverInfo()) }
        let package = EPUBPackageParser.parsePackage(opf, path: resolver.resolve(opfPath) ?? opfPath)
        let info = BookCoverInfo(title: package.title, authors: package.creators)
        guard maxPixelSize > 0 else { return Result(info: info) } // the title only (`info(from:)`)
        let jpeg = epubCoverPath(package: package, read: read)
            .flatMap(read)
            .flatMap { thumbnail(imageData: $0, maxPixelSize: maxPixelSize) }
        return Result(info: info, jpeg: jpeg)
    }

    // MARK: - EPUB

    /// The path of an EPUB's cover picture, tried in the order reading apps
    /// use, from the most explicit to a good guess:
    /// 1. EPUB 3: the manifest item with `properties="cover-image"`.
    /// 2. EPUB 2: the item named by `<meta name="cover" content="…">` (if it
    ///    names a page rather than a picture, that page's first picture).
    /// 3. The guide's cover page (`<reference type="cover">`), its first
    ///    picture.
    /// 4. A manifest picture with "cover" in its id or file name.
    /// 5. The first page of the book, if it is little more than a picture.
    static func epubCoverPath(package: EPUBPackage, read: (String) -> Data?) -> String? {
        let images = package.manifest.filter { $0.mediaType.lowercased().hasPrefix("image/") }

        if let item = images.first(where: { $0.properties.contains("cover-image") }) {
            return item.path
        }
        if let id = package.coverItemID, let item = package.manifest.first(where: { $0.id == id }) {
            if item.mediaType.lowercased().hasPrefix("image/") { return item.path }
            if let page = read(item.path), let src = firstImage(inPage: page, at: item.path) { return src }
        }
        if let path = package.guideCoverPath {
            if images.contains(where: { $0.path == path }) { return path }
            if let page = read(path), let src = firstImage(inPage: page, at: path) { return src }
        }
        if let item = images.first(where: {
            $0.id.lowercased().contains("cover")
                || ($0.path as NSString).lastPathComponent.lowercased().contains("cover")
        }) {
            return item.path
        }
        if let first = package.spine.first, let page = read(first),
           visibleTextLength(page) < 300, let src = firstImage(inPage: page, at: first) {
            return src
        }
        return nil
    }

    /// The first picture in an XHTML page (`<img src>`, or SVG's
    /// `<image href>` / `xlink:href`, common on cover pages), resolved
    /// against the page's folder. A regular expression rather than an XML
    /// parser, because cover pages are often not well-formed.
    static func firstImage(inPage page: Data, at pagePath: String) -> String? {
        guard let text = String(data: page, encoding: .utf8) ?? String(data: page, encoding: .isoLatin1) else { return nil }
        let pattern = #"<(?:img\b[^>]*?\bsrc|image\b[^>]*?\b(?:xlink:)?href)\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let href = String(text[range]).removingPercentEncoding ?? String(text[range])
        return PathResolver.join(base: (pagePath as NSString).deletingLastPathComponent, href: href)
    }

    /// Roughly how much text a page shows: its body with the tags taken out.
    static func visibleTextLength(_ page: Data) -> Int {
        guard var text = String(data: page, encoding: .utf8) else { return .max }
        if let body = text.range(of: "<body", options: .caseInsensitive) { text = String(text[body.lowerBound...]) }
        let stripped = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        return stripped.filter { !$0.isWhitespace }.count
    }

    // MARK: - PDF

    /// The first page of a PDF, drawn on white, and the title from its
    /// document information (if it has one).
    public static func pdf(provider: CGDataProvider, maxPixelSize: Int) -> Result {
        guard let document = CGPDFDocument(provider), !document.isEncrypted || document.isUnlocked,
              let page = document.page(at: 1) else { return Result(info: BookCoverInfo()) }
        var info = BookCoverInfo()
        if let dictionary = document.info {
            var string: CGPDFStringRef?
            if CGPDFDictionaryGetString(dictionary, "Title", &string), let string,
               let title = CGPDFStringCopyTextString(string) as String?,
               !title.trimmingCharacters(in: .whitespaces).isEmpty {
                info.title = title
            }
        }

        guard maxPixelSize > 0 else { return Result(info: info) } // the title only (`info(from:)`)

        // The page's visible area, turned as the PDF says it should be shown.
        let box = page.getBoxRect(.cropBox)
        let turned = page.rotationAngle % 180 != 0
        let pageSize = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard pageSize.width > 0, pageSize.height > 0 else { return Result(info: info) }
        let scale = CGFloat(maxPixelSize) / max(pageSize.width, pageSize.height)
        let width = max(1, Int((pageSize.width * scale).rounded()))
        let height = max(1, Int((pageSize.height * scale).rounded()))
        let jpeg = draw(width: width, height: height) { context in
            context.scaleBy(x: scale, y: scale)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSize),
                                                         rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
        }
        return Result(info: info, jpeg: jpeg)
    }

    // MARK: - Pictures

    /// A JPEG of a picture made no larger than `maxPixelSize` on its longest
    /// side. ImageIO decodes only what that size needs. Transparent parts
    /// (common in PNG covers) come out white rather than black.
    static func thumbnail(imageData: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return draw(width: image.width, height: image.height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    /// Draws on a white sRGB canvas and encodes the result as a JPEG.
    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        body(context)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
