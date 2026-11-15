import Combine
import CoreGraphics
import Foundation
import ImageIO
import PlatenCore

/// One thing in a folder the folder view shows: a book, or a folder inside
/// it.
struct FolderEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case folder, book }

    /// Where it is. For a book still in iCloud only, the place it will be
    /// once downloaded (not the hidden ".name.icloud" stand-in).
    let url: URL
    /// The file name without its extension (books) or the folder's name.
    let name: String
    let kind: Kind
    /// False for a book whose contents are not on the device yet (in iCloud
    /// only). Its cover cannot be read until it is downloaded.
    var isDownloaded: Bool = true
    /// When the file last changed, so an edited or replaced book gets a new
    /// cover.
    var modified: Date?

    var id: URL { url }
}

/// Reads what is in a folder: the books Platen opens and the folders inside
/// it, in Finder's order (folders first, then by name, with numbers in
/// number order).
enum FolderScanner {
    /// The book file extensions shown (the same types as Info.plist).
    static let bookExtensions: Set<String> = ["epub", "kepub", "mobi", "prc", "azw", "azw3", "pdf", "txt"]

    static func entries(in folder: URL) -> [FolderEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                      .contentModificationDateKey]
        // Hidden files are not skipped here, because iCloud's stand-ins for
        // files not yet downloaded are hidden (".Book.epub.icloud").
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: []
        ) else { return [] }

        var entries: [FolderEntry] = []
        var seen = Set<String>()
        for url in urls {
            let fileName = url.lastPathComponent
            if fileName.hasPrefix(".") {
                // ".Book.epub.icloud" stands for "Book.epub", not downloaded.
                guard fileName.hasSuffix(".icloud"), fileName.count > ".x.icloud".count else { continue }
                let realName = String(fileName.dropFirst().dropLast(".icloud".count))
                let real = folder.appendingPathComponent(realName)
                guard isBook(real), seen.insert(realName).inserted else { continue }
                entries.append(FolderEntry(url: real, name: displayName(real), kind: .book, isDownloaded: false))
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isHidden == true { continue }
            if values?.isDirectory == true, values?.isPackage != true {
                entries.append(FolderEntry(url: url, name: fileName, kind: .folder))
            } else if isBook(url), seen.insert(fileName).inserted {
                // Newer iCloud Drive (and other file providers) list files
                // not yet downloaded under their own names.
                let status = values?.ubiquitousItemDownloadingStatus
                let downloaded = values?.isUbiquitousItem != true || status == nil || status == .current || status == .downloaded
                entries.append(FolderEntry(url: url, name: displayName(url), kind: .book, isDownloaded: downloaded,
                                           modified: values?.contentModificationDate))
            }
        }
        return entries.sorted { a, b in
            if a.kind != b.kind { return a.kind == .folder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func isBook(_ url: URL) -> Bool {
        bookExtensions.contains(url.pathExtension.lowercased())
    }

    /// "Middlemarch.kepub.epub" → "Middlemarch".
    static func displayName(_ url: URL) -> String {
        var name = url.deletingPathExtension()
        if name.pathExtension.lowercased() == "kepub" { name = name.deletingPathExtension() }
        return name.lastPathComponent
    }

    /// True if `url` is `folder` or somewhere inside it.
    static func isInside(_ url: URL, folder: URL) -> Bool {
        let a = canonicalPath(url), b = canonicalPath(folder)
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    /// The path with symbolic links resolved, so "/var/…" and
    /// "/private/var/…" (both seen on iOS) compare equal.
    static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        // resolvingSymlinksInPath drops "/private" only for files that exist
        // (a book may have gone), so do it here too.
        for folder in ["/private/var/", "/private/tmp/"] where path.hasPrefix(folder) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}

/// The folder the reader chose for the folder view, kept as a bookmark
/// (which keeps permission to read it across launches), and the folder
/// inside it that was last looked at.
///
/// Opening one book gives access to that file only, never its folder, so
/// the reader picks the folder once ("Choose Folder…"). Access is held for
/// as long as the app runs.
@MainActor
final class LibraryFolder: ObservableObject {
    static let shared = LibraryFolder(defaults: AppDefaults.store)

    /// The chosen folder, while it can be reached.
    @Published private(set) var root: URL?
    /// The folder on show: the one the last book was opened from, if it is
    /// inside `root`; otherwise `root` itself.
    @Published private(set) var current: URL?

    private let defaults: UserDefaults
    private static let bookmarkKey = "libraryFolder"
    private static let currentKey = "libraryCurrentFolder"
    private var accessing: URL?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
            // Deleted, or on a share or provider that has gone away.
            defaults.removeObject(forKey: Self.bookmarkKey)
            return
        }
        startAccess(url)
        if stale, let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: Self.bookmarkKey) }
        root = url
        // Back to the folder last shown, if it is still there.
        if let path = defaults.string(forKey: Self.currentKey) {
            let saved = URL(fileURLWithPath: path, isDirectory: true)
            if FolderScanner.isInside(saved, folder: url),
               (try? saved.checkResourceIsReachable()) == true {
                current = saved
            }
        }
        if current == nil { current = url }
    }

    /// The reader chose a folder (a security-scoped URL from the folder
    /// picker).
    func choose(_ url: URL) {
        if let accessing { accessing.stopAccessingSecurityScopedResource() }
        accessing = nil
        startAccess(url)
        guard let data = try? url.bookmarkData() else { return }
        defaults.set(data, forKey: Self.bookmarkKey)
        root = url
        show(url)
    }

    /// A book was opened: if it lives inside the chosen folder, its folder is
    /// the one shown from now on.
    func bookOpened(_ book: URL) {
        guard let root, FolderScanner.isInside(book, folder: root) else { return }
        show(book.deletingLastPathComponent())
    }

    /// The folder view moved to another folder.
    func show(_ folder: URL) {
        current = folder
        defaults.set(folder.path, forKey: Self.currentKey)
    }

    /// The folders from `root` down to `current`, for the navigation path
    /// (not including `root` itself).
    var pathFromRoot: [URL] {
        guard let root, let current, FolderScanner.isInside(current, folder: root) else { return [] }
        var path: [URL] = []
        var folder = current
        while FolderScanner.canonicalPath(folder) != FolderScanner.canonicalPath(root) {
            path.insert(folder, at: 0)
            let parent = folder.deletingLastPathComponent()
            if parent == folder { return [] }
            folder = parent
        }
        return path
    }

    private func startAccess(_ url: URL) {
        if url.startAccessingSecurityScopedResource() { accessing = url }
    }
}

/// What one folder holds, kept up to date: its books and folders, and the
/// books' covers as they are made. Watches the folder (books added,
/// removed or downloaded) through `NSFilePresenter` while its view is on
/// screen (`start()` / `stop()`); the view also calls `refresh()` when the
/// app comes back to the front.
@MainActor
final class FolderModel: NSObject, ObservableObject {
    let folder: URL
    @Published private(set) var entries: [FolderEntry] = []
    /// False until the folder has been read once. Reading a large folder,
    /// or one on a network share, takes a while; until then the view says
    /// it is looking, not that the folder is empty.
    @Published private(set) var hasLoaded = false
    /// Covers made so far, by book URL. A book with no entry is waiting.
    @Published private(set) var covers: [URL: BookCoverInfo] = [:]
    @Published private(set) var images: [URL: CGImage] = [:]
    /// Books being downloaded because the reader tapped them; opened once
    /// they arrive.
    @Published private(set) var downloading: Set<URL> = []

    private let cache: CoverCache
    /// Covers are made one at a time, in the background, in grid order.
    private static let coverQueue = DispatchQueue(label: "org.platenreader.covers", qos: .userInitiated)
    /// Folders are read on their own queue, so a long run of covers being
    /// made never holds up a new book appearing.
    private static let scanQueue = DispatchQueue(label: "org.platenreader.folder-scan", qos: .userInitiated)
    /// The books whose covers have been asked for, with the modification
    /// date they had then.
    private var requested: [URL: Date?] = [:]
    private var downloadTimer: Timer?
    private var refreshPending = false
    /// Called when a book the reader tapped has finished downloading.
    var onDownloaded: ((URL) -> Void)?

    init(folder: URL, cache: CoverCache = .standard()) {
        self.folder = folder
        self.cache = cache
        super.init()
        refresh()
    }

    private var watching = false

    /// Starts watching the folder (when its view appears), and reads it again.
    func start() {
        if !watching {
            watching = true
            NSFileCoordinator.addFilePresenter(self)
        }
        refresh()
    }

    /// Stops watching (when its view goes away or is covered by another
    /// folder's). The system holds file presenters until they are removed.
    func stop() {
        guard watching else { return }
        watching = false
        NSFileCoordinator.removeFilePresenter(self)
    }

    /// Reads the folder again.
    func refresh() {
        let folder = folder
        Self.scanQueue.async {
            let entries = FolderScanner.entries(in: folder)
            DispatchQueue.main.async { [weak self] in self?.apply(entries) }
        }
    }

    private func apply(_ new: [FolderEntry]) {
        if new != entries { entries = new }
        if !hasLoaded { hasLoaded = true }
        // Covers of books that changed are made again (their cache key
        // changes); those of books that went are dropped.
        let urls = Set(new.map(\.url))
        requested = requested.filter { urls.contains($0.key) }
        covers = covers.filter { urls.contains($0.key) }
        images = images.filter { urls.contains($0.key) }
        for entry in new where entry.kind == .book && entry.isDownloaded {
            loadCover(entry)
        }
        // A tapped book that has arrived: open it.
        for url in downloading where new.contains(where: { $0.url == url && $0.isDownloaded }) {
            downloading.remove(url)
            onDownloaded?(url)
        }
        if downloading.isEmpty { downloadTimer?.invalidate(); downloadTimer = nil }
    }

    private func loadCover(_ entry: FolderEntry) {
        let url = entry.url
        if let asked = requested[url], asked == entry.modified { return }
        requested[url] = entry.modified
        let cache = cache
        Self.coverQueue.async {
            let entry = cache.cover(for: url)
            let image = entry.imageURL.flatMap(Self.decode)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requested[url] != nil else { return }
                self.covers[url] = entry.info
                self.images[url] = image
            }
        }
    }

    /// Covers still to make, and how many books want one, for the progress
    /// bar while they are made (books in iCloud only have none yet).
    var coverProgress: (done: Int, total: Int) {
        let books = entries.filter { $0.kind == .book && $0.isDownloaded }
        return (books.filter { covers[$0.url] != nil }.count, books.count)
    }

    /// Decodes a cached cover now, off the main thread, so scrolling never
    /// waits for it.
    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// A book in iCloud only was tapped: download it, then open it
    /// (`onDownloaded`). Progress is checked every second as well as through
    /// file presentation, which does not always report downloads.
    func download(_ entry: FolderEntry) {
        guard !downloading.contains(entry.url) else { return }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: entry.url)
        } catch {
            log.error("Could not download \(entry.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        downloading.insert(entry.url)
        if downloadTimer == nil {
            downloadTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// Several changes often arrive together (a folder copied in): read the
    /// folder once, a moment after the first.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }
}

extension FolderModel: NSFilePresenter {
    nonisolated var presentedItemURL: URL? { folder }
    nonisolated var presentedItemOperationQueue: OperationQueue { .main }

    nonisolated func presentedItemDidChange() { changed() }
    nonisolated func presentedSubitemDidChange(at url: URL) { changed() }
    nonisolated func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
    nonisolated func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        changed()
        completionHandler(nil)
    }

    nonisolated private func changed() {
        DispatchQueue.main.async { [weak self] in self?.scheduleRefresh() }
    }
}
