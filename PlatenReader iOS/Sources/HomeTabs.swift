import PlatenCore
import SwiftUI
import UIKit

/// What the home screen asks of its view controller (HomeViewController).
struct HomeActions {
    let openBook: (URL) -> Void
    let chooseBook: () -> Void
    let chooseFolder: () -> Void
}

/// Which tab is showing, and the folders open in Recent Folders: kept by
/// HomeViewController, so a folder just chosen ("Choose Folder…") opens
/// there.
@MainActor
final class HomeNavigation: ObservableObject {
    enum Tab: Int, Hashable, CaseIterable { case home, books, folders }
    @Published var tab: Tab = .home
    @Published var folderPath: [URL] = []

    /// A sideways swipe on a tab's main screen moves to the tab beside it:
    /// left for the next, right for the one before. Inside a folder, a swipe
    /// right goes back instead (SwipeBack), so tabs do not change there.
    func swiped(left: Bool) {
        guard tab != .folders || folderPath.isEmpty,
              let next = Tab(rawValue: tab.rawValue + (left ? 1 : -1)) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { tab = next }
    }

    /// Shows a folder in the Recent Folders tab (just chosen, or tapped).
    func show(folder: URL) {
        FolderAccess.hold(folder)
        tab = .folders
        folderPath = [folder]
    }
}

/// Folders opened from Recent Folders (or just chosen) keep their access
/// while the app runs: their books are read from them.
@MainActor
enum FolderAccess {
    private static var held: Set<URL> = []
    static func hold(_ url: URL) {
        guard !held.contains(url), url.startAccessingSecurityScopedResource() else { return }
        held.insert(url)
    }
}

/// The home screen: three tabs, whose bar stays at the bottom even inside a
/// folder, so the reader can always get back out.
/// - **Home:** the welcome (Open Book…, Choose Folder…), for now.
/// - **Recent Books:** books opened lately, from anywhere, newest first.
/// - **Recent Folders:** folders looked at lately, as a list; a folder opens
///   inside the tab.
struct HomeTabs: View {
    @ObservedObject var navigation: HomeNavigation
    let actions: HomeActions

    var body: some View {
        TabView(selection: $navigation.tab) {
            WelcomeView(open: actions.chooseBook, chooseFolder: actions.chooseFolder)
                .contentShape(Rectangle())
                .tabSwipe(navigation)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(HomeNavigation.Tab.home)
            RecentBooksView(actions: actions)
                .tabSwipe(navigation)
                .tabItem { Label("Recent Books", systemImage: "clock") }
                .tag(HomeNavigation.Tab.books)
            RecentFoldersView(navigation: navigation, actions: actions)
                .tabSwipe(navigation)
                .tabItem { Label("Recent Folders", systemImage: "folder") }
                .tag(HomeNavigation.Tab.folders)
        }
    }
}

extension View {
    /// Switches tabs on a clear sideways swipe (see HomeNavigation.swiped),
    /// alongside the screen's own scrolling and taps.
    func tabSwipe(_ navigation: HomeNavigation) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { drag in
                    let dx = drag.translation.width, dy = drag.translation.height
                    // Mostly sideways, and far enough (or quick enough).
                    guard abs(dx) > abs(dy) * 2,
                          abs(dx) > 90 || abs(drag.predictedEndTranslation.width) > 200 else { return }
                    navigation.swiped(left: dx < 0)
                }
        )
    }
}

/// Whether a recent item can be reached: being checked (in the background,
/// with a time limit), yes, or no.
enum Reach { case checking, available, unavailable }

// MARK: - Recent Books

/// Books opened lately, wherever they are, as covers (copies kept with the
/// list, so they show even when the book cannot be reached). A book that
/// cannot be reached now (moved, deleted, or on a drive or share that is
/// not connected) is greyed with a mark. A long press offers Remove from
/// Recents; + opens another book.
struct RecentBooksView: View {
    @ObservedObject private var recents = RecentList.books
    let actions: HomeActions

    @State private var reach: [RecentItem.ID: Reach] = [:]
    @State private var cannotOpen: RecentItem?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 200), spacing: 18, alignment: .bottom)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(recents.items) { item in
                        Button { open(item) } label: {
                            BookTile(title: item.displayName, author: item.author, imageFile: recents.coverURL(for: item),
                                     badge: reach[item.id] == .unavailable ? .unavailable : nil)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { recents.remove(item) } label: {
                                Label("Remove from Recents", systemImage: "minus.circle")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .overlay {
                if recents.items.isEmpty {
                    ContentUnavailableView {
                        Label("No Recent Books", systemImage: "clock")
                    } description: {
                        Text("Books you open appear here.")
                    } actions: {
                        Button("Open Book…", action: actions.chooseBook)
                    }
                }
            }
            .navigationTitle("Recent Books")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: actions.chooseBook) { Label("Open Book…", systemImage: "plus") }
                }
            }
            // Covers, and whether each book can be reached, looked up again
            // whenever the list changes or the app comes back.
            .task(id: recents.items.map(\.id)) { await refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await refresh() }
            }
            .alert(Text("This book can’t be opened"), isPresented: Binding(
                get: { cannotOpen != nil }, set: { if !$0 { cannotOpen = nil } }
            ), presenting: cannotOpen) { item in
                Button("Remove from Recents", role: .destructive) { recents.remove(item) }
                Button("OK", role: .cancel) {}
            } message: { _ in
                Text("It may have been moved or deleted, or it is on a drive or network share that is not connected.")
            }
        }
    }

    private func open(_ item: RecentItem) {
        reach[item.id] = .checking
        Task {
            if case .yes(let url) = await recents.reachability(of: item, timeout: 10) {
                reach[item.id] = .available
                actions.openBook(url)
            } else {
                reach[item.id] = .unavailable
                cannotOpen = item
            }
        }
    }

    /// Checks each book can be reached, in the background (a network share
    /// can be slow to answer). The covers load themselves (BookTile).
    private func refresh() async {
        await checkReach(recents.items, in: recents, into: $reach)
    }
}

/// Checks each item at once, in the background, each with its own time
/// limit: they show as being checked until they answer.
@MainActor
private func checkReach(_ items: [RecentItem], in list: RecentList, into reach: Binding<[RecentItem.ID: Reach]>) async {
    for item in items where reach.wrappedValue[item.id] == nil { reach.wrappedValue[item.id] = .checking }
    // Each check answers within its time limit (see reachability), so this
    // finishes even when a share does not answer.
    await withTaskGroup(of: Void.self) { group in
        for item in items {
            group.addTask { @MainActor in
                if case .yes = await list.reachability(of: item) {
                    reach.wrappedValue[item.id] = .available
                } else {
                    reach.wrappedValue[item.id] = .unavailable
                }
            }
        }
    }
}


// MARK: - Recent Folders

/// Folders looked at lately, as a list: an icon for where each is kept
/// (this device, iCloud Drive, a network share, a drive), its name, its
/// path (the end of it always shown) and when. Tapping one shows it inside
/// this tab. Each is checked in the background; one that does not answer is
/// greyed. A long press (or a swipe) removes it; + adds a folder.
struct RecentFoldersView: View {
    @ObservedObject private var recents = RecentList.folders
    @ObservedObject var navigation: HomeNavigation
    let actions: HomeActions

    @State private var reach: [RecentItem.ID: Reach] = [:]
    @State private var cannotOpen: RecentItem?

    var body: some View {
        NavigationStack(path: $navigation.folderPath) {
            List {
                ForEach(recents.items) { item in
                    Button { open(item) } label: { row(item) }
                        .buttonStyle(.plain) // ordinary text, not the tint
                        .contextMenu {
                            Button(role: .destructive) { recents.remove(item) } label: {
                                Label("Remove from Recents", systemImage: "minus.circle")
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { recents.remove(item) } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if recents.items.isEmpty {
                    ContentUnavailableView {
                        Label("No Recent Folders", systemImage: "folder")
                    } description: {
                        Text("Folders you look at appear here.")
                    } actions: {
                        Button("Choose Folder…", action: actions.chooseFolder)
                    }
                }
            }
            .navigationTitle("Recent Folders")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: actions.chooseFolder) { Label("Choose Folder…", systemImage: "plus") }
                }
            }
            .navigationDestination(for: URL.self) { folder in
                FolderGridView(folder: folder, openBook: actions.openBook,
                               openFolder: { navigation.folderPath.append($0) },
                               chooseBook: actions.chooseBook, chooseFolder: actions.chooseFolder)
                    .id(folder)
            }
            .task(id: recents.items.map(\.id)) { await checkReach(recents.items, in: recents, into: $reach) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                reach = [:]
                Task { await checkReach(recents.items, in: recents, into: $reach) }
            }
            .alert(Text("This folder can’t be opened"), isPresented: Binding(
                get: { cannotOpen != nil }, set: { if !$0 { cannotOpen = nil } }
            ), presenting: cannotOpen) { item in
                Button("Remove from Recents", role: .destructive) { recents.remove(item) }
                Button("OK", role: .cancel) {}
            } message: { _ in
                Text("It may have been moved or deleted, or it is on a drive or network share that is not connected.")
            }
        }
    }

    private func row(_ item: RecentItem) -> some View {
        let state = reach[item.id] ?? .checking
        let gone = state == .unavailable
        let kind = item.storageKind
        return HStack(spacing: 14) {
            Image(systemName: kind.symbol)
                .font(.title3)
                .foregroundStyle(gone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 32)
                .accessibilityLabel(kind.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(gone ? .secondary : .primary)
                // The path, cut at the start if long: its end (the folder
                // and those just above it) is what tells folders apart.
                Text(item.locationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Group {
                    switch state {
                    case .unavailable:
                        Text(kind == .network ? "Not connected" : "Not available")
                    case .checking, .available:
                        Text(item.lastOpened.formatted(.relative(presentation: .named)))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if state == .checking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Opens a folder once it answers (checked again, in case it has been
    /// connected since); a share that does not answer is said to be so.
    private func open(_ item: RecentItem) {
        reach[item.id] = .checking
        Task {
            guard case .yes(let url) = await recents.reachability(of: item, timeout: 10) else {
                reach[item.id] = .unavailable
                cannotOpen = item
                return
            }
            reach[item.id] = .available
            navigation.show(folder: url)
        }
    }
}
