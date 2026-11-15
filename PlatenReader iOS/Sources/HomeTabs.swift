import PlatenCore
import SwiftUI
import UIKit

/// What the home screen asks of its view controller (HomeViewController).
struct HomeActions {
    let openBook: (URL) -> Void
    let chooseBook: () -> Void
    let chooseFolder: () -> Void
}

/// The home screen: three tabs, whose bar stays at the bottom even inside a
/// folder, so the reader can always get back out.
/// - **Home:** the chosen folder as covers (FolderBrowserView), or the
///   welcome until a folder is chosen.
/// - **Recent Books:** books opened lately, from anywhere, newest first.
/// - **Recent Folders:** folders looked at lately, as a list.
struct HomeTabs: View {
    @ObservedObject var library: LibraryFolder
    let actions: HomeActions

    private enum Tab: Hashable { case home, books, folders }
    @State private var tab: Tab = .home

    var body: some View {
        TabView(selection: $tab) {
            home
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)
            RecentBooksView(openBook: actions.openBook)
                .tabItem { Label("Recent Books", systemImage: "clock") }
                .tag(Tab.books)
            RecentFoldersView(actions: actions)
                .tabItem { Label("Recent Folders", systemImage: "folder") }
                .tag(Tab.folders)
        }
    }

    @ViewBuilder private var home: some View {
        if library.root != nil {
            FolderBrowserView(library: library, openBook: actions.openBook,
                              chooseBook: actions.chooseBook, chooseFolder: actions.chooseFolder)
        } else {
            WelcomeView(open: actions.chooseBook, chooseFolder: actions.chooseFolder)
        }
    }
}

// MARK: - Recent Books

/// Books opened lately, wherever they are, as covers (copies kept with the
/// list, so they show even when the book cannot be reached). A book that
/// cannot be reached now (moved, deleted, or on a drive or share that is
/// not connected) is greyed with a mark. A long press offers Remove from
/// Recents.
struct RecentBooksView: View {
    @ObservedObject private var recents = RecentList.books
    let openBook: (URL) -> Void

    @State private var images: [RecentItem.ID: CGImage] = [:]
    @State private var unavailable: Set<RecentItem.ID> = []
    @State private var cannotOpen: RecentItem?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 200), spacing: 18, alignment: .bottom)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(recents.items) { item in
                        Button { open(item) } label: {
                            BookTile(title: item.displayName, author: item.author, image: images[item.id],
                                     badge: unavailable.contains(item.id) ? .unavailable : nil)
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
                    ContentUnavailableView("No Recent Books", systemImage: "clock",
                                           description: Text("Books you open appear here."))
                }
            }
            .navigationTitle("Recent Books")
            // Covers and whether each book can be reached, looked up again
            // whenever the list changes or the tab is shown.
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
        Task {
            let url = await Task.detached { RecentList.isReachable(item) ? RecentList.resolve(item) : nil }.value
            if let url {
                unavailable.remove(item.id)
                openBook(url)
            } else {
                unavailable.insert(item.id)
                cannotOpen = item
            }
        }
    }

    /// Loads the covers not yet loaded, and checks each book can be reached
    /// (in the background: a network share can be slow to answer).
    private func refresh() async {
        let items = recents.items
        for item in items where images[item.id] == nil {
            guard let url = recents.coverURL(for: item) else { continue }
            if let image = await Task.detached(operation: { Self.decode(url) }).value { images[item.id] = image }
        }
        let reachable = await withTaskGroup(of: (RecentItem.ID, Bool).self) { group in
            for item in items { group.addTask { (item.id, RecentList.isReachable(item)) } }
            var result: [RecentItem.ID: Bool] = [:]
            for await (id, ok) in group { result[id] = ok }
            return result
        }
        unavailable = Set(reachable.filter { !$0.value }.map(\.key))
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

// MARK: - Recent Folders

/// Folders looked at lately, as a list (name, the folder it is in, and when).
/// Tapping one shows it, inside this tab. One that cannot be reached is
/// greyed. A long press (or a swipe) removes it from the list.
struct RecentFoldersView: View {
    @ObservedObject private var recents = RecentList.folders
    let actions: HomeActions

    @State private var path: [URL] = []
    @State private var unavailable: Set<RecentItem.ID> = []
    @State private var cannotOpen: RecentItem?
    /// Folders opened from here hold their access while the app runs (their
    /// books are read from them).
    private static var accessing: Set<URL> = []

    var body: some View {
        NavigationStack(path: $path) {
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
                    ContentUnavailableView("No Recent Folders", systemImage: "folder",
                                           description: Text("Folders you look at appear here."))
                }
            }
            .navigationTitle("Recent Folders")
            .navigationDestination(for: URL.self) { folder in
                FolderGridView(folder: folder, openBook: actions.openBook, openFolder: { path.append($0) },
                               chooseBook: actions.chooseBook, chooseFolder: actions.chooseFolder)
                    .id(folder)
            }
            .task(id: recents.items.map(\.id)) { await checkReachable() }
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
        let gone = unavailable.contains(item.id)
        return HStack(spacing: 14) {
            Image(systemName: gone ? "folder.badge.questionmark" : "folder.fill")
                .font(.title2)
                .foregroundStyle(gone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(gone ? .secondary : .primary)
                Text(gone ? String(localized: "Not available") : "\(item.place) · \(item.lastOpened.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func open(_ item: RecentItem) {
        Task {
            let url = await Task.detached { RecentList.isReachable(item) ? RecentList.resolve(item) : nil }.value
            guard let url else {
                unavailable.insert(item.id)
                cannotOpen = item
                return
            }
            unavailable.remove(item.id)
            if !Self.accessing.contains(url), url.startAccessingSecurityScopedResource() { Self.accessing.insert(url) }
            path = [url]
        }
    }

    private func checkReachable() async {
        let items = recents.items
        let reachable = await withTaskGroup(of: (RecentItem.ID, Bool).self) { group in
            for item in items { group.addTask { (item.id, RecentList.isReachable(item)) } }
            var result: [RecentItem.ID: Bool] = [:]
            for await (id, ok) in group { result[id] = ok }
            return result
        }
        unavailable = Set(reachable.filter { !$0.value }.map(\.key))
    }
}
