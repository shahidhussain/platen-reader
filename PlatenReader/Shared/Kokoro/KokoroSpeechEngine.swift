import AVFoundation
import Kokoro
import Foundation

/// Where the natural voice's files are (docs/read-aloud.md, "Hosting"): the
/// downloaded pack, or (Debug builds) a folder named by `PLATEN_KOKORO_PACK`
/// for testing without a download.
///
/// A pack holds `kokoro-weights.bin` and `.json` (Kokoro-82M's weights, made
/// by scripts/make-kokoro-pack.py), `config.json` (its symbol table), Misaki's lexicons (`us_gold.json`, `us_silver.json`,
/// `gb_gold.json`, `gb_silver.json`), `cmudict.dict` and `voices/*.bin`.
enum KokoroPack {
    static let requiredFiles = ["kokoro-weights.bin", "kokoro-weights.json", "config.json", "us_gold.json", "us_silver.json",
                                "gb_gold.json", "gb_silver.json", "cmudict.dict"]

    /// Where a downloaded pack is kept (Application Support, not backed up).
    static var downloadFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Platen Reader", isDirectory: true)
            .appendingPathComponent("Voice", isDirectory: true)
    }

    /// The installed pack's folder, if one is complete.
    static var installed: URL? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PLATEN_KOKORO_PACK"], !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if isComplete(url) { return url }
        }
        #endif
        if let url = backgroundAssetsFolder, isComplete(url) { return url }
        return isComplete(downloadFolder) ? downloadFolder : nil
    }

    /// Set by the iOS app once Background Assets has the pack on the device.
    static var backgroundAssetsFolder: URL?

    static func isComplete(_ folder: URL) -> Bool {
        let manager = FileManager.default
        return requiredFiles.allSatisfy { manager.fileExists(atPath: folder.appendingPathComponent($0).path) }
            && !voices(in: folder).isEmpty
    }

    /// The voices in a pack ("bf_emma", "am_michael"…), British first.
    static func voices(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("voices").path)) ?? []
        return names.filter { $0.hasSuffix(".bin") }.map { String($0.dropLast(4)) }
            .sorted { ($0.hasPrefix("b") ? 0 : 1, $0) < ($1.hasPrefix("b") ? 0 : 1, $1) }
    }
}

/// A number shared between the main thread and the work queue.
private final class GenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Read aloud with the natural voice (Kokoro-82M, `KokoroModel`): English
/// books, once the voice pack is installed (`SpeechEngineChooser`).
///
/// Sentences are turned into speech one at a time on a background queue,
/// at most `ahead` sentences ahead of what is playing, and played back to
/// back through an `AVAudioPlayerNode`; each one's start and end, and each
/// word as it is reached (from Kokoro's own durations), are reported on the
/// main thread, so the page underlines it. Speed is given to Kokoro itself,
/// so a faster reading keeps its pitch.
@MainActor
final class KokoroSpeechEngine: SpeechEngine {
    /// Sentences made ready before they are needed (the brief: one or two).
    static let ahead = 2

    var onStart: ((Int) -> Void)?
    var onFinish: ((Int) -> Void)?
    var onWord: ((Int, NSRange) -> Void)?
    var speed: Double = 1

    private let pack: URL
    private let voiceName: String
    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: KokoroModel.sampleRate, channels: 1)!
    private let work = DispatchQueue(label: "org.platenreader.kokoro", qos: .userInitiated)

    /// Waiting to be turned into speech, in order.
    private var waiting: [(id: Int, text: String)] = []
    /// Made and queued for playback, in order (the first is playing).
    private var scheduled: [Int] = []
    private var making = false
    private var playing: Int?
    /// Bumped by `stop`, so work from before it is dropped.
    private var generation = 0
    /// `generation`, readable from the work queue, so a sentence waiting to
    /// be made after a stop is skipped.
    private let currentGeneration = GenerationBox()
    private var paused = false

    /// Where the player is up to, for the words: the sample (on the
    /// player's own clock) the last queued sentence ends at, and the words
    /// still to be reached, in order.
    private var queuedEnd = 0
    private var wordsAhead: [(id: Int, sample: Int, range: NSRange)] = []
    private var wordTimer: Timer?

    /// The model, shared by every book (loading it takes a moment and its
    /// memory), dropped when iOS warns of low memory.
    nonisolated(unsafe) private static var loaded: (url: URL, model: KokoroModel)?
    nonisolated(unsafe) private static var texts: [Bool: KokoroText] = [:]

    init(pack: URL, voice: String) {
        self.pack = pack
        let voices = KokoroPack.voices(in: pack)
        voiceName = voices.contains(voice) ? voice : (voices.contains("af_bella") ? "af_bella" : (voices.first ?? voice))
        audio.attach(player)
        audio.connect(player, to: audio.mainMixerNode, format: format)
    }

    /// Frees the model (it is loaded again when next needed).
    nonisolated static func releaseModel() {
        loaded = nil
        texts.removeAll()
    }

    func enqueue(_ sentences: [(id: Int, text: String)], language: String) {
        waiting += sentences
        pump()
    }

    func pause() {
        paused = true
        player.pause()
    }

    func resume() {
        paused = false
        startAudioIfNeeded()
        player.play()
    }

    func stop() {
        generation += 1
        currentGeneration.value = generation
        waiting.removeAll()
        scheduled.removeAll()
        playing = nil
        making = false
        wordsAhead.removeAll()
        queuedEnd = 0
        wordTimer?.invalidate()
        wordTimer = nil
        player.stop()
        audio.stop()
    }

    // MARK: - Making speech ahead of playback

    /// Makes the next sentence if fewer than `ahead` are ready or playing.
    private func pump() {
        guard !making, !waiting.isEmpty, scheduled.count < Self.ahead + 1 else { return }
        let next = waiting.removeFirst()
        making = true
        let generation = self.generation
        let pack = self.pack, voiceName = self.voiceName, speed = Float(self.speed)
        let current = self.currentGeneration
        work.async {
            // Stopped while waiting its turn: not made at all.
            guard current.value == generation else { return }
            let speech = Self.speech(for: next.text, pack: pack, voice: voiceName, speed: speed)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.generation else { return }
                    self.making = false
                    self.schedule(id: next.id, samples: speech.samples, words: speech.words)
                    self.pump()
                }
            }
        }
    }

    /// The sentence's speech (on `work`), and when each word begins in it.
    /// Empty if it could not be made: the sentence is then passed over, not
    /// read.
    nonisolated private static func speech(for text: String, pack: URL, voice: String,
                                           speed: Float) -> (samples: [Float], words: [(sample: Int, range: NSRange)]) {
        do {
            if loaded?.url != pack {
                loaded = (pack, try KokoroModel(pack: pack))
                log.info("natural voice: model opened")
            }
            guard let model = loaded?.model,
                  let voicePack = KokoroVoicePack(url: pack.appendingPathComponent("voices/\(voice).bin")) else { return ([], []) }
            let british = voicePack.isBritish
            if texts[british] == nil {
                texts[british] = KokoroText(pack: pack, british: british)
                // For the diagnostics file: how a fixed phrase (not the
                // book's text) is pronounced, which shows whether Apple's
                // word tagger is working on this device ("a" as "ɐ").
                if let check = texts[british]?.phonemes("A man saw a cat.") {
                    log.info("natural voice: pronunciation check: \(check, privacy: .public)")
                }
            }
            guard let kokoroText = texts[british] else { return ([], []) }
            let started = Date()
            var samples: [Float] = []
            var words: [(sample: Int, range: NSRange)] = []
            for piece in kokoroText.pieces(text) {
                let made = model.synthesize(tokens: piece.tokens, style: voicePack.style(forTokens: piece.tokens.count), speed: speed)
                words += piece.wordStarts(durations: made.durations, samplesPerFrame: KokoroModel.samplesPerFrame)
                    .map { (samples.count + $0.sample, $0.range) }
                samples += made.samples
            }
            // For the diagnostics file: how fast speech is made on this device.
            let seconds = Double(samples.count) / KokoroModel.sampleRate
            let took = Date().timeIntervalSince(started)
            log.info("natural voice: \(seconds, format: .fixed(precision: 1)) s of speech in \(Int(took * 1000)) ms (real-time factor \(seconds > 0 ? took / seconds : 0, format: .fixed(precision: 2)))")
            return (samples, words)
        } catch {
            log.error("natural voice: \(String(describing: error), privacy: .public)")
            return ([], [])
        }
    }

    // MARK: - Playback

    private func schedule(id: Int, samples: [Float], words: [(sample: Int, range: NSRange)]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            // Nothing to say: start and finish it at once, so reading goes on
            // (after what is already queued has played, it is reported now).
            if scheduled.isEmpty {
                onStart?(id)
                onFinish?(id)
            }
            pump()
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        let generation = self.generation
        scheduled.append(id)
        startAudioIfNeeded()
        // The sentence starts where the last one ends or, if the player has
        // run dry, now; its words are reached that many samples later.
        let start = max(queuedEnd, playerSample() ?? 0)
        queuedEnd = start + samples.count
        wordsAhead += words.map { (id, start + $0.sample, $0.range) }
        watchWords()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.finished(id)
                }
            }
        }
        if playing == nil { begin(id) }
        if !paused, !player.isPlaying { player.play() }
    }

    private func begin(_ id: Int) {
        playing = id
        onStart?(id)
    }

    private func finished(_ id: Int) {
        scheduled.removeAll { $0 == id }
        playing = nil
        onFinish?(id)
        // The next one queued is now playing.
        if let next = scheduled.first { begin(next) }
        pump()
    }

    // MARK: - Words

    /// The sample the player is at, on its own clock (it stands still while
    /// paused and starts again from 0 after `stop`), counted at the voice's
    /// 24 kHz: the clock itself runs at the output's rate (often 48 kHz).
    private func playerSample() -> Int? {
        guard player.isPlaying, let now = player.lastRenderTime, let time = player.playerTime(forNodeTime: now),
              time.sampleRate > 0 else { return nil }
        let at = Int(Double(time.sampleTime) * KokoroModel.sampleRate / time.sampleRate)
        if loggedClockRate != time.sampleRate {
            loggedClockRate = time.sampleRate
            log.info("natural voice: player clock at \(Int(time.sampleRate)) Hz")
        }
        return at
    }
    private var loggedClockRate = 0.0

    /// Checks thirty times a second for words the player has reached, while
    /// any are still to come.
    private func watchWords() {
        guard wordTimer == nil, !wordsAhead.isEmpty else { return }
        wordTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachWords() }
        }
    }

    private func reachWords() {
        guard let now = playerSample() else { return }
        while let word = wordsAhead.first, word.sample <= now {
            wordsAhead.removeFirst()
            onWord?(word.id, word.range)
        }
        if wordsAhead.isEmpty {
            wordTimer?.invalidate()
            wordTimer = nil
        }
    }

    private func startAudioIfNeeded() {
        guard !audio.isRunning else { return }
        do { try audio.start() } catch {
            log.error("natural voice: audio: \(error.localizedDescription, privacy: .public)")
        }
    }
}
