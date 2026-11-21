import Combine
import CoreGraphics
import Foundation
import ImageIO
import PlatenCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One thing in a folder the folder view shows: a book, or a folder inside
/// it.
struct FolderEntry: Identifiable, Equatable, Sendable, Codable {
    enum Kind: String, Equatable, Sendable, Codable { case folder, book }

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
    /// cover (and for sorting).
    var modified: Date?
    /// When it was made, and its size in bytes, for sorting.
    var created: Date?
    var size: Int64?

    var id: URL { url }
}

/// The kinds of file Platen opens (the same types as Info.plist), by
/// extension, for the folder view's filter.
enum BookFileType: String, CaseIterable, Identifiable, Sendable {
    case epub, kepub, mobi, kindle, pdf, text

    var id: String { rawValue }

    init?(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let inner = url.deletingPathExtension().pathExtension.lowercased()
        switch ext {
        case "epub": self = inner == "kepub" ? .kepub : .epub // Name.kepub.epub
        case "kepub": self = .kepub
        case "mobi", "prc": self = .mobi
        case "azw", "azw3": self = .kindle
        case "pdf": self = .pdf
        case "txt": self = .text
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .epub: return "EPUB"
        case .kepub: return "KEPUB"
        case .mobi: return "MOBI"
        case .kindle: return "AZW and AZW3"
        case .pdf: return "PDF"
        case .text: return String(localized: "Plain Text")
        }
    }
}

/// How the folder view orders its books (folders always come first, by
/// name).
enum FolderSort: String, CaseIterable, Identifiable, Sendable {
    case name, title, author, modified, created, size
    var id: String { rawValue }

    var label: String {
        switch self {
        // The file's name (without its extension), not the book's title:
        // the folder knows every file's name at once, but titles only once
        // each book has been read (and never for one only in iCloud).
        case .name: return String(localized: "File Name")
        case .title: return String(localized: "Title")
        case .author: return String(localized: "Author")
        case .modified: return String(localized: "Date Modified")
        case .created: return String(localized: "Date Created")
        case .size: return String(localized: "Size")
        }
    }

    /// Names, titles and authors A to Z; dates newest first; sizes largest
    /// first. Ties by file name. Titles and authors come from `info` (what
    /// has been read of each book so far): a book with no title known sorts
    /// by its file name, and one with no author known goes after those
    /// with one. Authors sort as the book gives them (usually first name
    /// first).
    func sorted(_ entries: [FolderEntry], info: [URL: BookCoverInfo] = [:]) -> [FolderEntry] {
        func title(_ e: FolderEntry) -> String { info[e.url]?.title ?? e.name }
        func author(_ e: FolderEntry) -> String? { info[e.url]?.authors.first }
        func ordered(_ x: String, _ y: String) -> Bool? {
            let order = x.localizedStandardCompare(y)
            return order == .orderedSame ? nil : order == .orderedAscending
        }
        return entries.sorted { a, b in
            if a.kind != b.kind { return a.kind == .folder }
            if a.kind == .book, self != .name {
                switch self {
                case .title:
                    if let answer = ordered(title(a), title(b)) { return answer }
                case .author:
                    switch (author(a), author(b)) {
                    case let (x?, y?): if let answer = ordered(x, y) { return answer }
                    case (.some, nil): return true
                    case (nil, .some): return false
                    case (nil, nil): break
                    }
                    if let answer = ordered(title(a), title(b)) { return answer }
                case .modified where a.modified != b.modified:
                    return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
                case .created where a.created != b.created:
                    return (a.created ?? .distantPast) > (b.created ?? .distantPast)
                case .size where a.size != b.size:
                    return (a.size ?? 0) > (b.size ?? 0)
                default: break
                }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// What the words under each cover in a folder say.
enum CoverLabel: String, CaseIterable, Identifiable, Sendable {
    /// The file's name without its extension ("Middlemarch").
    case fileName
    /// The book's title, with its author below.
    case titleThenAuthor
    /// The author, with the book's title below.
    case authorThenTitle
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fileName: return String(localized: "File Name")
        case .titleThenAuthor: return String(localized: "Title, then Author")
        case .authorThenTitle: return String(localized: "Author, then Title")
        }
    }

    /// The first and second lines under a cover. A book not read yet (or
    /// only in iCloud) has no title or author known: its file name stands
    /// in for the title.
    func lines(fileName: String, title: String?, author: String?) -> (String, String?) {
        let title = title ?? fileName
        switch self {
        case .fileName: return (fileName, nil)
        case .titleThenAuthor: return (title, author)
        case .authorThenTitle: return author.map { ($0, title) } ?? (title, nil)
        }
    }
}

/// How the folder view shows a folder, one choice for every folder, kept
/// with the settings: which kinds of book (all unless the reader turns some
/// off in the View Options sheet, never none), in what order, what the
/// words under each cover say, and how many covers across (a pinch changes
/// it).
@MainActor
final class BookTypeFilter: ObservableObject {
    static let shared = BookTypeFilter(defaults: AppDefaults.store)

    @Published private(set) var hidden: Set<BookFileType>
    @Published var sort: FolderSort { didSet { defaults.set(sort.rawValue, forKey: "folderSort") } }
    @Published var coverLabel: CoverLabel { didSet { defaults.set(coverLabel.rawValue, forKey: "folderCoverLabel") } }
    /// Covers across, when the reader has pinched (nil: the default for the
    /// screen).
    @Published var columns: Int? { didSet { defaults.set(columns, forKey: "folderColumns") } }
    /// When a pinch on a grid last moved: a tap that ends a pinch must not
    /// open the book under the fingers.
    var lastPinch: Date = .distantPast
    var justPinched: Bool { Date().timeIntervalSince(lastPinch) < 0.4 }
    private let defaults: UserDefaults
    private static let key = "hiddenBookTypes"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(BookFileType.init(rawValue:)))
        hidden = saved.count == BookFileType.allCases.count ? [] : saved
        sort = defaults.string(forKey: "folderSort").flatMap(FolderSort.init) ?? .name
        coverLabel = defaults.string(forKey: "folderCoverLabel").flatMap(CoverLabel.init) ?? .titleThenAuthor
        columns = defaults.object(forKey: "folderColumns") as? Int
    }

    /// True unless some kinds are hidden (the filter button shows that).
    var showsAll: Bool { hidden.isEmpty }

    func isShown(_ type: BookFileType) -> Bool { !hidden.contains(type) }

    /// Whether a file in the folder is shown (folders always are).
    func shows(_ url: URL) -> Bool { BookFileType(url).map(isShown) ?? false }

    /// Shows or hides a kind; the last kind shown cannot be hidden.
    func toggle(_ type: BookFileType) {
        if hidden.contains(type) {
            hidden.remove(type)
        } else if hidden.count < BookFileType.allCases.count - 1 {
            hidden.insert(type)
        }
        defaults.set(hidden.map(\.rawValue).sorted(), forKey: Self.key)
    }
}

/// Reads what is in a folder: the books Platen opens and the folders inside
/// it, in Finder's order (folders first, then by name, with numbers in
/// number order).
enum FolderScanner {

    static func entries(in folder: URL) -> [FolderEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                      .contentModificationDateKey, .creationDateKey, .fileSizeKey]
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
                                           modified: values?.contentModificationDate,
                                           created: values?.creationDate, size: values?.fileSize.map(Int64.init)))
            }
        }
        return entries.sorted { a, b in
            if a.kind != b.kind { return a.kind == .folder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func isBook(_ url: URL) -> Bool { BookFileType(url) != nil }

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

    /// The path in one form, so "/var/…" and "/private/var/…" (both seen
    /// on iOS for the same place) compare equal. Worked out from the text
    /// alone: resolving links would touch the disk, which can hang on a
    /// network share that has gone away, and this runs on the main thread.
    static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for folder in ["/private/var/", "/private/tmp/"] where path.hasPrefix(folder) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}

/// What one folder holds, kept up to date: its books and folders, and the
/// books' covers as they are made. Watches the folder (books added,
/// removed or downloaded) through `NSFilePresenter` while its view is on
/// screen (`start()` / `stop()`); the view also calls `refresh()` when the
/// app comes back to the front.
///
/// Each folder has queues of its own, so a read that hangs (a network share
/// that has gone away) holds up only that folder, never the others; when
/// the folder leaves the screen, its covers not yet made are skipped. The
/// last listing of each folder is kept (`FolderListingCache`), so a folder
/// shows at once and is then brought up to date. Covers are kept as files
/// (CoverCache) and decoded only for the tiles on screen (`CoverImages`).
@MainActor
final class FolderModel: NSObject, ObservableObject {
    let folder: URL
    @Published private(set) var entries: [FolderEntry] = []
    /// False until the folder has been read once (or a listing kept from
    /// before is shown). Reading a large folder, or one on a network share,
    /// takes a while; until then the view says it is looking, not that the
    /// folder is empty.
    @Published private(set) var hasLoaded = false
    /// Covers made so far, by book URL. A book with no entry is waiting.
    @Published private(set) var covers: [URL: BookCoverInfo] = [:]
    /// The cover picture files (in the cover cache), by book URL.
    @Published private(set) var coverFiles: [URL: URL] = [:]
    /// Books being downloaded because the reader tapped them; opened once
    /// they arrive.
    @Published private(set) var downloading: Set<URL> = []

    private let cache: CoverCache
    /// This folder's own queues: covers one at a time in grid order, and
    /// reading the folder (kept apart, so covers never hold up a new book
    /// appearing).
    private let coverQueue: DispatchQueue
    private let scanQueue: DispatchQueue
    /// Set while the folder is on screen; covers still queued are skipped
    /// once it is not.
    private let active = ActiveFlag()
    /// The books whose covers have been asked for, with the modification
    /// date they had then.
    private var requested: [URL: Date?] = [:]
    /// The same, for books in iCloud only (their stored thumbnails; see
    /// `loadCloudThumbnail`).
    private var requestedCloud: [URL: Date?] = [:]
    private var downloadTimer: Timer?
    private var refreshPending = false
    /// A read of the folder is under way; another asked for meanwhile
    /// follows it (`rescan`), rather than queueing up behind a slow one.
    private var scanning = false
    private var rescan = false
    /// Called when a book the reader tapped has finished downloading.
    var onDownloaded: ((URL) -> Void)?

    init(folder: URL, cache: CoverCache = .standard()) {
        self.folder = folder
        self.cache = cache
        coverQueue = DispatchQueue(label: "org.platenreader.covers", qos: .userInitiated)
        scanQueue = DispatchQueue(label: "org.platenreader.folder-scan", qos: .userInitiated)
        super.init()
        if let kept = FolderListingCache.listing(of: folder) {
            entries = kept
            hasLoaded = true
        }
    }

    private var watching = false

    /// Starts watching the folder (when its view appears), and reads it again.
    func start() {
        active.isOn = true
        if !watching {
            watching = true
            Self.presenterQueue.async { NSFileCoordinator.addFilePresenter(self) }
        }
        // Covers asked for before, but skipped while away, are asked again.
        requested = requested.filter { covers[$0.key] != nil }
        apply(entries, fresh: false)
        refresh()
    }

    /// Stops watching (when its view goes away or is covered by another
    /// folder's). The system holds file presenters until they are removed.
    func stop() {
        active.isOn = false
        downloadTimer?.invalidate()
        downloadTimer = nil
        guard watching else { return }
        watching = false
        Self.presenterQueue.async { NSFileCoordinator.removeFilePresenter(self) }
    }

    /// Adding and removing a file presenter wait for the system's file
    /// coordination, which can hang for a network share that has gone
    /// away (it froze the app when the folder view left the screen), so
    /// they are done in order on a queue of their own.
    private static let presenterQueue = DispatchQueue(label: "org.platenreader.folder-presenter", qos: .utility)

    /// Reads the folder again.
    func refresh() {
        guard !scanning else { rescan = true; return }
        scanning = true
        let folder = folder
        scanQueue.async {
            let entries = FolderScanner.entries(in: folder)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanning = false
                FolderListingCache.keep(entries, of: folder)
                self.apply(entries, fresh: true)
                if self.rescan {
                    self.rescan = false
                    self.refresh()
                }
            }
        }
    }

    private func apply(_ new: [FolderEntry], fresh: Bool) {
        if new != entries { entries = new }
        if fresh, !hasLoaded { hasLoaded = true }
        // Covers of books that changed are made again (their cache key
        // changes); those of books that went are dropped.
        let urls = Set(new.map(\.url))
        requested = requested.filter { urls.contains($0.key) }
        requestedCloud = requestedCloud.filter { urls.contains($0.key) }
        covers = covers.filter { urls.contains($0.key) }
        coverFiles = coverFiles.filter { urls.contains($0.key) }
        for entry in new where entry.kind == .book {
            if entry.isDownloaded { loadCover(entry) } else { loadCloudThumbnail(entry) }
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
        let active = active
        coverQueue.async {
            // Left the screen: skip, and let start() ask again.
            guard active.isOn else {
                DispatchQueue.main.async { [weak self] in self?.requested[url] = nil }
                return
            }
            let made = cache.cover(for: url)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requested[url] != nil else { return }
                self.covers[url] = made.info
                self.coverFiles[url] = made.imageURL
            }
        }
    }

    /// The cover of a book in iCloud only, without downloading the book.
    ///
    /// Its own cover cannot be read until it is downloaded, but iCloud Drive
    /// usually keeps a small picture of each file, made by the device that
    /// uploaded it (for a book, its cover), and that is what the Files app
    /// shows. Quick Look's thumbnail generator fetches it: a few kilobytes
    /// through the system's own iCloud, as a tap on the book fetches the
    /// book. If iCloud has none (the uploading device could not make one),
    /// the tile stays plain. The picture is kept in the cover cache, under a
    /// key of its own (made from the book's path and date, as no size is
    /// known), and replaced by the book's real cover once it is downloaded.
    /// Asked for one at a time, in grid order, like the covers.
    private func loadCloudThumbnail(_ entry: FolderEntry) {
        let url = entry.url
        if let asked = requestedCloud[url], asked == entry.modified { return }
        requestedCloud[url] = entry.modified
        let cache = cache
        let active = active
        let key = CoverCache.key(path: "icloud-thumbnail:" + FolderScanner.canonicalPath(url), size: 0,
                                 modified: entry.modified ?? .distantPast)
        coverQueue.async {
            guard active.isOn else {
                DispatchQueue.main.async { [weak self] in self?.requestedCloud[url] = nil }
                return
            }
            let made = cache.cached(key: key) ?? Self.cloudThumbnail(of: url, maxPixelSize: cache.maxPixelSize)
                .map { cache.store(BookCover.Result(info: BookCoverInfo(), jpeg: $0), key: key) }
            guard let made, made.imageURL != nil else { return }
            DispatchQueue.main.async { [weak self] in
                // Not if the book has arrived meanwhile and has its own.
                guard let self, self.requestedCloud[url] != nil, self.requested[url] == nil else { return }
                self.covers[url] = made.info
                self.coverFiles[url] = made.imageURL
            }
        }
    }

    /// iCloud's stored picture of a file, as a JPEG, or nil if it has none
    /// (or none comes within 15 seconds). Only a real thumbnail is taken,
    /// never the generic icon for the file's type. Waits, so call it on a
    /// background queue.
    private nonisolated static func cloudThumbnail(of url: URL, maxPixelSize: Int) -> Data? {
        let side = CGFloat(maxPixelSize) / 3
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side * 2 / 3, height: side),
                                                   scale: 3, representationTypes: .thumbnail)
        let done = DispatchSemaphore(value: 0)
        let result = ThumbnailResult()
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            if let error { log.info("No iCloud thumbnail for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            result.image = representation?.cgImage
            done.signal()
        }
        guard done.wait(timeout: .now() + 15) == .success, let image = result.image else {
            QLThumbnailGenerator.shared.cancel(request)
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Covers still to make, and how many books want one, for the progress
    /// bar while they are made (books in iCloud only have none yet).
    var coverProgress: (done: Int, total: Int) {
        let books = entries.filter { $0.kind == .book && $0.isDownloaded }
        return (books.filter { covers[$0.url] != nil }.count, books.count)
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

/// Carries a thumbnail from Quick Look's callback to the queue waiting for it.
private final class ThumbnailResult: @unchecked Sendable {
    var image: CGImage?
}

/// A switch read from background queues (is the folder still on screen?).
final class ActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The last listing of each folder, so a folder shows at once when opened
/// again (in this run, or after a relaunch) and is brought up to date as it
/// is read. Kept in memory and as small JSON files in Caches (the system
/// may clear them; the folder is then simply read).
enum FolderListingCache {
    @MainActor private static var memory: [String: [FolderEntry]] = [:]

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Listings", isDirectory: true)
    }

    private static func file(for folder: URL) -> URL {
        let key = CoverCache.key(path: FolderScanner.canonicalPath(folder), size: 0, modified: .distantPast)
        return directory.appendingPathComponent(key + ".json")
    }

    @MainActor
    static func listing(of folder: URL) -> [FolderEntry]? {
        let key = FolderScanner.canonicalPath(folder)
        if let kept = memory[key] { return kept }
        guard let data = try? Data(contentsOf: file(for: folder)),
              let kept = try? JSONDecoder().decode([FolderEntry].self, from: data) else { return nil }
        memory[key] = kept
        return kept
    }

    @MainActor
    static func keep(_ entries: [FolderEntry], of folder: URL) {
        let key = FolderScanner.canonicalPath(folder)
        guard memory[key] != entries else { return }
        memory[key] = entries
        let file = file(for: folder)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
        }
    }
}

/// Cover pictures decoded for the tiles on screen, at about the size they
/// are shown (not the cover file's full size), and kept in a cache the
/// system empties when memory runs short. Before, every folder kept all its
/// covers decoded at full size, which in a folder of hundreds of books took
/// hundreds of megabytes.
final class CoverImages: @unchecked Sendable {
    static let shared = CoverImages()
    private let cache = NSCache<NSURL, CGImage>()
    private let queue = DispatchQueue(label: "org.platenreader.cover-images", qos: .userInitiated, attributes: .concurrent)
    /// Pixels on the longest side: a tile is at most 200 points wide, at 3×.
    static let maxPixels = 600

    private init() {
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    func cached(_ file: URL) -> CGImage? { cache.object(forKey: file as NSURL) }

    func image(_ file: URL) async -> CGImage? {
        if let image = cached(file) { return image }
        return await withCheckedContinuation { continuation in
            queue.async {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.maxPixels,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                let image = CGImageSourceCreateWithURL(file as CFURL, nil)
                    .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
                if let image { self.cache.setObject(image, forKey: file as NSURL, cost: image.bytesPerRow * image.height) }
                continuation.resume(returning: image)
            }
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
