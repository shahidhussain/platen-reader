import Combine
import UIKit

/// Read aloud in a book (iOS; docs/read-aloud.md). The speaker button
/// (ReaderTopBar) calls `toggleReadAloud`:
///
/// - Off: starts. An English book where the natural voice can be offered and
///   no choice has been made yet first asks which voice to use (Apple's, or
///   download the natural voice), and remembers the answer; every other book
///   reads straight away, with the best Apple voice for its language.
/// - Reading: pauses. Paused: goes on.
///
/// The text, the highlight and the page turns are the session's
/// (`BookSession.startReadAloud`); the audio session, the lock screen and
/// interruptions are `ReadAloudAudio`'s.
extension ReaderViewController {
    func toggleReadAloud() {
        switch state.readAloud {
        case .starting, .playing: session.pauseReadAloud()
        case .paused: session.resumeReadAloud()
        case .off: beginReadAloud()
        }
    }

    private var readAloudSettings: ReadAloudSettings { .shared }

    private func beginReadAloud() {
        guard session.hasRendered else { return }
        let language = session.readAloudLanguage
        let kind = SpeechEngineChooser.choose(language: language, choice: readAloudSettings.choice,
                                              kokoroOffered: KokoroVoice.isOffered,
                                              kokoroInstalled: KokoroVoice.isInstalled)
        switch kind {
        case .apple(let language):
            noteIfOnlyStandardVoice(for: language) { [weak self] in self?.startReading(with: self?.appleEngine()) }
        case .kokoro:
            startReading(with: naturalEngine() ?? appleEngine())
        case .askFirst(let language):
            askForVoice(language: language)
        }
    }

    /// The natural voice, if its pack is installed.
    private func naturalEngine() -> SpeechEngine? {
        guard let pack = KokoroPack.installed else { return nil }
        let engine = KokoroSpeechEngine(pack: pack, voice: readAloudSettings.kokoroVoice)
        engine.speed = readAloudSettings.speed
        return engine
    }

    private func appleEngine() -> SpeechEngine {
        let engine = AppleSpeechEngine()
        engine.preferredVoice = readAloudSettings.appleVoice
        engine.speed = readAloudSettings.speed
        return engine
    }

    private func startReading(with engine: SpeechEngine?) {
        guard let engine else { return }
        ReadAloudAudio.shared.begin(
            title: state.title, author: state.author, chapter: state.chapter,
            controls: .init(play: { [weak self] in self?.session.resumeReadAloud() },
                            pause: { [weak self] in self?.session.pauseReadAloud() }))
        watchReadAloud()
        session.startReadAloud(engine: engine)
        let voice = engine is AppleSpeechEngine ? "Apple voice" : "natural voice"
        log.info("read aloud: started (\(self.session.readAloudLanguage, privacy: .public), \(voice, privacy: .public))")
    }

    /// Now Playing follows the reading (playing or paused, the chapter), and
    /// the audio session ends with it.
    private func watchReadAloud() {
        readAloudWatch = state.$readAloud.combineLatest(state.$chapter)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, chapter in
                guard let self else { return }
                if phase == .off {
                    ReadAloudAudio.shared.end()
                    self.readAloudWatch = nil
                } else {
                    ReadAloudAudio.shared.update(title: self.state.title, author: self.state.author,
                                                 chapter: chapter, playing: phase != .paused)
                }
            }
    }

    // MARK: - The first tap in an English book

    /// Which voice for English books: Apple's, or download the natural one.
    /// The answer is remembered (Settings › Read Aloud can change it).
    private func askForVoice(language: String) {
        let voices = AppleSpeechEngine.installedVoices()
        let size = KokoroVoice.downloadSize.formatted(.measurement(width: .abbreviated, usage: .asProvided))
        var message = String(localized: "Choose a voice for English books. You can change it later in Settings › Read Aloud.")
        message += "\n\n" + String(localized: "The better voice is a one-time download of about \(size). Nothing about you is sent. It is used for English books only; other languages use Apple’s voices.")
        if AppleVoices.onlyStandard(for: language, among: voices) {
            message += "\n\n" + String(localized: "Better Apple voices can be added in Settings › Accessibility › Read & Speak › Voices.")
        }
        let alert = UIAlertController(title: String(localized: "Read Aloud"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Read with Apple Voice"), style: .default) { [weak self] _ in
            ReadAloudSettings.shared.choice = .apple
            self?.startReading(with: self?.appleEngine())
        })
        alert.addAction(UIAlertAction(title: String(localized: "Download Better Voice (about \(size))"), style: .default) { [weak self] _ in
            ReadAloudSettings.shared.choice = .kokoro
            if KokoroVoice.isInstalled {
                self?.startReading(with: self?.naturalEngine())
            } else {
                self?.downloadNaturalVoice()
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Better Apple voices

    /// Where only a default-quality Apple voice is installed for the book's
    /// language, says once (for each language) that better ones can be added
    /// in Settings, then reads.
    private func noteIfOnlyStandardVoice(for language: String, then read: @escaping () -> Void) {
        let base = AppleVoices.baseLanguage(language)
        let key = "readAloudVoiceNoteShown.\(base)"
        guard AppleVoices.onlyStandard(for: language, among: AppleSpeechEngine.installedVoices()),
              !AppDefaults.store.bool(forKey: key) else { return read() }
        AppDefaults.store.set(true, forKey: key)
        let name = Locale.current.localizedString(forLanguageCode: base) ?? base
        let alert = UIAlertController(
            title: String(localized: "Read Aloud"),
            message: String(localized: "This book is read with the standard \(name) voice. Better Apple voices can be added in Settings › Accessibility › Read & Speak › Voices."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in read() })
        present(alert, animated: true)
    }

    // MARK: - The natural voice's download

    /// Downloads the natural voice (`KokoroDownload`), showing its progress
    /// with Cancel, then starts reading with it.
    func downloadNaturalVoice() {
        KokoroDownloadUI.present(from: self) { [weak self] installed in
            guard let self else { return }
            self.startReading(with: installed ? self.naturalEngine() : self.appleEngine())
        }
    }
}
