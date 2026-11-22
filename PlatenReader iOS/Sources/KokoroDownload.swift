import BackgroundAssets
import SwiftUI
import System
import UIKit

/// The natural voice's download on iOS (docs/read-aloud.md, "Hosting"): an
/// Apple-hosted Background Assets pack ("KokoroVoice"), on iOS 26 and later.
/// The one network request read aloud makes, only when the reader asks for
/// it (spec: the second network exception). Nothing about the reader is
/// sent: it is the system fetching the app's own pack from the App Store.
///
/// The pack is offered only once it is live in App Store Connect: the app's
/// Info.plist says so (`PlatenKokoroAssetPack`), and the Background Assets
/// keys and download extension come with that step. Debug builds can
/// "download" from a local folder (`PLATEN_KOKORO_DOWNLOAD_FROM`), to try the
/// whole flow in the Simulator.
@MainActor
enum KokoroDownload {
    static let assetPackID = "KokoroVoice"

    /// Whether the download can be offered here.
    static var isAvailable: Bool { testSource != nil || usesBackgroundAssets }

    /// The app has its Background Assets pack (the Info.plist says so, once
    /// the pack is live in App Store Connect, with the Background Assets keys
    /// it needs). `AssetPackManager` is never touched without them: it stops
    /// the app if the keys are missing.
    static var usesBackgroundAssets: Bool {
        guard #available(iOS 26.4, *) else { return false }
        return Bundle.main.object(forInfoDictionaryKey: "PlatenKokoroAssetPack") as? Bool == true
    }

    /// Debug builds: a local folder to "download" from.
    static var testSource: URL? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PLATEN_KOKORO_DOWNLOAD_FROM"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return nil
    }

    /// At launch: says whether the download can be offered, and where an
    /// already downloaded Background Assets pack is.
    static func prepare() {
        KokoroVoice.downloadAvailable = isAvailable
        if #available(iOS 26.4, *), usesBackgroundAssets,
           AssetPackManager.shared.assetPackIsAvailableLocally(withID: assetPackID) {
            KokoroPack.backgroundAssetsFolder = try? AssetPackManager.shared.url(for: FilePath("kokoro.onnx"))
                .deletingLastPathComponent()
        }
    }

    /// Downloads the pack, reporting progress (0 to 1); returns its folder.
    static func download(progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        #if DEBUG
        if let source = testSource { return try await copyForTesting(from: source, progress: progress) }
        #endif
        guard #available(iOS 26.4, *), usesBackgroundAssets else { throw CocoaError(.featureUnsupported) }
        let manager = AssetPackManager.shared
        let pack = try await manager.assetPack(withID: assetPackID)
        let watcher = Task {
            for await update in manager.statusUpdates(forAssetPackWithID: assetPackID) {
                if case .downloading(_, let fraction) = update {
                    await MainActor.run { progress(fraction.fractionCompleted) }
                }
            }
        }
        defer { watcher.cancel() }
        try await manager.ensureLocalAvailability(of: pack)
        let folder = try manager.url(for: FilePath("kokoro.onnx")).deletingLastPathComponent()
        KokoroPack.backgroundAssetsFolder = folder
        return folder
    }

    /// Removes the downloaded voice (Settings › Read Aloud).
    static func remove() async {
        KokoroSpeechEngine.releaseModel()
        if #available(iOS 26.4, *), usesBackgroundAssets {
            try? await AssetPackManager.shared.remove(assetPackWithID: assetPackID)
        }
        KokoroPack.backgroundAssetsFolder = nil
        try? FileManager.default.removeItem(at: KokoroPack.downloadFolder)
    }

    #if DEBUG
    /// The download, from a local folder (Debug builds), at a pace that
    /// shows the progress sheet: the pack's files copied one by one.
    private static func copyForTesting(from source: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let manager = FileManager.default
        let destination = KokoroPack.downloadFolder
        try? manager.removeItem(at: destination)
        try manager.createDirectory(at: destination.appendingPathComponent("voices"), withIntermediateDirectories: true)
        let voices = KokoroPack.voices(in: source).map { "voices/\($0).bin" }
        let files = KokoroPack.requiredFiles + voices
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            try manager.copyItem(at: source.appendingPathComponent(file), to: destination.appendingPathComponent(file))
            progress(Double(index + 1) / Double(files.count))
            try await Task.sleep(for: .milliseconds(150))
        }
        return destination
    }
    #endif
}

/// The download's sheet: what is happening, how far it has got, and Cancel.
enum KokoroDownloadUI {
    /// Shows the sheet over `controller` and downloads; `done` is told
    /// whether the voice is now installed (false if cancelled or failed).
    @MainActor
    static func present(from controller: UIViewController, done: @escaping (Bool) -> Void) {
        let model = KokoroDownloadModel()
        let sheet = UIHostingController(rootView: KokoroDownloadView(model: model))
        sheet.isModalInPresentation = true
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium()]
            presentation.prefersGrabberVisible = false
        }
        model.task = Task { @MainActor in
            do {
                _ = try await KokoroDownload.download { model.progress = $0 }
                sheet.dismiss(animated: true) { done(true) }
            } catch is CancellationError {
                sheet.dismiss(animated: true) { done(false) }
            } catch {
                log.error("natural voice: download failed: \(error.localizedDescription, privacy: .public)")
                sheet.dismiss(animated: true) {
                    let alert = UIAlertController(
                        title: String(localized: "The Better Voice Could Not Be Downloaded"),
                        message: String(localized: "Check your connection and try again from Settings › Read Aloud."),
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in done(false) })
                    controller.present(alert, animated: true)
                }
            }
        }
        controller.present(sheet, animated: true)
    }
}

@MainActor
final class KokoroDownloadModel: ObservableObject {
    @Published var progress = 0.0
    var task: Task<Void, Never>?
}

struct KokoroDownloadView: View {
    @ObservedObject var model: KokoroDownloadModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Downloading the Better Voice")
                .font(.headline)
            ProgressView(value: model.progress)
                .padding(.horizontal, 32)
            Text("A one-time download of about \(KokoroVoice.downloadSize.formatted(.measurement(width: .abbreviated, usage: .asProvided))). Nothing about you is sent. Reading starts when it finishes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Cancel", role: .cancel) { model.task?.cancel() }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 24)
    }
}
