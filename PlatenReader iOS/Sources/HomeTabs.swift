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

/// The home screen: three sections side by side, Home, Recent Books and
/// Recent Folders, which slide sideways under the finger (or when a tab is
/// tapped), so they read as three pages in a row. The tab bar stays at the
/// bottom even inside a folder, so the reader can always get back out;
/// there, a swipe right goes back instead (the row stands still).
/// - **Home:** the welcome (Open Book…, Choose Folder…), for now.
/// - **Recent Books:** books opened lately, from anywhere, newest first.
/// - **Recent Folders:** folders looked at lately, as a list; a folder opens
///   inside the section.
///
/// The system's tab view cannot slide between its tabs, so the sections are
/// pages of a paging scroll view, with a tab bar of Platen's own on glass.
struct HomeTabs: View {
    @ObservedObject var navigation: HomeNavigation
    let actions: HomeActions
    /// The page the row is scrolled to (follows the finger).
    @State private var shown: HomeNavigation.Tab? = .home

    /// Inside a folder the row stands still: a swipe goes back.
    private var rowLocked: Bool { navigation.tab == .folders && !navigation.folderPath.isEmpty }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(HomeNavigation.Tab.allCases, id: \.self) { tab in
                    page(tab)
                        .containerRelativeFrame(.horizontal)
                        .id(tab)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $shown)
        .scrollIndicators(.hidden)
        .scrollDisabled(rowLocked)
        .safeAreaInset(edge: .bottom) {
            HomeTabBar(selection: Binding(get: { navigation.tab }, set: { tab in
                // Tapping Recent Folders again goes back to its list.
                if tab == navigation.tab, tab == .folders { navigation.folderPath = [] }
                navigation.tab = tab
            }))
        }
        // A swipe that settles on a page makes it the tab; a tab chosen
        // (tapped, or a folder just chosen) slides the row to it.
        .onChange(of: shown) { _, tab in
            if let tab, tab != navigation.tab { navigation.tab = tab }
        }
        .onChange(of: navigation.tab) { _, tab in
            guard shown != tab else { return }
            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy(duration: 0.35)) { shown = tab }
        }
        // A tab chosen before the row was laid out (a folder chosen at
        // launch): go to it once it is on screen.
        .onAppear {
            DispatchQueue.main.async { if shown != navigation.tab { shown = navigation.tab } }
        }
    }

    @ViewBuilder private func page(_ tab: HomeNavigation.Tab) -> some View {
        switch tab {
        case .home: WelcomeView(open: actions.chooseBook, chooseFolder: actions.chooseFolder)
        case .books: RecentBooksView(actions: actions)
        case .folders: RecentFoldersView(navigation: navigation, actions: actions)
        }
    }
}

/// The tab bar: Home, Recent Books and Recent Folders, on glass, the one
/// shown picked out.
struct HomeTabBar: View {
    @Binding var selection: HomeNavigation.Tab

    var body: some View {
        HStack(spacing: 4) {
            item(.home, "Home", "house")
            item(.books, "Recent Books", "clock")
            item(.folders, "Recent Folders", "folder")
        }
        .padding(4)
        .overlaySurface(Capsule())
        .padding(.bottom, 4)
    }

    private func item(_ tab: HomeNavigation.Tab, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        let selected = selection == tab
        return Button { selection = tab } label: {
            VStack(spacing: 2) {
                Image(systemName: selected ? symbol + ".fill" : symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(width: 100, height: 48)
            .background {
                if selected { Capsule().fill(Color.primary.opacity(0.08)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
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
    @ObservedObject private var options = BookTypeFilter.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: CoverColumns.items(options, sizeClass), alignment: .leading,
                          spacing: CoverColumns.spacing(options, sizeClass) + 6) {
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
            .coverPinch(options, sizeClass)
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
        guard !options.justPinched else { return } // the end of a pinch, not a tap
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
/// greyed. A long press removes it (a sideways swipe moves between the
/// home screen's sections); + adds a folder. Edit (top left, as in iOS's own
/// lists) shows handles to drag the folders into an order of the reader's
/// own, which the list then keeps (`RecentList.isOrderedByHand`), and
/// delete buttons; while editing, Sort by Date goes back to newest first.
struct RecentFoldersView: View {
    @ObservedObject private var recents = RecentList.folders
    @ObservedObject var navigation: HomeNavigation
    let actions: HomeActions

    @State private var reach: [RecentItem.ID: Reach] = [:]
    @State private var cannotOpen: RecentItem?
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack(path: $navigation.folderPath) {
            List {
                ForEach(recents.items) { item in
                    Button { open(item) } label: { row(item) }
                        .buttonStyle(.plain) // ordinary text, not the tint
                        // While editing, rows are only moved or deleted (not
                        // greyed, as disabling them would make them look gone).
                        .allowsHitTesting(!editMode.isEditing)
                        .contextMenu {
                            Button(role: .destructive) { recents.remove(item) } label: {
                                Label("Remove from Recents", systemImage: "minus.circle")
                            }
                        }
                }
                .onMove { recents.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    for item in offsets.map({ recents.items[$0] }) { recents.remove(item) }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .onChange(of: recents.items.isEmpty) { _, empty in if empty { editMode = .inactive } }
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
                if !recents.items.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(editMode.isEditing ? "Done" : "Edit") {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        }
                        .fontWeight(editMode.isEditing ? .semibold : .regular)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if editMode.isEditing {
                        Button("Sort by Date") { withAnimation { recents.sortByDate() } }
                            .disabled(!recents.isOrderedByHand)
                    } else {
                        Button(action: actions.chooseFolder) { Label("Choose Folder…", systemImage: "plus") }
                    }
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
            } else if !editMode.isEditing { // the drag handle stands there instead
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
