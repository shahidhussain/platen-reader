import Foundation

/// Read aloud's settings: global, like every other setting (no per-book
/// data; docs/read-aloud.md, "What is stored"). Settings › Read Aloud shows
/// them; the first tap of the speaker button in an English book sets
/// `choice` when it is still undecided.
final class ReadAloudSettings: ObservableObject {
    static let shared = ReadAloudSettings()

    /// The speeds offered: slower and faster than normal.
    static let speeds: [Double] = [0.75, 0.9, 1, 1.1, 1.25, 1.5]

    private let defaults = AppDefaults.store

    /// English books: Apple's voices or the natural voice, or not yet chosen.
    @Published var choice: ReadAloudVoiceChoice {
        didSet { defaults.set(choice.rawValue, forKey: "readAloudChoice") }
    }
    /// An Apple voice chosen in Settings (its identifier), or nil for the best
    /// installed voice for each book's language.
    @Published var appleVoice: String? {
        didSet { defaults.set(appleVoice, forKey: "readAloudAppleVoice") }
    }
    /// The natural voice's speaker, for when it is installed: Bella
    /// ("af_bella") unless chosen otherwise, the reader's pick of the voices
    /// on an iPhone (22 Nov 2026; Emma sounded flat).
    @Published var kokoroVoice: String {
        didSet { defaults.set(kokoroVoice, forKey: "readAloudKokoroVoice") }
    }
    /// 1 is normal speed.
    @Published var speed: Double {
        didSet { defaults.set(speed, forKey: "readAloudSpeed") }
    }

    private init() {
        choice = ReadAloudVoiceChoice(rawValue: defaults.string(forKey: "readAloudChoice") ?? "") ?? .undecided
        appleVoice = defaults.string(forKey: "readAloudAppleVoice")
        kokoroVoice = defaults.string(forKey: "readAloudKokoroVoice") ?? "af_bella"
        let saved = defaults.double(forKey: "readAloudSpeed")
        speed = saved > 0 ? saved : 1
    }
}
