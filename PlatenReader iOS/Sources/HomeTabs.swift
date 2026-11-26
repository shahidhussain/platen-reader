import PlatenCore
import SwiftUI
import UIKit

/// What the home screen asks of its view controller (HomeViewController).
struct HomeActions {
    let openBook: (URL) -> Void
    let chooseBook: () -> Void
    let chooseFolder: () -> Void
}

/// Which tab is showing, and the folders open in the Home tab: kept by
/// HomeViewController, so a folder just chosen ("Choose Folder…") opens
/// there.
@MainActor
final class HomeNavigation: ObservableObject {
    /// In the order they are shown: Home, Favourites, Recent Books (the
    /// reader's order, 24 Nov 2026).
    enum Tab: Int, Hashable, CaseIterable { case home, favourites, books }
    // Each change is logged, so a busy moment in the diagnostics file shows
    // which part of Home it came in (no names: just the tab and the depth).
    @Published var tab: Tab = .home {
        didSet { if tab != oldValue { log.info("home: \(String(describing: tab), privacy: .public) tab") } }
    }
    @Published var folderPath: [URL] = [] {
        didSet { if folderPath.count != oldValue.count { log.info("home: folder depth \(folderPath.count)") } }
    }

    /// Shows a folder in the Home tab (just chosen, or tapped in the list).
    func show(folder: URL) {
        FolderAccess.hold(folder)
        tab = .home
        folderPath = [folder]
    }
}

/// Folders opened from the Home tab (or just chosen) keep their access
/// while the app runs: their books are read from them.
@MainActor
enum FolderAccess {
    private static var held: Set<URL> = []
    static func hold(_ url: URL) {
        guard !held.contains(url), url.startAccessingSecurityScopedResource() else { return }
        held.insert(url)
    }
}

/// The home screen.
///
/// The first time Platen is opened, with nothing to show (no folders, no
/// recent books, no favourites), it is the welcome alone: Open Book… and
/// Choose Folder…. As soon as a book is opened or a folder chosen, the
/// welcome is gone for good and the home screen is three tabs:
/// - **Home:** the reader's folders (the ones they chose), as a list (a
///   folder opens inside the tab), and the first few favourites, in the
///   order the reader puts them (HomeSections.swift). Settings is the gear.
/// - **Favourites:** books the reader marked as favourites (a cover's
///   long-press menu), "what I am reading now".
/// - **Recent Books:** books opened lately, from anywhere, newest first.
struct HomeTabs: View {
    @ObservedObject var navigation: HomeNavigation
    let actions: HomeActions
    @ObservedObject private var books = RecentList.books
    @ObservedObject private var folders = RecentList.folders
    @ObservedObject private var favourites = RecentList.favorites

    private var isFirstRun: Bool { books.items.isEmpty && folders.items.isEmpty && favourites.items.isEmpty }

    var body: some View {
        Group {
            if isFirstRun {
                WelcomeView(open: actions.chooseBook, chooseFolder: actions.chooseFolder)
            } else {
                HomeTabRow(navigation: navigation, actions: actions)
            }
        }
        // The first book opened from the welcome: closing it comes back to
        // Recent Books, where it is, rather than to an empty Home.
        .onChange(of: isFirstRun) { _, first in
            if !first, folders.items.isEmpty { navigation.tab = .books }
        }
    }
}

/// The three tabs side by side, which slide sideways under the finger (or
/// when a tab is tapped), so they read as three pages in a row. The tab bar
/// stays at the bottom even inside a folder, so the reader can always get
/// back out; there, a swipe right goes back instead (the row stands still).
///
/// The system's tab view cannot slide between its tabs, so the sections are
/// pages of a paging scroll view, with a tab bar of Platen's own on glass.
struct HomeTabRow: View {
    @ObservedObject var navigation: HomeNavigation
    let actions: HomeActions
    /// The page the row is scrolled to (follows the finger).
    @State private var shown: HomeNavigation.Tab? = .home

    /// Inside a folder the row stands still: a swipe goes back.
    private var rowLocked: Bool { navigation.tab == .home && !navigation.folderPath.isEmpty }

    var body: some View {
        // The row spans the whole width, safe areas included, and each page
        // is inset by the side safe areas within its own full-width slot. Paging moves by
        // the row's full width, so a page only the safe width wide left the
        // next tab showing in the strip beside it: where the status bar runs
        // down one side (an iPhone Duo opened out, 22 Nov 2026), or the
        // notch's strips on an iPhone turned sideways.
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(HomeNavigation.Tab.allCases, id: \.self) { tab in
                        page(tab)
                            // Padding, not safe-area padding: each tab's own
                            // navigation bar must move in too.
                            .padding(.leading, insets.leading)
                            .padding(.trailing, insets.trailing)
                            // The strips beside it in the page's own colour.
                            .background(slotColour(tab), ignoresSafeAreaEdges: .all)
                            .containerRelativeFrame(.horizontal)
                            .id(tab)
                    }
                }
                .scrollTargetLayout()
            }
            .ignoresSafeArea(.container, edges: .horizontal)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $shown)
            .scrollIndicators(.hidden)
            .scrollDisabled(rowLocked)
            // A new width (an iPhone Duo folded or opened, a turn) leaves the
            // row at its old offset, part-way into another page: back to the
            // tab chosen.
            .onChange(of: outer.size) { _, _ in
                let tab = navigation.tab
                DispatchQueue.main.async { reader.scrollTo(tab, anchor: .leading) }
            }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HomeTabBar(selection: Binding(get: { navigation.tab }, set: { tab in
                // Tapping Home again goes back to the list of folders.
                if tab == navigation.tab, tab == .home { navigation.folderPath = [] }
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
        // launch, or from the welcome): go to it once it is on screen.
        .onAppear {
            DispatchQueue.main.async { if shown != navigation.tab { shown = navigation.tab } }
        }
    }

    /// The colour behind a page, carried into the side strips: Home's list
    /// of folders is grouped (grey in light mode); a folder's grid and the
    /// shelves are plain.
    private func slotColour(_ tab: HomeNavigation.Tab) -> Color {
        tab == .home && navigation.folderPath.isEmpty ? Color(.systemGroupedBackground) : Color(.systemBackground)
    }

    @ViewBuilder private func page(_ tab: HomeNavigation.Tab) -> some View {
        switch tab {
        case .home: RecentFoldersView(navigation: navigation, actions: actions)
        case .books: BookShelfView(shelf: .recent, actions: actions)
        case .favourites: BookShelfView(shelf: .favourites, actions: actions)
        }
    }
}

/// The tab bar: Home, Recent Books and Favourites, on glass, the one shown
/// picked out.
struct HomeTabBar: View {
    @Binding var selection: HomeNavigation.Tab

    var body: some View {
        HStack(spacing: 4) {
            item(.home, "Home", "house")
            item(.favourites, "Favourites", "heart")
            item(.books, "Recent Books", "clock")
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
enum Reach: Equatable {
    case checking, available, unavailable
    /// Still being checked after a moment (`checkReach`): a share or cloud
    /// that is not answering straight away, perhaps coming back after the
    /// device went offline or changed networks. Shown as "Reconnecting…"
    /// with a spinner (the reader asked, 25 Nov 2026); a quick answer, as
    /// from a folder on the device, never shows it.
    case reconnecting
    /// Being checked, quickly or not.
    var isChecking: Bool { self == .checking || self == .reconnecting }
    /// A book kept only in iCloud: it opens (downloading first) while online.
    case inCloud
}

extension Reach {
    init(_ answer: RecentList.Reached) {
        switch answer {
        case .yes: self = .available
        case .inCloud: self = .inCloud
        case .no, .noAnswer: self = .unavailable
        }
    }
}

// MARK: - Recent Books and Favourites

/// Books as covers: those opened lately (Recent Books), or the reader's
/// favourites. Covers are copies kept with the list, so they show even when
/// the book cannot be reached. A book that cannot be reached now (moved,
/// deleted, or on a drive or share that is not connected) is greyed with a
/// mark. A long press takes it off the list; in Recent Books, + opens
/// another book.
struct BookShelfView: View {
    enum Shelf { case recent, favourites }
    let shelf: Shelf
    @ObservedObject private var recents: RecentList
    let actions: HomeActions

    @State private var reach: [RecentItem.ID: Reach] = [:]
    @State private var cannotOpen: RecentItem?
    /// The book tapped, while it is checked before opening.
    @State private var opening: RecentItem.ID?
    @ObservedObject private var options = BookTypeFilter.shared
    @ObservedObject private var network = NetworkStatus.shared
    @ObservedObject private var favourites = RecentList.favorites
    @ObservedObject private var offline = OfflineCopies.shared
    /// Counts each book's hearts (marked as a favourite), to start its
    /// heartbeat.
    @State private var heartbeats: [RecentItem.ID: Int] = [:]
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(shelf: Shelf, actions: HomeActions) {
        self.shelf = shelf
        self.actions = actions
        recents = shelf == .recent ? RecentList.books : RecentList.favorites
    }

    private var removeLabel: LocalizedStringKey {
        shelf == .recent ? "Remove from Recents" : "Remove from Favourites"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: CoverColumns.items(options, sizeClass), alignment: .leading,
                          spacing: CoverColumns.spacing(options, sizeClass) + 6) {
                    ForEach(recents.items) { item in
                        Button { open(item) } label: {
                            BookTile(title: item.displayName, author: item.author, imageFile: recents.coverURL(for: item),
                                     badge: badge(for: item),
                                     isFavourite: shelf == .recent && isFavourite(item),
                                     heartbeats: heartbeats[item.id, default: 0])
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            BookWindows.MenuItem { BookWindows.open(bookmark: item.bookmark, title: item.displayName) }
                            if shelf == .recent {
                                Button {
                                    if Favourites.toggle(item, from: recents) { heartbeats[item.id, default: 0] += 1 }
                                } label: {
                                    Favourites.menuLabel(isFavourite: isFavourite(item))
                                }
                            }
                            Button(role: .destructive) { recents.remove(item) } label: {
                                Label(removeLabel, systemImage: shelf == .recent ? "minus.circle" : "heart.slash")
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
                    switch shelf {
                    case .recent:
                        ContentUnavailableView {
                            Label("No Recent Books", systemImage: "clock")
                        } description: {
                            Text("Books you open appear here.")
                        } actions: {
                            Button("Open Book…", action: actions.chooseBook)
                        }
                    case .favourites:
                        ContentUnavailableView {
                            Label("No Favourites", systemImage: "heart")
                        } description: {
                            Text("Touch and hold a book’s cover, in a folder or in Recent Books, and choose Add to Favourites.")
                        }
                    }
                }
            }
            .navigationTitle(shelf == .recent ? "Recent Books" : "Favourites")
            .toolbar {
                if shelf == .recent {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: actions.chooseBook) { Label("Open Book…", systemImage: "plus") }
                    }
                }
            }
            // Whether each book can be reached, looked up again whenever the
            // list changes or the app comes back.
            .task(id: recents.items.map(\.id)) { await refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await refresh() }
            }
            // Offline, back online, or another network: books kept away
            // from the device are checked again (reconnecting meanwhile).
            .onReceive(network.$changes.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
                recheckAway(recents.items, in: $reach)
                Task { await refresh() }
            }
            .alert(Text("This book can’t be opened"), isPresented: Binding(
                get: { cannotOpen != nil }, set: { if !$0 { cannotOpen = nil } }
            ), presenting: cannotOpen) { item in
                Button("Try Again") {
                    reach[item.id] = .reconnecting
                    Task { await checkThenOpen(item, sayIfNot: false) }
                }
                Button(removeLabel, role: .destructive) { recents.remove(item) }
                Button("OK", role: .cancel) {}
            } message: { item in
                if reach[item.id] == .inCloud {
                    Text("It is in iCloud and not yet on this device. Connect to the internet to download it.")
                } else {
                    Text("It may have been moved or deleted, or it is on a drive or network share that is not connected.")
                }
            }
        }
    }

    private func isFavourite(_ item: RecentItem) -> Bool {
        favourites.contains(RecentItem.pathURL(item.path))
    }

    /// The mark on a book's cover: being checked before it opens, in iCloud
    /// (downloads when opened), or not available now, greyed with a word
    /// saying why: a share not connected, offline for a book only in
    /// iCloud, or moved, deleted or not answering.
    private func badge(for item: RecentItem) -> BookTile.Badge? {
        if opening == item.id { return .downloading }
        // A favourite kept on this device opens whatever its place says.
        if offline.copyURL(forBookAt: item.path) != nil, reach[item.id] != .available { return nil }
        switch reach[item.id] {
        case .reconnecting:
            return .reconnecting
        case .unavailable:
            return .unavailable(item.storageKind == .network ? String(localized: "Not connected")
                                                             : String(localized: "Not available"))
        case .inCloud:
            return network.isOnline ? .inCloud : .unavailable(String(localized: "Offline"))
        case .checking, .available, nil:
            return nil
        }
    }

    private func open(_ item: RecentItem) {
        guard !options.justPinched else { return } // the end of a pinch, not a tap
        guard opening == nil else { return } // one at a time
        let known = reach[item.id]
        // Known to be out of reach: said at once (no wait for a check that
        // will fail), unless a copy is kept on this device.
        if known == .unavailable || (known == .inCloud && !network.isOnline) {
            if let copy = offline.copyURL(forBookAt: item.path) { return actions.openBook(copy) }
            cannotOpen = item
            return
        }
        // Reconnecting: the copy kept on this device, if there is one, at
        // once; otherwise it opens if the check comes back in time, and if
        // not it is greyed, without a message (it said it was reconnecting).
        if known?.isChecking == true, let copy = offline.copyURL(forBookAt: item.path) { return actions.openBook(copy) }
        opening = item.id
        Task { await checkThenOpen(item, sayIfNot: known == .available) }
    }

    /// Checks the book (a share may have gone), then opens it, or its copy
    /// on this device; if neither, it is greyed and, if `sayIfNot`, said.
    private func checkThenOpen(_ item: RecentItem, sayIfNot: Bool) async {
        let answer = await recents.reachability(of: item, timeout: 10)
        opening = nil
        reach[item.id] = Reach(answer)
        switch answer {
        case .yes(let url):
            actions.openBook(url)
        case .inCloud(let url) where network.isOnline:
            actions.openBook(url) // the reader downloads it
        case .inCloud, .no, .noAnswer:
            if let copy = offline.copyURL(forBookAt: item.path) {
                actions.openBook(copy)
            } else if sayIfNot {
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
/// limit: they show as being checked until they answer. An item that does
/// not answer in time is not shown as unavailable (it may be iCloud's file
/// service still waking): it stays as being checked and is asked again, up
/// to three times in all, a few seconds apart; only a clear no greys it.
@MainActor
func checkReach(_ items: [RecentItem], in list: RecentList, into reach: Binding<[RecentItem.ID: Reach]>) async {
    for item in items where reach.wrappedValue[item.id] == nil { reach.wrappedValue[item.id] = .checking }
    // Those still not answered after a moment show as reconnecting.
    Task {
        try? await Task.sleep(for: .seconds(0.6))
        for item in items where reach.wrappedValue[item.id] == .checking { reach.wrappedValue[item.id] = .reconnecting }
    }
    var pending = items
    var counts: [String: Int] = [:]
    let started = Date()
    for attempt in 1...3 where !pending.isEmpty {
        if attempt > 1 { try? await Task.sleep(for: .seconds(4)) }
        // Each check answers within its time limit (see reachability), so
        // this finishes even when a share does not answer.
        let silent: [RecentItem] = await withTaskGroup(of: RecentItem?.self) { group in
            for item in pending {
                group.addTask { @MainActor in
                    let answer = await list.reachability(of: item)
                    // Asked to check again meanwhile (another network):
                    // that check's answer stands.
                    if case .noAnswer = answer {
                        if attempt == 3 { reach.wrappedValue[item.id] = .unavailable }
                        return item
                    }
                    reach.wrappedValue[item.id] = Reach(answer)
                    return nil
                }
            }
            var silent: [RecentItem] = []
            for await item in group { if let item { silent.append(item) } }
            return silent
        }
        counts["no answer \(attempt)"] = silent.count
        pending = silent
    }
    // For the diagnostics file: how the checks went (no names).
    let states = items.map { reach.wrappedValue[$0.id] ?? .checking }
        .map { $0 == .reconnecting ? .checking : $0 }
    let summary = "\(states.filter { $0 == .available }.count) here, \(states.filter { $0 == .inCloud }.count) in iCloud, "
        + "\(states.filter { $0 == .unavailable }.count) not available; no answer: \(counts["no answer 1"] ?? 0), "
        + "then \(counts["no answer 2"] ?? 0), \(counts["no answer 3"] ?? 0)"
    log.info("home: \(items.count) items checked in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(summary, privacy: .public)")
}

/// The connection changed (offline, back online, another network): items
/// kept away from this device show as being checked again, rather than as
/// they were on the old connection.
@MainActor
func recheckAway(_ items: [RecentItem], in reach: Binding<[RecentItem.ID: Reach]>) {
    for item in items where item.storageKind != .device { reach.wrappedValue[item.id] = nil }
}

// MARK: - Home: the reader's folders

/// The Home tab: the folders the reader chose (Choose Folder…), as a list:
/// an icon for where each is kept (this device, iCloud Drive, a network
/// share, a drive), its name, its path (the end of it always shown) and
/// when. Tapping one shows it inside this tab. Folders browsed into from
/// there are not added: the list holds only what the reader chose, so it
/// stays tidy. Each is checked in the background; one that does not answer
/// is greyed. A long press removes it from the list (a sideways swipe moves
/// between the home screen's tabs); + adds a folder. The gear's menu holds
/// Settings and Edit Home, which shows handles to drag the folders (and the
/// sections) into an order of the reader's own, kept by the list
/// (`RecentList.isOrderedByHand`), and delete buttons; Done (top right)
/// ends it. Edit is not at the top left, as in many iOS lists: that is
/// where a Back button stands on the screens this one is reached from, and
/// a tap meant for Back that landed late kept starting it (device testing,
/// 21 Nov 2026). Each row starts with a small fan of the folder's covers
/// (`FolderRowPicture`).
struct RecentFoldersView: View {
    @ObservedObject private var recents = RecentList.folders
    @ObservedObject var navigation: HomeNavigation
    let actions: HomeActions

    @State private var reach: [RecentItem.ID: Reach] = [:]
    @State private var cannotOpen: RecentItem?
    @State private var editMode: EditMode = .inactive
    @State private var showingSettings = false
    @ObservedObject private var favourites = RecentList.favorites
    @ObservedObject private var sectionOrder = HomeSectionOrder.shared
    @ObservedObject private var network = NetworkStatus.shared

    /// The Favourites section shows once there is a favourite.
    private var showsFavourites: Bool { !favourites.items.isEmpty }

    var body: some View {
        NavigationStack(path: $navigation.folderPath) {
            List {
                // While editing: the sections' order, with drag handles.
                if editMode.isEditing && showsFavourites {
                    Section {
                        ForEach(sectionOrder.order) { section in
                            Label(section.label, systemImage: section.symbol)
                        }
                        .onMove { sectionOrder.move(fromOffsets: $0, toOffset: $1) }
                        .deleteDisabled(true)
                    } header: {
                        Text("Sections")
                    }
                }
                ForEach(sectionOrder.order) { section in
                    switch section {
                    case .folders: foldersSection
                    case .favourites: if showsFavourites { favouritesSection }
                    }
                }
            }
            .listStyle(.insetGrouped)
            // Room between the large "Home" title and the list.
            .contentMargins(.top, 16, for: .scrollContent)
            .sheet(isPresented: $showingSettings) { ReaderSettingsView() }
            .environment(\.editMode, $editMode)
            .onChange(of: recents.items.isEmpty && !showsFavourites) { _, empty in if empty { editMode = .inactive } }
            // The app's name heads the home screen (the tab below still
            // says Home). Its version is in Settings, under About.
            .navigationTitle(Text(verbatim: "Platen Reader"))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if editMode.isEditing {
                        Button("Done") { withAnimation { editMode = .inactive } }
                            .fontWeight(.semibold)
                    } else {
                        // Settings: about the app, not a book, so here
                        // rather than among the reader's buttons; with it,
                        // Edit Home.
                        Menu {
                            Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                            if !recents.items.isEmpty || showsFavourites {
                                Button { withAnimation { editMode = .active } } label: {
                                    Label("Edit Home", systemImage: "pencil")
                                }
                            }
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        Button(action: actions.chooseFolder) { Label("Choose Folder…", systemImage: "plus") }
                    }
                }
            }
            .navigationDestination(for: URL.self) { folder in
                FolderGridView(folder: folder, openBook: actions.openBook,
                               openFolder: { navigation.folderPath.append($0) })
                    .id(folder)
            }
            .task(id: recents.items.map(\.id)) { await checkReach(recents.items, in: recents, into: $reach) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                reach = [:]
                Task { await checkReach(recents.items, in: recents, into: $reach) }
            }
            // Offline, back online, or another network: folders kept away
            // from the device are checked again (reconnecting meanwhile).
            .onReceive(network.$changes.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
                recheckAway(recents.items, in: $reach)
                Task { await checkReach(recents.items, in: recents, into: $reach) }
            }
            .alert(Text("This folder can’t be opened"), isPresented: Binding(
                get: { cannotOpen != nil }, set: { if !$0 { cannotOpen = nil } }
            ), presenting: cannotOpen) { item in
                Button("Try Again") { checkThenOpen(item, sayIfNot: false) }
                Button("Remove from List", role: .destructive) { recents.remove(item) }
                Button("OK", role: .cancel) {}
            } message: { _ in
                Text("It may have been moved or deleted, or it is on a drive or network share that is not connected.")
            }
        }
    }

    private var foldersSection: some View {
        Section {
            ForEach(recents.items) { item in
                Button { open(item) } label: { row(item) }
                    .buttonStyle(.plain) // ordinary text, not the tint
                    // While editing, rows are only moved or deleted (not
                    // greyed, as disabling them would make them look gone).
                    .allowsHitTesting(!editMode.isEditing)
                    .contextMenu {
                        Button(role: .destructive) { recents.remove(item) } label: {
                            Label("Remove from List", systemImage: "minus.circle")
                        }
                    }
            }
            .onMove { recents.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { offsets in
                for item in offsets.map({ recents.items[$0] }) { recents.remove(item) }
            }
        } header: {
            Text("Folders")
        } footer: {
            if recents.items.isEmpty { emptyFolders }
        }
    }

    /// The first few favourites, three across, with See All (the iOS way
    /// to the whole list, as in Music or the App Store) going to the
    /// Favourites tab.
    private var favouritesSection: some View {
        Section {
            FavouritesStrip(actions: actions)
                .allowsHitTesting(!editMode.isEditing)
                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
                .deleteDisabled(true)
                .moveDisabled(true)
        } header: {
            HStack {
                Text("Favourites")
                Spacer()
                Button("See All") { navigation.tab = .favourites }
                    .font(.subheadline)
                    .textCase(nil)
                    .disabled(editMode.isEditing)
            }
        }
    }

    /// No folders yet.
    private var emptyFolders: some View {
        ContentUnavailableView {
            Label("No Folders", systemImage: "folder")
        } description: {
            Text("Choose a folder of books to find it here.")
        } actions: {
            Button("Choose Folder…", action: actions.chooseFolder)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ item: RecentItem) -> some View {
        let state = reach[item.id] ?? .checking
        let gone = state == .unavailable
        let kind = item.storageKind
        return HStack(spacing: 12) {
            // Reconnecting: the spinner stands where the folder's covers
            // are, the part of the row the eye goes to.
            if state == .reconnecting {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                FolderRowPicture(item: item, gone: gone)
            }
            // Two lines whatever the state, so a row never changes size as
            // the folders are checked (a third line for "Reconnecting…" made
            // the list jump at launch; device testing, 25 Nov 2026).
            VStack(alignment: .leading, spacing: 2) {
                // Reconnecting: said in the title ("Reconnecting Comics…").
                Text(state == .reconnecting ? String(localized: "Reconnecting \(item.name)…") : item.name)
                    .foregroundStyle(gone ? .secondary : .primary)
                    .lineLimit(1)
                // The path, cut at the start if long: its end (the folder
                // and those just above it) is what tells folders apart. When
                // the folder cannot be reached, that is said in its place.
                Group {
                    if state == .unavailable {
                        Text(kind == .network ? "Not connected" : "Not available")
                    } else {
                        Text(item.locationText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if !editMode.isEditing { // the drag handle stands there instead
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Opens a folder.
    /// - Not available (greyed): says so at once, with Try Again, rather
    ///   than checking again first: the wait, then the message, read as the
    ///   tap doing nothing (the reader saw it, 25 Nov 2026).
    /// - Reconnecting: opens if it answers in time; if not, it is greyed,
    ///   with no message (it said it was reconnecting).
    /// - Available: checked again (a share may have gone since), then
    ///   opened, or said to be out of reach.
    private func open(_ item: RecentItem) {
        let known = reach[item.id] ?? .checking
        if known == .unavailable {
            cannotOpen = item
            return
        }
        checkThenOpen(item, sayIfNot: known == .available)
    }

    private func checkThenOpen(_ item: RecentItem, sayIfNot: Bool) {
        reach[item.id] = .reconnecting
        Task {
            guard let url = await recents.reachability(of: item, timeout: 10).url else {
                reach[item.id] = .unavailable
                if sayIfNot { cannotOpen = item }
                return
            }
            reach[item.id] = .available
            recents.openedSoon(url) // brings its date up to date
            navigation.show(folder: url)
        }
    }
}
