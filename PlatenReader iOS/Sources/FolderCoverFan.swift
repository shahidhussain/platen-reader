import PlatenCore
import SwiftUI

/// The picture at the start of a row in the Home tab's folder list: a small
/// fan of the folder's first two or three covers, so folders are told apart
/// at a glance; a folder glyph when none are known.
///
/// An experiment (design review, 21 Nov 2026), kept apart so it is easy to
/// take out: set `FolderRowPicture.showsCovers` to false and the rows go
/// back to the icon for where each folder is kept.
///
/// Nothing here touches the folder or its books, which may be on a share
/// that has gone away: the covers come from what was saved when the folder
/// was last shown (its listing in `FolderListingCache`, and the covers in
/// `CoverCache`, both on this device). A folder never opened in Platen shows
/// the glyph until it has been.
struct FolderRowPicture: View {
    static let showsCovers = true

    let item: RecentItem
    /// Greyed: the folder cannot be reached now.
    let gone: Bool

    @State private var covers: [FolderCovers.Cover] = []

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
        .task(id: item.path) {
            guard Self.showsCovers else { return }
            covers = await FolderCovers.first(3, of: item)
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
                ForEach(Array(covers.enumerated()).reversed(), id: \.offset) { index, cover in
                    Group {
                        switch cover {
                        case .image(let image):
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .plain(let title):
                            // A book with no cover picture: its plain
                            // cover's colour, as in the folder.
                            PlainCover(title: title, author: nil, showsText: false)
                        }
                    }
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

/// The covers of a folder's first books, as saved on this device.
enum FolderCovers {
    enum Cover {
        case image(CGImage)
        /// No cover picture: drawn plain, in a colour from its title.
        case plain(String)
    }

    /// The first `count` books' covers that are known, in the order the
    /// folder view shows them (its sort, only the kinds of book shown).
    @MainActor
    static func first(_ count: Int, of item: RecentItem) async -> [Cover] {
        guard let listing = FolderListingCache.listing(of: RecentItem.pathURL(item.path)) else { return [] }
        let filter = BookTypeFilter.shared
        let books = filter.sort.sorted(listing)
            .filter { $0.kind == .book && $0.isDownloaded && filter.shows($0.url) }
            .prefix(12) // enough to find three with covers, without reading many
        // Each book's saved cover (a picture's file), or its title for a
        // plain one; books whose covers were never made are skipped.
        let found: [(file: URL?, title: String)] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let cache = CoverCache.standard()
                var found: [(URL?, String)] = []
                for book in books where found.count < count {
                    guard let size = book.size, let modified = book.modified else { continue }
                    let key = CoverCache.key(path: book.url.standardizedFileURL.path, size: size, modified: modified)
                    guard let entry = cache.cached(key: key) else { continue }
                    found.append((entry.imageURL, entry.info.title ?? book.name))
                }
                continuation.resume(returning: found)
            }
        }
        var covers: [Cover] = []
        for (file, title) in found {
            if let file, let image = await CoverImages.shared.image(file) {
                covers.append(.image(image))
            } else {
                covers.append(.plain(title))
            }
        }
        return covers
    }
}
