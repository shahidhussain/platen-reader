import PlatenCore
import SwiftUI

/// The picture at the start of a row in the Home tab's folder list: a small
/// fan of three of the folder's covers, so folders are told apart at a
/// glance; a folder glyph until some are known.
///
/// Only real cover pictures are used (never a book's plain stand-in, nor a
/// PDF's first page), and
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
/// they are. On a new day three others are drawn at random from the books
/// in the folder's saved listing whose covers are real pictures (avoiding
/// yesterday's where the folder has enough); if none can be found (the
/// folder has not been opened lately), yesterday's stay.
@MainActor
enum FolderFans {
    static let count = 3

    /// What each row showed last, for drawing it at once when it returns.
    static var shown: [RecentItem.ID: [CGImage]] = [:]

    private struct Record: Codable {
        var day: String
        /// The cover keys chosen (CoverCache keys), to avoid them next day.
        var keys: [String]
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
        let record = (try? Data(contentsOf: recordURL(id))).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        var files = (0..<count).map { pictureURL(id, $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }

        if record?.day != day() || files.isEmpty {
            // Time for a fresh three (or the first).
            if let listing = FolderListingCache.listing(of: RecentItem.pathURL(item.path)) {
                // Books with covers of their own: a PDF's "cover" is only
                // its first page (often a page of text), and text files have
                // none.
                let books = listing.filter {
                    $0.kind == .book && $0.isDownloaded && ![.pdf, .text].contains(BookFileType($0.url))
                }
                let avoid = Set(record?.keys ?? [])
                let picked: [(key: String, file: URL)] = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(returning: pick(from: books, avoiding: avoid))
                    }
                }
                if !picked.isEmpty {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for index in 0..<count { try? FileManager.default.removeItem(at: pictureURL(id, index)) }
                    files = []
                    for (index, choice) in picked.enumerated() {
                        let copy = pictureURL(id, index)
                        if (try? FileManager.default.copyItem(at: choice.file, to: copy)) != nil { files.append(copy) }
                    }
                    CoverImages.shared.forget(files)
                    let saved = Record(day: day(), keys: picked.map(\.key))
                    if let data = try? JSONEncoder().encode(saved) { try? data.write(to: recordURL(id), options: .atomic) }
                }
            }
        }

        var images: [CGImage] = []
        for file in files {
            if let image = await CoverImages.shared.image(file) { images.append(image) }
        }
        if !images.isEmpty { shown[id] = images }
        return images
    }

    /// Three books at random whose saved covers are real pictures, not
    /// yesterday's if the folder has enough others. Reads only the cover
    /// cache's small records, never the books.
    private nonisolated static func pick(from books: [FolderEntry], avoiding avoid: Set<String>) -> [(key: String, file: URL)] {
        let cache = CoverCache.standard()
        var fresh: [(String, URL)] = []
        var seen: [(String, URL)] = []
        // One cover per title: the same book kept twice (an EPUB and its
        // KEPUB, say) would show the same picture twice.
        var titles: Set<String> = []
        // At most a couple of hundred looked at, in random order, so a
        // very large folder costs no more than a small one.
        for book in books.shuffled().prefix(200) {
            guard let size = book.size, let modified = book.modified else { continue }
            let key = CoverCache.key(path: book.url.standardizedFileURL.path, size: size, modified: modified)
            guard let entry = cache.cached(key: key), let image = entry.imageURL else { continue }
            let title = (entry.info.title ?? book.name).lowercased()
            guard titles.insert(title).inserted else { continue }
            if avoid.contains(key) { seen.append((key, image)) } else { fresh.append((key, image)) }
            if fresh.count == count { break }
        }
        return Array((fresh + seen).prefix(count))
    }
}
