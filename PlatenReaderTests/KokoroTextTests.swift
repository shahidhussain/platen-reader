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
        XCTAssertNil(fallback.pronounce("Zxqwv").0, "an unknown word is left unsaid, not guessed")
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
}
