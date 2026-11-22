import AVFoundation

/// Read aloud with Apple's voices (AVSpeechSynthesizer): every language, and
/// English for readers who have not downloaded the natural voice. The voice
/// is the best installed one for the book's language (`AppleVoices.best`),
/// or the one chosen in Settings.
@MainActor
final class AppleSpeechEngine: NSObject, SpeechEngine {
    var onStart: ((Int) -> Void)?
    var onFinish: ((Int) -> Void)?
    var onWord: ((Int, NSRange) -> Void)?
    var speed: Double = 1

    /// A voice the reader chose in Settings, used where it speaks the book's
    /// language.
    var preferredVoice: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var ids: [ObjectIdentifier: Int] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Apple's installed voices, as `AppleVoices` takes them.
    static func installedVoices() -> [AppleVoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            let quality: AppleVoiceInfo.Quality
            switch voice.quality {
            case .premium: quality = .premium
            case .enhanced: quality = .enhanced
            default: quality = .standard
            }
            return AppleVoiceInfo(identifier: voice.identifier, name: voice.name,
                                  language: voice.language, quality: quality)
        }
    }

    /// The voice to use for `language`.
    func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let info = AppleVoices.best(for: language, among: Self.installedVoices(), preferred: preferredVoice),
           let voice = AVSpeechSynthesisVoice(identifier: info.identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: language)
    }

    func enqueue(_ sentences: [(id: Int, text: String)], language: String) {
        let voice = voice(for: language)
        // Apple's scale: 0.5 is a normal pace; speed 1 keeps it.
        let rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * speed,
                                 Double(AVSpeechUtteranceMinimumSpeechRate)),
                             Double(AVSpeechUtteranceMaximumSpeechRate)))
        for sentence in sentences {
            let utterance = AVSpeechUtterance(string: sentence.text)
            utterance.voice = voice
            utterance.rate = rate
            utterance.prefersAssistiveTechnologySettings = false
            ids[ObjectIdentifier(utterance)] = sentence.id
            synthesizer.speak(utterance)
        }
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func resume() { synthesizer.continueSpeaking() }

    func stop() {
        ids.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension AppleSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let id = self.ids[key] { self.onStart?(id) }
        }
    }

    /// Each word as it is about to be spoken, for the page's underline.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let id = self.ids[key] { self.onWord?(id, characterRange) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let id = self.ids.removeValue(forKey: key) { self.onFinish?(id) }
        }
    }
}
