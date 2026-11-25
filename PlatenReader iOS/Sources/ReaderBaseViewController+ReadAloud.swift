import PlatenCore
import UIKit

/// Read aloud in a book or a PDF (iOS; docs/read-aloud.md). The speaker
/// button (ReaderTopBar) calls `toggleReadAloud`; what happens then is the
/// shared `ReadAloudStarter`'s. This is the iOS part: its questions as
/// alerts, the download's sheet, and the lock screen (`ReadAloudAudio`).
extension ReaderBaseViewController: ReadAloudHost {
    func toggleReadAloud() { readAloudStarter.toggle() }
    func pageMovedByHand() { readAloudStarter.pageMovedByHand() }
    func downloadNaturalVoice() { readAloudStarter.downloadNaturalVoice() }

    func readAloudAsk(message: String, buttons: [ReadAloudPromptButton], cancellable: Bool) {
        let alert = UIAlertController(title: String(localized: "Read Aloud"), message: message, preferredStyle: .alert)
        for button in buttons {
            alert.addAction(UIAlertAction(title: button.title, style: .default) { _ in button.action() })
        }
        if cancellable { alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel)) }
        present(alert, animated: true)
    }

    func readAloudDownloadVoice(done: @escaping (Bool) -> Void) {
        KokoroDownloadUI.present(from: self, done: done)
    }

    func readAloudAudioBegin(controls: ReadAloudControls) {
        let cover = readAloudCover
        ReadAloudAudio.shared.begin(title: state.title, author: state.author, chapter: state.chapter,
                                    cover: cover, controls: controls)
        // No copy in Recent Books (a book opened from elsewhere, or its
        // cover not made yet): read it from the book, in the background (a
        // book's cover picture, or a PDF's first page).
        guard cover == nil else { return }
        let url = self.url
        DispatchQueue.global(qos: .utility).async {
            let jpeg = BookCover.extract(from: url, maxPixelSize: 600).jpeg
            DispatchQueue.main.async {
                guard let jpeg, let image = UIImage(data: jpeg) else { return }
                ReadAloudAudio.shared.setCover(image)
            }
        }
    }

    func readAloudAudioUpdate(chapter: String, playing: Bool) {
        ReadAloudAudio.shared.update(title: state.title, author: state.author, chapter: chapter, playing: playing)
    }

    func readAloudAudioEnd() { ReadAloudAudio.shared.end() }

    /// The book's cover, for the lock screen: the copy Recent Books keeps.
    private var readAloudCover: UIImage? {
        let books = RecentList.books
        guard let item = books.item(at: url), let file = books.coverURL(for: item) else { return nil }
        return UIImage(contentsOfFile: file.path)
    }
}
