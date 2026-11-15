import Combine
import Foundation
import PlatenCore

/// A book or folder the reader opened lately, for the home screen's Recent
/// Books and Recent Folders tabs.
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

    /// "Middlemarch" for "Middlemarch.kepub.epub"; a folder's own name.
    var displayName: String { title ?? FolderScanner.displayName(URL(fileURLWithPath: path)) }

    /// The folder it is in ("Kids"), to tell apart two items of one name.
    var place: String { URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent }
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
    enum Kind: String { case books, folders }

    @Published private(set) var items: [RecentItem] = []
    let kind: Kind
    let directory: URL
    let limit: Int

    static let books = RecentList(kind: .books)
    static let folders = RecentList(kind: .folders)

    /// Application Support/Platen Reader/recents (or the test home).
    nonisolated static var defaultDirectory: URL {
        PositionStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("recents", isDirectory: true)
    }

    init(kind: Kind, directory: URL = RecentList.defaultDirectory, limit: Int = 60) {
        self.kind = kind
        self.directory = directory
        self.limit = limit
        if let data = try? Data(contentsOf: listURL),
           let saved = try? JSONDecoder.recents.decode([RecentItem].self, from: data) {
            items = saved
        }
    }

    private var listURL: URL { directory.appendingPathComponent("\(kind.rawValue).json") }

    /// Where an item's cover copy is (books only).
    func coverURL(for item: RecentItem) -> URL? {
        guard item.hasCover else { return nil }
        return directory.appendingPathComponent("covers", isDirectory: true).appendingPathComponent("\(item.id.uuidString).jpg")
    }

    /// An item was opened: it goes to the top (the same item opened before
    /// moves up rather than appearing twice). Call while access to it is
    /// held, so the bookmark keeps permission to read it.
    @discardableResult
    func opened(_ url: URL, title: String? = nil, author: String? = nil, now: Date = Date()) -> RecentItem? {
        guard let bookmark = try? url.bookmarkData() else { return nil }
        let path = FolderScanner.canonicalPath(url)
        var item = items.first { $0.path == path }
            ?? RecentItem(bookmark: bookmark, name: url.lastPathComponent, path: path, lastOpened: now)
        item.bookmark = bookmark
        item.name = url.lastPathComponent
        item.lastOpened = now
        if let title, !title.isEmpty { item.title = title }
        if let author, !author.isEmpty { item.author = author }
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        for dropped in items.dropFirst(limit) { removeCover(of: dropped) }
        items = Array(items.prefix(limit))
        save()
        return item
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
    nonisolated static func resolve(_ item: RecentItem) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: item.bookmark, bookmarkDataIsStale: &stale)
    }

    /// Whether the item can be reached now: its bookmark resolves and the
    /// file or folder is there. Off the main thread.
    nonisolated static func isReachable(_ item: RecentItem) -> Bool {
        guard let url = resolve(item) else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.checkResourceIsReachable()) == true
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
