import XCTest
@testable import PlatenCore

/// Plain-text books: decoding, paragraphs, chapters and metadata.
final class TextBookTests: XCTestCase {
    private func open(_ text: String, name: String = "My Story.txt") throws -> Book {
        try Book.open(source: MemoryByteSource(data: Data(text.utf8)), fileName: name)
    }

    private func html(_ book: Book) throws -> String {
        try book.package!.spine.map { String(decoding: try book.resource(at: $0).data, as: UTF8.self) }.joined()
    }

    /// A paragraph hard-wrapped at about 70 characters, as in Gutenberg files.
    private func wrapped(_ n: Int) -> String {
        let words = (0..<120).map { ["the", "quiet", "river", "ran", "on", "beneath", "an", "old", "stone", "bridge"][($0 + n) % 10] }
        var lines: [String] = [], line = ""
        for word in words {
            if line.count + word.count + 1 > 70 { lines.append(line); line = word } else { line += line.isEmpty ? word : " " + word }
        }
        return (lines + [line]).joined(separator: "\n")
    }

    private func chapters(_ count: Int) -> String {
        (1...count).map { "CHAPTER \($0)\n\n" + wrapped($0) + "\n\n" + wrapped($0 + 3) }.joined(separator: "\n\n\n")
    }

    func testOpensAsTextWithFileNameTitle() throws {
        let book = try open("Just a short note.\n")
        XCTAssertEqual(book.format, .text)
        XCTAssertEqual(book.title, "My Story")
        XCTAssertFalse(try html(book).isEmpty)
        // The made-up files are served, with sizes for foliate-js.
        XCTAssertNotNil(book.entrySizes["META-INF/container.xml"])
        XCTAssertEqual(try book.resource(at: "text/style.css").mimeType, "text/css")
    }

    func testHardWrappedProseIsJoinedIntoParagraphs() throws {
        let book = try open((0..<6).map(wrapped).joined(separator: "\n\n"))
        let html = try html(book)
        XCTAssertEqual(html.components(separatedBy: "<p").count - 1, 6)
        XCTAssertFalse(html.contains("class=\"lines\""))
        XCTAssertFalse(html.contains("bridge\nthe"), "line breaks inside a paragraph should be joined")
    }

    func testPoetryKeepsItsLineBreaks() throws {
        let poem = "The woods are lovely, dark and deep,\nBut I have promises to keep,\nAnd miles to go before I sleep."
        let book = try open((0..<6).map(wrapped).joined(separator: "\n\n") + "\n\n" + poem)
        XCTAssertTrue(try html(book).contains("<p class=\"lines\">The woods are lovely, dark and deep,\nBut I have"))
    }

    func testChaptersBecomeSectionsAndContents() throws {
        let book = try open(chapters(3))
        XCTAssertEqual(book.package?.spine.count, 3)
        let nav = String(decoding: try book.resource(at: "text/nav.xhtml").data, as: UTF8.self)
        XCTAssertTrue(nav.contains(">CHAPTER 1</a>"))
        XCTAssertTrue(nav.contains(">CHAPTER 3</a>"))
    }

    func testRomanNumeralAndTitledHeadings() throws {
        XCTAssertEqual(TextBook.heading(.init(lines: ["CHAPTER IV.", "The Rabbit Sends in a Little Bill"])),
                       "CHAPTER IV. The Rabbit Sends in a Little Bill")
        XCTAssertEqual(TextBook.heading(.init(lines: ["Part One"])), "Part One")
        XCTAssertEqual(TextBook.heading(.init(lines: ["Prologue"])), "Prologue")
        XCTAssertNil(TextBook.heading(.init(lines: ["Chapter and verse were quoted at length by the vicar."])))
        XCTAssertNil(TextBook.heading(.init(lines: ["Book lovers will know the feeling."])))
    }

    func testContentsListIsNotMistakenForChapters() throws {
        // A contents list with one entry per paragraph, then the chapters.
        let contents = (1...3).map { "Chapter \($0)" }.joined(separator: "\n\n")
        let book = try open("CONTENTS\n\n" + contents + "\n\n\n" + chapters(3))
        // Front matter (the list) plus three chapters; the list entries are not sections.
        XCTAssertEqual(book.package?.spine.count, 4)
    }

    func testNoHeadingsMeansOneSectionAndNoContents() throws {
        let book = try open((0..<4).map(wrapped).joined(separator: "\n\n"))
        XCTAssertEqual(book.package?.spine.count, 1)
        let nav = String(decoding: try book.resource(at: "text/nav.xhtml").data, as: UTF8.self)
        XCTAssertFalse(nav.contains("<li>"))
    }

    func testGutenbergHeaderGivesTitleAuthorAndLanguage() throws {
        let header = "The Project Gutenberg eBook of Alice\n\nTitle: Alice's Adventures in Wonderland\n\nAuthor: Lewis Carroll\n\nLanguage: English\n\n*** START OF THE PROJECT GUTENBERG EBOOK ***\n\n"
        let book = try open(header + chapters(2))
        XCTAssertEqual(book.title, "Alice's Adventures in Wonderland")
        XCTAssertEqual(book.authors, ["Lewis Carroll"])
        XCTAssertEqual(book.package?.languages, ["en"])
    }

    /// "Jane Austen - Sense and Sensibility.txt", whose text says "by Jane
    /// Austen": the title and author come from the name, the right way
    /// round. The other order works too; with nothing in the text to say
    /// which part is the author, the whole name stays the title.
    func testTitleAndAuthorFromFileNameWhenTheTextAgrees() throws {
        let story = "Sense and Sensibility, by Jane Austen\n\n" + chapters(2)
        var book = try open(story, name: "Jane Austen - Sense and Sensibility.txt")
        XCTAssertEqual(book.title, "Sense and Sensibility")
        XCTAssertEqual(book.authors, ["Jane Austen"])
        book = try open(story, name: "Sense and Sensibility - Jane Austen.txt")
        XCTAssertEqual(book.title, "Sense and Sensibility")
        book = try open(chapters(2), name: "Jane Austen - Sense and Sensibility.txt")
        XCTAssertEqual(book.title, "Jane Austen - Sense and Sensibility")
        XCTAssertEqual(book.authors, [])
    }

    /// A title page as plain text sets it out ("FULFILMENT", "by", the
    /// author, each on its own): centred lines, not indented paragraphs;
    /// and the author written as on the page, matched to a surname-first
    /// file name.
    func testTitlePageIsCentredAndNamesTheAuthor() throws {
        let story = "FULFILMENT\n\n\n\nby\n\n\n\nA.E. Van Vogt\n\n\n\n\n" + String(repeating: "I sit on a hill and think about the valley below, as I always have. ", count: 4)
            + "\n\nAnother paragraph.\n"
        let book = try open(story, name: "Vogt, A E Van - Fulfilment.txt")
        XCTAssertEqual(book.title, "Fulfilment")
        XCTAssertEqual(book.authors, ["A.E. Van Vogt"])
        let text = try html(book)
        XCTAssertTrue(text.contains("<p class=\"title name\">FULFILMENT</p>"))
        XCTAssertTrue(text.contains("<p class=\"title\">by</p>"))
        XCTAssertFalse(text.contains("<p class=\"title\">I sit"))
    }

    /// Short lines at the start of ordinary prose are not a title page
    /// unless a real paragraph follows them.
    func testShortOpeningLinesWithoutAParagraphAreNotATitlePage() throws {
        let book = try open("One.\n\nTwo.\n\nThree.\n")
        XCTAssertFalse(try html(book).contains("class=\"title"))
    }

    /// An old Project Gutenberg file's notice before the first chapter has
    /// its own Contents entry.
    func testGutenbergNoticeHasAContentsEntry() throws {
        let notice = "The Project Gutenberg Etext of A Book\n\n" + wrapped(9) + "\n\n"
        let book = try open(notice + chapters(2))
        let nav = String(decoding: try book.resource(at: "text/nav.xhtml").data, as: UTF8.self)
        XCTAssertTrue(nav.contains("<li><a href=\"section-1.xhtml\">Project Gutenberg Notice</a></li>"))
        XCTAssertTrue(nav.contains(">CHAPTER 1</a>"))
    }

    func testWindows1252AndUTF16AreDecoded() throws {
        let cp1252 = Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x93, 0x6F, 0x6B, 0x94]) // Café “ok”
        XCTAssertEqual(TextBook.decode(cp1252), "Café \u{201C}ok\u{201D}")
        let utf16 = Data([0xFF, 0xFE]) + "Hi\r\nthere".data(using: .utf16LittleEndian)!
        XCTAssertEqual(TextBook.decode(utf16), "Hi\nthere")
        XCTAssertTrue(TextBook.looksLikeText(utf16))
    }

    func testMarkupInTextIsEscaped() throws {
        let book = try open(wrapped(0) + "\n\nif a < b && c > d then <script>alert(1)</script>\u{07}")
        let html = try html(book)
        XCTAssertTrue(html.contains("a &lt; b &amp;&amp; c &gt; d"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("\u{07}"))
    }

    func testHugeTextWithoutHeadingsIsSplit() throws {
        let book = try open((0..<400).map(wrapped).joined(separator: "\n\n"))
        XCTAssertGreaterThan(book.package?.spine.count ?? 0, 1)
    }

    func testTextStartingWithContentsIsNotKFX() throws {
        XCTAssertEqual(try open("CONTENTS\n\nChapter 1\n").format, .text)
    }

    func testSameTextGetsSameKey() throws {
        XCTAssertEqual(try open("Hello there.", name: "a.txt").key, try open("Hello there.", name: "b.txt").key)
    }
}
