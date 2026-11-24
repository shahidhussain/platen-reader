import SwiftUI

/// Settings › Read Aloud, in both apps (docs/read-aloud.md): the voice for English books
/// (where the natural voice can be offered), Apple's voice with a sample,
/// the speed, and where better Apple voices come from.
struct ReadAloudSettingsSection: View {
    @ObservedObject var settings = ReadAloudSettings.shared
    @State private var sampler = VoiceSampler()

    /// Apple's English voices, best first (the choice here is for English
    /// books; other languages use the best installed voice for each).
    private var englishVoices: [AppleVoiceInfo] {
        AppleSpeechEngine.installedVoices()
            .filter { AppleVoices.baseLanguage($0.language) == "en" }
            .sorted { $0.quality != $1.quality ? $0.quality > $1.quality : $0.name < $1.name }
    }

    @State private var installed = KokoroVoice.isInstalled
    @State private var confirmRemove = false
    @State private var downloading = false
    @State private var downloadProgress = 0.0

    private var size: String {
        KokoroVoice.downloadSize.formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    var body: some View {
        Section {
            #if os(macOS)
            macRows
            #else
            iOSRows
            #endif
        } header: {
            #if os(iOS)
            Text("Read Aloud")
            #endif
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if KokoroVoice.isOffered {
                    #if os(macOS)
                    Text("The natural voice reads English books. It is a one-time download, kept on this Mac; nothing about you is sent. Other languages use Apple’s voices.")
                    #else
                    Text("The natural voice reads English books. It is a one-time download, kept on this device; nothing about you is sent. Other languages use Apple’s voices.")
                    #endif
                }
                Text(ReadAloudStarter.systemVoicesPlace)
            }
            #if os(macOS)
            .font(.caption)
            .foregroundStyle(.secondary)
            #endif
        }
        .confirmationDialog("Remove the natural voice?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await KokoroDownload.remove()
                    installed = false
                    if settings.choice == .kokoro { settings.choice = .undecided }
                }
            }
        } message: {
            Text("English books will be read with Apple’s voices until you download it again.")
        }
    }

    #if os(iOS)
    /// iOS: one row each, buttons as rows (the Settings app's pattern).
    @ViewBuilder private var iOSRows: some View {
        if KokoroVoice.isOffered {
            Picker("English Books", selection: $settings.choice) {
                Text("Apple Voice").tag(ReadAloudVoiceChoice.apple)
                Text("Natural Voice").tag(ReadAloudVoiceChoice.kokoro)
                if settings.choice == .undecided { Text("Ask First").tag(ReadAloudVoiceChoice.undecided) }
            }
            if installed, let pack = KokoroPack.installed {
                Picker("Natural Voice", selection: $settings.kokoroVoice) {
                    ForEach(KokoroPack.voices(in: pack), id: \.self) { voice in
                        Text(Self.describeNatural(voice)).tag(voice)
                    }
                }
                Button("Play Natural Sample") {
                    sampler.playNatural(pack: pack, voice: settings.kokoroVoice, speed: settings.speed)
                }
                Button("Remove Voice Download (\(KokoroVoice.installedSize.formatted(.measurement(width: .abbreviated, usage: .asProvided))))",
                       role: .destructive) { confirmRemove = true }
            } else if downloading {
                ProgressView(value: downloadProgress) {
                    Text("Downloading the Better Voice")
                }
            } else {
                Button("Download Better Voice (about \(size))") { download() }
            }
        }
        Picker("Apple Voice", selection: $settings.appleVoice) {
            Text("Best Installed").tag(String?.none)
            ForEach(englishVoices, id: \.identifier) { voice in
                Text(Self.describe(voice)).tag(Optional(voice.identifier))
            }
        }
        Button("Play Sample") { sampler.play(voice: settings.appleVoice, speed: settings.speed) }
        Picker("Speed", selection: $settings.speed) {
            ForEach(ReadAloudSettings.speeds, id: \.self) { speed in
                Text(speed.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(speed)
            }
        }
    }
    #else
    /// Mac: each voice's picker with its sample button beside it, and the
    /// download's buttons at the end of a labelled row (System Settings'
    /// pattern).
    @ViewBuilder private var macRows: some View {
        if KokoroVoice.isOffered {
            Picker("English Books", selection: $settings.choice) {
                Text("Apple Voice").tag(ReadAloudVoiceChoice.apple)
                Text("Natural Voice").tag(ReadAloudVoiceChoice.kokoro)
                if settings.choice == .undecided { Text("Ask First").tag(ReadAloudVoiceChoice.undecided) }
            }
            if installed, let pack = KokoroPack.installed {
                LabeledContent("Natural Voice") {
                    HStack {
                        Picker("Natural Voice", selection: $settings.kokoroVoice) {
                            ForEach(KokoroPack.voices(in: pack), id: \.self) { voice in
                                Text(Self.describeNatural(voice)).tag(voice)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Self.sampleButton {
                            sampler.playNatural(pack: pack, voice: settings.kokoroVoice, speed: settings.speed)
                        }
                    }
                }
                LabeledContent("Voice Download") {
                    Button("Remove (\(KokoroVoice.installedSize.formatted(.measurement(width: .abbreviated, usage: .asProvided))))…") {
                        confirmRemove = true
                    }
                }
            } else if downloading {
                LabeledContent("Natural Voice") {
                    ProgressView(value: downloadProgress)
                        .frame(width: 160)
                }
            } else {
                LabeledContent("Natural Voice") {
                    Button("Download (about \(size))") { download() }
                }
            }
        }
        LabeledContent("Apple Voice") {
            HStack {
                Picker("Apple Voice", selection: $settings.appleVoice) {
                    Text("Best Installed").tag(String?.none)
                    ForEach(englishVoices, id: \.identifier) { voice in
                        Text(Self.describe(voice)).tag(Optional(voice.identifier))
                    }
                }
                .labelsHidden()
                .fixedSize()
                Self.sampleButton { sampler.play(voice: settings.appleVoice, speed: settings.speed) }
            }
        }
        Picker("Speed", selection: $settings.speed) {
            ForEach(ReadAloudSettings.speeds, id: \.self) { speed in
                Text(speed.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(speed)
            }
        }
    }

    /// A small ▶︎ beside a voice's picker that plays a sample of it.
    private static func sampleButton(_ play: @escaping () -> Void) -> some View {
        Button(action: play) {
            Label("Play Sample", systemImage: "play.fill")
                .labelStyle(.iconOnly)
        }
        .help(Text("Play Sample"))
    }
    #endif

    private func download() {
        downloading = true
        downloadProgress = 0
        Task {
            do {
                _ = try await KokoroDownload.download { downloadProgress = $0 }
                installed = true
                settings.choice = .kokoro
            } catch {
                log.error("natural voice: download failed: \(error.localizedDescription, privacy: .public)")
            }
            downloading = false
        }
    }

    /// "Emma (British, female)".
    private static func describeNatural(_ voice: String) -> String {
        let parts = voice.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let code = parts.first, code.count == 2 else { return voice }
        let name = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        let british = code.hasPrefix("b")
        let female = code.hasSuffix("f")
        switch (british, female) {
        case (true, true): return String(localized: "\(name) (British, female)")
        case (true, false): return String(localized: "\(name) (British, male)")
        case (false, true): return String(localized: "\(name) (American, female)")
        case (false, false): return String(localized: "\(name) (American, male)")
        }
    }

    /// "Serena (British English, Enhanced)".
    private static func describe(_ voice: AppleVoiceInfo) -> String {
        let place = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        switch voice.quality {
        case .premium: return String(localized: "\(voice.name) (\(place), Premium)")
        case .enhanced: return String(localized: "\(voice.name) (\(place), Enhanced)")
        case .standard: return "\(voice.name) (\(place))"
        }
    }
}

/// Speaks a line in the chosen voice, for Settings' Play Sample.
@MainActor
final class VoiceSampler {
    private let engine = AppleSpeechEngine()
    private var natural: KokoroSpeechEngine?

    func playNatural(pack: URL, voice: String, speed: Double) {
        engine.stop()
        natural?.stop()
        let natural = KokoroSpeechEngine(pack: pack, voice: voice)
        natural.speed = speed
        self.natural = natural
        natural.enqueue([(0, String(localized: "This is how books will sound when they are read aloud."))], language: "en")
    }

    func play(voice: String?, speed: Double) {
        natural?.stop()
        engine.stop()
        engine.preferredVoice = voice
        engine.speed = speed
        engine.enqueue([(0, String(localized: "This is how books will sound when they are read aloud."))], language: "en")
    }
}
