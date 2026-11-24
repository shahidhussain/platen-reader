import PlatenCore
import SwiftUI

/// Callbacks from the sidebar to the reader.
struct ContentsActions {
    var goToTOCItem: (ReaderState.TOCItem) -> Void
    var goToBookmark: (BookRecord.Bookmark) -> Void
    var removeBookmark: (BookRecord.Bookmark) -> Void
    var search: (String) -> Void
    var goToHit: (ReaderState.SearchHit) -> Void
    var close: () -> Void
}

/// The contents popover (⌘T): Contents, Bookmarks and Search tabs. It hangs
/// from the Contents button in the overlay; a click outside it closes it.
struct ContentsPopover: View {
    @ObservedObject var state: ReaderState
    let actions: ContentsActions

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $state.sidebarTab) {
                ForEach(ReaderState.SidebarTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            switch state.sidebarTab {
            case .contents: ContentsList(state: state, actions: actions)
            case .bookmarks: BookmarksList(state: state, actions: actions)
            case .search: SearchPanel(state: state, actions: actions)
            }
        }
        // A popover from the overlay's Contents button.
        .frame(width: 340, height: 460)
        #if os(macOS)
        .onExitCommand(perform: actions.close) // Esc closes the popover
        #endif
        .platenPopover()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Contents and Bookmarks"))
    }
}

private struct ContentsList: View {
    @ObservedObject var state: ReaderState
    let actions: ContentsActions

    var body: some View {
        if state.toc.isEmpty {
            EmptyPanel(text: String(localized: "This book has no table of contents."))
        } else {
            ScrollViewReader { proxy in
                List(state.toc) { item in
                    let current = item.href == state.chapterHref
                        || (state.chapterHref == nil && item.label == state.chapter)
                    Button { actions.goToTOCItem(item) } label: {
                        Text(item.label.isEmpty ? String(localized: "Untitled") : item.label)
                            .fontWeight(current ? .semibold : .regular)
                            .lineLimit(2)
                            .padding(.leading, CGFloat(min(item.depth, 4)) * 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            // The chapter being read: a slim bar of the
                            // accent at its edge, as well as the weight.
                            .overlay(alignment: .leading) {
                                if current {
                                    Capsule().fill(Color.platenAccent)
                                        .frame(width: 3)
                                        .padding(.vertical, 1)
                                        .offset(x: -9)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(current ? Color.platenAccent.opacity(0.15) : Color.clear)
                    .accessibilityAddTraits(current ? .isSelected : [])
                    .id(item.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onAppear {
                    if let current = state.toc.first(where: { $0.href == state.chapterHref }) {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct BookmarksList: View {
    @ObservedObject var state: ReaderState
    let actions: ContentsActions

    private var showsPages: Bool { state.bookmarks.contains { $0.page?.isEmpty == false } }

    var body: some View {
        if state.bookmarks.isEmpty {
            #if os(macOS)
            EmptyPanel(text: String(localized: "No bookmarks yet. Click the top-right corner of a page, or press ⌘D."))
            #else
            EmptyPanel(text: String(localized: "No bookmarks yet. Tap the top-right corner of a page, or the bookmark button."))
            #endif
        } else {
            List(state.bookmarks, id: \.cfi) { bookmark in
                Button { actions.goToBookmark(bookmark) } label: {
                    // The page in a column of its own at the right, as in a
                    // book's contents page, so the list scans down it.
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bookmark.chapter?.isEmpty == false ? bookmark.chapter! : String(localized: "Bookmark"))
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text(bookmark.snippet)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // (Only where some bookmark has a page: an EPUB's
                        // bookmarks have one when the book gives printed
                        // page numbers; a PDF's always do.)
                        if showsPages {
                            Text(bookmark.page ?? "")
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                                .accessibilityLabel(bookmark.page.map { Text("page \($0)") } ?? Text(verbatim: ""))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove Bookmark", role: .destructive) { actions.removeBookmark(bookmark) }
                }
                .accessibilityAction(named: Text("Remove Bookmark")) { actions.removeBookmark(bookmark) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct SearchPanel: View {
    /// A result's line, its match in the text colour on a translucent tint
    /// of the accent, as matches are marked on the page.
    static func excerpt(_ hit: ReaderState.SearchHit) -> AttributedString {
        var match = AttributedString(hit.match)
        match.foregroundColor = .primary
        match.backgroundColor = Color.platenAccent.opacity(0.3)
        return AttributedString(hit.pre) + match + AttributedString(hit.post)
    }

    @ObservedObject var state: ReaderState
    let actions: ContentsActions
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Find in Book", text: $state.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { actions.search(state.searchQuery) }
                if state.searchRunning {
                    ProgressView(value: state.searchProgress).progressViewStyle(.circular).controlSize(.small)
                }
            }
            .padding(10)

            if let done = state.searchDoneQuery, !state.searchRunning {
                let count = state.allHits.count
                Text(count == 0 ? String(localized: "No results for “\(done)”")
                     : count == 1 ? String(localized: "1 result")
                                  : String(localized: "\(count) results"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }

            List {
                ForEach(state.searchGroups) { group in
                    Section(group.label.isEmpty ? String(localized: "Untitled") : group.label) {
                        ForEach(group.hits) { hit in
                            Button { actions.goToHit(hit) } label: {
                                Text(Self.excerpt(hit))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(hit.id == state.currentHitID ? Color.platenAccent.opacity(0.15) : Color.clear)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        // Ready to type into. On iOS only when there is nothing to show yet:
        // a search already made (Search Book for "…" from a selection) keeps
        // the keyboard down, so it does not cover the results.
        .onAppear {
            #if os(iOS)
            fieldFocused = state.searchQuery.isEmpty
            #else
            fieldFocused = true
            #endif
        }
        .onChange(of: state.searchFocusRequest) { fieldFocused = true }
    }
}

private struct EmptyPanel: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
