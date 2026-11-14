import PlatenCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The window's root: Platen's own home screen. It decides what the reader
/// sees when nothing is being read, and it presents the readers.
///
/// - At launch it goes back to the book that was open when Platen was last
///   left (`LastOpenBook`); otherwise it shows the welcome screen (the Mac's,
///   full screen): the app's name and one "Open Book…" button.
/// - "Open Book…" shows the system's document picker, which opens the book
///   where it is (Files, iCloud Drive, SMB shares, any file provider) through
///   a security-scoped URL. Nothing is ever copied into the app.
/// - Books opened from other apps go straight to the reader (SceneDelegate
///   calls `openBook(at:)`).
///
/// Platen has no library of its own; folders are the library. (A view of the
/// folder the last book came from is planned to replace the welcome here.)
final class HomeViewController: UIViewController, UIDocumentPickerDelegate {
    /// The book or PDF on screen, if any.
    private(set) var reader: ReaderBaseViewController?

    /// A book asked for before this screen was in the window (at launch, from
    /// another app). Presenting then would lay the book out at zero size, so
    /// it waits for `viewDidAppear`.
    private var pendingBook: URL?
    private var hasAppeared = false
    /// While a book opens at launch: a plain page in the theme's colour over
    /// the welcome, so the welcome does not flash up first.
    private var launchCover: UIView?

    /// The book types Platen opens, as declared in Info.plist. Plain text
    /// is shown as a book too (see PlatenCore's TextBook).
    static let contentTypes: [UTType] = [
        UTType("org.idpf.epub-container"), UTType("com.kobo.kepub"),
        UTType("com.amazon.mobi"), UTType("com.amazon.azw"), UTType("com.amazon.azw3"),
        .plainText, .pdf,
    ].compactMap { $0 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let welcome = UIHostingController(rootView: WelcomeView(open: { [weak self] in self?.chooseBook() }))
        addChild(welcome)
        welcome.view.frame = view.bounds
        welcome.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        welcome.view.backgroundColor = .clear
        view.addSubview(welcome.view)
        welcome.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if let url = pendingBook {
            pendingBook = nil
            present(book: url, animated: false)
        }
    }

    // MARK: - Choosing a book

    /// "Open Book…": the system's document picker, opening in place (not
    /// `asCopy`), so the book stays where it is and its URL is the original.
    func chooseBook() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.contentTypes, asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true // .epub and .mobi look alike otherwise
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // The picker dismisses itself; the reader is presented once it has.
        if let url = urls.first { present(book: url) }
    }

    // MARK: - Opening

    /// Opens a book: one handed to the app from outside (another app, Files'
    /// "Open in", a debug launch argument), the one reopened at launch, or
    /// one chosen here. Replaces a book that is already open.
    func openBook(at url: URL) {
        present(book: url)
    }

    private func coverUntilBookOpens() {
        guard launchCover == nil else { return }
        loadViewIfNeeded()
        let cover = UIView(frame: view.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = ReaderSettings.shared.theme(for: traitCollection).uiBackground
        view.addSubview(cover)
        launchCover = cover
    }

    private func present(book url: URL, animated: Bool = true) {
        guard hasAppeared else {
            pendingBook = url
            coverUntilBookOpens()
            return
        }
        let show = { [weak self] in
            guard let self else { return }
            // PDFs are shown by PDFKit; everything else by the book reader.
            let isPDF = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true
                || url.pathExtension.lowercased() == "pdf"
            let reader: ReaderBaseViewController = isPDF ? PDFReaderViewController(url: url) : ReaderViewController(url: url)
            reader.onClose = { [weak self, weak reader] in
                LastOpenBook.forget() // closed on purpose: next launch, the welcome
                reader?.dismiss(animated: true)
                self?.reader = nil
            }
            LastOpenBook.remember(url)
            reader.modalPresentationStyle = .fullScreen
            self.reader = reader
            self.present(reader, animated: animated) { [weak self] in
                self?.launchCover?.removeFromSuperview()
                self?.launchCover = nil
            }
        }
        if let reader {
            // Replace the book that is open.
            reader.savePositionNow()
            reader.dismiss(animated: false, completion: show)
            self.reader = nil
        } else if let presented = presentedViewController {
            // The picker (or anything else) still on its way out.
            presented.dismiss(animated: false, completion: show)
        } else {
            show()
        }
    }
}

/// The book that was open when Platen was last left, kept as a bookmark (a
/// reference that survives the file moving, and keeps permission to read
/// it). Launching goes back to it; Close forgets it, so the next launch
/// shows the welcome screen instead.
enum LastOpenBook {
    private static let key = "lastOpenBook"

    /// The book to reopen at launch, if there is one and it can still be
    /// reached.
    static var url: URL? {
        guard let data = AppDefaults.store.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
            forget() // deleted, or no longer reachable
            return nil
        }
        if stale { remember(url) }
        return url
    }

    static func remember(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData() { AppDefaults.store.set(data, forKey: key) }
    }

    static func forget() {
        AppDefaults.store.removeObject(forKey: key)
    }
}
