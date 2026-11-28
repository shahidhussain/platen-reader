import AppKit
import PlatenCore
import SwiftUI
import UniformTypeIdentifiers

/// The Home window: the Mac's home screen, with the same three parts as the
/// iOS app's tabs (spec, "Folders on the Mac"; docs/mac-folder-view-plan.md):
///
/// - **Home:** the folders the reader chose, then their first favourites;
///   a folder opens inside it as a grid of covers.
/// - **Favourites:** the books the reader marked (a cover's right-click
///   menu).
/// - **Recent Books:** books opened lately, from anywhere.
///
/// On iOS these are tabs at the bottom; on the Mac they are a sidebar, as in
/// Books, Music and Finder, with the reader's folders listed under them so
/// each is a click away. The lists and grids themselves are the iOS app's
/// own views (HomeViews.swift, FolderView.swift), shared.
///
/// It shows when Platen starts with no book to reopen, when the last book
/// window closes, and from Window › Home (⇧⌘H). Until anything has been
/// opened or chosen it is the welcome alone (Open Book…, Choose Folder…), as
/// on iOS. Books open in their own windows, as they always have; Home stays.
final class HomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HomeWindowController()

    /// Which part of Home shows, and the folders open in it.
    let navigation = HomeNavigation()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = String(localized: "Platen Reader")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 420)
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        let actions = HomeActions(
            openBook: { Self.open(book: $0) },
            chooseBook: { [weak self] in self?.chooseBook() },
            chooseFolder: { [weak self] in self?.chooseFolder() },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        )
        let hosting = NSHostingController(rootView: MacHomeView(navigation: navigation, actions: actions))
        // The window keeps the size it is given (or the reader's), rather
        // than shrinking to the welcome's.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        // (Setting the content shrinks the window to it: the size is set
        // again.) Where the reader left it, and its size; centred the
        // first time.
        window.setContentSize(NSSize(width: 980, height: 660))
        if !window.setFrameUsingName("Home") { window.center() }
        window.setFrameAutosaveName("Home")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Actions

    /// Opens a book in its own window (the document system: Open Recent,
    /// window restoration and tabs all come with it). It joins Recent Books
    /// as it opens (`BookDocument`).
    static func open(book url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    /// "Open Book…": the Open panel, as a sheet on Home.
    func chooseBook() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.bookTypes
        present(panel) { urls in urls.forEach(Self.open(book:)) }
    }

    /// "Choose Folder…" (and File › Open Folder…): a folder of books, which
    /// joins Home's list and opens there.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        present(panel) { [weak self] urls in
            if let url = urls.first { self?.showChosen(folder: url) }
        }
    }

    /// A folder chosen (or, testing, named at launch): it joins the list and
    /// opens in Home.
    func showChosen(folder url: URL) {
        FolderAccess.hold(url)
        RecentList.folders.opened(url)
        navigation.show(folder: url)
        show()
    }

    private func present(_ panel: NSOpenPanel, then done: @escaping ([URL]) -> Void) {
        show()
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            done(panel.urls)
        }
    }

    /// The kinds of book the Open panel offers: those listed in Info.plist
    /// (EPUB, KEPUB, MOBI, AZW, AZW3, plain text, PDF).
    static var bookTypes: [UTType] {
        ["org.idpf.epub-container", "com.kobo.kepub", "com.amazon.mobi", "com.amazon.azw", "com.amazon.azw3"]
            .compactMap { UTType($0) } + [UTType(filenameExtension: "epub")].compactMap { $0 } + [.plainText, .pdf]
    }
}

// MARK: - The window's content

/// One entry in the sidebar: one of the three parts, or a folder from the
/// reader's list (shown in Home).
private enum SidebarItem: Hashable {
    case part(HomeNavigation.Tab)
    case folder(RecentItem.ID)
}

/// Home's content: the welcome on first launch; then the sidebar and the
/// part chosen in it.
struct MacHomeView: View {
    @ObservedObject var navigation: HomeNavigation
    let actions: HomeActions
    @ObservedObject private var books = RecentList.books
    @ObservedObject private var folders = RecentList.folders
    @ObservedObject private var favourites = RecentList.favorites

    /// Nothing opened or chosen yet: the welcome alone, as on iOS.
    private var isFirstRun: Bool { books.items.isEmpty && folders.items.isEmpty && favourites.items.isEmpty }

    var body: some View {
        Group {
            if isFirstRun {
                WelcomeView(open: actions.chooseBook,
                            openURLs: { $0.forEach(actions.openBook) },
                            chooseFolder: actions.chooseFolder)
                    .frame(minWidth: 620, minHeight: 420)
            } else {
                NavigationSplitView {
                    HomeSidebar(navigation: navigation, actions: actions)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
                } detail: {
                    page
                }
            }
        }
        // The first book opened from the welcome: Recent Books, where it now
        // is, rather than an empty Home (as on iOS).
        .onChange(of: isFirstRun) { _, first in
            if !first, folders.items.isEmpty { navigation.tab = .books }
        }
    }

    @ViewBuilder private var page: some View {
        switch navigation.tab {
        case .home: RecentFoldersView(navigation: navigation, actions: actions)
        case .favourites: BookShelfView(shelf: .favourites, actions: actions)
        case .books: BookShelfView(shelf: .recent, actions: actions)
        }
    }
}

/// The sidebar: Home, Favourites and Recent Books (the iOS tabs, in their
/// order), then the reader's folders. A folder can be dragged into another
/// place in the list, and removed or shown in Finder from its menu.
private struct HomeSidebar: View {
    @ObservedObject var navigation: HomeNavigation
    let actions: HomeActions
    @ObservedObject private var folders = RecentList.folders
    @ObservedObject private var network = NetworkStatus.shared
    @State private var reach: [RecentItem.ID: Reach] = [:]
    @State private var cannotOpen: RecentItem?

    var body: some View {
        List(selection: selection) {
            Section {
                row(.home, "Home", "house")
                row(.favourites, "Favourites", "heart")
                row(.books, "Recent Books", "clock")
            }
            Section("Folders") {
                ForEach(folders.items) { item in
                    folderRow(item)
                        .tag(SidebarItem.folder(item.id))
                        .contextMenu {
                            Button { actions.reveal?(RecentItem.pathURL(item.path)) } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }
                            Button(role: .destructive) { folders.remove(item) } label: {
                                Label("Remove from List", systemImage: "minus.circle")
                            }
                        }
                }
                .onMove { folders.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            // + adds a folder, as at the foot of Finder's and Music's sidebars.
            HStack {
                Button(action: actions.chooseFolder) { Label("Choose Folder…", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("Choose Folder…")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Each folder checked in the background, as in Home's list; one
        // out of reach is greyed.
        .task(id: folders.items.map(\.id)) { await checkReach(folders.items, in: folders, into: $reach) }
        .onReceive(NotificationCenter.default.publisher(for: .platenAppReturned)) { _ in
            Task { await checkReach(folders.items, in: folders, into: $reach) }
        }
        .onReceive(NetworkStatus.shared.changed.debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
            recheckAway(folders.items, in: $reach)
            Task { await checkReach(folders.items, in: folders, into: $reach) }
        }
        .alert(Text("This folder can’t be opened"), isPresented: Binding(
            get: { cannotOpen != nil }, set: { if !$0 { cannotOpen = nil } }
        ), presenting: cannotOpen) { item in
            Button("Try Again") { open(item, sayIfNot: true) }
            Button("Remove from List", role: .destructive) { folders.remove(item) }
            Button("OK", role: .cancel) {}
        } message: { _ in
            Text("It may have been moved or deleted, or it is on a drive or network share that is not connected.")
        }
    }

    private func row(_ tab: HomeNavigation.Tab, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).tag(SidebarItem.part(tab))
    }

    private func folderRow(_ item: RecentItem) -> some View {
        let state = reach[item.id] ?? .checking
        return Label {
            Text(item.name)
                .foregroundStyle(state == .unavailable ? .secondary : .primary)
        } icon: {
            if state == .reconnecting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: item.storageKind.symbol)
            }
        }
        .help(state == .unavailable ? RecentFoldersView.unavailableReason(item.storageKind, online: network.isOnline)
                                    : item.locationText)
    }

    /// What the sidebar shows as chosen: a folder from the list while it (or
    /// a folder inside it) is open in Home; otherwise the part showing.
    private var selection: Binding<SidebarItem?> {
        Binding {
            if navigation.tab == .home, let first = navigation.folderPath.first,
               let item = folders.items.first(where: { $0.path == FolderScanner.canonicalPath(first) }) {
                return .folder(item.id)
            }
            return .part(navigation.tab)
        } set: { chosen in
            switch chosen {
            case .part(let tab):
                // Home again: back to the list of folders.
                if tab == .home { navigation.folderPath = [] }
                navigation.tab = tab
            case .folder(let id):
                if let item = folders.items.first(where: { $0.id == id }) { open(item, sayIfNot: true) }
            case nil:
                break
            }
        }
    }

    /// Opens a folder in Home once it answers (a share may have gone); one
    /// known to be out of reach is said at once.
    private func open(_ item: RecentItem, sayIfNot: Bool) {
        if reach[item.id] == .unavailable, !sayIfNot { return }
        reach[item.id] = .reconnecting
        Task {
            guard let url = await folders.reachability(of: item, timeout: 10).url else {
                reach[item.id] = .unavailable
                if sayIfNot { cannotOpen = item }
                return
            }
            reach[item.id] = .available
            folders.openedSoon(url)
            navigation.show(folder: url)
        }
    }
}
