import AVFoundation
import Foundation

/// Where the natural voice's files are (docs/read-aloud.md, "Hosting"): the
/// downloaded pack, or (Debug builds) a folder named by `PLATEN_KOKORO_PACK`
/// for testing without a download.
///
/// A pack holds `kokoro.onnx` (Kokoro-82M, int8), `config.json` (its symbol
/// table), Misaki's lexicons (`us_gold.json`, `us_silver.json`,
/// `gb_gold.json`, `gb_silver.json`), `cmudict.dict` and `voices/*.bin`.
enum KokoroPack {
    static let requiredFiles = ["kokoro.onnx", "config.json", "us_gold.json", "us_silver.json",
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

#if canImport(onnxruntime)
/// A number shared between the main thread and the work queue.
private final class GenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Read aloud with the natural voice (Kokoro-82M on ONNX Runtime): English
/// books, once the voice pack is installed (`SpeechEngineChooser`).
///
/// Sentences are turned into speech one at a time on a background queue,
/// at most `ahead` sentences ahead of what is playing, and played back to
/// back through an `AVAudioPlayerNode`; each one's start and end are
/// reported on the main thread, so the page highlights it. Speed is given
/// to Kokoro itself, so a faster reading keeps its pitch.
@MainActor
final class KokoroSpeechEngine: SpeechEngine {
    /// Sentences made ready before they are needed (the brief: one or two).
    static let ahead = 2

    var onStart: ((Int) -> Void)?
    var onFinish: ((Int) -> Void)?
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

    /// The model, shared by every book (loading it takes a moment and its
    /// memory), dropped when iOS warns of low memory.
    nonisolated(unsafe) private static var loaded: (url: URL, model: KokoroModel)?
    nonisolated(unsafe) private static var texts: [Bool: KokoroText] = [:]

    init(pack: URL, voice: String) {
        self.pack = pack
        let voices = KokoroPack.voices(in: pack)
        voiceName = voices.contains(voice) ? voice : (voices.first ?? voice)
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
            let samples = Self.speech(for: next.text, pack: pack, voice: voiceName, speed: speed)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.generation else { return }
                    self.making = false
                    self.schedule(id: next.id, samples: samples)
                    self.pump()
                }
            }
        }
    }

    /// The sentence's speech (on `work`). Empty if it could not be made: the
    /// sentence is then passed over, not read.
    nonisolated private static func speech(for text: String, pack: URL, voice: String, speed: Float) -> [Float] {
        do {
            let modelURL = pack.appendingPathComponent("kokoro.onnx")
            if loaded?.url != modelURL {
                let started = Date()
                loaded = (modelURL, try KokoroModel(model: modelURL))
                log.info("natural voice: model loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
            guard let model = loaded?.model,
                  let voicePack = KokoroVoicePack(url: pack.appendingPathComponent("voices/\(voice).bin")) else { return [] }
            let british = voicePack.isBritish
            if texts[british] == nil { texts[british] = KokoroText(pack: pack, british: british) }
            guard let kokoroText = texts[british] else { return [] }
            let started = Date()
            var samples: [Float] = []
            for piece in kokoroText.tokens(text) {
                samples += try model.synthesize(tokens: piece, style: voicePack.style(forTokens: piece.count), speed: speed)
            }
            // For the diagnostics file: how fast speech is made on this device.
            let seconds = Double(samples.count) / KokoroModel.sampleRate
            let took = Date().timeIntervalSince(started)
            log.info("natural voice: \(seconds, format: .fixed(precision: 1)) s of speech in \(Int(took * 1000)) ms (real-time factor \(seconds > 0 ? took / seconds : 0, format: .fixed(precision: 2)))")
            return samples
        } catch {
            log.error("natural voice: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    // MARK: - Playback

    private func schedule(id: Int, samples: [Float]) {
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

    private func startAudioIfNeeded() {
        guard !audio.isRunning else { return }
        do { try audio.start() } catch {
            log.error("natural voice: audio: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
