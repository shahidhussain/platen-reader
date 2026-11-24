import AppKit
import PlatenCore
import SwiftUI

/// Read aloud in a book or a PDF (Mac; docs/read-aloud.md). The speaker on
/// the overlay bar and View › Read Aloud (⌘R) call the shared
/// `ReadAloudStarter`; this is the Mac's part: its questions as sheets on
/// the window, the download's sheet, and Now Playing (`ReadAloudAudio`).
extension ReaderBaseViewController: ReadAloudHost {
    func readAloudAsk(message: String, buttons: [ReadAloudPromptButton], cancellable: Bool) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Read Aloud")
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button.title) }
        if cancellable { alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}" }
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if buttons.indices.contains(index) { buttons[index].action() }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    func readAloudDownloadVoice(done: @escaping (Bool) -> Void) {
        KokoroDownloadSheet.present(from: self, done: done)
    }

    func readAloudAudioBegin(controls: ReadAloudControls) {
        ReadAloudAudio.shared.begin(owner: self, title: state.title, author: state.author, chapter: state.chapter,
                                    controls: controls)
        // The cover for Now Playing, read in the background (a book's cover
        // picture, or a PDF's first page).
        guard let url = document.fileURL else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let jpeg = BookCover.extract(from: url, maxPixelSize: 600).jpeg
            DispatchQueue.main.async {
                guard let self, let jpeg, let image = NSImage(data: jpeg) else { return }
                ReadAloudAudio.shared.setCover(image, owner: self)
            }
        }
    }

    func readAloudAudioUpdate(chapter: String, playing: Bool) {
        ReadAloudAudio.shared.update(owner: self, title: state.title, author: state.author, chapter: chapter, playing: playing)
    }

    func readAloudAudioEnd() { ReadAloudAudio.shared.end(owner: self) }
}

/// The natural voice's download as a sheet on the reader's window: what is
/// happening, how far it has got, and Cancel.
@MainActor
enum KokoroDownloadSheet {
    /// Shows the sheet over `controller` and downloads; `done` is told
    /// whether the voice is now installed (false if cancelled or failed).
    static func present(from controller: NSViewController, done: @escaping (Bool) -> Void) {
        let model = KokoroDownloadModel()
        let sheet = NSHostingController(rootView: KokoroDownloadView(model: model).frame(width: 400))
        model.task = Task { @MainActor in
            do {
                _ = try await KokoroDownload.download { model.progress = $0 }
                controller.dismiss(sheet)
                done(true)
            } catch is CancellationError {
                controller.dismiss(sheet)
                done(false)
            } catch {
                log.error("natural voice: download failed: \(error.localizedDescription, privacy: .public)")
                controller.dismiss(sheet)
                let alert = NSAlert()
                alert.messageText = String(localized: "The Better Voice Could Not Be Downloaded")
                alert.informativeText = (error as? KokoroVoiceDownloadError)?.errorDescription
                    ?? String(localized: "Check your connection and try again from Settings › Read Aloud.")
                if let window = controller.view.window {
                    alert.beginSheetModal(for: window) { _ in done(false) }
                } else {
                    alert.runModal()
                    done(false)
                }
            }
        }
        controller.presentAsSheet(sheet)
    }
}
