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
        g2p.phonemize(text: Self.spoken(text).text).0
    }

    /// The sentence as it is given to Misaki, and for each of its UTF-16
    /// units the place in the sentence it came from (so the underline still
    /// finds each word on the page):
    ///
    /// - A curly apostrophe (weren’t, human’s) becomes a straight one.
    ///   Misaki took the curly one for a word of its own, with no sound but
    ///   a space, so a little pause followed every such word (the reader
    ///   heard pauses "here and there", 25 Nov 2026).
    /// - "%" is said: "20%" is "20 percent". Misaki left it out.
    static func spoken(_ text: String) -> (text: String, origin: [Int]) {
        let units = Array(text.utf16)
        var out: [UInt16] = []
        var origin: [Int] = []
        out.reserveCapacity(units.count)
        let space = UInt16(UInt8(ascii: " "))
        for (i, unit) in units.enumerated() {
            switch unit {
            case 0x2019: // ’
                out.append(UInt16(UInt8(ascii: "'")))
                origin.append(i)
            case UInt16(UInt8(ascii: "%")):
                var word = Array("percent".utf16)
                if out.last.map({ $0 != space }) ?? false { word.insert(space, at: 0) }
                if i + 1 < units.count, let next = Unicode.Scalar(units[i + 1]),
                   CharacterSet.alphanumerics.contains(next) { word.append(space) }
                out += word
                origin += Array(repeating: i, count: word.count)
            default:
                out.append(unit)
                origin.append(i)
            }
        }
        return (String(decoding: out, as: UTF16.self), origin)
    }

    /// Words after which a long sentence is not split when it has to be
    /// split between words: a piece ending "…to promote a" left the voice
    /// hanging on the "a" (the reader heard it, 25 Nov 2026).
    static let joiningWords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "at", "by", "for", "with", "from", "into", "and", "or", "but",
        "nor", "as", "than", "that", "this", "these", "those", "my", "your", "his", "her", "its", "our", "their",
        "is", "was", "are", "were", "be", "been", "had", "has", "have", "would", "could", "should", "will", "can",
        "not", "no", "very", "so", "if", "who", "which", "whose", "i", "he", "she", "we", "they", "it", "you",
    ]

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
        let spoken = Self.spoken(text)
        let (phonemes, words) = g2p.phonemize(text: spoken.text)
        let symbols = Array(phonemes)
        // Which word each sound belongs to (an index into `ranges`), found by
        // walking Misaki's tokens, whose sounds and spaces make up the string
        // in order; -1 for spaces and punctuation.
        var owner = [Int](repeating: -1, count: symbols.count)
        var ranges: [NSRange] = []
        // Words are found in the text as given to Misaki, then put back on
        // the sentence (`spoken`'s origins).
        let sentence = spoken.text as NSString
        var searchFrom = 0, position = 0
        // Spaces right after a joining word ("a", "the"…), where a split
        // would leave the voice hanging.
        var avoid = Set<Int>()
        for word in words {
            let sounds = (word.phonemes ?? g2p.unk).count
            let found = sentence.range(of: word.text, options: [],
                                       range: NSRange(location: searchFrom, length: sentence.length - searchFrom))
            if found.location != NSNotFound {
                searchFrom = found.location + found.length
                if sounds > 0, word.text.contains(where: { $0.isLetter || $0.isNumber }) {
                    let start = spoken.origin[found.location]
                    let end = spoken.origin[found.location + found.length - 1] + 1
                    ranges.append(NSRange(location: start, length: end - start))
                    for i in position..<min(position + sounds, symbols.count) { owner[i] = ranges.count - 1 }
                }
            }
            if sounds > 0, Self.joiningWords.contains(word.text.lowercased()) { avoid.insert(position + sounds) }
            position += sounds + word.whitespace.count
        }
        return Self.splitRanges(symbols, limit: Self.pieceSymbols, avoiding: avoid).compactMap { span in
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
            let endsAtPause = span.last.map { Self.pauses.contains(symbols[$0]) } ?? false
            return tokens.count > 2 ? KokoroPiece(tokens: tokens, words: marks, endsAtPause: endsAtPause) : nil
        }
    }

    /// Splits a string of sounds into pieces of at most `limit` symbols, at
    /// the last pause (punctuation) before the limit, else the last space.
    static func split(_ phonemes: String, limit: Int) -> [String] {
        let symbols = Array(phonemes)
        return splitRanges(symbols, limit: limit).map { String(symbols[$0]) }
    }

    /// Punctuation the voice pauses at, where a sentence is best split.
    static let pauses: Set<Character> = Set(".,;:!?—…")

    /// How far over `pieceSymbols` a sentence may run and still be read in
    /// one piece: splitting one just over the limit (137 sounds) made a
    /// pause in the middle of it (25 Nov 2026).
    static let pieceSlack = 40

    /// `split`, as ranges of `symbols`, without spaces at either end. A
    /// split between words is not made at a space in `avoiding` (after a
    /// joining word), unless there is no other.
    static func splitRanges(_ symbols: [Character], limit: Int, avoiding: Set<Int> = []) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = 0
        func add(_ range: Range<Int>) {
            var lower = range.lowerBound, upper = range.upperBound
            while lower < upper, symbols[lower].isWhitespace { lower += 1 }
            while upper > lower, symbols[upper - 1].isWhitespace { upper -= 1 }
            if lower < upper { pieces.append(lower..<upper) }
        }
        while symbols.count - start > limit + pieceSlack {
            let window = start..<(start + limit)
            // At the last pause in the second half of the window, else
            // between words (not after a joining word), else anywhere.
            let half = start + limit / 2
            let cut = window.last(where: { $0 >= half && pauses.contains(symbols[$0]) }).map { $0 + 1 }
                ?? window.last(where: { symbols[$0] == " " && !avoiding.contains($0) })
                ?? window.last(where: { pauses.contains(symbols[$0]) }).map { $0 + 1 }
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
    /// Whether the piece ends at punctuation (so a pause after it is
    /// natural), rather than between two words.
    var endsAtPause = false

    /// A sentence's pieces, once spoken, joined into one sound. Each piece
    /// Kokoro makes starts with about 0.4 s of silence and ends with about
    /// 0.6 s, right for a sentence on its own but over a second of silence
    /// in the middle of one split in two (the reader heard it, 25 Nov 2026).
    /// Between pieces, the silence is cut to a short pause at punctuation
    /// (`pauseGap`), or a word's gap elsewhere (`wordGap`); the sentence
    /// keeps its own silence at either end. Each word's start moves with
    /// its sound.
    static func join(_ parts: [(samples: [Float], words: [(sample: Int, range: NSRange)], endsAtPause: Bool)])
        -> (samples: [Float], words: [(sample: Int, range: NSRange)]) {
        var samples: [Float] = []
        var words: [(sample: Int, range: NSRange)] = []
        for (index, part) in parts.enumerated() {
            var lower = 0, upper = part.samples.count
            if index > 0 { lower = max(0, silence(in: part.samples, fromEnd: false) - leadKept) }
            if index < parts.count - 1 {
                let keep = part.endsAtPause ? pauseGap : wordGap
                upper = max(lower, part.samples.count - max(0, silence(in: part.samples, fromEnd: true) - keep))
            }
            let offset = samples.count - lower
            words += part.words.map { (max(samples.count, $0.sample + offset), $0.range) }
            samples += part.samples[lower..<upper]
        }
        return (samples, words)
    }

    /// Kept of a piece's silence after punctuation (0.25 s at 24 kHz), and
    /// between two words (0.05 s); and of the silence at a later piece's
    /// start (0.02 s, so its first sound is not clipped).
    static let pauseGap = 6000
    static let wordGap = 1200
    static let leadKept = 480

    /// How many samples at the start (or end) of `samples` are silent:
    /// counted in 10 ms steps, each quieter than -40 dB throughout.
    static func silence(in samples: [Float], fromEnd: Bool) -> Int {
        let step = 240
        var count = 0
        while count + step <= samples.count {
            let range = fromEnd ? (samples.count - count - step)..<(samples.count - count) : count..<(count + step)
            if samples[range].contains(where: { abs($0) >= 0.01 }) { break }
            count += step
        }
        return count
    }

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
/// without eSpeak, which is GPL). In order: the CMU Pronouncing Dictionary
/// (BSD), its ARPAbet turned into Kokoro's symbols, for the word as written,
/// without its accents ("café"), and in the other spelling ("civilisation",
/// "theatre"); a possessive's owner and "z"; the word without a common
/// ending ("-s", "-ed", "-ing"…) and the ending's sound; two known words
/// joined ("drygoods"); a short word in capitals spelt out (an acronym);
/// and last, English spelling rules (`KokoroLetterRules`), so that a name
/// no dictionary has is still said, as a reader would guess it, never left
/// out (the reader asked, 22 Nov 2026).
final class KokoroFallback {
    let british: Bool
    private let dictionaryURL: URL
    private lazy var dictionary: [String: String] = Self.load(dictionaryURL)

    init(dictionary: URL, british: Bool) {
        dictionaryURL = dictionary
        self.british = british
    }

    /// Misaki's fallback answer: the sounds and a rating (1, as Misaki
    /// rates its own fallback), or nil when there is nothing to say (no
    /// letters at all).
    func pronounce(_ word: String) -> (String?, Int?) {
        if let arpabet = arpabet(for: word) { return (Self.symbols(arpabet, british: british), 1) }
        return (nil, nil)
    }

    /// The word's sounds as ARPAbet, by the first way that works.
    func arpabet(for word: String) -> String? {
        let plain = Self.plain(word)
        let lower = plain.lowercased()
        if let known = known(lower) { return known }
        // A possessive: the owner, then "z" ("Grubach's").
        for mark in ["'s", "s'"] where lower.hasSuffix(mark) && lower.count > 3 {
            let owner = String(plain.dropLast(mark == "'s" ? 2 : 1))
            if let sounds = arpabet(for: owner) { return mark == "'s" ? sounds + Self.possessive(after: sounds) : sounds }
        }
        for (ending, sound) in Self.endings where lower.hasSuffix(ending) && lower.count > ending.count + 2 {
            let stem = String(lower.dropLast(ending.count))
            if let sounds = known(stem) ?? known(stem + "e") { return sounds + " " + sound }
        }
        if let compound = compound(lower) { return compound }
        let letters = plain.filter(\.isLetter)
        if !letters.isEmpty, letters.count <= 5, letters == letters.uppercased(), letters.count > 1 || letters != "A" {
            return letters.compactMap { Self.letterNames[$0] }.joined(separator: " _ ")
        }
        return KokoroLetterRules.arpabet(plain)
    }

    /// In the dictionary as written, or in the other spelling.
    private func known(_ lower: String) -> String? {
        if let arpabet = dictionary[lower] { return arpabet }
        for variant in Self.spellingVariants(of: lower) {
            if let arpabet = dictionary[variant] { return arpabet }
        }
        return nil
    }

    /// Two known words of three letters or more, the first as long as can
    /// be ("drygoods", "tomtoms"). A part whose dictionary entry has more
    /// sounds than letters plus one is an acronym ("mit" as M.I.T.), not a
    /// word to build with.
    private func compound(_ lower: String) -> String? {
        let chars = Array(lower)
        guard chars.count >= 6, chars.allSatisfy(\.isLetter) else { return nil }
        func word(_ part: ArraySlice<Character>) -> String? {
            guard let entry = dictionary[String(part)], entry.split(separator: " ").count <= part.count + 1 else { return nil }
            return entry
        }
        for cut in stride(from: chars.count - 3, through: 3, by: -1) {
            if let first = word(chars[..<cut]), let second = word(chars[cut...]) {
                // The second word's stress becomes secondary.
                return first + " " + second.replacingOccurrences(of: "1", with: "2")
            }
        }
        return nil
    }

    /// The word without accents and with plain apostrophes ("Bürstner" →
    /// "Burstner", "Dorchin’s" → "Dorchin's").
    static func plain(_ word: String) -> String {
        word.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "œ", with: "oe")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
    }

    /// British spellings as American, and the other way round, for the
    /// dictionary (which is American).
    static func spellingVariants(of lower: String) -> [String] {
        var variants: [String] = []
        let swaps = [("isation", "ization"), ("ise", "ize"), ("ised", "ized"), ("ising", "izing"), ("our", "or"),
                     ("ours", "ors"), ("tre", "ter"), ("tres", "ters"), ("ogue", "og"), ("ence", "ense"),
                     ("lled", "led"), ("lling", "ling"), ("eable", "able")]
        for (from, to) in swaps {
            if lower.hasSuffix(from) { variants.append(String(lower.dropLast(from.count)) + to) }
            if lower.hasSuffix(to) { variants.append(String(lower.dropLast(to.count)) + from) }
        }
        return variants
    }

    /// "'s" after a hissing sound is "iz" ("Bush's"), after a voiceless
    /// one "s", else "z".
    private static func possessive(after sounds: String) -> String {
        let last = sounds.split(separator: " ").last.map(String.init) ?? ""
        if ["S", "Z", "SH", "ZH", "CH", "JH"].contains(last) { return " IH0 Z" }
        if ["P", "T", "K", "F", "TH"].contains(last) { return " S" }
        return " Z"
    }

    /// Common endings and their sounds (ARPAbet), for a known stem.
    private static let endings: [(String, String)] = [
        ("'s", "Z"), ("s", "Z"), ("es", "IH0 Z"), ("ed", "D"), ("ing", "IH0 NG"), ("ly", "L IY0"), ("er", "ER0"),
        ("est", "IH0 S T"), ("ness", "N AH0 S"), ("less", "L AH0 S"),
    ]

    /// The names of the letters (ARPAbet), for spelling out an acronym.
    static let letterNames: [Character: String] = [
        "A": "EY1", "B": "B IY1", "C": "S IY1", "D": "D IY1", "E": "IY1", "F": "EH1 F", "G": "JH IY1", "H": "EY1 CH",
        "I": "AY1", "J": "JH EY1", "K": "K EY1", "L": "EH1 L", "M": "EH1 M", "N": "EH1 N", "O": "OW1", "P": "P IY1",
        "Q": "K Y UW1", "R": "AA1 R", "S": "EH1 S", "T": "T IY1", "U": "Y UW1", "V": "V IY1", "W": "D AH1 B AH0 L Y UW0",
        "X": "EH1 K S", "Y": "W AY1", "Z": "Z IY1",
    ]

    /// "HH AH0 L OW1" as Kokoro's symbols ("həlˈO"): each stress mark goes
    /// just before its vowel, as Misaki writes them. "_" is a space between
    /// words (the letters of an acronym).
    static func symbols(_ arpabet: String, british: Bool) -> String {
        var out = ""
        let phones = arpabet.split(separator: " ").map(String.init)
        for (index, phone) in phones.enumerated() {
            if phone == "_" { out += " "; continue }
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
