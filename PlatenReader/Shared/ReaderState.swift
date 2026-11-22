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
    /// While the book opens, how far it has got (the loading bar); nil once
    /// the first page is on screen, or the book could not be opened.
    @Published var opening: OpeningStage? = .reading
    /// What to call the book while it opens, before its own title is read:
    /// its title from Recent Books if it has been opened before, else its
    /// file name (set by the reader as it starts).
    @Published var openingTitle = ""
    @Published var title = ""
    @Published var author = ""
    /// The book's own language (`dc:language`), if it gives one; read
    /// aloud chooses its voice from it.
    @Published var language: String?
    /// Read aloud: what it is doing (the speaker button follows it).
    @Published var readAloud: ReadAloudPhase = .off
    @Published var isFixedLayout = false
    /// A PDF (shown by PDFKit) rather than a book: the text controls (font,
    /// size, spacing, line width) do not apply.
    @Published var isPDF = false
    /// PDFs: "p. 12 of 300", shown in the location line instead of a
    /// percentage (a PDF's pages are fixed, so its page numbers are stable).
    @Published var locationDetail: String?
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
    /// The page's background colour ("#rrggbb", from the theme), for the
    /// band behind the controls (`PageBand`), so no text shows behind them.
    @Published var pageColour = "#ffffff"
    /// With ambient light (iOS): the colours of the bands behind the top and
    /// bottom controls, taken from the glow at those edges (`GlowBand`), so
    /// the bands blend into it; nil without a glow, when they are the
    /// page's colour.
    @Published var topBandColour: String?
    @Published var bottomBandColour: String?
    /// Whether the controls need a band behind them at all (iOS): false when
    /// what is behind them already lets them read clearly
    /// (`GlowBand.needsBand`), so no band, edge or fade is drawn.
    @Published var topBandNeeded = true
    @Published var bottomBandNeeded = true

    // Jumps: "Back to p. 87" after a jump, until the reader moves on.
    @Published var backLabel: String?

    // Sidebar and search
    @Published var sidebarVisible = false
    @Published var sidebarTab: SidebarTab = .contents
    @Published var searchQuery = ""
    /// The search whose results are being shown (results of older searches
    /// are dropped). Not published: nothing displays it.
    var activeSearchQuery = ""
    @Published var searchGroups: [SearchGroup] = []
    @Published var searchRunning = false
    @Published var searchProgress: Double = 0
    @Published var searchDoneQuery: String?
    @Published var currentHitID: Int?
    /// Bumped to ask the search field to take keyboard focus.
    @Published var searchFocusRequest = 0

    @Published var selection: Selection?

    /// A footnote pop-up is open in the page (Esc closes it first).
    @Published var noteOpen = false

    /// True while a popover from the overlay (Aa) is open, so the overlay
    /// does not hide underneath it.
    @Published var overlayPopoverOpen = false

    /// A PDF in Two Pages, held in landscape, whose pages are already
    /// spreads (each clearly wider than tall), so they show one at a time.
    @Published var pagesAreSpreads = false

    /// How many pages are side by side on screen right now.
    @Published var columnsOnScreen = 1

    /// False on iPhone, where books always show one page (spec, "Layout");
    /// Two Pages is then not offered at all.
    var allowsTwoPages = true

    /// The layouts the reader can choose here.
    var availableLayouts: [ReadingLayout] {
        ReadingLayout.allCases.filter { $0 != .twoPages || allowsTwoPages }
    }

    /// The layout in use, as the Layout picker shows it.
    var currentLayout: ReadingLayout {
        ReadingLayout(flow: flow, pages: allowsTwoPages ? ReaderSettings.shared.pageLayout : .one)
    }

    /// Two Pages is chosen but the window is too narrow, so one page shows.
    var twoPagesTooNarrow: Bool {
        allowsTwoPages && flow == .paginated && !isFixedLayout
            && ReaderSettings.shared.pageLayout == .two && columnsOnScreen < 2
    }

    var allHits: [SearchHit] { searchGroups.flatMap(\.hits) }

    /// "Chapter 4 · 37%", optionally with pages left in the chapter.
    func locationLine(showPagesLeft: Bool) -> String {
        var parts: [String] = []
        if !chapter.isEmpty { parts.append(chapter) }
        parts.append(locationDetail ?? fraction.formatted(.percent.precision(.fractionLength(0))))
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
