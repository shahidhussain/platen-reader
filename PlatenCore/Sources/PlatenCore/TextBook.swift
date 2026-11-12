import Foundation

/// Turns a plain-text file into a small EPUB, held in memory, so the reader
/// shows it exactly like any other book (pages, contents, search, settings).
///
/// Plain text has no publisher design, so the made-up book supplies sensible
/// defaults: a book serif and comfortable line spacing. The reader's own
/// Font and Line Spacing settings override them as usual.
///
/// What it works out from the text:
/// - **Encoding:** UTF-8 or UTF-16 (with a byte-order mark), falling back to
///   Windows-1252 for old files that are not valid UTF-8.
/// - **Paragraphs:** blank lines separate paragraphs. Many text books (Project
///   Gutenberg's especially) also break every line at about 70 characters;
///   those lines are joined back into flowing paragraphs. Blocks that do not
///   look like that (poetry, lists, indented or tabular text) keep their line
///   breaks.
/// - **Chapters:** headings such as "CHAPTER I", "Chapter 12", "BOOK II" or
///   "PART ONE" start a new section and appear in Contents.
/// - **Title and author:** from "Title:" and "Author:" lines near the top (as
///   in Gutenberg files), otherwise from the file name.
enum TextBook {
    /// The files of the made-up EPUB, by path.
    struct Output {
        var files: [String: Data]
        var title: String
    }

    static let opfPath = "platen-text.opf"

    /// Sections longer than this are split (at a paragraph) so a huge text
    /// with no headings still opens quickly: the reader lays out one section
    /// at a time.
    static let sectionLimit = 120_000

    // MARK: Recognising text

    /// True if the start of a file looks like text rather than binary data:
    /// a byte-order mark, or no NUL bytes and few control characters.
    static func looksLikeText(_ head: Data) -> Bool {
        if head.starts(with: [0xEF, 0xBB, 0xBF]) || head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) {
            return true
        }
        guard !head.isEmpty else { return false }
        var control = 0
        for byte in head {
            if byte == 0 { return false }
            // Tab, line feed, form feed and carriage return are normal in text.
            if byte < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D].contains(byte) { control += 1 }
        }
        return control * 100 < head.count // under 1%
    }

    // MARK: Decoding

    static func decode(_ data: Data) -> String {
        var text: String
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(decoding: data.dropFirst(3), as: UTF8.self)
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16) ?? String(decoding: data, as: UTF8.self)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            // Not valid UTF-8: almost certainly an older Western file.
            text = String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        }
        // One kind of line ending, and form feeds treated as blank lines.
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0C}", with: "\n\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    // MARK: Blocks and paragraphs

    /// A run of lines between blank lines.
    struct Block {
        var lines: [String]
        var characterCount: Int { lines.reduce(0) { $0 + $1.count } }
    }

    static func blocks(in text: String) -> [Block] {
        var result: [Block] = []
        var current: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Trailing spaces only; leading spaces matter (indented poetry).
            var line = String(rawLine)
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            if line.isEmpty {
                if !current.isEmpty { result.append(Block(lines: current)); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(Block(lines: current)) }
        return result
    }

    /// The width the file was hard-wrapped at, if it was: the length most
    /// long lines stop at. Nil if lines run on (one paragraph per line).
    static func wrapWidth(of blocks: [Block]) -> Int? {
        // Only lines that are followed by another line in the same block
        // show where wrapping happened.
        let wrapped = blocks.flatMap { $0.lines.dropLast() }.map(\.count).sorted()
        guard wrapped.count >= 10 else { return nil }
        let p90 = wrapped[wrapped.count * 9 / 10]
        let median = wrapped[wrapped.count / 2]
        // Hard-wrapped prose: lines stop by about 80 characters, and most of
        // them come close to that width.
        guard p90 <= 100, median * 10 >= p90 * 6 else { return nil }
        return p90
    }

    enum Kind { case prose, lines }

    /// How one block should be shown.
    static func kind(of block: Block, wrapWidth: Int?) -> Kind {
        let lines = block.lines
        if lines.count == 1 { return .prose }
        // Mostly indented lines: poetry, quoted verse, code or a table.
        let indented = lines.filter { $0.first == " " || $0.first == "\t" }.count
        if indented * 2 > lines.count { return .lines }
        guard let width = wrapWidth else {
            // Not a hard-wrapped file: each line is meant as it is.
            return .lines
        }
        // A hard-wrapped paragraph fills its lines (bar the last) to near
        // the wrap width; short ragged lines are verse or a list.
        let full = lines.dropLast().filter { $0.count * 10 >= width * 6 }.count
        return full * 10 >= (lines.count - 1) * 7 ? .prose : .lines
    }

    // MARK: Chapter headings

    static let headingPattern = try! NSRegularExpression(pattern: """
        ^\\s*(CHAPTER|Chapter|BOOK|Book|PART|Part|VOLUME|Volume|ACT|Act|SECTION|Section|\
        PROLOGUE|Prologue|EPILOGUE|Epilogue|PREFACE|Preface|INTRODUCTION|Introduction|\
        FOREWORD|Foreword|AFTERWORD|Afterword|APPENDIX|Appendix)\\b(.*)$
        """)

    static let numberWords = ["ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "TEN",
                              "ELEVEN", "TWELVE", "THIRTEEN", "FOURTEEN", "FIFTEEN", "SIXTEEN", "SEVENTEEN",
                              "EIGHTEEN", "NINETEEN", "TWENTY", "THIRTY", "FORTY", "FIFTY", "FIRST", "SECOND",
                              "THIRD", "FOURTH", "FIFTH", "SIXTH", "SEVENTH", "EIGHTH", "NINTH", "TENTH", "LAST"]

    /// The heading's text if this block is a chapter heading: one to three
    /// short lines, the first starting with a word like "Chapter" followed by
    /// a number (or nothing, for "Prologue" and the like).
    static func heading(_ block: Block) -> String? {
        guard block.lines.count <= 3, block.lines.allSatisfy({ $0.count <= 70 }) else { return nil }
        let first = block.lines[0]
        let range = NSRange(first.startIndex..., in: first)
        guard let match = headingPattern.firstMatch(in: first, range: range),
              let wordRange = Range(match.range(at: 1), in: first),
              let restRange = Range(match.range(at: 2), in: first) else { return nil }
        let word = first[wordRange].uppercased()
        let rest = first[restRange].trimmingCharacters(in: .whitespaces)
        let standalone = ["PROLOGUE", "EPILOGUE", "PREFACE", "INTRODUCTION", "FOREWORD", "AFTERWORD"]
        if !standalone.contains(word) {
            // "Chapter" must be followed by a number: arabic, roman or a word.
            let token = rest.split(whereSeparator: { " .:-—–".contains($0) }).first.map(String.init)?.uppercased() ?? ""
            let isNumber = !token.isEmpty && (token.allSatisfy(\.isNumber)
                || token.allSatisfy({ "IVXLCDM".contains($0) })
                || numberWords.contains(token)
                || (token.count == 1 && token.first!.isLetter)) // "Appendix A"
            guard isNumber else { return nil }
        } else if rest.count > 50 {
            return nil
        }
        // A sentence that merely starts with "Book" is not a heading.
        if block.lines.count == 1, first.hasSuffix(","), first.count > 30 { return nil }
        return block.lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    // MARK: Metadata

    /// "Title:", "Author:" and "Language:" lines near the top, as in
    /// Project Gutenberg files.
    static func headerFields(in text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.prefix(20_000).split(separator: "\n").prefix(200) {
            for key in ["Title", "Author", "Language"] where fields[key] == nil {
                let prefix = key + ":"
                if line.hasPrefix(prefix) {
                    let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { fields[key] = value }
                }
            }
            if line.hasPrefix("*** START OF") { break }
        }
        return fields
    }

    static let languageCodes = ["english": "en", "french": "fr", "german": "de", "spanish": "es", "italian": "it",
                                "portuguese": "pt", "dutch": "nl", "swedish": "sv", "danish": "da",
                                "norwegian": "no", "finnish": "fi", "polish": "pl", "russian": "ru",
                                "latin": "la", "greek": "el", "chinese": "zh", "japanese": "ja"]

    // MARK: Building the book

    static func make(data: Data, fileName: String?) -> Output {
        let text = decode(data)
        let fields = headerFields(in: text)
        let fallbackTitle = fileName.map { ($0 as NSString).deletingPathExtension } ?? ""
        let title = fields["Title"] ?? fallbackTitle
        let author = fields["Author"]
        let language = fields["Language"].flatMap { languageCodes[$0.lowercased()] }

        let allBlocks = blocks(in: text)
        let width = wrapWidth(of: allBlocks)

        // Find headings, ignoring any with almost nothing after them before
        // the next (a contents list laid out one entry per paragraph).
        var headingAt: [Int: String] = [:]
        var candidates: [(Int, String)] = []
        for (i, block) in allBlocks.enumerated() {
            if let h = heading(block) { candidates.append((i, h)) }
        }
        for (n, (index, label)) in candidates.enumerated() {
            let end = n + 1 < candidates.count ? candidates[n + 1].0 : allBlocks.count
            let body = allBlocks[(index + 1)..<end].reduce(0) { $0 + $1.characterCount }
            if body >= 200 { headingAt[index] = label }
        }
        if headingAt.count < 2 { headingAt = [:] } // one "heading" is more likely a coincidence

        // Sections: a new one at every heading, and when one grows too long.
        struct Section { var html = ""; var length = 0; var heading: String? }
        var sections: [Section] = [Section()]
        var afterHeading = true
        for (i, block) in allBlocks.enumerated() {
            if let label = headingAt[i] {
                if sections[sections.count - 1].length > 0 { sections.append(Section()) }
                sections[sections.count - 1].heading = label
                let id = "h\(sections.count)"
                let lines = block.lines.map { escape($0.trimmingCharacters(in: .whitespaces)) }
                sections[sections.count - 1].html += "<h2 id=\"\(id)\">\(lines.joined(separator: "<br/>"))</h2>\n"
                sections[sections.count - 1].length += label.count
                afterHeading = true
                continue
            }
            if sections[sections.count - 1].length > sectionLimit { sections.append(Section()) }
            let html: String
            switch kind(of: block, wrapWidth: width) {
            case .prose:
                let joined = block.lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                html = "<p\(afterHeading ? " class=\"first\"" : "")>\(escape(joined))</p>"
            case .lines:
                html = "<p class=\"lines\">\(escape(block.lines.joined(separator: "\n")))</p>"
            }
            afterHeading = false
            sections[sections.count - 1].html += html + "\n"
            sections[sections.count - 1].length += block.characterCount
        }
        if sections.count > 1, sections[0].length == 0 { sections.removeFirst() }

        // The files.
        var files: [String: Data] = [:]
        let lang = language.map { " xml:lang=\"\($0)\" lang=\"\($0)\"" } ?? ""
        var manifest = "<item id=\"css\" href=\"text/style.css\" media-type=\"text/css\"/>\n"
        manifest += "<item id=\"nav\" href=\"text/nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        var spine = ""
        var toc = ""
        for (n, section) in sections.enumerated() {
            let name = "text/section-\(n + 1).xhtml"
            files[name] = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"\(lang)>
            <head><title>\(escape(section.heading ?? title))</title><link rel="stylesheet" href="style.css"/></head>
            <body>
            \(section.html)</body>
            </html>
            """.utf8)
            manifest += "<item id=\"s\(n + 1)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"s\(n + 1)\"/>\n"
            if let heading = section.heading {
                toc += "<li><a href=\"section-\(n + 1).xhtml\">\(escape(heading))</a></li>\n"
            }
        }
        files["text/style.css"] = Data(stylesheet.utf8)
        files["text/nav.xhtml"] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(escape(title))</title></head>
        <body><nav epub:type="toc"><ol>
        \(toc)</ol></nav></body>
        </html>
        """.utf8)
        files["META-INF/container.xml"] = Data("""
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8)
        files[opfPath] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">platen-text</dc:identifier>
            <dc:title>\(escape(title))</dc:title>
            \(author.map { "<dc:creator>\(escape($0))</dc:creator>" } ?? "")
            \(language.map { "<dc:language>\($0)</dc:language>" } ?? "")
          </metadata>
          <manifest>\(manifest)</manifest>
          <spine>\(spine)</spine>
        </package>
        """.utf8)
        return Output(files: files, title: title)
    }

    /// The made-up book's design: what "Publisher Default" means for plain
    /// text. A book serif (Iowan Old Style, as in Apple Books, on Mac and
    /// iOS alike) and line spacing of 1.5; no font size, so the reader's
    /// Text Size applies unchanged.
    static let stylesheet = """
    body { font-family: "Iowan Old Style", "Palatino", "Georgia", serif; line-height: 1.5; }
    p { margin: 0; text-indent: 1.5em; }
    p.first { text-indent: 0; }
    /* Blocks whose line breaks matter (poetry, lists, tables) keep them,
       and their indentation. */
    p.lines { text-indent: 0; white-space: pre-wrap; margin: 0.8em 0; }
    h2 { font-size: 1.3em; font-weight: normal; text-align: center; margin: 2.5em 0 1.5em; line-height: 1.3; }
    """

    static func escape(_ s: String) -> String {
        // XML forbids most control characters, which old files sometimes hold.
        let clean = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            $0.value >= 0x20 || $0 == "\n" || $0 == "\t"
        }))
        return clean.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
