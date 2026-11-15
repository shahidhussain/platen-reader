import PlatenCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The window's root: Platen's own home screen. It decides what the reader
/// sees when nothing is being read, and it presents the readers.
///
/// - At launch it goes back to the book that was open when Platen was last
///   left (`LastOpenBook`).
/// - Otherwise, once the reader has chosen a folder, it shows the folder the
///   last book came from as a grid of covers (`FolderBrowserView`). Until
///   then it shows the welcome screen (the Mac's, full screen): the app's
///   name, "Open Book…" and "Choose Folder…".
/// - "Open Book…" shows the system's document picker, which opens the book
///   where it is (Files, iCloud Drive, SMB shares, any file provider) through
///   a security-scoped URL. Nothing is ever copied into the app.
///   "Choose Folder…" picks a folder the same way, kept as a bookmark
///   (`LibraryFolder`): opening one book gives no access to its folder.
/// - Books opened from other apps go straight to the reader (SceneDelegate
///   calls `openBook(at:)`).
///
/// Platen has no library of its own; folders are the library.
final class HomeViewController: UIViewController, UIDocumentPickerDelegate {
    private let library = LibraryFolder.shared
    /// The picker on screen is choosing a folder, not a book.
    private var pickingFolder = false

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
        // The tabs (Home, Recent Books, Recent Folders), whose Home tab is
        // the folder view once a folder is chosen, or the welcome until then.
        let tabs = UIHostingController(rootView: HomeTabs(library: library, actions: HomeActions(
            openBook: { [weak self] in self?.openBook(at: $0) },
            chooseBook: { [weak self] in self?.chooseBook() },
            chooseFolder: { [weak self] in self?.chooseFolder() }
        )))
        addChild(tabs)
        tabs.view.frame = view.bounds
        tabs.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Below the launch cover, if it is up.
        if let launchCover { view.insertSubview(tabs.view, belowSubview: launchCover) } else { view.addSubview(tabs.view) }
        tabs.didMove(toParent: self)
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
        pickingFolder = false
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.contentTypes, asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true // .epub and .mobi look alike otherwise
        present(picker, animated: true)
    }

    /// "Choose Folder…": the folder whose books the home screen shows.
    func chooseFolder() {
        pickingFolder = true
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.directoryURL = library.root
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if pickingFolder {
            library.choose(url)
        } else {
            // The picker dismisses itself; the reader is presented once it has.
            present(book: url)
        }
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
                LastOpenBook.forget() // closed on purpose: next launch, the home screen
                reader?.dismiss(animated: true)
                self?.reader = nil
                NotificationCenter.default.post(name: .platenFolderShouldRefresh, object: nil)
            }
            LastOpenBook.remember(url)
            // Its folder is the one the folder view shows from now on.
            self.library.bookOpened(url)
            self.addToRecents(url)
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

extension HomeViewController {
    /// Puts the book at the top of Recent Books, then (in the background)
    /// adds its title, author and a copy of its cover, so the list shows them
    /// even when the book cannot be reached later. The reader holds access
    /// to the book meanwhile.
    func addToRecents(_ url: URL) {
        guard let item = RecentList.books.opened(url) else { return }
        Task.detached(priority: .utility) {
            let entry = CoverCache.standard().cover(for: url)
            let jpeg = entry.imageURL.flatMap { try? Data(contentsOf: $0) }
            await MainActor.run {
                RecentList.books.update(item.id, title: entry.info.title, author: entry.info.authors.first, cover: jpeg)
            }
        }
    }
}

/// The book that was open when Platen was last left, kept as a bookmark (a
/// reference that survives the file moving, and keeps permission to read
/// it). Launching goes back to it; Close forgets it, so the next launch
/// shows the home screen instead.
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
