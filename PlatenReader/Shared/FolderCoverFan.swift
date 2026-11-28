import PlatenCore
import SwiftUI

/// The picture at the start of a row in the Home tab's folder list: a small
/// fan of three of the folder's covers, so folders are told apart at a
/// glance; a folder glyph until some are known.
///
/// Only real cover pictures are used (never a book's plain stand-in, nor a
/// PDF's first page when it is a page of text: `CoverLook`), and
/// once chosen they stay for the day: the same three every time the list is
/// shown. The next day three others are drawn at random from the folder
/// (`FolderFans`), so the fan changes a little each day.
///
/// An experiment (design review, 21 Nov 2026), kept apart so it is easy to
/// take out: set `FolderRowPicture.showsCovers` to false and the rows go
/// back to the icon for where each folder is kept.
///
/// Nothing here touches the folder or its books, which may be on a share
/// that has gone away: the covers come from what was saved when the folder
/// was last shown (its listing in `FolderListingCache`, and the covers in
/// `CoverCache`, both on this device), and the three chosen are copied
/// aside, so they stay even if those caches are cleared.
struct FolderRowPicture: View {
    static let showsCovers = true

    let item: RecentItem
    /// Greyed: the folder cannot be reached now.
    let gone: Bool

    @State private var covers: [CGImage]

    init(item: RecentItem, gone: Bool) {
        self.item = item
        self.gone = gone
        // Drawn at once from memory when the row comes back on screen, so
        // the fan never blinks out and in.
        _covers = State(initialValue: FolderFans.shown[item.id] ?? [])
    }

    var body: some View {
        Group {
            if Self.showsCovers {
                fan
            } else {
                storageIcon
            }
        }
        .frame(width: 44, height: 44)
        .opacity(gone ? 0.45 : 1)
        .saturation(gone ? 0 : 1)
        .task(id: item.id) {
            guard Self.showsCovers else { return }
            let chosen = await FolderFans.covers(for: item)
            if !chosen.isEmpty || covers.isEmpty { covers = chosen }
        }
    }

    private var storageIcon: some View {
        Image(systemName: item.storageKind.symbol)
            .font(.title3)
            .foregroundStyle(gone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .accessibilityLabel(item.storageKind.label)
    }

    /// Up to three covers, the first in front, the others turned out
    /// behind it like cards in a hand.
    @ViewBuilder private var fan: some View {
        if covers.isEmpty {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(gone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .accessibilityHidden(true)
        } else {
            let angles: [Double] = covers.count == 1 ? [0] : covers.count == 2 ? [-7, 7] : [-12, 0, 12]
            ZStack {
                // Drawn back to front: the first cover last, on top.
                ForEach(Array(covers.enumerated()).reversed(), id: \.offset) { index, image in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .rotationEffect(.degrees(angles[index]), anchor: .bottom)
                        .offset(x: angles[index] * 0.5)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// The three covers each folder's fan shows, chosen once a day.
///
/// For each folder (by its entry's id, which outlives a change of path) a
/// small record is kept in Caches: the day the covers were chosen, and
/// copies of the three pictures. Until the day changes they are shown as
/// they are; if fewer than three were found (the folder was only glanced
/// at, so few covers had been read), more are added as they become known.
/// On a new day three others are drawn at random from the books whose
/// covers are real pictures (avoiding yesterday's where the folder has
/// enough): books in the folder's saved listing (not its subfolders'),
/// and books only in iCloud (by iCloud's thumbnail of them). If none can be found (the folder has not been opened lately),
/// yesterday's stay. Each choice is logged with its counts ("folder fan:").
@MainActor
enum FolderFans {
    static let count = 3

    /// What each row showed last, for drawing it at once when it returns.
    static var shown: [RecentItem.ID: [CGImage]] = [:]

    /// The listing each folder's covers were last searched in, so a fan
    /// still short of three is searched again only when that has changed.
    private static var lastSearched: [RecentItem.ID: [FolderEntry]] = [:]

    private struct Record: Codable {
        var day: String
        /// The cover keys chosen (CoverCache keys), to avoid them next day.
        var keys: [String]
        /// Their titles, so a fan topped up later never shows one twice.
        var titles: [String]? = nil
    }

    /// A book whose saved cover might go in a fan: where its cover is kept
    /// in `CoverCache`, and whether it is a PDF (whose first page may be
    /// text).
    private struct Candidate: Sendable {
        let name: String
        let key: String
        let isPDF: Bool
    }

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderFans", isDirectory: true)
    }

    private static func recordURL(_ id: RecentItem.ID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func pictureURL(_ id: RecentItem.ID, _ index: Int) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-\(index).jpg")
    }

    /// Today, as the record says it ("2026-11-21", in the reader's time zone).
    nonisolated static func day(_ date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func covers(for item: RecentItem) async -> [CGImage] {
        let id = item.id
        let today = day()
        let record = (try? Data(contentsOf: recordURL(id))).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        let saved = (0..<count).map { pictureURL(id, $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        var files = saved

        // A new day (or none yet): a fresh three. The same day with fewer
        // than three (chosen before many covers had been read, say): topped
        // up, keeping those already shown.
        let newDay = record?.day != today || saved.isEmpty
        let wanted = newDay ? count : count - saved.count
        let listing = FolderListingCache.listing(of: RecentItem.pathURL(item.path)) ?? []
        // Topping up looks again only once the folder's listing has changed
        // (more covers read since): before, a folder with too few covers was
        // searched again on every return to Home, for nothing.
        let unchanged = !newDay && lastSearched[id] == listing
        if wanted > 0, !unchanged {
            let keep = newDay ? [] : (record?.keys ?? [])
            let keepTitles = newDay ? [] : (record?.titles ?? [])
            let avoid = newDay ? Set(record?.keys ?? []) : []
            // The books and their cover keys are worked out in the
            // background too: it touched the disk for each book, and on the
            // main thread that held Home up on every return to it (device
            // diagnostics, 22 Nov 2026).
            let (found, picked): (Int, [Pick]) = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let books = candidates(in: listing)
                    continuation.resume(returning: (books.count, pick(wanted, from: books, excluding: Set(keep),
                                                                      titles: Set(keepTitles), avoiding: avoid)))
                }
            }
            lastSearched[id] = listing
            log.info("folder fan: \(found, privacy: .public) books to look at, \(picked.count, privacy: .public) picked, \(saved.count, privacy: .public) kept, \(newDay ? "new day" : "topping up", privacy: .public)")
            if !picked.isEmpty {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if newDay {
                    for index in 0..<count { try? FileManager.default.removeItem(at: pictureURL(id, index)) }
                    files = []
                }
                for choice in picked {
                    let copy = pictureURL(id, files.count)
                    if (try? FileManager.default.copyItem(at: choice.file, to: copy)) != nil { files.append(copy) }
                }
                CoverImages.shared.forget(files)
                let record = Record(day: today, keys: keep + picked.map(\.key),
                                    titles: keepTitles + picked.map(\.title))
                if let data = try? JSONEncoder().encode(record) { try? data.write(to: recordURL(id), options: .atomic) }
            }
        }

        var images: [CGImage] = []
        for file in files {
            if let image = await CoverImages.shared.image(file) { images.append(image) }
        }
        if !images.isEmpty { shown[id] = images }
        return images
    }

    /// The books whose covers may have been saved: those directly in the
    /// folder's saved listing (`listing`), not in its subfolders (a fan of covers from
    /// folders further down mixed in books the folder does not show; the
    /// reader asked for its own books only, 21 Nov 2026). A book only in
    /// iCloud counts as well: its cover is iCloud's thumbnail of it, saved
    /// under a key of its own (FolderModel). Text files have no cover.
    private nonisolated static func candidates(in listing: [FolderEntry]) -> [Candidate] {
        var found: [Candidate] = []
        for entry in listing.prefix(4000) {
            if entry.kind == .folder { continue }
            guard let type = BookFileType(entry.url), type != .text else { continue }
            let key: String
            if entry.isDownloaded {
                guard let size = entry.size, let modified = entry.modified else { continue }
                // The path as the cover cache keys it (`standardizedFileURL`),
                // worked out without the disk.
                key = CoverCache.key(path: FolderScanner.standardPath(entry.url), size: size, modified: modified)
            } else {
                key = CoverCache.key(path: "icloud-thumbnail:" + FolderScanner.canonicalPath(entry.url), size: 0,
                                     modified: entry.modified ?? .distantPast)
            }
            found.append(Candidate(name: entry.name, key: key, isPDF: type == .pdf))
        }
        return found
    }

    private struct Pick: Sendable {
        let key: String
        let title: String
        let file: URL
    }

    /// Up to `wanted` books at random whose saved covers are real pictures
    /// (a PDF's not a page of text), one per title, none already chosen,
    /// and not yesterday's if the folder has enough others. Reads only the
    /// cover cache's small records, never the books.
    private nonisolated static func pick(_ wanted: Int, from books: [Candidate], excluding chosen: Set<String>,
                                         titles chosenTitles: Set<String>, avoiding avoid: Set<String>) -> [Pick] {
        let cache = CoverCache.standard()
        var fresh: [Pick] = []
        var seen: [Pick] = []
        // One cover per title: the same book kept twice (an EPUB and its
        // KEPUB, say) would show the same picture twice.
        var titles = chosenTitles
        // At most a few hundred looked at, in random order, so a very
        // large folder costs no more than a small one.
        for book in books.shuffled().prefix(400) where !chosen.contains(book.key) {
            guard let entry = cache.cached(key: book.key), let image = entry.imageURL else { continue }
            // A PDF's "cover" is its first page: left out when that is a
            // page of text, which would show as a blank card.
            if book.isPDF, CoverLook.isTextLike(file: image) { continue }
            let title = (entry.info.title ?? book.name).lowercased()
            guard titles.insert(title).inserted else { continue }
            let pick = Pick(key: book.key, title: title, file: image)
            if avoid.contains(book.key) { seen.append(pick) } else { fresh.append(pick) }
            if fresh.count == wanted { break }
        }
        return Array((fresh + seen).prefix(wanted))
    }
}
