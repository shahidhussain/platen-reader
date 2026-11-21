import PlatenCore
import SwiftUI
import UIKit

extension Notification.Name {
    /// Asks the folder view to read its folder again (a reader was closed;
    /// the book may have been moved or deleted meanwhile).
    static let platenFolderShouldRefresh = Notification.Name("platenFolderShouldRefresh")
}

/// One folder's grid of covers (about three across on an iPhone), the
/// folders inside it first, shown in the Home tab. Tapping a
/// folder goes into it, with the usual Back button; tapping a book opens it.
/// Search (by file name, title and author) and a filter by kind of book are
/// in the toolbar.
struct FolderGridView: View {
    let folder: URL
    let openBook: (URL) -> Void
    /// A folder inside this one was tapped.
    let openFolder: (URL) -> Void
    @StateObject private var model: FolderModel
    /// The search field (shown by the search button) and what is typed in it.
    @State private var query = ""
    @State private var searching = false
    /// The book whose Get Info sheet is showing.
    @State private var infoFor: FolderEntry?
    /// Favourites, for the heart on their covers and the long-press menu.
    @ObservedObject private var favourites = RecentList.favorites
    /// Counts each book's hearts (marked as a favourite), to start its
    /// heartbeat.
    @State private var heartbeats: [URL: Int] = [:]
    @State private var showingOptions = false
    @ObservedObject private var filter = BookTypeFilter.shared

    init(folder: URL, openBook: @escaping (URL) -> Void, openFolder: @escaping (URL) -> Void) {
        self.folder = folder
        self.openBook = openBook
        self.openFolder = openFolder
        _model = StateObject(wrappedValue: FolderModel(folder: folder))
    }

    /// The books and folders that match the search (all of them when
    /// nothing is typed): by file name, and for books their title and
    /// authors too.
    private var shown: [FolderEntry] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return filter.sort.sorted(model.entries, info: model.covers).filter { entry in
            if entry.kind == .book, !filter.shows(entry.url) { return false }
            guard searching else { return true }
            let info = model.covers[entry.url]
            return FolderSearch.matches(query, name: entry.name, title: info?.title, authors: info?.authors ?? [])
        }
    }

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            LazyVGrid(columns: CoverColumns.items(filter, sizeClass), alignment: .leading,
                      spacing: CoverColumns.spacing(filter, sizeClass) + 6) {
                ForEach(shown) { entry in
                    Button {
                        tapped(entry)
                    } label: {
                        switch entry.kind {
                        case .folder:
                            FolderTile(name: entry.name)
                        case .book:
                            let info = model.covers[entry.url]
                            let lines = filter.coverLabel.lines(fileName: entry.name, title: info?.title,
                                                                author: info?.authors.first)
                            BookTile(title: info?.title ?? entry.name, author: info?.authors.first,
                                     imageFile: model.coverFiles[entry.url],
                                     badge: entry.isDownloaded ? nil
                                         : model.downloading.contains(entry.url) ? .downloading : .inCloud,
                                     caption: lines.0, subcaption: lines.1,
                                     titleOnTop: filter.coverLabel != .authorThenTitle || info?.authors.first == nil,
                                     isFavourite: favourites.contains(entry.url),
                                     heartbeats: heartbeats[entry.url, default: 0])
                        }
                    }
                    .buttonStyle(.plain)
                    // A long press on a book: Favourite, and Get Info.
                    .contextMenu {
                        if entry.kind == .book {
                            Button {
                                if Favourites.toggle(entry.url) { heartbeats[entry.url, default: 0] += 1 }
                            } label: {
                                Favourites.menuLabel(isFavourite: favourites.contains(entry.url))
                            }
                            Button { infoFor = entry } label: { Label("Get Info", systemImage: "info.circle") }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .coverPinch(filter, sizeClass)
        .sheet(item: $infoFor) { entry in
            BookInfoView(entry: entry, info: model.covers[entry.url])
        }
        .overlay {
            if !model.hasLoaded {
                // Reading the folder (slow for a large one or a network
                // share): not empty, just not read yet.
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Looking for books…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if model.entries.isEmpty == false, shown.isEmpty {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("No Books of These Kinds", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Change the filter to see the other books here."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else if model.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Books Here", systemImage: "books.vertical")
                } description: {
                    Text("Books added to this folder in Files appear here.")
                }
            }
        }
        .overlay(alignment: .bottom) {
            let (done, total) = model.coverProgress
            if model.hasLoaded, total > 0, done < total {
                CoverProgress(done: done, total: total)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.coverProgress.done < model.coverProgress.total)
        .navigationTitle(folder.lastPathComponent)
        // The title sits in the bar with the buttons, so the grid gets the
        // space. iOS's own Back button is at the top left (long-press it for
        // the whole way back); a swipe across the page goes back too
        // (SwipeBack), as does tapping the Home tab.
        .navigationBarTitleDisplayMode(.inline)
        // The search field opens from the search button (and closes with
        // Cancel, clearing the search).
        .searchable(text: $query, isPresented: $searching,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text("Title, author or file name"))
        // A note in the log of what each search found, once typing pauses,
        // to tell "not in the folder's listing yet" from "not matched".
        .task(id: query) {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            logSearch()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { searching = true } label: { Label("Search", systemImage: "magnifyingglass") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // View Options: the order, the kinds of book shown and the
                // words under each cover, in a sheet (filled in when some
                // kinds are hidden).
                Button { showingOptions = true } label: {
                    Label("View Options", systemImage: filter.showsAll ? "line.3.horizontal.decrease.circle"
                                                                       : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showingOptions) { FolderViewOptions() }
        .refreshable { model.refresh() }
        .onAppear {
            model.onDownloaded = openBook
            model.start()
            // Not added to the Home list: only folders the reader chose
            // go there (Choose Folder…), not every folder browsed into.
        }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .platenFolderShouldRefresh)) { _ in
            model.refresh()
        }
    }

    private func logSearch() {
        let books = model.entries.filter { $0.kind == .book }
        let found = shown
        let byName = books.filter { FolderSearch.matches(query, name: $0.name) }.count
        let titled = books.filter { model.covers[$0.url]?.title != nil }.count
        log.info("folder search: \(found.count) shown of \(model.entries.count) entries (\(books.count) books, \(titled) with titles read, \(byName) matching by file name), loaded: \(model.hasLoaded)")
        #if DEBUG
        // Debug builds only: the words and names themselves.
        log.info("folder search for \(query, privacy: .public) in \(folder.lastPathComponent, privacy: .public): \(found.map(\.name).joined(separator: " | "), privacy: .public)")
        #endif
    }

    private func tapped(_ entry: FolderEntry) {
        guard !filter.justPinched else { return } // the end of a pinch, not a tap
        switch entry.kind {
        case .folder:
            openFolder(entry.url)
        case .book where entry.isDownloaded:
            openBook(entry.url)
        case .book:
            // In iCloud only: fetch it first; it opens when it arrives.
            model.download(entry)
        }
    }
}

/// View Options, a sheet from the folder view's filter button: the order of
/// the books, the kinds shown (at least one stays ticked), and the words
/// under each cover. One choice for every folder.
struct FolderViewOptions: View {
    @ObservedObject private var filter = BookTypeFilter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort By") {
                    Picker("Sort By", selection: $filter.sort) {
                        ForEach(FolderSort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Picker("Under Each Cover", selection: $filter.coverLabel) {
                        ForEach(CoverLabel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Under Each Cover")
                } footer: {
                    Text("A book’s title and author are known once Platen has read it; until then, and for books only in iCloud, its file name is shown.")
                }
                Section {
                    ForEach(BookFileType.allCases) { type in
                        Toggle(type.label, isOn: Binding(get: { filter.isShown(type) }, set: { _ in filter.toggle(type) }))
                            .disabled(filter.isShown(type) && BookFileType.allCases.filter(filter.isShown).count == 1)
                    }
                } header: {
                    Text("Show")
                }
            }
            .navigationTitle("View Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// How many covers fit across a grid (folders, Recent Books): the reader's
/// choice, made by pinching (out for fewer and bigger, in for more and
/// smaller), or three on an iPhone and five on an iPad.
enum CoverColumns {
    static func range(_ sizeClass: UserInterfaceSizeClass?) -> ClosedRange<Int> {
        sizeClass == .regular ? 3...8 : 2...5
    }

    @MainActor static func count(_ options: BookTypeFilter, _ sizeClass: UserInterfaceSizeClass?) -> Int {
        let range = range(sizeClass)
        return min(max(options.columns ?? (sizeClass == .regular ? 5 : 3), range.lowerBound), range.upperBound)
    }

    @MainActor static func spacing(_ options: BookTypeFilter, _ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        count(options, sizeClass) > 3 ? 12 : 18
    }

    @MainActor static func items(_ options: BookTypeFilter, _ sizeClass: UserInterfaceSizeClass?) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing(options, sizeClass), alignment: .bottom),
              count: count(options, sizeClass))
    }
}

extension View {
    /// A pinch on a cover grid changes how many covers fit across.
    @MainActor func coverPinch(_ options: BookTypeFilter, _ sizeClass: UserInterfaceSizeClass?) -> some View {
        simultaneousGesture(
            MagnifyGesture()
                .onChanged { _ in options.lastPinch = Date() }
                .onEnded { value in
                options.lastPinch = Date()
                let now = CoverColumns.count(options, sizeClass)
                let next = value.magnification > 1.15 ? now - 1 : value.magnification < 0.87 ? now + 1 : now
                let range = CoverColumns.range(sizeClass)
                guard next != now, range.contains(next) else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { options.columns = next }
            }
        )
    }
}

/// While covers are being made: a small bar floating at the bottom, with
/// how many are done. Covers are made once and kept, so this shows the
/// first time a folder is opened (or after many books are added).
private struct CoverProgress: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: Double(done), total: Double(total))
                .progressViewStyle(.linear)
                .frame(width: 160)
            Text("Making covers: \(done) of \(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tiles

/// A book: its cover, bottom-aligned in a 2:3 space so covers of different
/// shapes sit on one line, with the title below. Used by the folder grids
/// and Recent Books.
struct BookTile: View {
    /// A mark on the cover, for a book that cannot be opened at once.
    enum Badge: Equatable {
        /// In iCloud only (tapping downloads it), and while it downloads
        /// (or, in Recent Books, while it is checked before opening).
        case inCloud, downloading
        /// Recent Books and Favourites: its file cannot be reached now
        /// (moved, deleted, on a drive or share that is not connected, or
        /// only in iCloud while offline), with a word saying which.
        case unavailable(String)

        var isUnavailable: Bool { if case .unavailable = self { true } else { false } }
    }

    let title: String
    let author: String?
    /// The cover picture's file (nil: none, or not made yet). It is decoded
    /// while the tile is on screen (CoverImages).
    let imageFile: URL?
    var badge: Badge?
    /// The words under the cover (the folder view's View Options choose
    /// them): one or two lines; the title alone when not given.
    var caption: String? = nil
    var subcaption: String? = nil
    /// Whether the first line is the title. The title is always in the
    /// main colour and the author in grey, whichever comes first.
    var titleOnTop = true
    /// A favourite shows a small heart on its cover (not in Favourites,
    /// where every book is one).
    var isFavourite = false
    /// Goes up when the book is marked as a favourite: the heart beats.
    var heartbeats = 0
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .bottom) { cover }
            // Two lines either way, so the rows of covers line up.
            if let subcaption {
                VStack(alignment: .leading, spacing: 1) {
                    Text(caption ?? title)
                        .foregroundStyle(titleOnTop ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                    Text(subcaption)
                        .foregroundStyle(titleOnTop ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                }
                .font(.caption)
            } else {
                Text(caption ?? title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .task(id: imageFile) {
            image = imageFile.flatMap(CoverImages.shared.cached)
            if image == nil, let imageFile { image = await CoverImages.shared.image(imageFile) }
        }
    }

    @ViewBuilder private var cover: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            } else {
                PlainCover(title: title, author: author)
            }
        }
        // A book that cannot be reached is greyed, with a label saying so.
        .saturation(badge?.isUnavailable == true ? 0 : 1)
        .opacity(badge?.isUnavailable == true ? 0.45 : 1)
        .overlay(alignment: .bottom) {
            if case .unavailable(let reason) = badge {
                Text(reason)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isFavourite {
                Image(systemName: "heart.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.red, in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .padding(5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3).delay(isFavourite ? 0.3 : 0), value: isFavourite)
        .heartbeat(heartbeats)
        .overlay(alignment: .bottomTrailing) {
            switch badge {
            case .inCloud:
                mark(Image(systemName: "icloud.and.arrow.down"))
            case .downloading:
                mark(ProgressView().tint(.white))
            case .unavailable, nil:
                EmptyView()
            }
        }
    }

    private func mark(_ content: some View) -> some View {
        content
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.45), in: Circle())
            .padding(6)
    }

    private var accessibilityLabel: String {
        var parts = [title]
        if let author { parts.append(author) }
        if isFavourite { parts.append(String(localized: "Favourite")) }
        switch badge {
        case .inCloud: parts.append(String(localized: "In iCloud"))
        case .downloading: parts.append(String(localized: "Downloading"))
        case .unavailable(let reason): parts.append(reason)
        case nil: break
        }
        return parts.joined(separator: ", ")
    }
}

/// A cover for a book without a picture (or one not downloaded yet): the
/// title and author on a quiet colour chosen from the title, so the same
/// book always looks the same.
struct PlainCover: View {
    let title: String
    let author: String?

    private static let colours: [Color] = [
        Color(red: 0.36, green: 0.42, blue: 0.52), Color(red: 0.50, green: 0.36, blue: 0.33),
        Color(red: 0.33, green: 0.46, blue: 0.40), Color(red: 0.45, green: 0.40, blue: 0.53),
        Color(red: 0.55, green: 0.47, blue: 0.32), Color(red: 0.30, green: 0.43, blue: 0.47),
    ]

    private var colour: Color {
        // A stable choice (String.hashValue changes every launch).
        let sum = title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.colours[sum % Self.colours.count]
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(colour.gradient)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay { words }
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }

    private var words: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .minimumScaleFactor(0.7)
            if let author {
                Text(author)
                    .font(.system(.caption2, design: .serif))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
    }
}

/// A folder inside the one on show.
struct FolderTile: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .secondarySystemFill))
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                }
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Folder: \(name)"))
        .accessibilityAddTraits(.isButton)
    }
}
