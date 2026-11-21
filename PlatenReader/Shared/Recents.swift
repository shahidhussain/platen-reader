import Combine
import Foundation
import PlatenCore

/// A book or folder on one of the home screen's lists: Recent Books, the
/// Home tab's folders, or Favourites.
///
/// It is found again through a bookmark (a reference that survives the item
/// being moved or renamed, and keeps permission to read it), never through
/// its path, which is kept only to recognise the same item opened twice and
/// to say where it was.
struct RecentItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var bookmark: Data
    /// The file or folder name, as it was ("Middlemarch.epub", "Kids").
    var name: String
    /// The book's own title and first author, if it names them.
    var title: String?
    var author: String?
    /// The path when last opened: to spot the same item again, and to show
    /// the folder it is in. Never used to open it.
    var path: String
    var lastOpened: Date
    /// A copy of the cover is kept with the list (`RecentList.coverURL`).
    var hasCover = false
    /// Where it is stored (on this device, iCloud Drive, a network share, a
    /// drive), for the icon; and where it is, as a reader would say it
    /// ("iCloud Drive/Books/Kids", "smb://nas/books/Kids"). Worked out when
    /// it was opened; older entries work them out from `path`.
    var storage: StorageKind?
    var location: String?

    var storageKind: StorageKind { storage ?? StoragePlace(path: path).kind }
    var locationText: String { location ?? StoragePlace(path: path).location }

    /// "Middlemarch" for "Middlemarch.kepub.epub"; a folder's own name.
    var displayName: String { title ?? FolderScanner.displayName(Self.pathURL(path)) }

    /// The folder it is in ("Kids"), to tell apart two items of one name.
    var place: String { Self.pathURL(path).deletingLastPathComponent().lastPathComponent }

    /// A saved path as a URL, for working with its name and folders only,
    /// without touching the disk. Plain `URL(fileURLWithPath:)` asks the
    /// file system whether the path is a folder, and for a book on a network
    /// share that has gone away (or a cloud folder not answering) that
    /// question can hang: building the Recent Books list on the main thread
    /// once waited more than 10 seconds and iOS ended the app. Saying it is
    /// not a folder costs nothing here: only the path's text is used.
    nonisolated static func pathURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: false)
    }
}

/// Where a file or folder is kept, for the icon in Recent Folders.
enum StorageKind: String, Codable, Sendable {
    case device, iCloud, network, drive, otherCloud

    var symbol: String {
        switch self {
        case .device: return "iphone"
        case .iCloud: return "icloud"
        case .network: return "server.rack"
        case .drive: return "externaldrive"
        case .otherCloud: return "cloud"
        }
    }

    var label: String {
        switch self {
        case .device: return String(localized: "On this device")
        case .iCloud: return String(localized: "iCloud Drive")
        case .network: return String(localized: "Network share")
        case .drive: return String(localized: "External drive")
        case .otherCloud: return String(localized: "Cloud storage")
        }
    }
}

/// Where a path is, worked out from the path alone (no disk access, so it
/// never waits on a share that has gone away): iOS keeps each kind of
/// storage in a place of its own.
/// - iCloud Drive: `…/Mobile Documents/com~apple~CloudDocs/…`, or an app's
///   own iCloud folder `…/Mobile Documents/iCloud~com~app/Documents/…`.
/// - Network shares (Files > Connect to Server):
///   `…/LiveFiles/com.apple.filesystems.smbclientd/<mount>/<share>/…`. The
///   server's name is not in the path; `RecentList` adds it when it can.
/// - External drives: `…/LiveFiles/com.apple.filesystems.userfsd/…` (and
///   other LiveFiles file systems); on the Mac, `/Volumes/<name>/…`.
/// - This device: On My iPhone (`…/File Provider Storage/…`), or an app's
///   own folder (`…/Containers/Data/Application/<id>/Documents/…`).
/// - Other providers (Dropbox, Google Drive…): `…/CloudStorage/<name>/…`.
struct StoragePlace: Equatable, Sendable {
    var kind: StorageKind
    /// The path as the reader would say it, ending in the folder itself.
    var location: String

    init(path: String) {
        let parts = path.split(separator: "/").map(String.init)
        func after(_ marker: String, skipping skip: Int = 0) -> [String]? {
            guard let i = parts.firstIndex(of: marker) else { return nil }
            return Array(parts.dropFirst(i + 1 + skip))
        }
        func join(_ head: String, _ rest: [String]) -> String { ([head] + rest).joined(separator: "/") }

        if let rest = after("com~apple~CloudDocs") {
            self.init(kind: .iCloud, location: join(String(localized: "iCloud Drive"), rest))
        } else if let i = parts.firstIndex(of: "Mobile Documents"), parts.count > i + 1 {
            // An app's own iCloud folder: iCloud~com~maker~App/Documents/…
            let app = parts[i + 1].split(separator: "~").last.map(String.init) ?? parts[i + 1]
            let rest = Array(parts.dropFirst(i + 2)).drop { $0 == "Documents" }
            self.init(kind: .iCloud, location: join(String(localized: "iCloud Drive"), [app] + rest))
        } else if let rest = after("com.apple.filesystems.smbclientd", skipping: 1) {
            self.init(kind: .network, location: join("smb:/", rest))
        } else if let i = parts.firstIndex(of: "LiveFiles"), parts.count > i + 2 {
            // A drive: <file system>/<mount or volume>/…
            let rest = Array(parts.dropFirst(i + 2))
            self.init(kind: .drive, location: rest.joined(separator: "/"))
        } else if parts.first == "Volumes", parts.count > 1 {
            self.init(kind: .drive, location: Array(parts.dropFirst()).joined(separator: "/"))
        } else if let rest = after("File Provider Storage") {
            self.init(kind: .device, location: join(String(localized: "On My iPhone"), rest))
        } else if let i = parts.firstIndex(of: "Application"), parts.count > i + 2, parts[i + 2] == "Documents" {
            self.init(kind: .device, location: join(String(localized: "On My iPhone"), ["Platen Reader"] + parts.dropFirst(i + 3)))
        } else if let rest = after("CloudStorage") {
            self.init(kind: .otherCloud, location: rest.joined(separator: "/"))
        } else {
            self.init(kind: .device, location: path)
        }
    }

    init(kind: StorageKind, location: String) {
        self.kind = kind
        self.location = location
    }
}

/// The recent books, or the recent folders: newest first, at most `limit`,
/// one entry per item. Kept as a JSON file (and, for books, a copy of each
/// cover) in Application Support, so recent books still show their covers
/// when the book itself cannot be reached (a share that is not connected,
/// a drive that is not plugged in).
///
/// This is the one place Platen keeps a list of what was read, at the
/// reader's request (docs/per-book-data.md, "Recents"); each entry can be
/// removed from the list (a long press), and nothing else is kept.
@MainActor
final class RecentList: ObservableObject {
    enum Kind: String { case books, folders, favorites }

    @Published private(set) var items: [RecentItem] = []
    /// True once the reader has put the list in an order of their own (by
    /// dragging, in Recent Folders). The list then keeps that order: an
    /// item opened again stays where it is, a new one goes at the top, and
    /// when the list is full the one opened longest ago goes. `sortByDate()`
    /// goes back to newest first. Kept in a small file of its own.
    @Published private(set) var isOrderedByHand = false
    let kind: Kind
    let directory: URL
    let limit: Int

    static let books = RecentList(kind: .books)
    static let folders = RecentList(kind: .folders)
    /// Books the reader marked as favourites (the heart in the reader): the
    /// home screen's Favourites tab, "what I am reading now". Newest first
    /// unless put in an order by hand; never trimmed by age.
    static let favorites = RecentList(kind: .favorites, limit: 1000)

    /// Application Support/Platen Reader/recents (or the test home).
    nonisolated static var defaultDirectory: URL {
        PositionStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("recents", isDirectory: true)
    }

    init(kind: Kind, directory: URL = RecentList.defaultDirectory, limit: Int = 60) {
        self.kind = kind
        self.directory = directory
        self.limit = limit
        isOrderedByHand = FileManager.default.fileExists(atPath: orderURL.path)
        if let data = try? Data(contentsOf: listURL),
           let saved = try? JSONDecoder.recents.decode([RecentItem].self, from: data) {
            // One entry per place, the newest kept (lists saved by earlier
            // versions could hold one place under two spellings of its path).
            items = Self.merged(saved, byHand: isOrderedByHand)
        }
    }

    /// One entry per place: of entries at the same place, the one opened
    /// most lately, dated by the latest of them. Newest first; or, for a
    /// list ordered by hand, where the first of them was.
    private nonisolated static func merged(_ list: [RecentItem], byHand: Bool) -> [RecentItem] {
        var byPlace: [String: RecentItem] = [:]
        var order: [String] = []
        for item in list {
            let key = key(item.path)
            guard var kept = byPlace[key] else { byPlace[key] = item; order.append(key); continue }
            if item.lastOpened > kept.lastOpened { kept = item }
            byPlace[key] = kept
        }
        if byHand { return order.compactMap { byPlace[$0] } }
        return byPlace.values.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// The form paths are compared in.
    private nonisolated static func key(_ path: String) -> String {
        FolderScanner.canonicalPath(RecentItem.pathURL(path)) // never the disk (see pathURL)
    }

    /// Whether this file or folder is on the list.
    func contains(_ url: URL) -> Bool {
        let path = FolderScanner.canonicalPath(url)
        return items.contains { Self.key($0.path) == path }
    }

    /// The entry for this file or folder, if it is on the list.
    func item(at url: URL) -> RecentItem? {
        let path = FolderScanner.canonicalPath(url)
        return items.first { Self.key($0.path) == path }
    }

    /// A book was opened (Recent Books) or marked as a favourite: it goes on
    /// the list (`opened`), then, in the background, its title, author and a
    /// copy of its cover are added, so the list shows them even when the
    /// book cannot be reached later. Call while access to the book is held
    /// (the reader holds it while the book is open).
    @discardableResult
    func addBook(_ url: URL) -> RecentItem? {
        guard let item = opened(url) else { return nil }
        DispatchQueue.global(qos: .utility).async {
            let entry = CoverCache.standard().cover(for: url)
            let jpeg = entry.imageURL.flatMap { try? Data(contentsOf: $0) }
            DispatchQueue.main.async { [weak self] in
                self?.update(item.id, title: entry.info.title, author: entry.info.authors.first, cover: jpeg)
            }
        }
        return item
    }

    private var listURL: URL { directory.appendingPathComponent("\(kind.rawValue).json") }
    /// Present when the list is ordered by hand (`isOrderedByHand`).
    private var orderURL: URL { directory.appendingPathComponent("\(kind.rawValue)-ordered-by-hand") }

    /// Where an item's cover copy is (books only).
    func coverURL(for item: RecentItem) -> URL? {
        guard item.hasCover else { return nil }
        return directory.appendingPathComponent("covers", isDirectory: true).appendingPathComponent("\(item.id.uuidString).jpg")
    }

    /// An item was opened: it goes to the top (the same item opened before
    /// moves up rather than appearing twice). Call while access to it is
    /// held, so the bookmark keeps permission to read it.
    @discardableResult
    func opened(_ url: URL, title: String? = nil, author: String? = nil, now: Date = Date(),
                bookmark made: Data? = nil) -> RecentItem? {
        guard let bookmark = made ?? (try? url.bookmarkData()) else { return nil }
        let path = FolderScanner.canonicalPath(url)
        var item = items.first { Self.key($0.path) == path }
            ?? RecentItem(bookmark: bookmark, name: url.lastPathComponent, path: path, lastOpened: now)
        item.bookmark = bookmark
        item.path = path
        item.name = url.lastPathComponent
        item.lastOpened = now
        let place = StoragePlace(path: path)
        item.storage = item.storage ?? place.kind
        item.location = item.location ?? place.location
        if let title, !title.isEmpty { item.title = title }
        if let author, !author.isEmpty { item.author = author }
        if isOrderedByHand, let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item // stays where the reader put it
        } else {
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
        }
        // Full: the one opened longest ago goes: the last, or, in a list
        // ordered by hand, wherever it is (never the one just opened).
        while items.count > limit {
            let oldest = isOrderedByHand
                ? items.filter({ $0.id != item.id }).min(by: { $0.lastOpened < $1.lastOpened })
                : items.last
            guard let oldest else { break }
            items.removeAll { $0.id == oldest.id }
            removeCover(of: oldest)
        }
        save()
        refinePlace(of: item, url: url)
        return item
    }

    /// Asks the file system, in the background, what the path alone cannot
    /// say: for a network share, the server's address ("smb://nas/books"),
    /// and whether a /Volumes path is a share or a drive.
    private func refinePlace(of item: RecentItem, url: URL) {
        Self.checkQueue.addOperation { [weak self] in
            let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeURLForRemountingKey, .volumeURLKey, .isUbiquitousItemKey]
            guard let values = try? url.resourceValues(forKeys: keys) else { return }
            var place: StoragePlace?
            if values.volumeIsLocal == false || values.volumeURLForRemounting != nil,
               let remount = values.volumeURLForRemounting, let volume = values.volume {
                // smb://user@nas/books plus the path below the share.
                let below = url.standardizedFileURL.path.dropFirst(volume.standardizedFileURL.path.count)
                var server = URLComponents(url: remount, resolvingAgainstBaseURL: false)
                server?.user = nil
                server?.password = nil
                let base = (server?.string ?? remount.absoluteString).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                place = StoragePlace(kind: .network, location: base + (below.hasPrefix("/") ? "" : "/") + below)
            } else if values.isUbiquitousItem == true, StoragePlace(path: url.path).kind != .iCloud {
                place = StoragePlace(kind: .otherCloud, location: StoragePlace(path: url.path).location)
            }
            guard let place else { return }
            DispatchQueue.main.async { self?.setPlace(place, of: item.id) }
        }
    }

    /// `opened`, with the bookmark made in the background first (making it
    /// asks the file system, which can be slow for a network share): for a
    /// folder shown on screen, which must not wait for it.
    func openedSoon(_ url: URL) {
        Self.checkQueue.addOperation {
            guard let bookmark = try? url.bookmarkData() else { return }
            DispatchQueue.main.async { [weak self] in self?.opened(url, bookmark: bookmark) }
        }
    }

    private func setPlace(_ place: StoragePlace, of id: RecentItem.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].storage = place.kind
        items[i].location = place.location
        save()
    }

    /// Fills in what was learnt about a book after it was opened: its title
    /// and author, and a copy of its cover (a JPEG).
    func update(_ id: RecentItem.ID, title: String?, author: String?, cover: Data?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty { items[index].title = title }
        if let author, !author.isEmpty { items[index].author = author }
        if let cover {
            let folder = directory.appendingPathComponent("covers", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? cover.write(to: folder.appendingPathComponent("\(id.uuidString).jpg"), options: .atomic)) != nil {
                items[index].hasCover = true
            }
        }
        save()
    }

    /// The reader dragged items to new places: the list keeps their order
    /// from now on (`isOrderedByHand`).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        setOrderedByHand(true)
        save()
    }

    /// Back to newest first.
    func sortByDate() {
        items.sort { $0.lastOpened > $1.lastOpened }
        setOrderedByHand(false)
        save()
    }

    private func setOrderedByHand(_ byHand: Bool) {
        guard byHand != isOrderedByHand else { return }
        isOrderedByHand = byHand
        if byHand {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: orderURL.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: orderURL)
        }
    }

    /// Takes an item off the list (its cover copy too). The book or folder
    /// itself is not touched.
    func remove(_ item: RecentItem) {
        items.removeAll { $0.id == item.id }
        removeCover(of: item)
        save()
    }

    /// The item's current place, from its bookmark (nil if it is gone, or on
    /// a drive or share that is not connected). Slow for a network share, so
    /// call it off the main thread (`RecentList.resolve` is nonisolated).
    /// A check in the background does not mount a share that is not
    /// connected (`mounting: false`); opening one may.
    nonisolated static func resolve(_ item: RecentItem, mounting: Bool = true) -> URL? {
        var stale = false
        let options: URL.BookmarkResolutionOptions = mounting ? [.withoutUI] : [.withoutUI, .withoutMounting]
        return try? URL(resolvingBookmarkData: item.bookmark, options: options, bookmarkDataIsStale: &stale)
    }

    /// Whether the item can be reached now, and where it is: its bookmark
    /// resolves and the file or folder is there. A book kept in iCloud but
    /// not on this device is `inCloud` (it can be opened, and downloaded,
    /// only while online). Off the main thread.
    nonisolated static func check(_ item: RecentItem) -> Reached {
        guard let url = resolve(item, mounting: false) else { return .no }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.checkResourceIsReachable()) == true else { return .no }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey,
                                                       .ubiquitousItemDownloadingStatusKey])
        if values?.isDirectory != true, values?.isUbiquitousItem == true,
           values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            return .inCloud(url)
        }
        return .yes(url)
    }

    /// The answer to "can this item be reached?".
    enum Reached: Sendable {
        /// Yes, and this is where it is now.
        case yes(URL)
        /// It is there, but only in iCloud: opening it downloads it first,
        /// which needs a connection.
        case inCloud(URL)
        case no
        /// No answer within the time allowed (a share that has gone away,
        /// or iOS's file service not answering).
        case noAnswer

        /// Where it is, if it was found.
        var url: URL? {
            switch self {
            case .yes(let url), .inCloud(let url): return url
            case .no, .noAnswer: return nil
            }
        }
    }

    /// Whether the item can be reached, giving up after `timeout` seconds. A
    /// network share that has gone away can take a long time to fail, and
    /// iOS's own file service has been seen to stop answering altogether.
    /// The check runs on a queue of its own (`checkQueue`), and the time
    /// limit is kept on the main thread, so the answer comes at the limit
    /// whatever the checks are doing. When the item is found, the list
    /// learns where it is now (`found`).
    func reachability(of item: RecentItem, timeout: TimeInterval = 6) async -> Reached {
        let answer: Reached = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Self.checks.check(item) { once.resume($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(.noAnswer) }
        }
        if let url = answer.url { found(item.id, at: url) }
        return answer
    }

    /// The checks under way, one per item at most.
    private nonisolated static let checks = ChecksUnderWay()

    /// Runs at most one check per item at a time. Asking about an item whose
    /// check is still running waits for that check's answer rather than
    /// starting another. Without this, a file system that stopped answering
    /// (it happened: iOS's own file service hung for minutes) left a new
    /// stuck thread behind every time the lists were checked (each return to
    /// the app, each list change), 64 of them in the end, until iOS ended
    /// the app and nothing at all would open meanwhile.
    final class ChecksUnderWay: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [RecentItem.ID: [(Reached) -> Void]] = [:]

        func check(_ item: RecentItem, answer: @escaping (Reached) -> Void) {
            let first = lock.withLock { () -> Bool in
                if waiting[item.id] != nil { waiting[item.id]!.append(answer); return false }
                waiting[item.id] = [answer]
                return true
            }
            guard first else { return }
            RecentList.checkQueue.addOperation {
                let result = RecentList.check(item)
                let answers = self.lock.withLock { self.waiting.removeValue(forKey: item.id) ?? [] }
                for answer in answers { answer(result) }
            }
        }
    }

    /// Where checks (and other questions to the file system about listed
    /// items) run: four at a time, the rest waiting their turn. One stuck on
    /// a share does not hold up the others, and when the file system stops
    /// answering altogether, at most four threads are stuck. (One thread per
    /// item, as before, took all 64 of the threads the app's background
    /// work shares, so even the time limits, then kept on that pool, never
    /// came: every folder showed its spinner for good and no book opened.)
    fileprivate nonisolated static let checkQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "org.platenreader.recents-check"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    /// An item was found at `url`. Its stored path is brought up to date (an
    /// app's own folder moves when the app is updated, for one), and
    /// entries that turn out to be the same place are merged, keeping the
    /// newest.
    func found(_ id: RecentItem.ID, at url: URL) {
        let path = FolderScanner.canonicalPath(url)
        guard let i = items.firstIndex(where: { $0.id == id }), Self.key(items[i].path) != path else { return }
        items[i].path = path
        let place = StoragePlace(path: path)
        if items[i].storage != .network { items[i].storage = place.kind; items[i].location = place.location }
        let merged = Self.merged(items, byHand: isOrderedByHand)
        for gone in items where !merged.contains(where: { $0.id == gone.id }) { removeCover(of: gone) }
        items = merged
        save()
    }

    private func removeCover(of item: RecentItem) {
        if let url = coverURL(for: item) { try? FileManager.default.removeItem(at: url) }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.recents.encode(items) {
            try? data.write(to: listURL, options: .atomic)
        }
    }
}

/// Resumes a continuation with the first answer given, ignoring the rest
/// (a check and its time limit race).
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(_ value: Value) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}

private extension JSONEncoder {
    static let recents: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let recents: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Matching a search in a folder against a book's file name, title and
/// authors (or a folder's name): every word typed must appear in one of
/// them, ignoring case and accents ("bronte jane" finds "Jane Eyre" by
/// Charlotte Brontë).
enum FolderSearch {
    static func matches(_ query: String, name: String, title: String? = nil, authors: [String] = []) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = ([name, title ?? ""] + authors).joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
