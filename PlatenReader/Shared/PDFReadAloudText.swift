import Foundation
import NaturalLanguage

/// A PDF's text as read aloud (docs/read-aloud.md, "PDFs"): the pages' text,
/// from PDFKit, made into one stream of sentences, the way a reader would
/// read the pages rather than the way they are printed.
///
/// - Running headers and footers are left out: a line at the top or bottom
///   of a page (the first or last two) that comes back on other pages near
///   it, with its numbers ignored ("Chapter 3 · The Hill · 41").
/// - So are page numbers: a line at the top or bottom that is only a number
///   or a Roman numeral, perhaps with "Page", "– 12 –" or "3 of 20".
/// - A word broken at the end of a line ("exam-" / "ple") is joined again;
///   every other line break, and every page break, becomes a space, so a
///   sentence that runs onto the next page is read whole.
///
/// What it cannot know: a scanned PDF has no text; footnotes, captions and
/// sidebars are read where the PDF puts them; and multi-column pages come in
/// the order the PDF's maker wrote them.
///
/// Every sentence keeps where it came from, so the page can turn to it and
/// underline its words: positions in the stream (UTF-16, as `NSString`)
/// map back to ranges of each page's text (`ranges(_:)`).
struct PDFReadAloudText {
    /// A piece of the stream copied from one page: `length` units from
    /// `pageOffset` in that page's text.
    struct Run: Equatable {
        let stream: Int
        let page: Int
        let pageOffset: Int
        let length: Int
    }

    /// A sentence: its place in the stream, and its text.
    struct Sentence: Equatable {
        let start: Int
        let length: Int
        let text: String
    }

    private(set) var stream = ""
    private(set) var runs: [Run] = []
    /// The pages added so far: from `firstPage` up to `nextPage` (not
    /// included).
    let firstPage: Int
    private(set) var nextPage: Int
    /// How far sentences have been taken from the stream.
    private var taken = 0
    /// The last line added was a heading in capitals.
    private var inHeading = false
    private var streamLength: Int { (stream as NSString).length }

    init(firstPage: Int) {
        self.firstPage = firstPage
        nextPage = firstPage
    }

    // MARK: - Pages in

    /// Adds the next page's text. `edgeLines` are the repeated header and
    /// footer lines near this page (`repeatedEdgeLines`), normalised.
    mutating func addPage(_ text: String, edgeLines: Set<String>) {
        let page = nextPage
        nextPage += 1
        let lines = Self.bodyLines(of: text, edgeLines: edgeLines)
        for line in lines {
            // A heading in capitals (of one line or several) is a sentence
            // of its own: a line break before and after it (which the
            // sentence splitter takes as an end, and the voice never sees),
            // rather than running into the sentences either side.
            let heading = Self.isHeading(line.text)
            appendLine(line.text, page: page, offset: line.offset, breakBefore: heading != inHeading)
            inHeading = heading
        }
    }

    /// A line of a page's text and where it starts in it.
    struct Line: Equatable {
        let text: String
        let offset: Int
    }

    /// The page's lines (trimmed, empty ones dropped), with where each is.
    static func lines(of text: String) -> [Line] {
        let ns = text as NSString
        var lines: [Line] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { _, range, _, _ in
            var start = range.location, end = range.location + range.length
            while start < end, Self.isSpace(ns.character(at: start)) { start += 1 }
            while end > start, Self.isSpace(ns.character(at: end - 1)) { end -= 1 }
            if end > start { lines.append(Line(text: ns.substring(with: NSRange(location: start, length: end - start)), offset: start)) }
        }
        return lines
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0xA0 || unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    /// How many lines at the top and at the bottom of a page may be a
    /// header, a footer or a page number.
    static let edgeDepth = 2

    /// A line all in capitals: a heading ("THE EFFICIENT MARKET
    /// HYPOTHESIS", "CHAPTER 4", "EXPERIMENT, PART VI:").
    static func isHeading(_ line: String) -> Bool {
        let letters = line.filter(\.isLetter)
        return letters.count >= 3 && letters == letters.uppercased() && letters != letters.lowercased()
    }

    /// Ornaments at the ends of lines (the asterisks and dingbats of
    /// section breaks), which are not read.
    static let ornaments = CharacterSet(charactersIn: "*•·◆◇❖❧☙✦✧~#§¤")

    /// The lines worth reading: without page numbers and repeated headers
    /// and footers at the page's top and bottom, without lines of nothing
    /// but ornaments ("* * *"), and with ornaments trimmed from their ends.
    static func bodyLines(of text: String, edgeLines: Set<String>) -> [Line] {
        // Lines of nothing but ornaments go first, so that they do not hide
        // a header behind them.
        var lines = lines(of: text).filter(hasWords)
        func isEdge(_ line: Line) -> Bool {
            let key = normalised(line.text)
            return isPageNumber(key) || edgeLines.contains(key)
        }
        // From the top, then from the bottom, while lines are headers or
        // footers (a header of two lines goes whole).
        var dropped = 0
        while dropped < edgeDepth, let first = lines.first, isEdge(first) { lines.removeFirst(); dropped += 1 }
        dropped = 0
        while dropped < edgeDepth, let last = lines.last, isEdge(last) { lines.removeLast(); dropped += 1 }
        return lines.compactMap(trimmingOrnaments)
    }

    /// Whether a line has letters or digits (else it is ornaments: "* * *").
    static func hasWords(_ line: Line) -> Bool {
        line.text.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// The line without ornaments at its ends.
    static func trimmingOrnaments(_ line: Line) -> Line? {
        let ns = line.text as NSString
        var start = 0, end = ns.length
        func trimmable(_ unit: unichar) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return false }
            return ornaments.contains(scalar) || isSpace(unit)
        }
        while start < end, trimmable(ns.character(at: start)) { start += 1 }
        while end > start, trimmable(ns.character(at: end - 1)) { end -= 1 }
        return Line(text: ns.substring(with: NSRange(location: start, length: end - start)), offset: line.offset + start)
    }

    // MARK: - Headers, footers and page numbers

    /// A line as compared between pages: lower case, its numbers (and
    /// Roman numerals) as "#", its spaces single.
    static func normalised(_ line: String) -> String {
        let words = line.lowercased()
            .replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map { word -> String in
                let core = word.trimmingCharacters(in: .punctuationCharacters)
                if !core.isEmpty, core.allSatisfy({ "ivxlcdm".contains($0) }), core.count <= 6, core != "mild", core != "mix" {
                    return "#"
                }
                return String(word)
            }
        return words.joined(separator: " ")
    }

    /// A normalised line that is only a page number: "#", "page #", "– # –",
    /// "# of #", "#/#".
    static func isPageNumber(_ key: String) -> Bool {
        // "#" stands for the numbers; it is punctuation itself, so it is
        // swapped for a letter before punctuation and spaces go.
        let bare = key.replacingOccurrences(of: "#", with: "n")
            .replacingOccurrences(of: "[\\p{P}\\p{S}\\s]", with: "", options: .regularExpression)
        return ["n", "pagen", "pn", "nofn", "nn", "pagenofn"].contains(bare)
    }

    /// The pages to compare with `index` to find its running heads: those
    /// on the same side (every other page, up to six each way), as books
    /// often have one head on left-hand pages and another on right-hand
    /// ones; a head on every page is on these too.
    static func edgeWindow(around index: Int, pageCount: Int) -> [Int] {
        stride(from: index - 12, through: index + 12, by: 2).filter { $0 >= 0 && $0 < pageCount }
    }

    /// The header and footer lines that repeat across `pages` (the texts of
    /// the pages around the one being read): normalised lines found at the
    /// top or bottom of at least 30% of them (and three), or of half of
    /// them when there are only a few. (The pages are those on the same side
    /// as the one being read, `edgeWindow`; a chapter's own head, on a short
    /// chapter's pages only, needs the lower share.)
    static func repeatedEdgeLines(_ pages: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for page in pages {
            let lines = lines(of: page).filter(hasWords)
            let edges = lines.prefix(edgeDepth) + lines.suffix(edgeDepth)
            for key in Set(edges.map { normalised($0.text) }) where key.count <= 120 && key.contains(where: \.isLetter) {
                counts[key, default: 0] += 1
            }
        }
        // Running heads are on most of these pages; a chapter's title at the
        // top of its first page is not (so "CHAPTER 57" is read, a running
        // "THE HILL · 41" is not).
        let needed = pages.count >= 6 ? max(3, Int((Double(pages.count) * 0.3).rounded(.up))) : max(2, (pages.count + 1) / 2)
        return Set(counts.filter { $0.value >= needed }.keys)
    }

    // MARK: - The stream

    private mutating func appendLine(_ line: String, page: Int, offset: Int, breakBefore: Bool) {
        // A word broken at the end of the last line: "exam-" + "ple" reads
        // as "example" (the hyphen goes; a capital after it keeps it, as in
        // "Anglo-" + "Saxon").
        let current = stream as NSString
        if current.length >= 2, let first = line.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(first),
           Self.isBreakHyphen(current.character(at: current.length - 1)),
           let before = UnicodeScalar(current.character(at: current.length - 2)),
           CharacterSet.letters.contains(before) {
            dropLastStreamUnit()
        } else if current.length > 0 {
            stream += breakBefore ? "\n" : " "
        }
        let start = streamLength
        stream += line
        runs.append(Run(stream: start, page: page, pageOffset: offset, length: (line as NSString).length))
    }

    private static func isBreakHyphen(_ unit: unichar) -> Bool {
        unit == 0x2D || unit == 0xAD || unit == 0x2010
    }

    /// Takes the hyphen off the end of the stream, and off its run.
    private mutating func dropLastStreamUnit() {
        let ns = stream as NSString
        stream = ns.substring(to: ns.length - 1)
        if let last = runs.last, last.stream + last.length > streamLength {
            runs[runs.count - 1] = Run(stream: last.stream, page: last.page, pageOffset: last.pageOffset,
                                       length: max(0, last.length - 1))
        }
    }

    // MARK: - Sentences out

    /// The sentences not yet taken. The last sentence in the stream is held
    /// back until more pages come (it may run on), unless `atEnd`.
    mutating func takeSentences(atEnd: Bool) -> [Sentence] {
        let ns = stream as NSString
        guard taken < ns.length else { return [] }
        let rest = ns.substring(from: taken)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = rest
        var found: [NSRange] = []
        tokenizer.enumerateTokens(in: rest.startIndex..<rest.endIndex) { range, _ in
            found.append(NSRange(range, in: rest))
            return true
        }
        if !atEnd, !found.isEmpty { found.removeLast() }
        var sentences: [Sentence] = []
        let restNS = rest as NSString
        for range in found {
            // Trimmed of spaces at either end, as sent to the voice.
            var start = range.location, end = range.location + range.length
            while start < end, Self.isSpace(restNS.character(at: start)) { start += 1 }
            while end > start, Self.isSpace(restNS.character(at: end - 1)) { end -= 1 }
            if end > start {
                sentences.append(Sentence(start: taken + start, length: end - start,
                                          text: restNS.substring(with: NSRange(location: start, length: end - start))))
            }
        }
        if let last = found.last { taken += last.location + last.length }
        return sentences
    }

    /// Skips sentences that end before `streamOffset` (the start of the page
    /// reading begins on), keeping the one that runs onto it.
    static func startingAt(_ sentences: [Sentence], streamOffset: Int) -> [Sentence] {
        sentences.filter { $0.start + $0.length > streamOffset }
    }

    /// Where page `page` starts in the stream, if any of it is there.
    func streamOffset(ofPage page: Int) -> Int? {
        runs.first { $0.page >= page }?.stream
    }

    // MARK: - Back to the pages

    /// The parts of each page's text that make up `length` units of the
    /// stream from `start` (a sentence or a word may run over two pages).
    func ranges(start: Int, length: Int) -> [(page: Int, range: NSRange)] {
        Self.ranges(in: runs, start: start, length: length)
    }

    /// `ranges(start:length:)`, from some of the runs (those of a sentence).
    static func ranges(in runs: [Run], start: Int, length: Int) -> [(page: Int, range: NSRange)] {
        let end = start + length
        var out: [(page: Int, range: NSRange)] = []
        for run in runs where run.stream < end && run.stream + run.length > start {
            let from = max(start, run.stream), to = min(end, run.stream + run.length)
            let range = NSRange(location: run.pageOffset + (from - run.stream), length: to - from)
            if let last = out.last, last.page == run.page, last.range.location + last.range.length <= range.location {
                // The same page: one range from the first to the last.
                out[out.count - 1].range = NSRange(location: last.range.location,
                                                   length: range.location + range.length - last.range.location)
            } else {
                out.append((run.page, range))
            }
        }
        return out
    }
}
