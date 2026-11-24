import Combine
import Foundation
import os

/// What the system's media controls (the lock screen on iOS, the media keys
/// and Control Centre's Now Playing on the Mac) do to the reading.
struct ReadAloudControls {
    var play: () -> Void
    var pause: () -> Void
    /// A sentence forward (1) or back (-1).
    var skip: (Int) -> Void
    /// Stops reading (another window began reading aloud, on the Mac).
    var stop: () -> Void
}

/// One button of a read-aloud question.
struct ReadAloudPromptButton {
    let title: String
    let action: () -> Void
}

/// What a reader window does for read aloud that is its platform's own:
/// asking questions, the download's sheet, and the system's Now Playing.
/// Each app's `ReaderBaseViewController` is one.
@MainActor
protocol ReadAloudHost: AnyObject {
    /// What reads aloud here (the book's session, the PDF's reader), once
    /// it is ready.
    var readAloudSource: ReadAloudSource? { get }
    /// Asks a question titled "Read Aloud": the buttons, then Cancel if
    /// `cancellable` (else a lone button acts as OK).
    func readAloudAsk(message: String, buttons: [ReadAloudPromptButton], cancellable: Bool)
    /// Downloads the natural voice with a progress sheet; `done` is told
    /// whether it is now installed.
    func readAloudDownloadVoice(done: @escaping (Bool) -> Void)
    /// Reading began: Now Playing shows the book, and the media controls
    /// work it.
    func readAloudAudioBegin(controls: ReadAloudControls)
    /// Now Playing kept up to date (the chapter, playing or paused).
    func readAloudAudioUpdate(chapter: String, playing: Bool)
    /// Reading stopped: Now Playing and the controls go.
    func readAloudAudioEnd()
}

/// Starting, pausing and restarting read aloud in a reader window, the same
/// on the Mac and iOS (docs/read-aloud.md). The speaker button (and on the
/// Mac, the menu and its key) calls `toggle`:
///
/// - Off: starts. An English book where the natural voice can be offered and
///   no choice has been made yet first asks which voice to use (Apple's, or
///   download the natural voice), and remembers the answer; every other book
///   reads straight away, with the best Apple voice for its language.
/// - Reading: pauses. Paused: goes on.
///
/// The text, the underline and the page turns are the reader's
/// `readAloudSource`'s (a book's `BookSession`, a PDF's `PDFReadAloud`).
@MainActor
final class ReadAloudStarter {
    private let state: ReaderState
    private weak var host: ReadAloudHost?
    /// Follows read aloud for Now Playing.
    private var watch: AnyCancellable?
    /// Reading aloud starts again on the page the reader moved to, once they
    /// have settled there (`pageMovedByHand`).
    private var handMoveRestart: DispatchWorkItem?

    /// Watches for reading that found no text, to say so.
    private var noTextWatch: AnyCancellable?

    init(state: ReaderState, host: ReadAloudHost) {
        self.state = state
        self.host = host
        noTextWatch = state.$readAloudFoundNoText
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sayThereIsNoText() }
    }

    /// Reading stopped at once because there is no text from here on (a
    /// scanned PDF: pictures of pages): says so, rather than just stopping.
    private func sayThereIsNoText() {
        log.info("read aloud: no text to read")
        host?.readAloudAsk(message: String(localized: "There’s no readable text here. Scanned books and PDFs hold pictures of their pages, not text that can be read aloud."),
                           buttons: [ReadAloudPromptButton(title: String(localized: "OK")) {}],
                           cancellable: false)
    }

    private var settings: ReadAloudSettings { .shared }
    private var source: ReadAloudSource? { host?.readAloudSource }

    func toggle() {
        guard let source else { return }
        switch state.readAloud {
        case .starting, .playing: source.pauseReadAloud()
        case .paused: source.resumeReadAloud()
        case .off: begin()
        }
    }

    func stop() { source?.stopReadAloud() }

    /// The reader moved the page themselves while reading aloud: once they
    /// have stopped moving (0.6 s), reading starts again from the page they
    /// are on; if it was paused, it stops, so the speaker starts there.
    func pageMovedByHand() {
        guard state.readAloud != .off else { return }
        // At once: the page no longer follows the voice, so the sentence
        // still being read does not turn it back while the reader settles.
        source?.holdReadAloudPage()
        handMoveRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartHere() }
        handMoveRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func restartHere() {
        guard let source, state.readAloud != .off else { return }
        let wasPaused = state.readAloud == .paused
        source.stopReadAloud()
        log.info("read aloud: the page was moved by hand; \(wasPaused ? "stopped" : "reading from there", privacy: .public)")
        if !wasPaused { begin() }
    }

    private func begin() {
        guard let source, source.canReadAloud else { return }
        let language = source.readAloudLanguage
        let kind = SpeechEngineChooser.choose(language: language, choice: settings.choice,
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
        let engine = KokoroSpeechEngine(pack: pack, voice: settings.kokoroVoice)
        engine.speed = settings.speed
        return engine
    }

    private func appleEngine() -> SpeechEngine {
        let engine = AppleSpeechEngine()
        engine.preferredVoice = settings.appleVoice
        engine.speed = settings.speed
        return engine
    }

    private func startReading(with engine: SpeechEngine?) {
        guard let engine, let source, let host else { return }
        host.readAloudAudioBegin(controls: ReadAloudControls(
            play: { [weak self] in self?.source?.resumeReadAloud() },
            pause: { [weak self] in self?.source?.pauseReadAloud() },
            skip: { [weak self] delta in self?.source?.skipReadAloud(by: delta) },
            stop: { [weak self] in self?.source?.stopReadAloud() }))
        watchReading()
        source.startReadAloud(engine: engine)
        let voice = engine is AppleSpeechEngine ? "Apple voice" : "natural voice"
        log.info("read aloud: started (\(source.readAloudLanguage, privacy: .public), \(voice, privacy: .public))")
    }

    /// Now Playing follows the reading (playing or paused, the chapter), and
    /// ends with it.
    private func watchReading() {
        watch = state.$readAloud.combineLatest(state.$chapter)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, chapter in
                guard let self else { return }
                if phase == .off {
                    self.host?.readAloudAudioEnd()
                    self.watch = nil
                } else {
                    self.host?.readAloudAudioUpdate(chapter: chapter, playing: phase != .paused)
                }
            }
    }

    // MARK: - The first time in an English book

    /// Where better Apple voices are added, in the system's settings.
    static var systemVoicesPlace: String {
        #if os(macOS)
        String(localized: "Better Apple voices can be added in System Settings › Accessibility › Read & Speak.")
        #else
        String(localized: "Better Apple voices can be added in Settings › Accessibility › Read & Speak › Voices.")
        #endif
    }

    /// Which voice for English books: Apple's, or download the natural one.
    /// The answer is remembered (Settings › Read Aloud can change it).
    private func askForVoice(language: String) {
        let voices = AppleSpeechEngine.installedVoices()
        let size = KokoroVoice.downloadSize.formatted(.measurement(width: .abbreviated, usage: .asProvided))
        var message = String(localized: "Choose a voice for English books. You can change it later in Settings › Read Aloud.")
        message += "\n\n" + String(localized: "The better voice is a one-time download of about \(size). Nothing about you is sent. It is used for English books only; other languages use Apple’s voices.")
        if AppleVoices.onlyStandard(for: language, among: voices) {
            message += "\n\n" + Self.systemVoicesPlace
        }
        host?.readAloudAsk(message: message, buttons: [
            ReadAloudPromptButton(title: String(localized: "Read with Apple Voice")) { [weak self] in
                ReadAloudSettings.shared.choice = .apple
                self?.startReading(with: self?.appleEngine())
            },
            ReadAloudPromptButton(title: String(localized: "Download Better Voice (about \(size))")) { [weak self] in
                ReadAloudSettings.shared.choice = .kokoro
                if KokoroVoice.isInstalled {
                    self?.startReading(with: self?.naturalEngine())
                } else {
                    self?.downloadNaturalVoice()
                }
            },
        ], cancellable: true)
    }

    // MARK: - Better Apple voices

    /// Where only a default-quality Apple voice is installed for the book's
    /// language, says once (for each language) that better ones can be added
    /// in the system's settings, then reads.
    private func noteIfOnlyStandardVoice(for language: String, then read: @escaping () -> Void) {
        let base = AppleVoices.baseLanguage(language)
        let key = Self.noteShownKey(base)
        guard AppleVoices.onlyStandard(for: language, among: AppleSpeechEngine.installedVoices()),
              !AppDefaults.store.bool(forKey: key) else { return read() }
        AppDefaults.store.set(true, forKey: key)
        let name = Locale.current.localizedString(forLanguageCode: base) ?? base
        #if os(macOS)
        let message = String(localized: "This book is read with the standard \(name) voice. Better Apple voices can be added in System Settings › Accessibility › Read & Speak.")
        #else
        let message = String(localized: "This book is read with the standard \(name) voice. Better Apple voices can be added in Settings › Accessibility › Read & Speak › Voices.")
        #endif
        host?.readAloudAsk(message: message, buttons: [
            ReadAloudPromptButton(title: String(localized: "OK"), action: read),
        ], cancellable: false)
    }

    /// The defaults key that says the note about better voices was shown
    /// for a language (automated runs set it, so a scripted start reads at
    /// once).
    static func noteShownKey(_ baseLanguage: String) -> String { "readAloudVoiceNoteShown.\(baseLanguage)" }

    // MARK: - The natural voice's download

    /// Downloads the natural voice, showing its progress with Cancel, then
    /// starts reading with it (or with Apple's voice if it did not come).
    func downloadNaturalVoice() {
        host?.readAloudDownloadVoice { [weak self] installed in
            guard let self else { return }
            self.startReading(with: installed ? self.naturalEngine() : self.appleEngine())
        }
    }
}
