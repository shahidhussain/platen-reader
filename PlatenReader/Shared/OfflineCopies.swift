import Combine
import PlatenCore
import Foundation

/// Copies of favourite books kept on this device, so a favourite can be
/// read when the place it lives is out of reach: a network share away from
/// home, iCloud Drive or another cloud while offline, a drive not plugged
/// in (the reader asked for it, 25 Nov 2026).
///
/// - Only favourites are copied, and only those kept somewhere other than
///   this device: a book already on the device (On My iPhone, the app's own
///   folder) needs no copy.
/// - A favourite is copied when it is marked, if its place answers then
///   (else the next time it does), and copied again when the original has
///   changed.
/// - Taking a book off Favourites deletes its copy at once. The copy cannot
///   come back without the original: marking it again copies it afresh,
///   from its place, so the copies on the device are only ever the
///   favourites.
/// - Settings › Keep Favourites on This Device (on unless turned off)
///   turns this off, deleting every copy, or on again.
///
/// A book is opened from its own place whenever that answers; the copy only
/// when it does not. Reading positions and bookmarks are kept by the book's
/// contents, not its place (docs/per-book-data.md), so the copy opens where
/// the reader was.
///
/// Copies are in Application Support/Platen Reader/offline/<favourite's
/// id>/<file name> (or the test home), kept out of iCloud backup, as they
/// can be made again.
@MainActor
final class OfflineCopies: ObservableObject {
    static let shared = OfflineCopies(list: RecentList.favorites)

    /// Favourites (by id) whose copy is on the device.
    @Published private(set) var copied: Set<RecentItem.ID> = []
    /// What the copies take up, in bytes (for Settings).
    @Published private(set) var bytes: Int64 = 0

    let list: RecentList
    let directory: URL
    private let defaults: UserDefaults
    /// Whether a favourite is kept somewhere it may not be reachable from,
    /// and so is copied.
    private let needsCopy: (RecentItem) -> Bool
    /// Favourites being copied now (one copy each at a time).
    private var copying: Set<RecentItem.ID> = []
    private var watches: Set<AnyCancellable> = []

    nonisolated static var defaultDirectory: URL {
        PositionStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("offline", isDirectory: true)
    }

    static let enabledKey = "keepFavouritesOffline"

    init(list: RecentList, directory: URL = OfflineCopies.defaultDirectory, defaults: UserDefaults = AppDefaults.store,
         needsCopy: @escaping (RecentItem) -> Bool = OfflineCopies.isKeptElsewhere) {
        self.list = list
        self.directory = directory
        self.defaults = defaults
        self.needsCopy = needsCopy
        measure()
    }

    /// A book kept anywhere but this device: iCloud Drive, another cloud,
    /// a network share or a drive.
    nonisolated static func isKeptElsewhere(_ item: RecentItem) -> Bool {
        #if DEBUG
        // PLATEN_COPY_ALL_FAVOURITES=1: every favourite counts as kept
        // elsewhere (the Simulator has no share to try it with).
        if ProcessInfo.processInfo.environment["PLATEN_COPY_ALL_FAVOURITES"] != nil { return true }
        #endif
        return item.storageKind != .device
    }

    /// Settings › Keep Favourites on This Device: on unless turned off.
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
            log.info("offline: keeping favourites on this device \(newValue ? "on" : "off", privacy: .public)")
            sync()
        }
    }

    /// Keeps the copies in step with the favourites from now on: when the
    /// list changes, when the connection changes (a share may be back), and
    /// once now.
    func start() {
        guard watches.isEmpty else { return }
        list.$items
            .map { $0.map(\.id) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &watches)
        NetworkStatus.shared.$changes
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &watches)
        sync()
    }

    // MARK: - Finding a copy

    /// The copy of a favourite, if there is one on the device.
    func copyURL(for item: RecentItem) -> URL? {
        guard copied.contains(item.id) else { return nil }
        let url = fileURL(for: item)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The copy of the book at `path` (as a list keeps it: Recent Books, a
    /// folder), if it is a favourite with a copy.
    func copyURL(forBookAt path: String) -> URL? {
        list.item(at: RecentItem.pathURL(path)).flatMap(copyURL(for:))
    }

    /// Whether `url` is one of the copies (opening one does not put it on
    /// Recent Books: the original is already there).
    nonisolated static func isCopy(_ url: URL, in directory: URL = OfflineCopies.defaultDirectory) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    private func folder(for id: RecentItem.ID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func fileURL(for item: RecentItem) -> URL {
        folder(for: item.id).appendingPathComponent(item.name)
    }

    // MARK: - Keeping them in step

    /// Deletes copies no longer wanted (taken off Favourites, or the
    /// setting off), and copies favourites that have none, or whose
    /// original has changed, from places that answer now.
    func sync() {
        let wanted = isEnabled ? list.items.filter(needsCopy) : []
        let wantedIDs = Set(wanted.map(\.id))
        // Delete what is not wanted.
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var deleted = 0
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent), wantedIDs.contains(id) else {
                try? FileManager.default.removeItem(at: folder)
                deleted += 1
                continue
            }
        }
        if deleted > 0 { log.info("offline: \(deleted) copies deleted") }
        measure()
        // Copy what is wanted, in the background.
        for item in wanted where !copying.contains(item.id) {
            copying.insert(item.id)
            Task { await self.fetch(item) }
        }
    }

    /// Copies one favourite if its place answers and the copy is missing or
    /// older than the original.
    private func fetch(_ item: RecentItem) async {
        defer { copying.remove(item.id) }
        let answer = await list.reachability(of: item)
        let url: URL
        switch answer {
        case .yes(let found): url = found
        // Only in iCloud: copying downloads it, which needs a connection.
        case .inCloud(let found) where NetworkStatus.shared.isOnline: url = found
        default: return
        }
        let destination = fileURL(for: item)
        let made: Bool = await withCheckedContinuation { continuation in
            Self.copyQueue.addOperation {
                continuation.resume(returning: Self.copy(url, to: destination))
            }
        }
        // Taken off Favourites (or the setting turned off) meanwhile: not
        // kept.
        guard isEnabled, list.items.contains(where: { $0.id == item.id }) else {
            try? FileManager.default.removeItem(at: folder(for: item.id))
            measure()
            return
        }
        measure()
        if made { log.info("offline: a favourite copied to this device") }
    }

    /// Copies run one at a time, apart from the checks.
    private nonisolated static let copyQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "org.platenreader.offline-copy"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    /// Copies the book at `source` to `destination` (through a temporary
    /// file, so a copy cut short never stands as the book), unless the copy
    /// there already matches it (the same modification date and size).
    /// iCloud downloads the book first, if it must. Returns whether a copy
    /// was made. Off the main thread.
    nonisolated static func copy(_ source: URL, to destination: URL) -> Bool {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        var made = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .totalFileSizeKey, .fileSizeKey]
            let original = try? readable.resourceValues(forKeys: keys)
            if manager.fileExists(atPath: destination.path),
               let kept = try? destination.resourceValues(forKeys: keys),
               kept.contentModificationDate == original?.contentModificationDate,
               (kept.totalFileSize ?? kept.fileSize) == (original?.totalFileSize ?? original?.fileSize) {
                return // up to date
            }
            do {
                let folder = destination.deletingLastPathComponent()
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                var excluded = URLResourceValues()
                excluded.isExcludedFromBackup = true
                var parent = folder.deletingLastPathComponent()
                try? parent.setResourceValues(excluded)
                let temporary = folder.appendingPathComponent(".partial-\(UUID().uuidString)")
                try manager.copyItem(at: readable, to: temporary)
                if let date = original?.contentModificationDate {
                    try? manager.setAttributes([.modificationDate: date], ofItemAtPath: temporary.path)
                }
                if manager.fileExists(atPath: destination.path) {
                    _ = try manager.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try manager.moveItem(at: temporary, to: destination)
                }
                made = true
            } catch {
                log.error("offline: copy failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let coordinationError {
            log.error("offline: copy failed: \(coordinationError.localizedDescription, privacy: .public)")
        }
        return made
    }

    /// Which favourites have a copy, and their size.
    private func measure() {
        let manager = FileManager.default
        var ids: Set<RecentItem.ID> = []
        var total: Int64 = 0
        for item in list.items {
            let url = fileURL(for: item)
            guard manager.fileExists(atPath: url.path) else { continue }
            ids.insert(item.id)
            total += Self.size(of: url)
        }
        if ids != copied { copied = ids }
        if total != bytes { bytes = total }
    }

    /// A file's size, or a folder's (an unpacked book), in bytes.
    private nonisolated static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0) }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)).map { Array($0) } ?? []
        return files.compactMap { $0 as? URL }.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
    }
}
