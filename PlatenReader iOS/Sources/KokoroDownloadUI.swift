import SwiftUI
import UIKit

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

