import XCTest

/// Tests of the natural voice's text side (Shared/Kokoro): words into
/// Kokoro's symbols and numbers, without the model.
final class KokoroTextTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("KokoroTextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A tiny pack: two words in Misaki's lexicons, a few in CMUdict,
        // and the symbols Kokoro knows.
        let gold = #"{"hello": "həlˈO", "world": "wˈɜɹld", "the": "ðə"}"#
        let goldGB = #"{"hello": "həlˈQ", "world": "wˈɜːld", "the": "ðə"}"#
        for (name, json) in [("us_gold", gold), ("gb_gold", goldGB), ("us_silver", "{}"), ("gb_silver", "{}")] {
            try json.write(to: folder.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
        }
        try """
        ;;; a comment
        quixote K IY0 HH OW1 T IY0
        quixote(2) K W IH1 K S AH0 T
        harbour HH AA1 R B ER0
        walk W AO1 K
        """.write(to: folder.appendingPathComponent("cmudict.dict"), atomically: true, encoding: .utf8)
        let symbols = Set("həlˈOwɜɹdðəQːkiItɪsʌbɑɔWAYuæɛʊŋɡʃʒʤʧθvzjmnpfˌᵻ ,.!?")
        let vocab = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { (String($0.element), $0.offset + 1) })
        let config = try JSONSerialization.data(withJSONObject: ["vocab": vocab])
        try config.write(to: folder.appendingPathComponent("config.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCMUSoundsBecomeKokorosSymbols() {
        XCTAssertEqual(KokoroFallback.symbols("HH AH0 L OW1", british: false), "həlˈO")
        XCTAssertEqual(KokoroFallback.symbols("W AO1 K", british: false), "wˈɔk")
        // British: "go" is Q, long vowels marked, and no R before a consonant.
        XCTAssertEqual(KokoroFallback.symbols("HH AA1 R B ER0", british: true), "hˈɑːbə")
        XCTAssertEqual(KokoroFallback.symbols("G OW1", british: true), "ɡˈQ")
        XCTAssertEqual(KokoroFallback.symbols("R EH1 D", british: true), "ɹˈɛd")
    }

    func testTheFallbackUsesTheDictionaryThenEndingsThenSpellsAcronyms() {
        let fallback = KokoroFallback(dictionary: folder.appendingPathComponent("cmudict.dict"), british: false)
        XCTAssertEqual(fallback.pronounce("Quixote").0, "kihˈOti", "the first pronunciation, not the (2)")
        XCTAssertEqual(fallback.pronounce("walking").0, "wˈɔkɪŋ")
        XCTAssertEqual(fallback.pronounce("walked").0, "wˈɔkd")
        XCTAssertEqual(fallback.pronounce("BBC").0, "bˈi bˈi sˈi")
        XCTAssertNotNil(fallback.pronounce("Zxqwv").0, "an unknown word is still said, by the spelling rules")
        XCTAssertNil(fallback.pronounce("~").0, "nothing to say without letters")
    }

    /// Words no dictionary has are said by English spelling rules, as a
    /// reader would guess them (the reader asked: never left out).
    func testUnknownNamesAreSaidByTheSpellingRules() {
        XCTAssertEqual(KokoroLetterRules.arpabet("Grubach"), "G R UW1 B AA0 K")
        XCTAssertEqual(KokoroLetterRules.arpabet("Feckle"), "F EH1 K AH0 L")
        XCTAssertEqual(KokoroLetterRules.arpabet("Grannitt"), "G R AE1 N IH0 T")
        XCTAssertEqual(KokoroLetterRules.arpabet("Dorchin"), "D AO1 R CH IH0 N")
        XCTAssertNil(KokoroLetterRules.arpabet("1234"))
    }

    /// Accents, the other spelling, possessives and compounds find the
    /// dictionary before the rules are needed.
    func testTheDictionaryIsTriedInOtherForms() {
        let fallback = KokoroFallback(dictionary: folder.appendingPathComponent("cmudict.dict"), british: false)
        XCTAssertEqual(fallback.arpabet(for: "Wálk"), "W AO1 K", "accents folded")
        XCTAssertEqual(fallback.arpabet(for: "harbor"), "HH AA1 R B ER0", "American spelling of a British entry")
        XCTAssertEqual(fallback.arpabet(for: "Quixote’s"), "K IY0 HH OW1 T IY0 Z", "a possessive, with a curly apostrophe")
        XCTAssertEqual(fallback.arpabet(for: "walkharbour"), "W AO1 K HH AA2 R B ER0", "two known words")
    }

    func testTheTokenizerWrapsInZerosAndDropsUnknownSymbols() {
        let tokenizer = KokoroTokenizer(vocab: ["h": 50, "ə": 83, "❓": 1])
        XCTAssertEqual(tokenizer.encode("hə"), [0, 50, 83, 0])
        XCTAssertEqual(tokenizer.encode("h?ə"), [0, 50, 83, 0])
    }

    func testLongSentencesAreSplitAtPausesWithinTheLimit() {
        let text = String(repeating: "abc ", count: 30) + "def, " + String(repeating: "ghi ", count: 30)
        let pieces = KokoroText.split(text, limit: 140)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 140 })
        XCTAssertTrue(pieces[0].hasSuffix("def,"), "split at the comma, the last pause before the limit")
        XCTAssertEqual(pieces.joined(separator: " ").filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace })
    }

    func testMisakiReadsFromThePackAndFallsBackToTheDictionary() throws {
        let american = try XCTUnwrap(KokoroText(pack: folder, british: false))
        let phonemes = american.phonemes("Hello world, walk.")
        XCTAssertTrue(phonemes.contains("həlˈO"), phonemes)
        XCTAssertTrue(phonemes.contains("wˈɜɹld"), phonemes)
        XCTAssertTrue(phonemes.contains("wˈɔk"), "walk comes from CMUdict: \(phonemes)")
        let british = try XCTUnwrap(KokoroText(pack: folder, british: true))
        XCTAssertTrue(british.phonemes("Hello").contains("həlˈQ"))
        let tokens = american.tokens("Hello world.")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].first, 0)
        XCTAssertEqual(tokens[0].last, 0)
    }

    /// "a" is the article ("ɐ", "uh"), not the letter's name ("ˈA"), even
    /// when Apple's tagger gives it no word class (as on an iPhone).
    func testTheArticleASoundsLikeUh() throws {
        let text = try XCTUnwrap(KokoroText(pack: folder, british: false))
        XCTAssertEqual(text.phonemes("A hello."), "ɐ həlˈO.")
        XCTAssertTrue(text.phonemes("hello a world").contains("ɐ wˈɜɹld"))
    }

    /// A hyphen inside a word ("hello-world") joins its parts with a plain
    /// word gap, not the long pause of a dash ("—"), which the reader heard
    /// at every hyphenated word (24 Nov 2026). A real dash keeps its pause.
    func testAHyphenInAWordIsNoPause() throws {
        let text = try XCTUnwrap(KokoroText(pack: folder, british: false))
        let joined = text.phonemes("hello-world")
        XCTAssertFalse(joined.contains("—"), joined)
        XCTAssertTrue(joined.contains("həlˈO wˈɜɹld"), joined)
        XCTAssertTrue(text.phonemes("hello — world").contains("—"))
    }

    /// Each word's place in the sentence, and the token its sounds start
    /// at, for the underline: punctuation is no word, and the places count
    /// UTF-16 units, as the page does.
    func testPiecesKnowWhereTheirWordsAre() throws {
        let text = try XCTUnwrap(KokoroText(pack: folder, british: false))
        let sentence = "“Hello,” world."
        let pieces = text.pieces(sentence)
        XCTAssertEqual(pieces.count, 1)
        let words = pieces[0].words.map { (sentence as NSString).substring(with: $0.range) }
        XCTAssertEqual(words, ["Hello", "world"])
        // "Hello" starts at the first token after the 0; "world" after
        // "həlˈO", its comma and space (the quotation marks are not sounds).
        XCTAssertEqual(pieces[0].words.first?.token, 1)
        let world = try XCTUnwrap(pieces[0].words.last?.token)
        let config = try XCTUnwrap(KokoroTokenizer(configURL: folder.appendingPathComponent("config.json")))
        XCTAssertEqual(pieces[0].tokens[world], config.id("w"))
    }

    func testALongSentenceIsReadInPiecesThatKeepTheirWords() throws {
        let text = try XCTUnwrap(KokoroText(pack: folder, british: false))
        let sentence = Array(repeating: "hello world", count: 20).joined(separator: ", ") + "."
        let pieces = text.pieces(sentence)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.tokens.count <= KokoroText.pieceSymbols + 2 })
        XCTAssertEqual(pieces.map(\.words.count).reduce(0, +), 40, "every word in exactly one piece")
    }

    /// Words begin where Kokoro's durations put their first sound: a
    /// duration frame is 600 samples, and the 0 at the start has one too.
    func testWordsBeginAtTheirFirstSoundsFrame() {
        let piece = KokoroPiece(tokens: [0, 5, 6, 1, 7, 0],
                                words: [.init(token: 1, range: NSRange(location: 0, length: 2)),
                                        .init(token: 4, range: NSRange(location: 3, length: 1))])
        let starts = piece.wordStarts(durations: [2, 3, 4, 1, 5, 2], samplesPerFrame: 600)
        XCTAssertEqual(starts.map(\.sample), [2 * 600, (2 + 3 + 4 + 1) * 600])
        XCTAssertEqual(starts.map(\.range), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 1)])
    }
}
