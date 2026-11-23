import XCTest

/// Read aloud's text for PDFs (`PDFReadAloudText`): what is left out (running
/// headers and footers, page numbers), what is joined (words broken at a
/// line's end, sentences across pages), and how sentences and words map back
/// to the pages for the underline.
final class PDFReadAloudTextTests: XCTestCase {
    private let pages = [
        "THE HILL\nIt was a cold morn-\ning on the hill. She walked up\nthe path and\n1",
        "THE HILL\nnever looked back. The wind rose.\n2",
        "THE HILL\nNight came at last.\n3",
    ]

    private func text(from first: Int = 0) -> PDFReadAloudText {
        var text = PDFReadAloudText(firstPage: first)
        let edges = PDFReadAloudText.repeatedEdgeLines(pages)
        for page in pages[first...] { text.addPage(page, edgeLines: edges) }
        return text
    }

    func testHeadersAndPageNumbersAreLeftOutAndLinesJoined() {
        var text = text()
        XCTAssertEqual(text.takeSentences(atEnd: true).map(\.text), [
            "It was a cold morning on the hill.",
            "She walked up the path and never looked back.",
            "The wind rose.",
            "Night came at last.",
        ])
    }

    func testTheLastSentenceWaitsForTheNextPage() {
        var text = PDFReadAloudText(firstPage: 0)
        let edges = PDFReadAloudText.repeatedEdgeLines(pages)
        text.addPage(pages[0], edgeLines: edges)
        XCTAssertEqual(text.takeSentences(atEnd: false).map(\.text), ["It was a cold morning on the hill."],
                       "\"She walked up the path and\" may run on")
        text.addPage(pages[1], edgeLines: edges)
        XCTAssertEqual(text.takeSentences(atEnd: false).map(\.text), ["She walked up the path and never looked back."])
    }

    func testRepeatedLinesAndPageNumbers() {
        XCTAssertEqual(PDFReadAloudText.normalised("Chapter 12 · The  Hill"), "chapter # · the hill")
        XCTAssertEqual(PDFReadAloudText.normalised("xiv"), "#")
        XCTAssertTrue(PDFReadAloudText.isPageNumber(PDFReadAloudText.normalised("– 214 –")))
        XCTAssertTrue(PDFReadAloudText.isPageNumber(PDFReadAloudText.normalised("Page 3 of 20")))
        XCTAssertFalse(PDFReadAloudText.isPageNumber(PDFReadAloudText.normalised("3 men")))
        // A line at the edge of two of three pages is a header; one in the
        // middle of the page is not looked at.
        XCTAssertEqual(PDFReadAloudText.repeatedEdgeLines(["Head\nA\nB\nC\nD\nE", "Head\nF\nG\nH\nI\nJ", "K\nL\nM\nN\nO\nP"]), ["head"])
    }

    func testSentencesAndWordsMapBackToTheirPages() {
        var text = text()
        let sentences = text.takeSentences(atEnd: true)
        // "She walked up the path and never looked back." spans pages 0 and 1.
        let walked = sentences[1]
        let ranges = text.ranges(start: walked.start, length: walked.length)
        XCTAssertEqual(ranges.map(\.page), [0, 1])
        XCTAssertEqual((pages[1] as NSString).substring(with: ranges[1].range), "never looked back.")
        // "morning", joined from "morn-" and "ing": both parts underlined.
        let morning = (sentences[0].text as NSString).range(of: "morning")
        let parts = text.ranges(start: sentences[0].start + morning.location, length: morning.length)
        XCTAssertEqual(parts.count, 1, "one page")
        XCTAssertEqual((pages[0] as NSString).substring(with: parts[0].range), "morn-\ning")
    }

    func testReadingStartsWithTheSentenceThatRunsOntoThePage() {
        var text = text()
        let start = text.streamOffset(ofPage: 1)!
        let from = PDFReadAloudText.startingAt(text.takeSentences(atEnd: true), streamOffset: start)
        XCTAssertEqual(from.first?.text, "She walked up the path and never looked back.")
    }
}
