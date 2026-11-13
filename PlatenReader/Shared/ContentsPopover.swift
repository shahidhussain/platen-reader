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
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(current ? Color.accentColor.opacity(0.15) : Color.clear)
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
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(bookmark.chapter?.isEmpty == false ? bookmark.chapter! : String(localized: "Bookmark"))
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            if let page = bookmark.page {
                                Text("p. \(page)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(bookmark.snippet)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                                (Text(hit.pre) + Text(hit.match).bold().foregroundColor(.primary) + Text(hit.post))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(hit.id == state.currentHitID ? Color.accentColor.opacity(0.15) : Color.clear)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .onAppear { fieldFocused = true }
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
