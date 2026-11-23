import Foundation
import PDFKit

/// What the PDF reader on screen does for read aloud: turn to a page, and
/// underline words (each app's `PDFReaderViewController`).
@MainActor
protocol PDFReadAloudHost: AnyObject {
    /// The first page on screen, where reading starts.
    var readAloudStartPage: Int { get }
    /// Shows `page`, if it is not on screen already.
    func readAloudShow(page: Int)
    /// Underlines these parts of the pages' text, in place of what was
    /// underlined before (none: takes the underline away).
    func readAloudUnderline(_ ranges: [(page: Int, range: NSRange)])
}

/// Read aloud in a PDF (docs/read-aloud.md, "PDFs"): the pages' text as
/// sentences for the voice (`PDFReadAloudText`, which leaves out headers,
/// footers and page numbers), and the voice's progress back on the page.
///
/// The text is read from a second copy of the document on a background
/// queue, a few pages ahead of the voice, so the copy on screen is only
/// touched from the main thread.
@MainActor
final class PDFReadAloud: ReadAloudSource {
    private let state: ReaderState
    private weak var host: PDFReadAloudHost?
    private let document: PDFDocument
    private let reopen: @Sendable () -> PDFDocument?
    private var controller: ReadAloudController?
    private let reader: TextReader

    /// What each sentence handed to the voice is, by its mark: where it
    /// starts in the stream, and the runs of page text it is made of.
    private var sentences: [String: (start: Int, runs: [PDFReadAloudText.Run])] = [:]
    private var nextMark = 0
    /// Bumped by every start and stop, so text read for an earlier start is
    /// dropped.
    private var generation = 0

    init(model: PDFReaderModel, host: PDFReadAloudHost) {
        state = model.state
        document = model.document
        reopen = model.reopen
        self.host = host
        reader = TextReader(pageCount: model.pageCount)
    }

    // MARK: - ReadAloudSource

    var canReadAloud: Bool { document.pageCount > 0 }

    /// The language of the PDF's text (PDFs seldom say), from the page on
    /// screen.
    var readAloudLanguage: String {
        let page = host?.readAloudStartPage ?? 0
        return SpeechEngineChooser.language(book: nil, text: document.page(at: page)?.string)
    }

    func startReadAloud(engine: SpeechEngine) {
        stopReadAloud()
        generation += 1
        sentences.removeAll()
        let controller = ReadAloudController(engine: engine, language: readAloudLanguage)
        controller.onPhase = { [weak self] phase in
            self?.state.readAloud = phase
            if phase == .off { self?.ended() }
        }
        controller.requestNext = { [weak self] in self?.readMore() }
        controller.mark = { [weak self] mark in self?.sentenceStarted(mark) }
        controller.markWord = { [weak self] mark, start, length in self?.wordStarted(mark, start: start, length: length) }
        self.controller = controller
        controller.start()
        state.readAloud = .starting
        reader.begin(at: host?.readAloudStartPage ?? 0, reopen: reopen)
        readMore()
    }

    func pauseReadAloud() { controller?.pause() }
    func resumeReadAloud() { controller?.resume() }
    func stopReadAloud() { controller?.stop() }

    private func ended() {
        controller = nil
        generation += 1
        state.readAloud = .off
        host?.readAloudUnderline([])
    }

    // MARK: - Text for the voice

    /// The next sentences, read in the background, handed to the voice.
    private func readMore() {
        let generation = self.generation
        reader.next { [weak self] batch in
            guard let self, generation == self.generation, let controller = self.controller else { return }
            let marked = batch.sentences.map { sentence -> ReadAloudSentence in
                let mark = "s\(self.nextMark)"
                self.nextMark += 1
                self.sentences[mark] = (sentence.start, batch.runs(for: sentence))
                return ReadAloudSentence(mark: mark, text: sentence.text)
            }
            controller.receive(ReadAloudBlock(language: nil, sentences: marked))
            if batch.atEnd { controller.endReached() }
        }
    }

    // MARK: - The voice's progress on the page

    /// A sentence is starting: its page is shown. (The underline waits for
    /// its first word.)
    private func sentenceStarted(_ mark: String) {
        guard let sentence = sentences[mark] else { return }
        if let first = PDFReadAloudText.ranges(in: sentence.runs, start: sentence.start, length: 1).first {
            host?.readAloudShow(page: first.page)
        }
        // Sentences already spoken are forgotten.
        if let number = Int(mark.dropFirst()) { sentences.removeValue(forKey: "s\(number - 40)") }
    }

    /// A word is starting: it is underlined, on whichever page it is.
    private func wordStarted(_ mark: String, start: Int, length: Int) {
        guard let sentence = sentences[mark] else { return }
        let ranges = PDFReadAloudText.ranges(in: sentence.runs, start: sentence.start + start, length: length)
        guard let first = ranges.first else { return }
        host?.readAloudShow(page: first.page)
        host?.readAloudUnderline(ranges)
    }

    // MARK: - Debug

    /// The first sentences read aloud from `page`, joined by " | ", for the
    /// corpus checks (headers and page numbers must not be in it).
    static func preview(of document: PDFDocument, from page: Int = 0, count: Int = 4) -> String {
        var text = PDFReadAloudText(firstPage: page)
        var found: [String] = []
        var index = page
        while found.count < count, index < document.pageCount {
            let edges = PDFReadAloudText.repeatedEdgeLines(
                PDFReadAloudText.edgeWindow(around: index, pageCount: document.pageCount).map { document.page(at: $0)?.string ?? "" })
            text.addPage(document.page(at: index)?.string ?? "", edgeLines: edges)
            index += 1
            found += text.takeSentences(atEnd: index == document.pageCount).map(\.text)
        }
        return found.prefix(count).joined(separator: " | ")
    }
}

/// Reads a PDF's text a batch of sentences at a time, on its own queue,
/// from a copy of the document. Its state is touched only on that queue.
private final class TextReader: @unchecked Sendable {
    struct Batch {
        var sentences: [PDFReadAloudText.Sentence]
        var allRuns: [PDFReadAloudText.Run]
        var atEnd: Bool

        /// The runs a sentence is made of.
        func runs(for sentence: PDFReadAloudText.Sentence) -> [PDFReadAloudText.Run] {
            let end = sentence.start + sentence.length
            return allRuns.filter { $0.stream < end && $0.stream + $0.length > sentence.start }
        }
    }

    /// Sentences handed over at a time: about a page or two.
    static let batchSize = 20

    private let queue = DispatchQueue(label: "org.platenreader.pdf-read-aloud", qos: .userInitiated)
    private let pageCount: Int
    private var document: PDFDocument?
    private var text = PDFReadAloudText(firstPage: 0)
    private var pageTexts: [Int: String] = [:]
    private var startOffset: Int?
    private var startPage = 0
    private var finished = false

    init(pageCount: Int) {
        self.pageCount = pageCount
    }

    /// Starts again from the beginning of `page` (and the sentence that runs
    /// onto it from the page before).
    func begin(at page: Int, reopen: @escaping @Sendable () -> PDFDocument?) {
        queue.async {
            if self.document == nil { self.document = reopen() }
            self.startPage = page
            self.text = PDFReadAloudText(firstPage: max(0, page - 1))
            self.startOffset = nil
            self.finished = false
        }
    }

    /// The next batch, delivered on the main thread.
    func next(_ deliver: @escaping @MainActor (Batch) -> Void) {
        queue.async {
            let batch = self.readBatch()
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(batch) } }
        }
    }

    private func pageText(_ index: Int) -> String {
        if let cached = pageTexts[index] { return cached }
        let string = document?.page(at: index)?.string ?? ""
        pageTexts[index] = string
        // A few hundred pages' text kept at most.
        if pageTexts.count > 400, let far = pageTexts.keys.max(by: { abs($0 - index) < abs($1 - index) }) {
            pageTexts.removeValue(forKey: far)
        }
        return string
    }

    private func readBatch() -> Batch {
        var sentences: [PDFReadAloudText.Sentence] = []
        guard !finished, document != nil else { return Batch(sentences: [], allRuns: [], atEnd: true) }
        while sentences.count < Self.batchSize {
            let atEnd = text.nextPage >= pageCount
            if !atEnd {
                let index = text.nextPage
                let around = PDFReadAloudText.edgeWindow(around: index, pageCount: pageCount).map(pageText)
                text.addPage(pageText(index), edgeLines: PDFReadAloudText.repeatedEdgeLines(around))
                if startOffset == nil, index >= startPage { startOffset = text.streamOffset(ofPage: startPage) }
            }
            var taken = text.takeSentences(atEnd: text.nextPage >= pageCount)
            if let startOffset { taken = PDFReadAloudText.startingAt(taken, streamOffset: startOffset) } else { taken = [] }
            sentences += taken
            if atEnd {
                finished = true
                break
            }
        }
        // Only the runs these sentences are made of go back.
        let from = sentences.first?.start ?? Int.max
        return Batch(sentences: sentences, allRuns: text.runs.filter { $0.stream + $0.length > from }, atEnd: finished)
    }
}
