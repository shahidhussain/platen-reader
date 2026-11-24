import Foundation
import NaturalLanguage

// Read aloud: the parts both apps share (docs/read-aloud.md). The shell
// supplies the text a block at a time (readaloud.js); a `SpeechEngine`
// speaks it; `ReadAloudController` keeps the two in step.

/// One sentence to read, with the name of its mark in the page (to
/// highlight it). A PDF's sentences have no mark.
struct ReadAloudSentence: Equatable, Sendable {
    var mark: String?
    var text: String
}

/// A block of the book (a paragraph, a heading) as the shell sends it.
struct ReadAloudBlock: Equatable, Sendable {
    /// The block's own language, if the book marks it (`xml:lang`).
    var language: String?
    var sentences: [ReadAloudSentence]
}

/// What can be read aloud: a book (`BookSession`) or a PDF (`PDFReadAloud`).
/// Each app's reader starts and steers it from the speaker button; it gives
/// the voice its sentences and the page its marks.
@MainActor
protocol ReadAloudSource: AnyObject {
    /// Ready to read (the first page is on screen).
    var canReadAloud: Bool { get }
    /// The language to read in.
    var readAloudLanguage: String { get }
    /// Starts reading from the first sentence on the page on screen.
    func startReadAloud(engine: SpeechEngine)
    func pauseReadAloud()
    func resumeReadAloud()
    func stopReadAloud()
    /// Skips a sentence forward (1) or back (-1).
    func skipReadAloud(by delta: Int)
    /// The reader moved the page themselves: the page stops following the
    /// voice (no turning back to the sentence still being spoken) until
    /// reading starts again.
    func holdReadAloudPage()
}

/// What read aloud is doing, for the speaker button.
enum ReadAloudPhase: Equatable, Sendable {
    case off
    /// Started, waiting for the first words (text from the page, or the
    /// voice getting ready).
    case starting
    case playing
    case paused
}

/// The reader's choice of voice for English books, made in the dialog on
/// the first tap of the speaker button, or in Settings.
enum ReadAloudVoiceChoice: String, CaseIterable, Sendable {
    /// Not chosen yet: the first tap asks.
    case undecided
    /// Apple's voices.
    case apple
    /// The downloaded natural voice (Kokoro).
    case kokoro
}

/// Which engine reads a book.
enum SpeechEngineKind: Equatable, Sendable {
    /// Apple's voices, for this language.
    case apple(language: String)
    /// The downloaded natural voice (English only).
    case kokoro
    /// Ask the reader first (an English book, no choice made yet, and the
    /// natural voice can be offered).
    case askFirst(language: String)
}

// MARK: - Choosing the engine

enum SpeechEngineChooser {
    /// The language to read a book in: the book's own (`dc:language`), else
    /// the language of its text, else English. A book in several languages
    /// is read in the book's own (the spec: "Mixed-language books: use the
    /// book's language").
    static func language(book: String?, text: String?) -> String {
        if let book = normalised(book) { return book }
        if let text, !text.isEmpty {
            let recogniser = NLLanguageRecognizer()
            recogniser.processString(String(text.prefix(2000)))
            if let found = recogniser.dominantLanguage, found != .undetermined { return found.rawValue }
        }
        return "en"
    }

    /// "en_GB", "EN-gb" and the like as BCP 47 ("en-GB"); nil if empty.
    static func normalised(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty else { return nil }
        let parts = code.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        guard let first = parts.first else { return nil }
        let rest = parts.dropFirst().map { $0.count == 2 ? $0.uppercased() : String($0) }
        return ([first.lowercased()] + rest).joined(separator: "-")
    }

    static func isEnglish(_ language: String) -> Bool {
        language.lowercased() == "en" || language.lowercased().hasPrefix("en-")
    }

    /// The engine for a book in `language`, given the reader's `choice`,
    /// whether the natural voice can be offered on this device
    /// (`kokoroOffered`: a new enough system and device) and whether it is
    /// downloaded (`kokoroInstalled`).
    static func choose(language: String, choice: ReadAloudVoiceChoice,
                       kokoroOffered: Bool, kokoroInstalled: Bool) -> SpeechEngineKind {
        guard isEnglish(language), kokoroOffered else { return .apple(language: language) }
        switch choice {
        case .apple: return .apple(language: language)
        case .kokoro: return kokoroInstalled ? .kokoro : .askFirst(language: language)
        case .undecided: return .askFirst(language: language)
        }
    }
}

// MARK: - Apple's voices

/// An installed Apple voice, as `AVSpeechSynthesisVoice` describes it
/// (kept apart from AVFoundation so the choice can be tested).
struct AppleVoiceInfo: Equatable, Sendable {
    enum Quality: Int, Comparable, Sendable {
        case standard = 1, enhanced = 2, premium = 3
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }
    var identifier: String
    var name: String
    /// BCP 47, "en-GB".
    var language: String
    var quality: Quality
}

enum AppleVoices {
    /// The best installed voice for `language`: Premium, then Enhanced,
    /// then a default voice; among voices of the same quality, one for the
    /// book's own region ("en-GB"), then the reader's region, then any.
    /// `preferred`: a voice the reader chose in Settings, used if it speaks
    /// the language.
    static func best(for language: String, among voices: [AppleVoiceInfo], preferred: String? = nil,
                     readerRegion: String? = Locale.current.region?.identifier) -> AppleVoiceInfo? {
        let base = baseLanguage(language)
        let matching = voices.filter { baseLanguage($0.language) == base }
        if let preferred, let voice = matching.first(where: { $0.identifier == preferred }) { return voice }
        let bookRegion = region(of: language)
        func score(_ voice: AppleVoiceInfo) -> (Int, Int) {
            let region = region(of: voice.language)
            let regionScore = region != nil && region == bookRegion ? 2 : (region != nil && region == readerRegion ? 1 : 0)
            return (voice.quality.rawValue, regionScore)
        }
        return matching.max { a, b in
            let (qa, ra) = score(a), (qb, rb) = score(b)
            return qa != qb ? qa < qb : (ra != rb ? ra < rb : a.name > b.name)
        }
    }

    /// Whether only a default-quality voice is installed for `language`
    /// (then the reader is told better ones can be added in Settings).
    static func onlyStandard(for language: String, among voices: [AppleVoiceInfo]) -> Bool {
        let base = baseLanguage(language)
        return !voices.contains { baseLanguage($0.language) == base && $0.quality > .standard }
    }

    static func baseLanguage(_ code: String) -> String {
        String(code.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first ?? "")
    }

    static func region(of code: String) -> String? {
        let parts = code.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        return parts.dropFirst().first { $0.count == 2 }.map { $0.uppercased() }
    }
}

// MARK: - The engine

/// Something that speaks sentences in order: Apple's voices
/// (`AppleSpeechEngine`) or the natural voice. It reports each sentence as
/// it starts and finishes, on the main thread, by the id it was given.
@MainActor
protocol SpeechEngine: AnyObject {
    var onStart: ((Int) -> Void)? { get set }
    var onFinish: ((Int) -> Void)? { get set }
    /// A word about to be spoken: the sentence's id and the word's place in
    /// its text (UTF-16, as JavaScript counts). Engines without word timing
    /// never call it; the page then underlines the whole sentence.
    var onWord: ((Int, NSRange) -> Void)? { get set }
    /// Speaking speed: 1 is normal, 0.5 half, 2 twice.
    var speed: Double { get set }
    /// Adds sentences after those already queued.
    func enqueue(_ sentences: [(id: Int, text: String)], language: String)
    func pause()
    func resume()
    /// Stops at once and forgets the queue.
    func stop()
}

// MARK: - Keeping text and speech in step

/// Feeds the engine from the page: asks for the next block while a few
/// sentences are still to be spoken (so there is no pause between blocks),
/// highlights each sentence as it starts, and stops at the end of the book.
@MainActor
final class ReadAloudController {
    /// More text is asked for while this many sentences are still to be
    /// spoken. Many: iOS suspends the page in the background, so the queue
    /// in hand is what is read at the lock screen until the app is opened
    /// again (readaloud.js sends about 20 at a time).
    nonisolated static let lookahead = 40

    let engine: SpeechEngine
    /// The language to read in (the book's).
    let language: String
    private(set) var phase: ReadAloudPhase = .off {
        didSet { if phase != oldValue { onPhase?(phase) } }
    }
    var onPhase: ((ReadAloudPhase) -> Void)?
    /// Asks the page for the next block (it answers with `receive`).
    var requestNext: (() -> Void)?
    /// A sentence is starting: the page turns to it (and underlines it, if
    /// no word timing follows).
    var mark: ((String) -> Void)?
    /// A word is starting: the page underlines it (the sentence's place,
    /// and the word's start and length in the sentence's text).
    var markWord: ((String, Int, Int) -> Void)?
    /// Reading reached the end without a single sentence to speak (a
    /// scanned PDF: pictures of pages, with no text in them).
    var onNothingToRead: (() -> Void)?

    private var queued: [Int: ReadAloudSentence] = [:]
    private var order: [Int] = []
    private var nextID = 0
    private var awaitingBlock = false
    private var reachedEnd = false

    /// This controller's lookahead (`lookahead`, smaller in the tests).
    let lookaheadCount: Int

    init(engine: SpeechEngine, language: String, lookahead: Int = ReadAloudController.lookahead) {
        self.engine = engine
        self.language = language
        lookaheadCount = lookahead
        engine.onStart = { [weak self] id in self?.started(id) }
        engine.onFinish = { [weak self] id in self?.finished(id) }
        engine.onWord = { [weak self] id, range in
            guard let self, let mark = self.queued[id]?.mark else { return }
            self.markWord?(mark, range.location, range.length)
        }
    }

    /// Reading begins; the caller has asked the page for the first block.
    func start() {
        phase = .starting
        awaitingBlock = true
        reachedEnd = false
    }

    /// A block from the page.
    func receive(_ block: ReadAloudBlock) {
        guard phase != .off else { return }
        awaitingBlock = false
        let items = block.sentences.map { sentence -> (id: Int, text: String) in
            let id = nextID
            nextID += 1
            queued[id] = sentence
            order.append(id)
            return (id, sentence.text)
        }
        guard !items.isEmpty else { return askForMore() }
        engine.enqueue(items, language: language)
        if order.count <= lookaheadCount { askForMore() }
    }

    /// The page has nothing more (the end of the book).
    func endReached() {
        awaitingBlock = false
        reachedEnd = true
        guard order.isEmpty else { return }
        // Nothing was ever given to the voice: there is no text to read.
        let nothingRead = nextID == 0 && heard.isEmpty
        stop()
        if nothingRead { onNothingToRead?() }
    }

    func pause() {
        guard phase == .playing || phase == .starting else { return }
        engine.pause()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        engine.resume()
        phase = order.isEmpty ? .starting : .playing
    }

    func stop() {
        engine.stop()
        queued.removeAll()
        order.removeAll()
        heard.removeAll()
        awaitingBlock = false
        phase = .off
    }

    /// The sentences heard last (the latest at the end), for skipping back.
    private var heard: [(id: Int, sentence: ReadAloudSentence)] = []

    /// Skips forward a sentence (`by` 1, the lock screen's next) or back
    /// one (-1, previous: the sentence before the one being read). Reading
    /// goes on (or starts again, if paused) from there.
    func skip(by delta: Int) {
        guard phase != .off, !order.isEmpty || !heard.isEmpty else { return }
        engine.stop()
        if delta > 0 {
            if let current = order.first {
                order.removeFirst()
                queued[current] = nil
            }
        } else if let previous = heard.popLast() {
            queued[previous.id] = previous.sentence
            order.insert(previous.id, at: 0)
        }
        let items = order.compactMap { id in queued[id].map { (id: id, text: $0.text) } }
        guard !items.isEmpty else {
            if reachedEnd { stop() } else { phase = .starting; askForMore() }
            return
        }
        phase = .starting
        engine.enqueue(items, language: language)
        engine.resume()
        if order.count <= lookaheadCount { askForMore() }
    }

    /// The sentences queued and not yet finished, in order (for tests).
    var pendingTexts: [String] { order.compactMap { queued[$0]?.text } }

    private func askForMore() {
        guard !awaitingBlock, !reachedEnd, phase != .off else { return }
        awaitingBlock = true
        requestNext?()
    }

    private func started(_ id: Int) {
        guard let sentence = queued[id] else { return }
        if phase != .paused { phase = .playing }
        if let mark = sentence.mark { self.mark?(mark) }
        // Sentences after this one still to come; ask for more in time.
        if let index = order.firstIndex(of: id), order.count - index - 1 <= lookaheadCount { askForMore() }
    }

    private func finished(_ id: Int) {
        if let sentence = queued[id] {
            heard.append((id, sentence))
            if heard.count > 10 { heard.removeFirst() }
        }
        queued[id] = nil
        order.removeAll { $0 == id }
        if order.isEmpty {
            if reachedEnd { stop() } else if phase == .playing { phase = .starting; askForMore() }
        }
    }
}

// MARK: - The natural voice's availability

/// Whether the natural voice (Kokoro) can be offered on this device, and
/// whether it is downloaded (docs/read-aloud.md). Offered where the app can
/// download it (`downloadAvailable`, set by each app; from GitHub, "Hosting
/// the voice") on a device with the memory for it (`hasMemoryForIt`), or
/// where a pack is already installed.
enum KokoroVoice {
    /// Set by the app at launch: the voice pack can be downloaded here.
    nonisolated(unsafe) static var downloadAvailable = false

    /// Reading takes up to about 300 MB (the pronunciation lexicons, and the
    /// model's working memory for a piece of about ten seconds; the weights
    /// themselves are mapped from the file, not held); devices with 6 GB of
    /// memory or more (iPhone 13 Pro, iPhone 15 and later) keep that
    /// comfortably alongside the book (docs/read-aloud.md, Measurements).
    static var hasMemoryForIt: Bool { ProcessInfo.processInfo.physicalMemory >= 5_500_000_000 }

    static var isOffered: Bool { isInstalled || (downloadAvailable && hasMemoryForIt) }
    static var isInstalled: Bool { KokoroPack.installed != nil }

    /// The download's size (the dialog says it), and what it takes on the
    /// device once installed (Settings' Remove says it). From
    /// scripts/make-kokoro-pack.py: 81.8 MB zipped, 103.1 MB unpacked.
    static let downloadSize = Measurement(value: 82, unit: UnitInformationStorage.megabytes)
    static let installedSize = Measurement(value: 103, unit: UnitInformationStorage.megabytes)
}
