import PlatenCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The window's root: Platen's own home screen. It decides what the reader
/// sees when nothing is being read, and it presents the readers.
///
/// - At launch it goes back to the book that was open when Platen was last
///   left (`LastOpenBook`).
/// - Otherwise it shows the home screen (HomeTabs): the welcome the first
///   time ("Open Book…" and "Choose Folder…"), then three tabs: Home (the
///   reader's folders, and Settings), Recent Books and Favourites.
/// - "Open Book…" shows the system's document picker, which opens the book
///   where it is (Files, iCloud Drive, SMB shares, any file provider) through
///   a security-scoped URL. Nothing is ever copied into the app.
///   "Choose Folder…" picks a folder the same way (opening one book gives no
///   access to its folder); it joins the Home list, kept as a bookmark, and
///   opens there.
/// - Books opened from other apps go straight to the reader (SceneDelegate
///   calls `openBook(at:)`).
///
/// Platen has no library of its own; folders are the library.
final class HomeViewController: UIViewController, UIDocumentPickerDelegate {
    /// The tab showing, and the folders open in the Home tab.
    let navigation = HomeNavigation()
    /// The picker on screen is choosing a folder, not a book.
    private var pickingFolder = false

    /// The book or PDF on screen, if any.
    private(set) var reader: ReaderBaseViewController?
    /// The open book's bookmark, which the window hands iOS to reopen it
    /// after the app has been ended (SceneDelegate, BookWindows).
    private(set) var openBookmark: Data?
    /// Told when a reader is made (the start-up animation follows the
    /// first book's progress).
    var onReaderCreated: ((ReaderBaseViewController) -> Void)?

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
        // The home screen: the welcome the first time, then the tabs (Home,
        // Recent Books, Favourites).
        let tabs = UIHostingController(rootView: HomeTabs(navigation: navigation, actions: HomeActions(
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
        moveLibraryFolderToRecents()
    }

    /// Before the tabs, one chosen folder was the home screen (kept under
    /// "libraryFolder"); it becomes a recent folder, once. Resolved in the
    /// background, as it may be on a share that is not connected.
    private func moveLibraryFolderToRecents() {
        guard let data = AppDefaults.store.data(forKey: "libraryFolder") else { return }
        AppDefaults.store.removeObject(forKey: "libraryFolder")
        AppDefaults.store.removeObject(forKey: "libraryCurrentFolder")
        DispatchQueue.global(qos: .utility).async {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            let bookmark = try? url.bookmarkData()
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let bookmark else { return }
            DispatchQueue.main.async {
                if !RecentList.folders.contains(url) { RecentList.folders.opened(url, bookmark: bookmark) }
            }
        }
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
        present(picker, animated: true)
    }

    /// A folder chosen (or, testing, named at launch): it joins Recent
    /// Folders and opens there. Access to it is held while the app runs.
    func showChosenFolder(_ url: URL) {
        FolderAccess.hold(url)
        RecentList.folders.opened(url)
        navigation.show(folder: url)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if pickingFolder {
            showChosenFolder(url)
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
            // (By name: asking the file system could wait on a network share.)
            let isPDF = BookFileType(url) == .pdf
            let reader: ReaderBaseViewController = isPDF ? PDFReaderViewController(url: url) : ReaderViewController(url: url)
            reader.onClose = { [weak self, weak reader] in
                LastOpenBook.forget() // closed on purpose: next launch, the home screen
                reader?.dismiss(animated: true)
                self?.reader = nil
                self?.openBookmark = nil
                self?.view.window?.windowScene?.title = nil
                NotificationCenter.default.post(name: .platenFolderShouldRefresh, object: nil)
            }
            LastOpenBook.remember(url)
            // A favourite's copy on this device (its place out of reach) is
            // not added: the book itself is on the list already.
            if !OfflineCopies.isCopy(url) { RecentList.books.addBook(url) }
            // The window is named for its book (iPad's window switcher), and
            // keeps the book's bookmark for state restoration (BookWindows).
            self.openBookmark = BookWindows.bookmark(for: url)
            self.view.window?.windowScene?.title = RecentList.books.item(at: url)?.displayName
                ?? url.deletingPathExtension().lastPathComponent
            reader.modalPresentationStyle = .fullScreen
            self.reader = reader
            self.onReaderCreated?(reader)
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
/// shows the home screen instead.
enum LastOpenBook {
    private static let key = "lastOpenBook"

    /// True if there is a book to go back to.
    static var isSaved: Bool { AppDefaults.store.data(forKey: key) != nil }

    /// Finds the book to reopen at launch, and calls `completion` on the
    /// main thread with where it is now, or nil: none saved, deleted, or no
    /// answer within `timeout` seconds.
    ///
    /// Resolving a bookmark asks the file system where the file is, and for
    /// a book on a network share that has gone away (or a cloud folder not
    /// answering) that can hang. Done on the main thread at launch, as it
    /// was, it could freeze the app until iOS ended it (it did just that to
    /// Recent Books, for the same reason). So it runs on a background queue
    /// of its own, and launch stops waiting at the time limit and shows the
    /// home screen. The book is only forgotten if it is truly gone, not on a
    /// timeout, so a share that comes back reopens it next time.
    @MainActor static func find(timeout: TimeInterval, completion: @escaping @MainActor (URL?) -> Void) {
        guard let data = AppDefaults.store.data(forKey: key) else { return completion(nil) }
        resolve(data, timeout: timeout, keepsFresh: true, completion: completion)
    }

    /// Where the book a bookmark refers to is now, in the background with a
    /// time limit, as `find` does: for the last book, and for the book a
    /// window had open (BookWindows). `keepsFresh`: the bookmark is the
    /// last book's, so it is renewed if the book has moved, and forgotten if
    /// it is gone.
    @MainActor static func resolve(_ data: Data, timeout: TimeInterval, keepsFresh: Bool = false,
                                   completion: @escaping @MainActor (URL?) -> Void) {
        let answer = AnswerOnce(completion)
        DispatchQueue(label: "org.platenreader.last-book", qos: .userInitiated).async {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
                if keepsFresh { DispatchQueue.main.async { forget() } } // deleted, or no longer reachable
                return answer.send(nil)
            }
            if stale, keepsFresh {
                // Moved: keep a fresh bookmark (made here too, off the main thread).
                let scoped = url.startAccessingSecurityScopedResource()
                let fresh = try? url.bookmarkData()
                if scoped { url.stopAccessingSecurityScopedResource() }
                if let fresh { DispatchQueue.main.async { AppDefaults.store.set(fresh, forKey: key) } }
            }
            answer.send(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { answer.send(nil) }
    }

    /// Hands the first answer to the main thread; later ones are dropped.
    private final class AnswerOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var sent = false
        private let completion: @MainActor (URL?) -> Void
        init(_ completion: @escaping @MainActor (URL?) -> Void) { self.completion = completion }
        func send(_ url: URL?) {
            lock.lock()
            let first = !sent
            sent = true
            lock.unlock()
            guard first else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.completion(url) } }
        }
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
