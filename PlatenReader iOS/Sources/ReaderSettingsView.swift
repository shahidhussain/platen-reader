import PlatenCore
import SwiftUI
import UIKit

/// The settings on iOS: a sheet from the gear at the foot of the home
/// screen. They are about how the app works, so they live there, not among
/// the reader's buttons (every one of which is about the book being read).
///
/// Only what the reader's own popovers do not hold is here: one page or
/// scroll and the line width are in the Layout popover; text size, font,
/// line spacing and appearance in Aa. Each setting is in one place only.
/// The Mac's File Types tab has no iOS counterpart. Changes apply to any
/// open book straight away.
struct ReaderSettingsView: View {
    @ObservedObject var settings = ReaderSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    Picker("Page Turn", selection: $settings.pageTurnStyle) {
                        ForEach(PageTurnStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Show Pages Left in Chapter", isOn: $settings.showPagesLeftInChapter)
                    // The explanation is the toggle's second line (the
                    // system's title-and-subtitle row), so it wraps beside
                    // the switch, which sits centred on both lines, instead
                    // of running under it with the title pressed against it
                    // (device testing, 22 Nov 2026).
                    Toggle(isOn: $settings.justify) {
                        Text("Justify Text")
                        Text("Lines flush at both sides, where the book asks for it. Off, lines end where their words do (ragged right), which leaves no wide gaps between words on a narrow screen.")
                    }
                    Toggle(isOn: $settings.hyphenate) {
                        Text("Hyphenate Text")
                        Text("Breaks long words at the ends of lines, so lines are more even and justified text has fewer wide gaps between words. Not used in books whose pages are laid out by the publisher.")
                    }
                }
                ReadAloudSettingsSection()
                Section {
                    Button("Clear Reading Positions and Bookmarks…", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("Platen keeps only where you are in each book and your bookmarks, on this device.")
                }
                Section {
                    ShareLink(item: DiagnosticsFile(), preview: SharePreview("Platen Reader Diagnostics")) {
                        Text("Share Diagnostics…")
                    }
                } footer: {
                    Text("A record of how the app has been running (how long books took to open, moments it was slow to respond, errors), kept on this device to help with a problem report. It holds no book titles or file names, and leaves the device only if you share it.")
                }
                Section {
                    LabeledContent("Platen Reader", value: AppVersion.line)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                    // Opens the website in the reader's browser; the app
                    // itself loads nothing (spec: no network).
                    Link(destination: AppLinks.website) {
                        LabeledContent("Website") {
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    // A little whimsy, unattributed (Slaughterhouse-Five).
                    Text(verbatim: "Poo-tee-weet?")
                        .font(.system(.footnote, design: .serif).italic())
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear all reading positions and bookmarks?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) { try? PositionStore.shared.removeAll() }
            } message: {
                Text("This cannot be undone.")
            }
        }
    }
}

/// The diagnostics file (`DiagnosticLog`) as the share sheet takes it: a
/// copy made when the reader chooses where to send it, named for the day.
private struct DiagnosticsFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            SentTransferredFile(try DiagnosticLog.shared.export())
        }
    }
}

/// Settings › Read Aloud (docs/read-aloud.md): the voice for English books
/// (where the natural voice can be offered), Apple's voice with a sample,
/// the speed, and where better Apple voices come from.
private struct ReadAloudSettingsSection: View {
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
        } header: {
            Text("Read Aloud")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if KokoroVoice.isOffered {
                    Text("The natural voice reads English books. It is a one-time download, kept on this device; nothing about you is sent. Other languages use Apple’s voices.")
                }
                Text("Better Apple voices can be added in Settings › Accessibility › Read & Speak › Voices.")
            }
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
private final class VoiceSampler {
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

/// The licences of the code and data Platen uses that others wrote: the
/// text files in Acknowledgements/, one page each.
private struct AcknowledgementsView: View {
    private var files: [URL] {
        (Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: nil) ?? [])
            .filter { Self.names.contains($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private static let names: Set<String> = ["MisakiSwift and Misaki (Apache-2.0)", "foliate-js", "Kokoro natural voice"]

    var body: some View {
        List(files, id: \.self) { file in
            NavigationLink(file.deletingPathExtension().lastPathComponent) {
                ScrollView {
                    Text((try? String(contentsOf: file, encoding: .utf8)) ?? "")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle(file.deletingPathExtension().lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationTitle("Acknowledgements")
    }
}
