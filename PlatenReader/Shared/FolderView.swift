import PlatenCore
import SwiftUI

/// One folder's grid of covers (about three across on an iPhone), the
/// folders inside it first, shown in the Home tab (iOS) or the Home window
/// (Mac). Tapping a
/// folder goes into it, with the usual Back button; tapping a book opens it.
/// Search (by file name, title and author) and a filter by kind of book are
/// in the toolbar.
struct FolderGridView: View {
    let folder: URL
    let openBook: (URL) -> Void
    /// A folder inside this one was tapped.
    let openFolder: (URL) -> Void
    /// Shows a book or folder in Finder (the Mac; nil on iOS).
    var reveal: ((URL) -> Void)? = nil
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

    init(folder: URL, openBook: @escaping (URL) -> Void, openFolder: @escaping (URL) -> Void,
         reveal: ((URL) -> Void)? = nil) {
        self.folder = folder
        self.openBook = openBook
        self.openFolder = openFolder
        self.reveal = reveal
        _model = StateObject(wrappedValue: FolderModel(folder: folder))
    }

    /// The books and folders that match the search (all of them when
    /// nothing is typed): by file name, and for books their title and
    /// authors too.
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var shown: [FolderEntry] {
        let searching = isSearching
        return filter.sort.sorted(model.entries, info: model.covers).filter { entry in
            if entry.kind == .book, !filter.shows(entry.url) { return false }
            guard searching else { return true }
            let info = model.info(for: entry.url)
            return FolderSearch.matches(query, name: entry.name, title: info?.title, authors: info?.authors ?? [])
        }
    }

    private let room = RoomyGrid()
    /// The tab row's bottom safe area (tab bar and keyboard), and the
    /// grid's own: the grid makes room for the difference, so its last row,
    /// and search results with the keyboard up, can be scrolled clear of
    /// them (`roomBelow`).
    @Environment(\.tabRowBottom) private var tabRowBottom
    @State private var ownBottom: CGFloat = 0
    /// The view's width, for the title's room in the bar.
    @State private var width: CGFloat = 390

    var body: some View {
        // Worked out once per redraw (a sort of the whole folder), not once
        // for each place that needs it.
        let items = shown
        ScrollView {
            LazyVGrid(columns: CoverColumns.items(filter, roomy: room.isRoomy), alignment: .leading,
                      spacing: CoverColumns.spacing(filter, roomy: room.isRoomy) + 6) {
                ForEach(items) { entry in
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
                        if entry.kind == .folder, let reveal {
                            Button { reveal(entry.url) } label: { Label("Show in Finder", systemImage: "folder") }
                        }
                        if entry.kind == .book {
                            #if os(iOS)
                            BookWindows.MenuItem { BookWindows.open(url: entry.url, title: entry.name) }
                            #endif
                            Button {
                                if Favourites.toggle(entry.url) { heartbeats[entry.url, default: 0] += 1 }
                            } label: {
                                Favourites.menuLabel(isFavourite: favourites.contains(entry.url))
                            }
                            Button { infoFor = entry } label: { Label("Get Info", systemImage: "info.circle") }
                            if let reveal {
                                Button { reveal(entry.url) } label: { Label("Show in Finder", systemImage: "folder") }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .roomBelow($ownBottom, tabRowBottom: tabRowBottom)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .coverPinch(filter, roomy: room.isRoomy)
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
            } else if model.entries.isEmpty == false, items.isEmpty {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("No Books of These Kinds", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Change the filter to see the other books here."))
                } else if model.titlesToRead == 0 {
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
            if isSearching, model.titlesToRead > 0 {
                // Still reading titles and authors to search: the results
                // grow as they come in.
                TitleProgress(left: model.titlesToRead)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else if model.hasLoaded, total > 0, done < total {
                CoverProgress(done: done, total: total)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.coverProgress.done < model.coverProgress.total)
        .navigationTitle(folder.lastPathComponent)
        .folderChrome(name: folder.lastPathComponent, width: width, query: $query, searching: $searching,
                      showingOptions: $showingOptions, filterShowsAll: filter.showsAll)
        // A note in the log of what each search found, once typing pauses,
        // to tell "not in the folder's listing yet" from "not matched".
        .task(id: query) {
            guard isSearching else { return }
            // Titles and authors not known yet (their covers still to be
            // made) are read now, so the search finds them.
            model.readTitlesForSearch()
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            logSearch()
        }
        .sheet(isPresented: $showingOptions) { FolderViewOptions() }
        .refreshable { await model.refreshByReader() }
        .onAppear {
            model.onDownloaded = openBook
            model.start()
            #if DEBUG
            // PLATEN_FOLDER_SEARCH=<words>: searches as the folder first
            // appears, as a reader typing at once would (DebugHooks.swift).
            if let words = ProcessInfo.processInfo.environment["PLATEN_FOLDER_SEARCH"], !words.isEmpty, query.isEmpty {
                searching = true
                query = words
            }
            #endif
            // Not added to the Home list: only folders the reader chose
            // go there (Choose Folder…), not every folder browsed into.
        }
        .onDisappear { model.stop() }
        // Covers are made in the order the grid shows (Random included).
        .onChange(of: items.map(\.url), initial: true) { _, order in model.showOrder(order) }
        .onReceive(NotificationCenter.default.publisher(for: .platenAppReturned)) { _ in
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
        let titled = books.filter { model.info(for: $0.url)?.title != nil }.count
        log.info("folder search: \(found.count) shown of \(model.entries.count) entries (\(books.count) books, \(titled) with titles read, \(byName) matching by file name), loaded: \(model.hasLoaded)")
        #if DEBUG
        // Debug builds only: the words and names themselves.
        log.info("folder search for \(query, privacy: .name) in \(folder.lastPathComponent, privacy: .name): \(found.map(\.name).joined(separator: " | "), privacy: .name)")
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .formStyle(.grouped)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 340, minHeight: 460)
        #endif
    }
}

/// How many covers fit across a grid (folders, Recent Books): the reader's
/// choice, made by pinching (out for fewer and bigger, in for more and
/// smaller), or three on an iPhone and five on an iPad or a Mac (`roomy`:
/// `RoomyGrid`).
enum CoverColumns {
    static func range(roomy: Bool) -> ClosedRange<Int> {
        roomy ? 3...8 : 2...5
    }

    @MainActor static func count(_ options: BookTypeFilter, roomy: Bool) -> Int {
        let range = range(roomy: roomy)
        return min(max(options.columns ?? (roomy ? 5 : 3), range.lowerBound), range.upperBound)
    }

    @MainActor static func spacing(_ options: BookTypeFilter, roomy: Bool) -> CGFloat {
        count(options, roomy: roomy) > 3 ? 12 : 18
    }

    @MainActor static func items(_ options: BookTypeFilter, roomy: Bool) -> [GridItem] {
        #if os(macOS)
        // A Mac window can be any width, so the count chooses a cover size
        // instead, and as many fit across as the window allows (as Finder's
        // icon size does): fewer is bigger.
        let width = macCoverWidth(count(options, roomy: roomy))
        return [GridItem(.adaptive(minimum: width, maximum: width * 1.25), spacing: spacing(options, roomy: roomy),
                         alignment: .bottom)]
        #else
        return Array(repeating: GridItem(.flexible(), spacing: spacing(options, roomy: roomy), alignment: .bottom),
                     count: count(options, roomy: roomy))
        #endif
    }

    /// A cover's width on the Mac for a count of 3 (biggest) to 8
    /// (smallest).
    static func macCoverWidth(_ count: Int) -> CGFloat {
        let widths: [Int: CGFloat] = [3: 200, 4: 160, 5: 128, 6: 110, 7: 96, 8: 84]
        return widths[count] ?? 128
    }

    /// One step bigger (fewer across) or smaller (more across): View ›
    /// Bigger Covers and Smaller Covers on the Mac.
    @MainActor static func step(_ options: BookTypeFilter, roomy: Bool, bigger: Bool) {
        let next = count(options, roomy: roomy) + (bigger ? -1 : 1)
        guard range(roomy: roomy).contains(next) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { options.columns = next }
    }
}

extension View {
    /// A pinch on a cover grid changes how many covers fit across.
    @MainActor func coverPinch(_ options: BookTypeFilter, roomy: Bool) -> some View {
        simultaneousGesture(
            MagnifyGesture()
                .onChanged { _ in options.lastPinch = Date() }
                .onEnded { value in
                options.lastPinch = Date()
                let now = CoverColumns.count(options, roomy: roomy)
                let next = value.magnification > 1.15 ? now - 1 : value.magnification < 0.87 ? now + 1 : now
                let range = CoverColumns.range(roomy: roomy)
                guard next != now, range.contains(next) else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { options.columns = next }
            }
        )
    }
}

extension View {
    /// The folder view's bar: its title, Search and View Options. On iOS the
    /// folder's name stands at the left beside Back, and the search field is
    /// a drawer under the bar (see below); on the Mac the window's title is
    /// the folder's name and the search field sits in the toolbar, as in
    /// Finder.
    fileprivate func folderChrome(name: String, width: CGFloat, query: Binding<String>, searching: Binding<Bool>,
                                  showingOptions: Binding<Bool>, filterShowsAll: Bool) -> some View {
        let options = Button { showingOptions.wrappedValue = true } label: {
            // View Options: the order, the kinds of book shown and the
            // words under each cover, in a sheet (filled in when some
            // kinds are hidden).
            Label("View Options", systemImage: filterShowsAll ? "line.3.horizontal.decrease.circle"
                                                               : "line.3.horizontal.decrease.circle.fill")
        }
        #if os(iOS)
        // The title sits in the bar with the buttons, so the grid gets the
        // space, and to the left, beside the Back button, as the book's own
        // title is in the reader (the reader asked, 27 Nov 2026): the bar's
        // own centred title is left empty, and the folder's name is the
        // first item on the left (`FolderTitle`). The navigation title is
        // still set, for the Back button's menu. iOS's own
        // Back button is at the top left (long-press it for the whole way
        // back); a swipe across the page goes back too (SwipeBack), as does
        // tapping the Home tab.
        return self
            .navigationBarTitleDisplayMode(.inline)
            // The search field opens from the search button (and closes with
            // Cancel, clearing the search). While it has words in it, it stays
            // up as the results are scrolled, so what was searched for stays in
            // sight; empty, it tucks away on scrolling as usual.
            .searchable(text: query, isPresented: searching,
                        placement: .navigationBarDrawer(displayMode: query.wrappedValue.isEmpty ? .automatic : .always),
                        prompt: Text("Title, author or file name"))
            .toolbar {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                FolderTitle(name: name, maxWidth: max(80, width - 250))
                ToolbarItem(placement: .topBarTrailing) {
                    Button { searching.wrappedValue = true } label: { Label("Search", systemImage: "magnifyingglass") }
                }
                ToolbarItem(placement: .topBarTrailing) { options }
            }
        #else
        return self
            .searchable(text: query, isPresented: searching, placement: .toolbar,
                        prompt: Text("Title, author or file name"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) { options }
            }
        #endif
    }
}

#if os(iOS)
/// The folder's name at the left of the bar, beside the Back button (as
/// plain text: on iOS 26, without the glass a bar item is given). The
/// bar's own centred title is hidden (`.principal`, empty).
private struct FolderTitle: ToolbarContent {
    let name: String
    /// The most it may take: the bar's width less the Back button and the
    /// two buttons on the right.
    let maxWidth: CGFloat

    var body: some ToolbarContent {
        // (The iOS 26 modifier only where the SDK has it: CI builds with an
        // older Xcode, as GlassSurface does.)
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            ToolbarItem(placement: .topBarLeading) { title }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { title }
        }
        #else
        ToolbarItem(placement: .topBarLeading) { title }
        #endif
    }

    private var title: some View {
        Text(verbatim: name)
            .font(.headline)
            .lineLimit(1)
            // Its whole width (a bar item is otherwise squeezed to a few
            // letters), up to what the buttons leave: a long name ends in
            // "…" short of them.
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityAddTraits(.isHeader)
    }
}
#endif

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

/// While a search waits for books' titles and authors to be read
/// (`FolderModel.readTitlesForSearch`): how many are left. The results grow
/// meanwhile.
private struct TitleProgress: View {
    let left: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Searching titles and authors: \(left) to go")
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
        /// Recent Books and Favourites: its place is not answering straight
        /// away (a share or cloud coming back after the device went offline
        /// or changed networks): a spinner and "Reconnecting…".
        case reconnecting
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
            if let reason = caption(for: badge) {
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
                    .background(Color.platenAccent, in: Circle())
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
            case .downloading, .reconnecting:
                mark(ProgressView().tint(.white))
            case .unavailable, nil:
                EmptyView()
            }
        }
    }

    /// The words on the cover: why it cannot be opened, or that it is
    /// reconnecting.
    private func caption(for badge: Badge?) -> String? {
        switch badge {
        case .unavailable(let reason): return reason
        case .reconnecting: return String(localized: "Reconnecting…")
        default: return nil
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
        case .reconnecting: parts.append(String(localized: "Reconnecting…"))
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
                .fill(.fill.secondary)
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
