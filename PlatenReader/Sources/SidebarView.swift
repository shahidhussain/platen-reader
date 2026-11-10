import PlatenCore
import SwiftUI

/// Callbacks from the sidebar to the reader.
struct SidebarActions {
    var goToTOCItem: (ReaderState.TOCItem) -> Void
    var goToBookmark: (BookRecord.Bookmark) -> Void
    var removeBookmark: (BookRecord.Bookmark) -> Void
    var search: (String) -> Void
    var goToHit: (ReaderState.SearchHit) -> Void
    var close: () -> Void
}

/// The contents panel (⌘T): Contents, Bookmarks and Search tabs. It slides
/// over the left of the page rather than resizing the window, so the text
/// does not re-flow when it opens.
struct SidebarView: View {
    @ObservedObject var state: ReaderState
    let actions: SidebarActions

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $state.sidebarTab) {
                ForEach(ReaderState.SidebarTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 40) // clear of the window buttons
            .padding(.bottom, 8)

            Divider()

            switch state.sidebarTab {
            case .contents: ContentsList(state: state, actions: actions)
            case .bookmarks: BookmarksList(state: state, actions: actions)
            case .search: SearchPanel(state: state, actions: actions)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        // Opaque rather than translucent: blurred book text behind a list
        // of chapter titles is hard to read.
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .trailing) { Divider() }
        .onExitCommand(perform: actions.close) // Esc closes the panel
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Contents and Bookmarks"))
    }
}

private struct ContentsList: View {
    @ObservedObject var state: ReaderState
    let actions: SidebarActions

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
    let actions: SidebarActions

    var body: some View {
        if state.bookmarks.isEmpty {
            EmptyPanel(text: String(localized: "No bookmarks yet. Click the top-right corner of a page, or press ⌘D."))
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
    let actions: SidebarActions
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

// MARK: - First-run explainer

/// The click-zone explainer: three translucent zones over the real page,
/// labelled "Back", "Show controls" and "Forward" (one zone in scroll mode).
/// Shown the first time any book opens, briefly when switching modes (first
/// three switches only), and from Help > Show Reading Controls.
struct ReadingControlsExplainer: View {
    static let seenKey = "hasSeenReadingControls"
    static let switchCountKey = "readingModeSwitchExplainerCount"

    static func resetTips() {
        UserDefaults.standard.removeObject(forKey: seenKey)
        UserDefaults.standard.removeObject(forKey: switchCountKey)
    }

    let flow: ReadingFlow
    let rightToLeft: Bool

    private var zones: [String] {
        if flow == .scrolled { return [String(localized: "Show controls")] }
        let back = String(localized: "Back"), forward = String(localized: "Forward")
        return rightToLeft
            ? [forward, String(localized: "Show controls"), back]
            : [back, String(localized: "Show controls"), forward]
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(zones.enumerated()), id: \.offset) { _, label in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    .overlay(
                        Text(label)
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    )
            }
        }
        .padding(10)
        .padding(.top, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Reading controls: click the left of the page to go back, the right to go forward, and the middle to show controls."))
    }
}
