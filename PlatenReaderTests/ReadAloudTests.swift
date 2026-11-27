import XCTest

/// Tests of read aloud's shared parts (Shared/ReadAloud.swift): which engine
/// reads a book, which Apple voice, and keeping text and speech in step.
@MainActor
final class ReadAloudTests: XCTestCase {
    // MARK: - Engine choice: language × choice × voice offered / installed

    func testEnglishBooksAskFirstUntilAChoiceIsMade() {
        XCTAssertEqual(SpeechEngineChooser.choose(language: "en-GB", choice: .undecided, kokoroOffered: true, kokoroInstalled: false),
                       .askFirst(language: "en-GB"))
        XCTAssertEqual(SpeechEngineChooser.choose(language: "en", choice: .undecided, kokoroOffered: true, kokoroInstalled: true),
                       .askFirst(language: "en"))
    }

    func testEnglishBooksFollowTheChoice() {
        XCTAssertEqual(SpeechEngineChooser.choose(language: "en-US", choice: .apple, kokoroOffered: true, kokoroInstalled: true),
                       .apple(language: "en-US"))
        XCTAssertEqual(SpeechEngineChooser.choose(language: "en-US", choice: .kokoro, kokoroOffered: true, kokoroInstalled: true),
                       .kokoro)
        // Chose the natural voice, then removed it: asked again.
        XCTAssertEqual(SpeechEngineChooser.choose(language: "en-US", choice: .kokoro, kokoroOffered: true, kokoroInstalled: false),
                       .askFirst(language: "en-US"))
    }

    func testOtherLanguagesAlwaysUseApplesVoices() {
        for choice in ReadAloudVoiceChoice.allCases {
            for installed in [false, true] {
                XCTAssertEqual(SpeechEngineChooser.choose(language: "fr", choice: choice, kokoroOffered: true, kokoroInstalled: installed),
                               .apple(language: "fr"))
            }
        }
    }

    func testWhereTheNaturalVoiceIsNotOfferedEnglishUsesApplesVoicesWithoutAsking() {
        for choice in ReadAloudVoiceChoice.allCases {
            XCTAssertEqual(SpeechEngineChooser.choose(language: "en", choice: choice, kokoroOffered: false, kokoroInstalled: false),
                           .apple(language: "en"))
        }
    }

    // MARK: - The book's language

    func testTheBooksOwnLanguageWinsOverItsText() {
        XCTAssertEqual(SpeechEngineChooser.language(book: "fr_FR", text: "This is plainly English text, for the most part."), "fr-FR")
        XCTAssertEqual(SpeechEngineChooser.language(book: "EN-gb", text: nil), "en-GB")
    }

    func testWithoutOneTheTextDecides() {
        XCTAssertEqual(SpeechEngineChooser.language(book: nil, text: "Ceci est un texte écrit en français, sans aucun doute possible."), "fr")
        XCTAssertEqual(SpeechEngineChooser.language(book: " ", text: ""), "en")
    }

    // MARK: - Apple's voices

    private let voices = [
        AppleVoiceInfo(identifier: "daniel", name: "Daniel", language: "en-GB", quality: .standard),
        AppleVoiceInfo(identifier: "samantha", name: "Samantha", language: "en-US", quality: .enhanced),
        AppleVoiceInfo(identifier: "serena", name: "Serena", language: "en-GB", quality: .enhanced),
        AppleVoiceInfo(identifier: "thomas", name: "Thomas", language: "fr-FR", quality: .standard),
    ]

    func testPremiumThenEnhancedThenDefault() {
        let premium = voices + [AppleVoiceInfo(identifier: "zoe", name: "Zoe", language: "en-US", quality: .premium)]
        XCTAssertEqual(AppleVoices.best(for: "en-GB", among: premium, readerRegion: "GB")?.identifier, "zoe")
    }

    func testAmongEqualVoicesTheBooksRegionThenTheReadersWins() {
        XCTAssertEqual(AppleVoices.best(for: "en-GB", among: voices, readerRegion: "US")?.identifier, "serena")
        XCTAssertEqual(AppleVoices.best(for: "en", among: voices, readerRegion: "US")?.identifier, "samantha")
        XCTAssertEqual(AppleVoices.best(for: "en", among: voices, readerRegion: "GB")?.identifier, "serena")
    }

    func testAVoiceChosenInSettingsIsUsedForItsLanguageOnly() {
        XCTAssertEqual(AppleVoices.best(for: "en-GB", among: voices, preferred: "daniel")?.identifier, "daniel")
        XCTAssertEqual(AppleVoices.best(for: "fr", among: voices, preferred: "daniel")?.identifier, "thomas")
    }

    func testTheReaderIsToldWhenOnlyADefaultVoiceIsInstalled() {
        XCTAssertTrue(AppleVoices.onlyStandard(for: "fr", among: voices))
        XCTAssertFalse(AppleVoices.onlyStandard(for: "en-AU", among: voices))
    }

    // MARK: - Keeping text and speech in step

    private func block(_ texts: [String], from first: Int = 0) -> ReadAloudBlock {
        ReadAloudBlock(language: "en", sentences: texts.enumerated().map {
            ReadAloudSentence(mark: String(first + $0.offset), text: $0.element)
        })
    }

    func testStartAsksForTheFirstBlockAndReadsFromIt() {
        let engine = FakeEngine()
        let controller = ReadAloudController(engine: engine, language: "en", lookahead: 2)
        var requests = 0, marks: [String] = []
        controller.requestNext = { requests += 1 }
        controller.mark = { marks.append($0) }
        var phases: [ReadAloudPhase] = []
        controller.onPhase = { phases.append($0) }

        controller.start()
        XCTAssertEqual(controller.phase, .starting)
        // The page sends the block holding the first sentence on screen,
        // from that sentence on (readaloud.js).
        controller.receive(block(["First on the page.", "Second.", "Third.", "Fourth."]))
        XCTAssertEqual(engine.texts, ["First on the page.", "Second.", "Third.", "Fourth."])
        XCTAssertEqual(requests, 0, "four sentences queued: no need for more yet")

        engine.startNext()
        XCTAssertEqual(marks, ["0"])
        XCTAssertEqual(controller.phase, .playing)
        XCTAssertEqual(phases, [.starting, .playing])
    }

    func testTheNextBlockIsAskedForWhileTwoSentencesRemain() {
        let engine = FakeEngine()
        let controller = ReadAloudController(engine: engine, language: "en", lookahead: 2)
        var requests = 0
        controller.requestNext = { requests += 1 }
        controller.start()
        controller.receive(block(["A.", "B.", "C.", "D."]))
        engine.startNext(); engine.finishCurrent() // A
        XCTAssertEqual(requests, 0)
        engine.startNext() // B: C and D still to come
        XCTAssertEqual(requests, 1)
        engine.finishCurrent()
        engine.startNext() // C: only D to come; already asked
        XCTAssertEqual(requests, 1, "asked once until the block arrives")
        controller.receive(block(["E.", "F."], from: 4))
        XCTAssertEqual(controller.pendingTexts, ["C.", "D.", "E.", "F."])
    }

    /// A book with nothing to read from here (a scanned PDF's pages are
    /// pictures) says so when it reaches the end; a book that was read to
    /// its end does not.
    func testReachingTheEndWithNothingReadIsReported() {
        let engine = FakeEngine()
        let controller = ReadAloudController(engine: engine, language: "en", lookahead: 2)
        var reported = 0
        controller.onNothingToRead = { reported += 1 }
        controller.requestNext = {}
        controller.start()
        controller.receive(ReadAloudBlock(language: nil, sentences: []))
        controller.endReached()
        XCTAssertEqual(controller.phase, .off)
        XCTAssertEqual(reported, 1)

        let read = ReadAloudController(engine: FakeEngine(), language: "en", lookahead: 2)
        read.onNothingToRead = { reported += 1 }
        read.requestNext = {}
        read.start()
        read.receive(block(["Last line."]))
        read.endReached()
        XCTAssertEqual(reported, 1)
    }

    func testReadingStopsAtTheEndOfTheBook() {
        let engine = FakeEngine()
        let controller = ReadAloudController(engine: engine, language: "en", lookahead: 2)
        controller.requestNext = {}
        controller.start()
        controller.receive(block(["Last line."]))
        controller.endReached()
        XCTAssertEqual(controller.phase, .starting)
        engine.startNext()
        XCTAssertEqual(controller.phase, .playing)
        engine.finishCurrent()
        XCTAssertEqual(controller.phase, .off)
        XCTAssertTrue(engine.stopped)
    }

    func testPauseAndResume() {
        let engine = FakeEngine()
        let controller = ReadAloudController(engine: engine, language: "en", lookahead: 2)
        controller.requestNext = {}
        controller.start()
        controller.receive(block(["One.", "Two.", "Three."]))
        engine.startNext()
        controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertTrue(engine.paused)
        controller.resume()
        XCTAssertEqual(controller.phase, .playing)
        XCTAssertFalse(engine.paused)
    }

    func testEachWordIsPassedOnWithItsSentencesPlace() {
        let engine = FakeEngine()
        let controller = ReadAloudController(engine: engine, language: "en", lookahead: 2)
        var words: [String] = []
        controller.requestNext = {}
        controller.markWord = { mark, start, length in words.append("\(mark):\(start)+\(length)") }
        controller.start()
        controller.receive(block(["Call me Ishmael.", "Some years ago."]))
        engine.startNext()
        engine.speakWord(NSRange(location: 0, length: 4))
        engine.speakWord(NSRange(location: 8, length: 7))
        engine.finishCurrent()
        engine.startNext()
        engine.speakWord(NSRange(location: 5, length: 5))
        XCTAssertEqual(words, ["0:0+4", "0:8+7", "1:5+5"])
    }

    /// The lock screen's next and previous: a sentence forward, or back to
    /// the one heard before; reading goes on from there.
    func testSkippingForwardAndBackASentence() {
        let engine = FakeEngine()
        let controller = ReadAloudController(engine: engine, language: "en", lookahead: 1)
        controller.requestNext = {}
        controller.start()
        controller.receive(block(["One.", "Two.", "Three.", "Four."]))
        engine.startNext()
        engine.finishCurrent() // "One." heard
        engine.startNext()     // "Two." being read
        controller.skip(by: 1)
        XCTAssertTrue(engine.stopped)
        XCTAssertEqual(engine.queue.map(\.text), ["Three.", "Four."], "on from the next sentence")
        engine.startNext()     // "Three."
        controller.skip(by: -1)
        XCTAssertEqual(engine.queue.map(\.text), ["One.", "Three.", "Four."],
                       "back to the sentence heard last (\"Two.\" was skipped, never heard)")
        XCTAssertEqual(controller.phase, .starting)
    }

    /// The lock screen's next and previous move a paragraph at a time in a
    /// book (the reader asked, 24 Nov 2026): next goes on from the next
    /// paragraph; previous goes back to the start of this one, or to the one
    /// before when this one has only just begun.
    func testSkippingForwardAndBackAParagraph() {
        let engine = FakeEngine()
        let controller = ReadAloudController(engine: engine, language: "en", lookahead: 1)
        controller.requestNext = {}
        controller.start()
        controller.receive(block(["A1.", "A2."]))
        controller.receive(block(["B1.", "B2.", "B3."]))
        controller.receive(block(["C1."]))
        engine.startNext()
        engine.finishCurrent() // "A1." heard
        engine.startNext()     // "A2." being read
        controller.skipParagraph(by: 1)
        XCTAssertEqual(engine.queue.map(\.text), ["B1.", "B2.", "B3.", "C1."], "on from the next paragraph")
        engine.startNext()
        engine.finishCurrent() // "B1." heard
        engine.startNext()     // "B2." being read
        controller.skipParagraph(by: -1)
        XCTAssertEqual(engine.queue.map(\.text), ["B1.", "B2.", "B3.", "C1."], "back to this paragraph's start")
        engine.startNext()     // "B1." being read, nothing of B heard
        controller.skipParagraph(by: -1)
        XCTAssertEqual(engine.queue.map(\.text).first, "A1.", "at a paragraph's start: the one before")
    }

    /// A PDF's blocks are not paragraphs: next and previous move a sentence.
    func testInAPDFSkippingMovesASentence() {
        let engine = FakeEngine()
        let controller = ReadAloudController(engine: engine, language: "en", lookahead: 1)
        controller.requestNext = {}
        controller.start()
        var pdfBlock = block(["One.", "Two.", "Three."])
        pdfBlock.isParagraph = false
        controller.receive(pdfBlock)
        engine.startNext()
        controller.skipParagraph(by: 1)
        XCTAssertEqual(engine.queue.map(\.text), ["Two.", "Three."])
    }

    func testBlocksWithNothingToReadAreSkipped() {
        let engine = FakeEngine()
        let controller = ReadAloudController(engine: engine, language: "en", lookahead: 2)
        var requests = 0
        controller.requestNext = { requests += 1 }
        controller.start()
        controller.receive(ReadAloudBlock(language: nil, sentences: []))
        XCTAssertEqual(requests, 1, "an empty block asks for the next at once")
    }
}

/// A speech engine that speaks when told to, for the tests.
// MARK: - Pictures between the words

/// Read aloud stays a moment on a page with only a picture on it, then
/// reads on (asked for 27 Nov 2026; readaloud.js sends the pictures).
@MainActor
final class ReadAloudPictureTests: XCTestCase {
    private func picture(_ mark: String) -> ReadAloudSentence { ReadAloudSentence(mark: mark, text: "", isPicture: true) }
    private func words(_ mark: String, _ text: String) -> ReadAloudSentence { ReadAloudSentence(mark: mark, text: text) }

    private func controller(_ engine: FakeEngine) -> ReadAloudController {
        let controller = ReadAloudController(engine: engine, language: "en", lookahead: 2, lingerTime: 0.2, answerTimeout: 0.5)
        controller.requestNext = {}
        return controller
    }

    private func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    func testAPicturePageIsStayedOnThenReadingGoesOn() async {
        let engine = FakeEngine()
        let controller = controller(engine)
        var shown: [String] = []
        controller.showPicture = { mark, answer in shown.append(mark); answer(true) }
        controller.start()
        controller.receive(ReadAloudBlock(language: "en", sentences: [words("a", "Before the plate."), picture("plate"),
                                                                       words("b", "After the plate.")]))
        // Only the words before the picture go to the voice.
        XCTAssertEqual(engine.texts, ["Before the plate."])
        engine.startNext()
        engine.finishCurrent()
        XCTAssertEqual(shown, ["plate"], "the page turns to the picture")
        await wait(0.05)
        XCTAssertEqual(engine.texts, ["Before the plate."], "still on the picture page")
        XCTAssertEqual(controller.phase, .playing)
        await wait(0.4)
        XCTAssertEqual(engine.texts, ["Before the plate.", "After the plate."], "then on to the words after it")
    }

    func testAPictureBesideWordsIsPassedStraightOver() async {
        let engine = FakeEngine()
        let controller = controller(engine)
        controller.showPicture = { _, answer in answer(false) }
        controller.start()
        controller.receive(ReadAloudBlock(language: "en", sentences: [words("a", "One."), picture("pic"), words("b", "Two.")]))
        engine.startNext()
        engine.finishCurrent()
        await wait(0.05)
        XCTAssertEqual(engine.texts, ["One.", "Two."])
    }

    func testStartingOnAPicturePageStaysOnItFirst() async {
        let engine = FakeEngine()
        let controller = controller(engine)
        var shown: [String] = []
        controller.showPicture = { mark, answer in shown.append(mark); answer(true) }
        controller.start()
        controller.receive(ReadAloudBlock(language: "en", sentences: [picture("cover")]))
        controller.receive(ReadAloudBlock(language: "en", sentences: [words("a", "Chapter One.")]))
        XCTAssertEqual(shown, ["cover"])
        XCTAssertEqual(engine.texts, [], "nothing read while the cover is shown")
        await wait(0.4)
        XCTAssertEqual(engine.texts, ["Chapter One."])
    }

    func testNoAnswerFromThePageReadsOn() async {
        let engine = FakeEngine()
        let controller = controller(engine)
        controller.showPicture = { _, _ in } // the page asleep (the app in the background)
        controller.start()
        controller.receive(ReadAloudBlock(language: "en", sentences: [picture("plate"), words("a", "After.")]))
        XCTAssertEqual(engine.texts, [])
        await wait(0.7)
        XCTAssertEqual(engine.texts, ["After."])
    }

    func testPausedOnAPictureReadingGoesOnAtResume() async {
        let engine = FakeEngine()
        let controller = controller(engine)
        controller.showPicture = { _, answer in answer(true) }
        controller.start()
        controller.receive(ReadAloudBlock(language: "en", sentences: [picture("plate"), words("a", "After.")]))
        controller.pause()
        await wait(0.4)
        XCTAssertEqual(engine.texts, [], "paused: still on the picture")
        controller.resume()
        XCTAssertEqual(engine.texts, ["After."])
    }

    func testSkippingPassesOverPictures() {
        let engine = FakeEngine()
        let controller = controller(engine)
        controller.showPicture = { _, _ in }
        controller.start()
        controller.receive(ReadAloudBlock(language: "en", sentences: [words("a", "One."), picture("plate"),
                                                                       words("b", "Two."), words("c", "Three.")]))
        engine.startNext()
        controller.skip(by: 1)
        XCTAssertEqual(controller.pendingTexts, ["Two.", "Three."])
        XCTAssertEqual(Array(engine.texts.suffix(2)), ["Two.", "Three."])
    }

    func testABookOfPicturesAloneHasNothingToRead() {
        let engine = FakeEngine()
        let controller = controller(engine)
        var nothing = 0
        controller.onNothingToRead = { nothing += 1 }
        controller.showPicture = { _, answer in answer(false) }
        controller.start()
        controller.endReached()
        XCTAssertEqual(nothing, 1)
    }
}

@MainActor
private final class FakeEngine: SpeechEngine {
    var onStart: ((Int) -> Void)?
    var onFinish: ((Int) -> Void)?
    var onWord: ((Int, NSRange) -> Void)?
    var speed: Double = 1
    private(set) var queue: [(id: Int, text: String)] = []
    private(set) var texts: [String] = []
    private var current: Int?
    private(set) var paused = false
    private(set) var stopped = false

    func enqueue(_ sentences: [(id: Int, text: String)], language: String) {
        queue += sentences
        texts += sentences.map(\.text)
    }

    func startNext() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next.id
        onStart?(next.id)
    }

    func speakWord(_ range: NSRange) {
        if let current { onWord?(current, range) }
    }

    func finishCurrent() {
        guard let current else { return }
        self.current = nil
        onFinish?(current)
    }

    func pause() { paused = true }
    func resume() { paused = false }
    func stop() { stopped = true; queue.removeAll() }
}
