import Foundation

/// What a problem report says about a book (spec, "Failure handling"): what
/// kind of file it is, its size, its EPUB version and the program that made
/// it. Read from the file afresh, so it works for a book that could not be
/// opened; anything that cannot be read is left out. Never the title, the
/// author or the file's name: the report is sent by the reader, and they may
/// not want those in it.
public struct BookFacts: Sendable, Equatable {
    /// "EPUB", "MOBI", "Kindle KFX", "plain text", "zip without an EPUB
    /// package", "unrecognised"…
    public var kind: String
    public var size: UInt64
    public var epubVersion: String?
    public var generator: String?
    /// The zip's entry count, for EPUBs.
    public var entries: Int?
    /// What the zip reader found wrong (a cut-short download and the like).
    public var problems: [String] = []

    public init(kind: String, size: UInt64, epubVersion: String? = nil, generator: String? = nil,
                entries: Int? = nil, problems: [String] = []) {
        self.kind = kind
        self.size = size
        self.epubVersion = epubVersion
        self.generator = generator
        self.entries = entries
        self.problems = problems
    }

    /// The facts as lines for the report ("Kind: EPUB", "EPUB version: 3.0"…).
    public var lines: [String] {
        var lines = ["Kind: \(kind)", "Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size) bytes)"]
        if let epubVersion { lines.append("EPUB version: \(epubVersion)") }
        if let generator { lines.append("Made with: \(generator)") }
        if let entries { lines.append("Files in the zip: \(entries)") }
        for problem in problems.prefix(10) { lines.append("Zip problem: \(problem)") }
        return lines
    }

    /// Reads the facts of the file at `url` (coordinated, as other apps and
    /// file providers expect).
    public static func read(url: URL) -> BookFacts {
        var facts = BookFacts(kind: "unreadable", size: 0)
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { readURL in
            if let source = try? FileByteSource(url: readURL) { facts = read(source: source) }
        }
        return facts
    }

    /// Reads the facts from bytes (the tests use this).
    public static func read(source: ByteSource) -> BookFacts {
        var facts = BookFacts(kind: "unrecognised", size: source.size)
        guard let head = try? source.read(offset: 0, length: 4096) else { return facts }
        if head.starts(with: Array("%PDF-".utf8)) {
            // "%PDF-1.7" → "PDF 1.7".
            let version = head.dropFirst(5).prefix(8).prefix { (0x30...0x39).contains($0) || $0 == 0x2E }
            facts.kind = "PDF " + (String(data: Data(version), encoding: .ascii) ?? "")
            return facts
        }
        // As Book.open tells KFX: "CONT" then a two-byte version (so a zero
        // byte; a text starting "CONTENTS" is not KFX), or the DRMION wrapper.
        let kfxContainer = head.starts(with: Array("CONT".utf8)) && head.count > 5 && head[head.startIndex + 5] == 0
        if kfxContainer || head.starts(with: [0xEA] + Array("DRMION".utf8)) {
            facts.kind = "Kindle KFX"
            return facts
        }
        if head.count >= 68, let type = String(data: head.subdata(in: 60..<68), encoding: .ascii), type == "BOOKMOBI" {
            facts.kind = "MOBI"
            return facts
        }
        guard let archive = try? ZipArchive(source: source) else {
            if TextBook.looksLikeText(head) { facts.kind = "plain text" }
            return facts
        }
        facts.entries = archive.entries.count
        facts.problems = archive.problems
        let paths = archive.entries.filter { !$0.isDirectory }.map(\.path)
        let resolver = PathResolver(paths: paths)
        func data(_ path: String) -> Data? {
            guard let actual = resolver.resolve(path), let entry = archive.entry(at: actual) else { return nil }
            return try? archive.data(for: entry, allowPartial: true)
        }
        guard let container = data("META-INF/container.xml"),
              let opfPath = try? EPUBPackageParser.packagePath(fromContainer: container),
              let opf = data(opfPath) else {
            facts.kind = paths.contains { $0.lowercased().hasSuffix(".kfx") } ? "Kindle KFX (zip)" : "zip without an EPUB package"
            return facts
        }
        let package = EPUBPackageParser.parsePackage(opf, path: opfPath)
        facts.kind = "EPUB"
        facts.epubVersion = package.version
        facts.generator = package.generator
        return facts
    }
}
