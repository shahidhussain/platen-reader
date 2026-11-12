import Foundation
import PlatenCore

/// Everything the overlay and sidebar show for one book, published so the
/// SwiftUI views update themselves. The view controller writes it in response
/// to messages from reader.js.
final class ReaderState: ObservableObject {
    struct TOCItem: Identifiable, Equatable {
        let id: Int
        let label: String
        let href: String
        let depth: Int
    }

    struct SearchHit: Identifiable, Equatable {
        let id: Int
        let cfi: String
        let pre: String
        let match: String
        let post: String
    }

    struct SearchGroup: Identifiable, Equatable {
        let id: Int
        let label: String
        var hits: [SearchHit]
    }

    /// What is selected in the book, for Copy with Citation and searching.
    struct Selection: Equatable {
        var text: String
        var chapter: String
        var page: String?
    }

    enum SidebarTab: String, CaseIterable, Identifiable {
        case contents, bookmarks, search
        var id: String { rawValue }
        var label: String {
            switch self {
            case .contents: return String(localized: "Contents")
            case .bookmarks: return String(localized: "Bookmarks")
            case .search: return String(localized: "Search")
            }
        }
    }

    // Book
    @Published var title = ""
    @Published var author = ""
    @Published var isFixedLayout = false
    @Published var isRightToLeft = false
    @Published var flow: ReadingFlow = .paginated

    // Location
    @Published var chapter = ""
    @Published var chapterHref: String?
    @Published var fraction: Double = 0
    @Published var pagesLeftInChapter: Int?
    /// Where each section starts, as a fraction of the book (slider ticks).
    @Published var sectionFractions: [Double] = []
    /// Chapter title for each section (slider label while dragging).
    @Published var sectionLabels: [String] = []

    // Contents and bookmarks
    @Published var toc: [TOCItem] = []
    @Published var bookmarks: [BookRecord.Bookmark] = []
    @Published var isPageBookmarked = false

    // Jumps: "Back to p. 87" after a jump, until the reader moves on.
    @Published var backLabel: String?

    // Sidebar and search
    @Published var sidebarVisible = false
    @Published var sidebarTab: SidebarTab = .contents
    @Published var searchQuery = ""
    @Published var searchGroups: [SearchGroup] = []
    @Published var searchRunning = false
    @Published var searchProgress: Double = 0
    @Published var searchDoneQuery: String?
    @Published var currentHitID: Int?
    /// Bumped to ask the search field to take keyboard focus.
    @Published var searchFocusRequest = 0

    @Published var selection: Selection?

    /// True while a popover from the overlay (Aa) is open, so the overlay
    /// does not hide underneath it.
    @Published var overlayPopoverOpen = false

    /// How many pages are side by side on screen right now.
    @Published var columnsOnScreen = 1

    /// Two Pages is chosen but the window is too narrow, so one page shows.
    var twoPagesTooNarrow: Bool {
        flow == .paginated && !isFixedLayout && ReaderSettings.shared.pageLayout == .two && columnsOnScreen < 2
    }

    var allHits: [SearchHit] { searchGroups.flatMap(\.hits) }

    /// "Chapter 4 · 37%", optionally with pages left in the chapter.
    func locationLine(showPagesLeft: Bool) -> String {
        var parts: [String] = []
        if !chapter.isEmpty { parts.append(chapter) }
        parts.append(fraction.formatted(.percent.precision(.fractionLength(0))))
        if showPagesLeft, let left = pagesLeftInChapter, flow == .paginated {
            parts.append(left == 0
                ? String(localized: "last page in chapter")
                : String(localized: "\(left) pages left in chapter"))
        }
        return parts.joined(separator: " · ")
    }

    /// The chapter at a fraction of the book, for the slider while dragging.
    func chapter(atFraction f: Double) -> String? {
        guard !sectionLabels.isEmpty, !sectionFractions.isEmpty else { return nil }
        // sectionFractions has one more entry than sections (it ends at 1).
        var index = 0
        for (i, start) in sectionFractions.enumerated() where start <= f { index = i }
        index = min(index, sectionLabels.count - 1)
        let label = sectionLabels[index]
        return label.isEmpty ? nil : label
    }
}
