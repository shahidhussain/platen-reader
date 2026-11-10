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
/// labelled "Previous Page", "Show Controls" and "Next Page" (one zone in
/// scroll mode). The side zones are wider, since most clicks turn pages.
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

    /// Must match `sideZoneFraction` in reader.js.
    static let sideZoneFraction: CGFloat = 0.38

    private struct Zone: Identifiable {
        let id: Int
        let label: String
        let symbol: String?
        let widthFraction: CGFloat
    }

    private var zones: [Zone] {
        let centre = String(localized: "Show Controls")
        if flow == .scrolled { return [Zone(id: 0, label: centre, symbol: nil, widthFraction: 1)] }
        let side = Self.sideZoneFraction
        let previous = Zone(id: 0, label: String(localized: "Previous Page"), symbol: "chevron.left", widthFraction: side)
        let next = Zone(id: 2, label: String(localized: "Next Page"), symbol: "chevron.right", widthFraction: side)
        let middle = Zone(id: 1, label: centre, symbol: nil, widthFraction: 1 - 2 * side)
        // In right-to-left books the left of the page moves forward.
        return rightToLeft
            ? [Zone(id: 0, label: next.label, symbol: "chevron.left", widthFraction: side), middle,
               Zone(id: 2, label: previous.label, symbol: "chevron.right", widthFraction: side)]
            : [previous, middle, next]
    }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 6
            let width = geo.size.width - spacing * CGFloat(zones.count - 1)
            HStack(spacing: spacing) {
                ForEach(zones) { zone in
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                        .overlay(
                            VStack(spacing: 6) {
                                if let symbol = zone.symbol {
                                    Image(systemName: symbol).font(.title.weight(.semibold))
                                }
                                Text(zone.label).font(.title3.weight(.semibold))
                                if zone.symbol == nil {
                                    Text("or press C").font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(6)
                        )
                        .frame(width: width * zone.widthFraction)
                }
            }
        }
        .padding(10)
        .padding(.top, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Reading controls: click the left of the page for the previous page, the right for the next page, and the middle to show controls, or press C."))
    }
}
