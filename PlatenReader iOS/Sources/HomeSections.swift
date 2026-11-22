import SwiftUI

/// The sections of the Home tab, in the order the reader has put them:
/// Folders and Favourites. Edit (top left) shows a short list of them with
/// drag handles, as Music's Library does for its categories: iOS lists do
/// not let whole sections be dragged. The order is kept with the settings.
enum HomeSection: String, CaseIterable, Identifiable {
    case folders, favourites
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .folders: return "Folders"
        case .favourites: return "Favourites"
        }
    }

    var symbol: String {
        switch self {
        case .folders: return "folder"
        case .favourites: return "heart"
        }
    }
}

@MainActor
final class HomeSectionOrder: ObservableObject {
    static let shared = HomeSectionOrder(defaults: AppDefaults.store)

    @Published private(set) var order: [HomeSection]
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        order = Self.order(from: defaults.stringArray(forKey: "homeSectionOrder"))
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        defaults.set(order.map(\.rawValue), forKey: "homeSectionOrder")
    }

    /// A saved order, made whole: unknown names dropped, and any section
    /// missing (one added in a later version) put at the end. Folders come
    /// first until the reader says otherwise.
    nonisolated static func order(from saved: [String]?) -> [HomeSection] {
        var order: [HomeSection] = []
        for name in saved ?? [] {
            if let section = HomeSection(rawValue: name), !order.contains(section) { order.append(section) }
        }
        for section in HomeSection.allCases where !order.contains(section) { order.append(section) }
        return order
    }
}

/// The Home tab's Favourites section: the first three favourites as covers,
/// three across, so a book being read is one tap from opening Platen. "See
/// All" in the section's header goes to the Favourites tab, with the rest.
struct FavouritesStrip: View {
    @ObservedObject private var favourites = RecentList.favorites
    @ObservedObject private var network = NetworkStatus.shared
    let actions: HomeActions
    /// The book tapped, while it is checked before opening.
    @State private var opening: RecentItem.ID?
    @State private var cannotOpen: RecentItem?

    static let count = 3

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: Self.count),
                  alignment: .leading, spacing: 14) {
            ForEach(favourites.items.prefix(Self.count)) { item in
                Button { open(item) } label: {
                    BookTile(title: item.displayName, author: item.author, imageFile: favourites.coverURL(for: item),
                             badge: opening == item.id ? .downloading : nil)
                }
                .buttonStyle(.plain)
            }
        }
        .alert(Text("This book can’t be opened"), isPresented: Binding(
            get: { cannotOpen != nil }, set: { if !$0 { cannotOpen = nil } }
        ), presenting: cannotOpen) { item in
            Button("Remove from Favourites", role: .destructive) { favourites.remove(item) }
            Button("OK", role: .cancel) {}
        } message: { _ in
            Text("It may have been moved or deleted, or it is on a drive or network share that is not connected, or in iCloud while this device is offline.")
        }
    }

    /// As in the Favourites tab: the book is checked (a share may not
    /// answer), then opened; a book only in iCloud opens (downloading) while
    /// online.
    private func open(_ item: RecentItem) {
        guard opening == nil else { return }
        opening = item.id
        Task {
            let answer = await favourites.reachability(of: item, timeout: 10)
            opening = nil
            switch answer {
            case .yes(let url):
                actions.openBook(url)
            case .inCloud(let url) where network.isOnline:
                actions.openBook(url)
            case .inCloud, .no, .noAnswer:
                cannotOpen = item
            }
        }
    }
}
