import SwiftUI
import UIKit

/// The natural voice's download on iOS (docs/read-aloud.md, "Hosting the
/// voice"): from Platen's GitHub release, checked and installed by the
/// shared `KokoroVoiceDownloader`, on every iOS the app supports. It keeps
/// going for a while if the reader leaves the app (a background task).
@MainActor
enum KokoroDownload {
    /// At launch: the download can be offered.
    static func prepare() {
        KokoroVoice.downloadAvailable = true
        #if DEBUG
        adoptCopiedPack()
        #endif
    }

    /// Downloads the voice, reporting progress (0 to 1); returns its folder.
    static func download(progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let background = UIApplication.shared.beginBackgroundTask(withName: "Natural voice download")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        return try await KokoroVoiceDownloader().download(progress: progress)
    }

    /// Removes the downloaded voice (Settings › Read Aloud).
    static func remove() async {
        KokoroSpeechEngine.releaseModel()
        try? FileManager.default.removeItem(at: KokoroPack.downloadFolder)
    }

    #if DEBUG
    /// Debug builds: a voice pack folder (`build/kokoro-pack`, made by
    /// scripts/make-kokoro-pack.py) copied into the app's Documents with
    /// Finder, named "kokoro-pack", is moved to where a downloaded pack
    /// lives, as if downloaded.
    private static func adoptCopiedPack() {
        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let copied = documents.appendingPathComponent("kokoro-pack", isDirectory: true)
        guard manager.fileExists(atPath: copied.path) else { return }
        guard KokoroPack.isComplete(copied) else {
            log.error("natural voice: Documents/kokoro-pack is incomplete; not installed")
            return
        }
        let destination = KokoroPack.downloadFolder
        do {
            try? manager.removeItem(at: destination)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: copied, to: destination)
            log.info("natural voice: installed the pack copied into Documents")
        } catch {
            log.error("natural voice: could not install the copied pack: \(error.localizedDescription, privacy: .public)")
        }
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
                    let reason = (error as? KokoroVoiceDownloadError)?.errorDescription
                        ?? String(localized: "Check your connection and try again from Settings › Read Aloud.")
                    let alert = UIAlertController(
                        title: String(localized: "The Better Voice Could Not Be Downloaded"),
                        message: reason,
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
