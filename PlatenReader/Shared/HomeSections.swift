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
/// three across (on the Mac, up to six), so a book being read is one tap from opening Platen. "See
/// All" in the section's header goes to the Favourites tab, with the rest.
struct FavouritesStrip: View {
    @ObservedObject private var favourites = RecentList.favorites
    @ObservedObject private var network = NetworkStatus.shared
    @ObservedObject private var offline = OfflineCopies.shared
    let actions: HomeActions
    /// The book tapped, while it is checked before opening.
    @State private var opening: RecentItem.ID?
    @State private var cannotOpen: RecentItem?
    @State private var reach: [RecentItem.ID: Reach] = [:]

    #if os(macOS)
    /// On the Mac, a row of up to six at a steady size (a wide window would
    /// otherwise make three covers huge).
    static let count = 6
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 120, maximum: 140), spacing: 16, alignment: .top)]
    }
    #else
    static let count = 3
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: Self.count)
    }
    #endif

    private var shown: [RecentItem] { Array(favourites.items.prefix(Self.count)) }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(shown) { item in
                Button { open(item) } label: {
                    BookTile(title: item.displayName, author: item.author, imageFile: favourites.coverURL(for: item),
                             badge: badge(for: item))
                }
                .buttonStyle(.plain)
            }
        }
        // As in the Favourites tab: each is checked, and again when the
        // app comes back or the connection changes.
        .task(id: shown.map(\.id)) { await checkReach(shown, in: favourites, into: $reach) }
        .onReceive(NotificationCenter.default.publisher(for: .platenAppReturned)) { _ in
            Task { await checkReach(shown, in: favourites, into: $reach) }
        }
        .onReceive(NetworkStatus.shared.changed.debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
            recheckAway(shown, in: $reach)
            Task { await checkReach(shown, in: favourites, into: $reach) }
        }
        .alert(Text("This book can’t be opened"), isPresented: Binding(
            get: { cannotOpen != nil }, set: { if !$0 { cannotOpen = nil } }
        ), presenting: cannotOpen) { item in
            Button("Try Again") {
                reach[item.id] = .reconnecting
                Task { await checkThenOpen(item, sayIfNot: false) }
            }
            Button("Remove from Favourites", role: .destructive) { favourites.remove(item) }
            Button("OK", role: .cancel) {}
        } message: { _ in
            Text("It may have been moved or deleted, or it is on a drive or network share that is not connected, or in iCloud while this device is offline.")
        }
    }

    /// As in the Favourites tab (BookShelfView.badge).
    private func badge(for item: RecentItem) -> BookTile.Badge? {
        if opening == item.id { return .downloading }
        if reach[item.id] != .available, offline.copyURL(for: item) != nil { return nil }
        switch reach[item.id] {
        case .reconnecting: return .reconnecting
        case .unavailable:
            return .unavailable(item.storageKind == .network ? String(localized: "Not connected")
                                                             : String(localized: "Not available"))
        case .inCloud: return network.isOnline ? .inCloud : .unavailable(String(localized: "Offline"))
        case .checking, .available, nil: return nil
        }
    }

    /// As in the Favourites tab (BookShelfView.open): out of reach is said
    /// at once; the copy on this device opens when the book's place does
    /// not answer.
    private func open(_ item: RecentItem) {
        guard opening == nil else { return }
        let known = reach[item.id]
        if known == .unavailable || (known == .inCloud && !network.isOnline) {
            if let copy = offline.copyURL(for: item) { return actions.openBook(copy) }
            cannotOpen = item
            return
        }
        if known?.isChecking == true, let copy = offline.copyURL(for: item) { return actions.openBook(copy) }
        opening = item.id
        Task { await checkThenOpen(item, sayIfNot: known == .available) }
    }

    private func checkThenOpen(_ item: RecentItem, sayIfNot: Bool) async {
        let answer = await favourites.reachability(of: item, timeout: 10)
        opening = nil
        reach[item.id] = Reach(answer)
        switch answer {
        case .yes(let url):
            actions.openBook(url)
        case .inCloud(let url) where network.isOnline:
            actions.openBook(url)
        case .inCloud, .no, .noAnswer:
            if let copy = offline.copyURL(for: item) {
                actions.openBook(copy)
            } else if sayIfNot {
                cannotOpen = item
            }
        }
    }
}
