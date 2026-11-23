import Foundation

/// English text into Kokoro's input: Misaki's pronunciations (the vendored
/// `EnglishG2P`), with `KokoroFallback` for words its lexicons lack, then
/// `KokoroTokenizer` for the model's numbers. Everything it reads comes from
/// the voice pack's folder (docs/read-aloud.md).
final class KokoroText {
    /// Kokoro takes at most 510 symbols at once (plus a 0 at each end).
    static let maxSymbols = 510

    let british: Bool
    private let g2p: EnglishG2P
    private let tokenizer: KokoroTokenizer

    /// `pack`: the voice pack's folder. Nil if its files cannot be read.
    init?(pack: URL, british: Bool) {
        guard let tokenizer = KokoroTokenizer(configURL: pack.appendingPathComponent("config.json")) else { return nil }
        self.british = british
        self.tokenizer = tokenizer
        let fallback = KokoroFallback(dictionary: pack.appendingPathComponent("cmudict.dict"), british: british)
        g2p = EnglishG2P(british: british, lexicons: pack, fallback: { fallback.pronounce($0.text) })
    }

    /// A sentence's sounds, in Kokoro's symbols.
    func phonemes(_ text: String) -> String {
        g2p.phonemize(text: text).0
    }

    /// A sentence as Kokoro's input: one list of token numbers per piece.
    func tokens(_ text: String) -> [[Int64]] {
        pieces(text).map(\.tokens)
    }

    /// The most sounds read in one piece: about ten seconds of speech.
    /// Kokoro itself takes up to 510, but its memory grows with the length
    /// of a piece (about 15 MB a second), and a shorter first piece starts
    /// reading sooner. Longer sentences are split at a pause.
    static let pieceSymbols = 130

    /// A sentence as Kokoro's input, in pieces of at most `pieceSymbols`
    /// sounds (split at the last pause before that, else at a space), each
    /// with where its words begin: the token each word's sounds start at
    /// and the word's place in `text` (UTF-16, as the page's underline takes
    /// it). Kokoro's durations for the tokens then say when each word is
    /// spoken.
    func pieces(_ text: String) -> [KokoroPiece] {
        let (phonemes, words) = g2p.phonemize(text: text)
        let symbols = Array(phonemes)
        // Which word each sound belongs to (an index into `ranges`), found by
        // walking Misaki's tokens, whose sounds and spaces make up the string
        // in order; -1 for spaces and punctuation.
        var owner = [Int](repeating: -1, count: symbols.count)
        var ranges: [NSRange] = []
        let sentence = text as NSString
        var searchFrom = 0, position = 0
        for word in words {
            let sounds = (word.phonemes ?? g2p.unk).count
            let found = sentence.range(of: word.text, options: [],
                                       range: NSRange(location: searchFrom, length: sentence.length - searchFrom))
            if found.location != NSNotFound {
                searchFrom = found.location + found.length
                if sounds > 0, word.text.contains(where: { $0.isLetter || $0.isNumber }) {
                    ranges.append(found)
                    for i in position..<min(position + sounds, symbols.count) { owner[i] = ranges.count - 1 }
                }
            }
            position += sounds + word.whitespace.count
        }
        return Self.splitRanges(symbols, limit: Self.pieceSymbols).compactMap { span in
            var tokens: [Int64] = [0]
            var marks: [KokoroPiece.Word] = []
            var last = -1
            for i in span {
                guard let id = tokenizer.id(symbols[i]) else { continue }
                if owner[i] >= 0, owner[i] != last {
                    marks.append(KokoroPiece.Word(token: tokens.count, range: ranges[owner[i]]))
                    last = owner[i]
                }
                tokens.append(id)
            }
            tokens.append(0)
            return tokens.count > 2 ? KokoroPiece(tokens: tokens, words: marks) : nil
        }
    }

    /// Splits a string of sounds into pieces of at most `limit` symbols, at
    /// the last pause (punctuation) before the limit, else the last space.
    static func split(_ phonemes: String, limit: Int) -> [String] {
        let symbols = Array(phonemes)
        return splitRanges(symbols, limit: limit).map { String(symbols[$0]) }
    }

    /// `split`, as ranges of `symbols`, without spaces at either end.
    static func splitRanges(_ symbols: [Character], limit: Int) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = 0
        func add(_ range: Range<Int>) {
            var lower = range.lowerBound, upper = range.upperBound
            while lower < upper, symbols[lower].isWhitespace { lower += 1 }
            while upper > lower, symbols[upper - 1].isWhitespace { upper -= 1 }
            if lower < upper { pieces.append(lower..<upper) }
        }
        while symbols.count - start > limit {
            let window = start..<(start + limit)
            let cut = window.last(where: { ".,;:!?—…".contains(symbols[$0]) }).map { $0 + 1 }
                ?? window.last(where: { symbols[$0] == " " })
                ?? window.upperBound
            add(start..<cut)
            start = cut
            while start < symbols.count, symbols[start] == " " { start += 1 }
        }
        add(start..<symbols.count)
        return pieces
    }
}

/// One piece of a sentence for Kokoro: its tokens (with the 0 at each end),
/// and the words in it.
struct KokoroPiece {
    struct Word: Equatable {
        /// The token the word's sounds begin at.
        let token: Int
        /// Where the word is in the sentence (UTF-16).
        let range: NSRange
    }
    let tokens: [Int64]
    let words: [Word]

    /// When each word begins, in samples from the piece's start, given
    /// Kokoro's duration (in frames) for each token.
    func wordStarts(durations: [Int], samplesPerFrame: Int) -> [(sample: Int, range: NSRange)] {
        var starts: [Int] = [0]
        for d in durations { starts.append(starts[starts.count - 1] + d) }
        return words.compactMap { word in
            word.token < starts.count ? (starts[word.token] * samplesPerFrame, word.range) : nil
        }
    }
}

/// Kokoro's symbols as numbers (`vocab` in the model's config.json).
struct KokoroTokenizer {
    private let vocab: [Character: Int64]

    init?(configURL: URL) {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vocab = json["vocab"] as? [String: Int] else { return nil }
        var table: [Character: Int64] = [:]
        for (symbol, id) in vocab { if let c = symbol.first, symbol.count == 1 { table[c] = Int64(id) } }
        self.vocab = table
    }

    init(vocab: [Character: Int64]) { self.vocab = vocab }

    /// The numbers for a string of sounds, with the model's 0 at each end;
    /// symbols it does not know are left out.
    func encode(_ phonemes: String) -> [Int64] {
        [0] + phonemes.compactMap { vocab[$0] } + [0]
    }

    /// One symbol's number, if Kokoro knows it.
    func id(_ symbol: Character) -> Int64? { vocab[symbol] }
}

/// Pronounces words Misaki's lexicons lack, without a neural network (and
/// without eSpeak, which is GPL): the CMU Pronouncing Dictionary (BSD), its
/// ARPAbet turned into Kokoro's symbols; failing that, the word without a
/// common ending ("-s", "-ed", "-ing"…) and the ending's sound; a short word
/// in capitals is spelt out letter by letter (an acronym); anything else is
/// left unsaid rather than guessed.
final class KokoroFallback {
    let british: Bool
    private let dictionaryURL: URL
    private lazy var dictionary: [String: String] = Self.load(dictionaryURL)

    init(dictionary: URL, british: Bool) {
        dictionaryURL = dictionary
        self.british = british
    }

    /// Misaki's fallback answer: the sounds and a rating (1, as Misaki
    /// rates its own fallback), or nil.
    func pronounce(_ word: String) -> (String?, Int?) {
        let lower = word.lowercased()
        if let arpabet = dictionary[lower] { return (Self.symbols(arpabet, british: british), 1) }
        for (ending, sound) in Self.endings where lower.hasSuffix(ending) && lower.count > ending.count + 2 {
            let stem = String(lower.dropLast(ending.count))
            if let arpabet = dictionary[stem] ?? dictionary[stem + "e"] {
                return (Self.symbols(arpabet, british: british) + sound, 1)
            }
        }
        let letters = word.filter(\.isLetter)
        if !letters.isEmpty, letters.count <= 5, letters == letters.uppercased() {
            return (letters.compactMap { Self.letterNames[$0] }.joined(separator: " "), 1)
        }
        return (nil, nil)
    }

    private static let endings: [(String, String)] = [
        ("'s", "z"), ("s", "z"), ("es", "ᵻz"), ("ed", "d"), ("ing", "ɪŋ"), ("ly", "li"), ("er", "əɹ"), ("est", "ᵻst"),
    ]

    /// The names of the letters, for spelling out an acronym.
    static let letterNames: [Character: String] = [
        "A": "ˈA", "B": "bˈi", "C": "sˈi", "D": "dˈi", "E": "ˈi", "F": "ˈɛf", "G": "ʤˈi", "H": "ˈAʧ", "I": "ˈI",
        "J": "ʤˈA", "K": "kˈA", "L": "ˈɛl", "M": "ˈɛm", "N": "ˈɛn", "O": "ˈO", "P": "pˈi", "Q": "kjˈu", "R": "ˈɑɹ",
        "S": "ˈɛs", "T": "tˈi", "U": "jˈu", "V": "vˈi", "W": "dˈʌbᵊljˌu", "X": "ˈɛks", "Y": "wˈI", "Z": "zˈi",
    ]

    /// "HH AH0 L OW1" as Kokoro's symbols ("həlˈO"): each stress mark goes
    /// just before its vowel, as Misaki writes them.
    static func symbols(_ arpabet: String, british: Bool) -> String {
        var out = ""
        let phones = arpabet.split(separator: " ").map(String.init)
        for (index, phone) in phones.enumerated() {
            var base = phone
            var stress = ""
            if let last = base.last, last.isNumber {
                stress = last == "1" ? "ˈ" : (last == "2" ? "ˌ" : "")
                base.removeLast()
                if base == "AH" && last == "0" { out += "ə"; continue }
                if base == "ER" {
                    // British English is non-rhotic: "bird" /bɜːd/, "-er" /ə/.
                    if british { out += last == "0" ? "ə" : stress + "ɜː" } else { out += last == "0" ? "əɹ" : stress + "ɜɹ" }
                    continue
                }
            }
            if let vowel = vowels[base] {
                out += stress + (british ? (britishVowels[base] ?? vowel) : vowel)
            } else if base == "R", british {
                // An R is only sounded before a vowel ("red", not "car").
                let next = index + 1 < phones.count ? phones[index + 1] : ""
                if next.last?.isNumber == true { out += "ɹ" }
            } else if let consonant = consonants[base] {
                out += consonant
            }
        }
        return out
    }

    private static let vowels: [String: String] = [
        "AA": "ɑ", "AE": "æ", "AH": "ʌ", "AO": "ɔ", "AW": "W", "AY": "I", "EH": "ɛ", "EY": "A", "IH": "ɪ",
        "IY": "i", "OW": "O", "OY": "Y", "UH": "ʊ", "UW": "u",
    ]
    /// Misaki's British symbols where they differ ("go" is /əʊ/, "Q").
    private static let britishVowels: [String: String] = ["OW": "Q", "AA": "ɑː", "AO": "ɔː", "IY": "iː", "UW": "uː"]
    private static let consonants: [String: String] = [
        "B": "b", "CH": "ʧ", "D": "d", "DH": "ð", "F": "f", "G": "ɡ", "HH": "h", "JH": "ʤ", "K": "k", "L": "l",
        "M": "m", "N": "n", "NG": "ŋ", "P": "p", "R": "ɹ", "S": "s", "SH": "ʃ", "T": "t", "TH": "θ", "V": "v",
        "W": "w", "Y": "j", "Z": "z", "ZH": "ʒ",
    ]

    /// cmudict.dict: "word AH0 B AW1 T", alternatives as "word(2) …"; the
    /// first pronunciation of each word is kept.
    private static func load(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var table: [String: String] = [:]
        table.reserveCapacity(140_000)
        for line in text.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let word = line[..<space]
            if word.hasSuffix(")") { continue } // an alternative
            var pron = line[line.index(after: space)...]
            if let hash = pron.firstIndex(of: "#") { pron = pron[..<hash] }
            table[String(word)] = pron.trimmingCharacters(in: .whitespaces)
        }
        return table
    }
}
