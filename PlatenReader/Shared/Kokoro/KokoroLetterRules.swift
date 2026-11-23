import Foundation

/// English spelling-to-sound rules: the last resort for a word no dictionary
/// knows (mostly names: "Grubach", "Feckle"), so that it is said as an
/// English reader would guess it rather than left out.
///
/// The method is the US Naval Research Laboratory's (Elovitz, Johnson,
/// McHugh and Shore, "Letter-to-sound rules for automatic translation of
/// English text to phonetics", 1976, a US government work in the public
/// domain): each rule turns a group of letters into sounds, when the letters
/// before and after it match. The rules for each letter are tried in order
/// and the first that fits wins, so the special cases come first and a plain
/// default last. The table here is written afresh for Platen, in that form.
/// Sounds are ARPAbet, as the CMU dictionary's, then turned into Kokoro's
/// symbols by `KokoroFallback.symbols`.
///
/// In the contexts:
/// - " " the edge of the word
/// - "#" one or more vowels
/// - ":" zero or more consonants
/// - "^" one consonant
/// - "." one voiced consonant (B D G J L M N R V W Z)
/// - "+" a front vowel (E I Y)
/// - "%" an ending: ER, E, ES, ED, ING, ELY (after the letters only)
/// - "&" a hissing sound: S C G Z X J, CH or SH (before the letters only)
/// - "@" a letter after which U says "oo": T S R D L Z N J, TH CH SH (before only)
enum KokoroLetterRules {
    /// The word's sounds, as ARPAbet with stress marks ("G R UW1 B AA0 K"),
    /// or nil if it has no letters.
    static func arpabet(_ word: String) -> String? {
        let letters = Array(" " + word.uppercased().filter { $0.isASCII && $0.isLetter } + " ")
        guard letters.count > 2 else { return nil }
        var sounds: [String] = []
        var i = 1
        while i < letters.count - 1 {
            let letter = letters[i]
            var matched = false
            for rule in table[letter] ?? [] where rule.matches(letters, at: i) {
                sounds += rule.sounds
                i += rule.match.count
                matched = true
                break
            }
            if !matched { i += 1 }
        }
        return stressed(collapsed(sounds))
    }

    /// Doubled consonant sounds said once ("Grannitt": one T).
    private static func collapsed(_ sounds: [String]) -> [String] {
        var out: [String] = []
        for s in sounds where !(s == out.last && !vowelSounds.contains(s)) { out.append(s) }
        return out
    }

    /// The first full vowel takes the stress (names are mostly stressed on
    /// their first syllable); the rest are unstressed, and AX is the schwa.
    private static func stressed(_ sounds: [String]) -> String? {
        guard !sounds.isEmpty else { return nil }
        var stressGiven = false
        let marked = sounds.map { sound -> String in
            if sound == "AX" { return "AH0" }
            guard vowelSounds.contains(sound) else { return sound }
            if !stressGiven { stressGiven = true; return sound + "1" }
            return sound + "0"
        }
        return marked.joined(separator: " ")
    }

    private static let vowelSounds: Set<String> = ["AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"]

    // MARK: - Rules

    struct Rule {
        let left: [Character]
        let match: [Character]
        let right: [Character]
        let sounds: [String]

        /// "left[MATCH]right=SOUNDS".
        init(_ text: String) {
            let open = text.firstIndex(of: "[")!, close = text.firstIndex(of: "]")!, equals = text.firstIndex(of: "=")!
            left = Array(text[..<open])
            match = Array(text[text.index(after: open)..<close])
            right = Array(text[text.index(after: close)..<equals])
            sounds = text[text.index(after: equals)...].split(separator: " ").map(String.init)
        }

        func matches(_ word: [Character], at i: Int) -> Bool {
            guard i + match.count <= word.count, Array(word[i..<(i + match.count)]) == match else { return false }
            return KokoroLetterRules.matchLeft(left, word, before: i - 1)
                && KokoroLetterRules.matchRight(right, word, from: i + match.count)
        }
    }

    private static let vowels: Set<Character> = ["A", "E", "I", "O", "U"]
    private static let voiced: Set<Character> = ["B", "D", "G", "J", "L", "M", "N", "R", "V", "W", "Z"]
    private static let front: Set<Character> = ["E", "I", "Y"]
    private static let hissing: Set<Character> = ["S", "C", "G", "Z", "X", "J"]
    private static let longU: Set<Character> = ["T", "S", "R", "D", "L", "Z", "N", "J"]

    private static func isVowel(_ c: Character) -> Bool { vowels.contains(c) }
    private static func isConsonant(_ c: Character) -> Bool { c != " " && !vowels.contains(c) }

    /// The context before the letters, read backwards from `index`. ":"
    /// and "#" take as many letters as let the rest of the pattern match.
    static func matchLeft(_ pattern: [Character], _ word: [Character], before index: Int) -> Bool {
        matchLeft(pattern, pattern.count - 1, word, index)
    }

    private static func matchLeft(_ pattern: [Character], _ p: Int, _ word: [Character], _ i: Int) -> Bool {
        guard p >= 0 else { return true }
        let at = { (k: Int) -> Character? in k >= 0 ? word[k] : nil }
        switch pattern[p] {
        case ":":
            var j = i
            while true {
                if matchLeft(pattern, p - 1, word, j) { return true }
                guard let c = at(j), isConsonant(c) else { return false }
                j -= 1
            }
        case "#":
            guard let c = at(i), isVowel(c) else { return false }
            var j = i - 1
            while true {
                if matchLeft(pattern, p - 1, word, j) { return true }
                guard let c = at(j), isVowel(c) else { return false }
                j -= 1
            }
        case "&":
            if let h = at(i), h == "H", let c = at(i - 1), c == "C" || c == "S", matchLeft(pattern, p - 1, word, i - 2) { return true }
            guard let c = at(i), hissing.contains(c) else { return false }
            return matchLeft(pattern, p - 1, word, i - 1)
        case "@":
            if let h = at(i), h == "H", let c = at(i - 1), "TCS".contains(c), matchLeft(pattern, p - 1, word, i - 2) { return true }
            guard let c = at(i), longU.contains(c) else { return false }
            return matchLeft(pattern, p - 1, word, i - 1)
        default:
            guard let c = at(i), single(pattern[p], c) else { return false }
            return matchLeft(pattern, p - 1, word, i - 1)
        }
    }

    /// The context after the letters, read forwards from `index`.
    static func matchRight(_ pattern: [Character], _ word: [Character], from index: Int) -> Bool {
        matchRight(pattern, 0, word, index)
    }

    private static func matchRight(_ pattern: [Character], _ p: Int, _ word: [Character], _ i: Int) -> Bool {
        guard p < pattern.count else { return true }
        let at = { (k: Int) -> Character? in k < word.count ? word[k] : nil }
        switch pattern[p] {
        case ":":
            var j = i
            while true {
                if matchRight(pattern, p + 1, word, j) { return true }
                guard let c = at(j), isConsonant(c) else { return false }
                j += 1
            }
        case "#":
            guard let c = at(i), isVowel(c) else { return false }
            var j = i + 1
            while true {
                if matchRight(pattern, p + 1, word, j) { return true }
                guard let c = at(j), isVowel(c) else { return false }
                j += 1
            }
        case "%":
            // An ending: ER, E, ES, ED, ING or ELY.
            let rest = String(word[min(i, word.count)...])
            for ending in ["ING", "ELY", "ER", "ES", "ED", "E"] where rest.hasPrefix(ending) {
                if matchRight(pattern, p + 1, word, i + ending.count) { return true }
            }
            return false
        default:
            guard let c = at(i), single(pattern[p], c) else { return false }
            return matchRight(pattern, p + 1, word, i + 1)
        }
    }

    /// One letter against one pattern character (a letter, or a class).
    private static func single(_ p: Character, _ c: Character) -> Bool {
        switch p {
        case " ": return c == " "
        case "^": return isConsonant(c)
        case ".": return voiced.contains(c)
        case "+": return front.contains(c)
        default: return c == p
        }
    }

    /// The rules, by the first letter they turn into sounds.
    static let table: [Character: [Rule]] = {
        var table: [Character: [Rule]] = [:]
        for line in rules {
            let rule = Rule(line)
            table[rule.match[0], default: []].append(rule)
        }
        return table
    }()

    private static let rules: [String] = [
        // A
        " [A] =AX", "#:^[A] =AX", " [ARE] =AA R", " [AR]O=AX R", "[AR]#=EH R", "^[AS]#=EY S", "[A]WA=AX", "[AW]=AO",
        " :[ANY]=EH N IY", "[A]^+#=EY", "#:[ALLY]=AX L IY", " [AL]#=AX L", "[AGAIN]=AX G EH N", "#:[AG]E=IH JH",
        "[A]^+:#=AE", " :[A]^+ =EY", "[A]^%=EY", " [ARR]=AX R", "[ARR]=AE R", " :[AR] =AA R", "[AR] =ER",
        "[AR]=AA R", "[AIR]=EH R", "[AI]=EY", "[AY]=EY", "[AU]=AO", "#:[AL] =AX L", "#:[ALS] =AX L Z",
        "[ALK]=AO K", "[AL]^=AO L", " :[ABLE]=EY B AX L", "[ABLE]=AX B AX L", "[ANG]+=EY N JH", "[ACH]=AA K",
        "[A]=AE",
        // B
        " [BE]^#=B IH", "[BEING]=B IY IH NG", " [BOTH] =B OW TH", " [BUS]#=B IH Z", "[BUIL]=B IH L", "[B]=B",
        // C
        " [CH]^=K", "^E[CH]=K", "[CH]=CH", " S[CI]#=S AY", "[CI]A=SH", "[CI]O=SH", "[CI]EN=SH", "[C]+=S",
        "[CK]=K", "[COM]%=K AH M", "[C]=K",
        // D
        "#:[DED] =D IH D", ".E[D] =D", "#^:E[D] =T", " [DE]^#=D IH", " [DO] =D UW", " [DOES]=D AH Z",
        " [DOING]=D UW IH NG", " [DOW]=D AW", "[DU]A=JH UW", "[D]=D",
        // E
        "#:[E] =", "'^:[E] =", " :[E] =IY", "#[ED] =D", "#:[E]D =", "[EV]ER=EH V", "[E]^%=IY", "[ERI]#=IY R IY",
        "[ERI]=EH R IH", "#:[ER]#=ER", "[ER]#=EH R", "[ER]=ER", " [EVEN]=IY V EH N", "#:[E]W=", "@[EW]=UW",
        "[EW]=Y UW", "[E]O=IY", "#:&[ES] =IH Z", "#:[E]S =", "#:[ELY] =L IY", "#:[EMENT]=M EH N T", "[EFUL]=F UH L",
        "[EE]=IY", "[EARN]=ER N", " [EAR]^=ER", "[EAD]=EH D", "#:[EA] =IY AX", "[EA]SU=EH", "[EA]=IY",
        "[EIGH]=EY", "[EI]=IY", " [EYE]=AY", "[EY]=IY", "[EU]=Y UW", "[E]=EH",
        // F
        "[FUL]=F UH L", "[F]=F",
        // G
        "[GIV]=G IH V", " [G]I^=G", "[GE]T=G EH", "SU[GGES]=G JH EH S", "[GG]=G", " B#[G]=G", "[G]+=JH",
        "[GREAT]=G R EY T", "#[GH]=", "[GN] =N", " [GN]=N", "[G]=G",
        // H
        " [HAV]=HH AE V", " [HERE]=HH IY R", " [HOUR]=AW ER", "[HOW]=HH AW", "[H]#=HH", "[H]=",
        // I
        " [IN]=IH N", " [I] =AY", "#:^[I] =IY", "[IN]D=AY N", "[IER]=IY ER", "#:R[IED]=IY D", "[IED] =AY D", "[IEN]=IY EH N",
        "[IE]T=AY EH", " :[I]%=AY", "[I]%=IY", "[IE]=IY", "[I]^+:#=IH", "[IR]#=AY R", "[IZ]%=AY Z", "[IS]%=AY Z",
        "[I]D%=AY", "+^[I]^+=IH", "[I]T%=AY", "#^:[I]^+=IH", "[I]^+=AY", "[IR]=ER", "[IGH]=AY", "[ILD]=AY L D",
        "[IGN] =AY N", "[IGN]^=AY N", "[IGN]%=AY N", "[IQUE]=IY K", "[I]=IH",
        // J
        "[J]=JH",
        // K
        " [K]N=", "[K]=K",
        // L
        "[LO]C#=L OW", "L[L]=", "#^:[L]%=AX L", "[LEAD]=L IY D", "[L]=L",
        // M
        "[MOV]=M UW V", "[M]=M",
        // N
        "E[NG]+=N JH", "[NG]R=NG G", "[NG]#=NG G", "[NGL]%=NG G AX L", "[NG]=NG", "[NK]=NG K", " [NOW] =N AW",
        "[N]=N",
        // O
        "[OF] =AX V", "[OROUGH]=ER OW", "#:[OR] =ER", "#:[ORS] =ER Z", "[OR]=AO R", " [ONE]=W AH N", "[OW]=OW",
        " [OVER]=OW V ER", "[OV]=AH V", "[O]^%=OW", "[O]^EN=OW", "[O]^I#=OW", "[OL]D=OW L", "[OUGHT]=AO T",
        "[OUGH]=AH F", " [OU]=AW", "H[OU]S#=AW", "[OUS]=AX S", "[OUR]=AO R", "[OULD]=UH D", "^[OU]^L=AH",
        "[OUP]=UW P", "[OU]=AW", "[OY]=OY", "[OING]=OW IH NG", "[OI]=OY", "[OOR]=AO R", "[OOK]=UH K",
        "[OOD]=UH D", "[OO]=UW", "[O]E=OW", "[O] =OW", "[OA]=OW", " [ONLY]=OW N L IY", " [ONCE]=W AH N S",
        "C[O]N=AA", "[O]NG=AO", " :^[O]N=AH", "I[ON]=AX N", "#:[ON] =AX N", "#^[ON]=AX N", "[O]ST =OW",
        "[OF]^=AO F", "[OTHER]=AH DH ER", "[OSS] =AO S", "#^:[OM]=AH M", "[O]=AA",
        // P
        "[PH]=F", "[PEOP]=P IY P", "[POW]=P AW", "[PUT] =P UH T", "[P]=P",
        // Q
        "[QUAR]=K W AO R", "[QU]=K W", "[Q]=K",
        // R
        " [RE]^#=R IY", "[RH]=R", "[R]=R",
        // S
        "[SH]=SH", "#[SION]=ZH AX N", "[SOME]=S AH M", "#[SUR]#=ZH ER", "[SUR]#=SH ER", "#[SU]#=ZH UW",
        "#[SSU]#=SH UW", "#[SED] =Z D", "#[S]#=Z", "[SAID]=S EH D", "^[SION]=SH AX N", "[S]S=", ".[S] =Z",
        "#:.E[S] =Z", "#^:##[S] =Z", "#^:#[S] =S", "U[S] =S", " :#[S] =Z", " [SCH]=S K", "[S]C+=", "#[SM]=Z M",
        "[S]=S",
        // T
        " [THE] =DH AX", "[TO] =T UW", "[THAT] =DH AE T", " [THIS] =DH IH S", " [THEY]=DH EY", " [THERE]=DH EH R",
        "[THER]=DH ER", "[THEIR]=DH EH R", " [THAN] =DH AE N", " [THEM] =DH EH M", "[THESE] =DH IY Z",
        " [THEN]=DH EH N", "[THROUGH]=TH R UW", "[THOSE]=DH OW Z", "[THOUGH] =DH OW", " [THUS]=DH AH S",
        "[TH]=TH", "#:[TED] =T IH D", "S[TI]#N=CH", "[TI]O=SH", "[TI]A=SH", "[TIEN]=SH AX N", "[TUR]#=CH ER",
        "[TU]A=CH UW", " [TWO]=T UW", "[TCH]=CH", "[T]=T",
        // U
        " [UN]I=Y UW N", " [UN]=AH N", " [UPON]=AX P AO N", "@[UR]#=UH R", "[UR]#=Y UH R", "[UR]=ER",
        "[U]^ =AH", "[U]^^=AH", "[UY]=AY", " G[U]#=", "G[U]%=", "G[U]#=W", "#N[U]=Y UW", "@[U]=UW", "[U]=Y UW",
        // V
        "[VIEW]=V Y UW", "[V]=V",
        // W
        " [WERE]=W ER", "[WA]S=W AA", "[WA]T=W AA", "[WHERE]=W EH R", "[WHAT]=W AA T", "[WHOL]=HH OW L",
        "[WHO]=HH UW", "[WH]=W", "[WAR]=W AO R", "[WOR]^=W ER", "[WR]=R", "[W]=W",
        // X
        " [X]=Z", "[X]=K S",
        // Y
        "[YOUNG]=Y AH NG", " [YOU]=Y UW", " [YES]=Y EH S", " [Y]=Y", "#^:[Y] =IY", "#^:[Y]I=IY", " :[Y] =AY",
        " :[Y]#=AY", " :[Y]^+:#=IH", " :[Y]^#=AY", "[Y]=IH",
        // Z
        "[Z]=Z",
    ]
}
