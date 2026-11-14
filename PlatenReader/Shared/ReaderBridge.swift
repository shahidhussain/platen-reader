import CoreGraphics
import Foundation
import PlatenCore

// The reader page (reader.js) and Swift talk in two directions:
//
//   JS → Swift: `post(type, body)` in bridge.js. Each message is decoded
//               here, once, into a `ReaderMessage`.
//   Swift → JS: `window.platen.<command>(…)`. `BookSession` has one Swift
//               method per command, so no script strings appear elsewhere.
//
// The settings sent with a book (`WebSettings`) are described here too, so
// everything that crosses the bridge is written down in one file.

/// A page turn: by the side of the screen (left/right, as clicked, tapped
/// or as the arrow keys say; they turn the right way in right-to-left
/// books) or in reading order (next/previous).
enum PageTurn: String {
    case left, right, next, prev

    /// The turn that undoes this one.
    var opposite: PageTurn {
        switch self {
        case .left: return .right
        case .right: return .left
        case .next: return .prev
        case .prev: return .next
        }
    }

    /// Which way the old page leaves the screen: towards the left is a
    /// forward turn in a left-to-right book.
    func leafMovesLeft(rightToLeft: Bool) -> Bool {
        switch self {
        case .right: return true
        case .left: return false
        case .next: return !rightToLeft
        case .prev: return rightToLeft
        }
    }

    /// For readers that only go forwards and backwards (PDFs, which are
    /// always left to right).
    var isForward: Bool { self == .next || self == .right }
}

/// Where on the page a click or tap landed. In paginated mode the sides
/// turn pages and the centre shows the controls.
enum ClickZone: String {
    case left, centre, right

    /// The fraction of the width on each side that turns pages. The side
    /// zones are wider than the centre, because most clicks are page turns.
    /// (input.js uses the same number for clicks inside the page.)
    static let sideFraction: CGFloat = 0.38

    /// The zone for a point `x` across a page `width` wide.
    init(x: CGFloat, width: CGFloat) {
        let side = width * Self.sideFraction
        self = x < side ? .left : x > width - side ? .right : .centre
    }
}

/// The settings object passed to reader.js (`platen.open` and
/// `platen.setSettings`). The last four are only set on iOS.
struct WebSettings: Equatable {
    var flow: ReadingFlow
    var pageLayout: PageLayout
    /// foliate-js's own slide animation, for Slide on the Mac (the curl is
    /// drawn natively, and swipes always slide; see reader.js).
    var animated: Bool
    var fontSize: Double
    var lineHeight: Double
    var lineWidth: LineWidth
    var fontFamily: String
    var hyphenate: Bool
    var theme: Theme
    /// Taps are recognised natively, so the page reports no click zones.
    var touch = false
    /// Swipes are drawn natively, so foliate's own touch dragging is off.
    var nativeSwipe = false
    /// Room at each side of the text, in points (nil: the shell's default).
    var sideMargin: Double?
    /// Room above and below the text, in points (nil: the shell's default).
    var verticalMargin: Double?

    /// As the plain values WebKit can pass to JavaScript.
    var payload: [String: Any] {
        var payload: [String: Any] = [
            "flow": flow.rawValue,
            "pageLayout": pageLayout.rawValue,
            "animated": animated,
            "fontSize": fontSize,
            "lineHeight": lineHeight,
            "lineWidth": lineWidth.rawValue,
            "fontFamily": fontFamily,
            "hyphenate": hyphenate,
            "theme": [
                "background": theme.background,
                "foreground": theme.foreground,
                "link": theme.link,
                "dark": theme.isDark,
            ] as [String: Any],
        ]
        if touch { payload["touch"] = true }
        if nativeSwipe { payload["nativeSwipe"] = true }
        if let sideMargin { payload["sideMargin"] = sideMargin }
        if let verticalMargin { payload["verticalMargin"] = verticalMargin }
        return payload
    }
}

/// One message from reader.js, decoded. The cases mirror the `post(…)`
/// calls in PlatenReader/Web.
enum ReaderMessage: Equatable {
    /// The shell has loaded and `window.platen` exists.
    case ready
    /// The first page is on screen.
    case firstRender
    /// The book is open: what the page learnt about it.
    case opened(Opened)
    /// The table of contents, built after the first page is shown.
    case contents(Contents)
    /// The reader moved: a page turn, a jump, or a re-layout.
    case relocate(Relocation)
    /// The Back button's label after a jump ("p. 87"), or nil to hide it.
    case back(label: String?)
    /// A footnote pop-up opened or closed.
    case note(open: Bool)
    /// Whether a page on screen is bookmarked.
    case pageBookmarked(Bool)
    /// The reader asked for a bookmark (corner click, ⌘D).
    case addBookmark(BookmarkDraft)
    case removeBookmark(cfi: String)
    /// What is selected, or nil when nothing is.
    case selection(ReaderState.Selection?)
    case searchResults(SearchResults)
    case searchProgress(query: String, progress: Double)
    case searchDone(query: String)
    /// A plain click on the page (not sent on iOS, where taps are native).
    case click(ClickZone)
    /// A click on a picture: show it full size.
    case image(Picture)
    /// A link to the web, to open in the browser.
    case externalLink(URL)
    /// The book could not be opened in the page.
    case failed(message: String, stack: String)
    /// The text on screen, for VoiceOver (see accessibility.js).
    case pageText(text: String, speak: Bool)
    /// A line for the log (script errors are forwarded this way).
    case log(String)

    struct Opened: Equatable {
        var title = ""
        var author = ""
        var isFixedLayout = false
        var isRightToLeft = false
        /// Where each section starts, as a fraction of the book.
        var sectionFractions: [Double] = []
    }

    struct Contents: Equatable {
        var toc: [ReaderState.TOCItem] = []
        /// The chapter title for each section.
        var sectionLabels: [String] = []
        /// True when the book had no contents and one was built from headings.
        var synthesised = false
    }

    struct Relocation: Equatable {
        /// Where the reader is, to save. Nil before a chapter has loaded.
        var cfi: String?
        var fraction: Double?
        var chapter = ""
        var chapterHref: String?
        var pagesLeft: Int?
        /// Pages side by side on screen.
        var columns = 1
    }

    struct BookmarkDraft: Equatable {
        var cfi: String
        var snippet = ""
        var chapter: String?
        var page: String?
        var fraction: Double?
    }

    struct SearchResults: Equatable {
        struct Hit: Equatable {
            var cfi: String
            var pre: String
            var match: String
            var post: String
        }
        var query: String
        /// The chapter these results are in.
        var label: String
        var hits: [Hit]
    }

    struct Picture: Equatable {
        var data: Data
        var mimeType: String
        var alt: String
        /// Where the picture sits in the web view (origin at the top left).
        var rect: CGRect
    }

    /// Decodes what `WKScriptMessage.body` holds: `{ type, body }`.
    /// Returns nil for anything that is not a known, well-formed message.
    init?(_ raw: Any) {
        guard let envelope = raw as? [String: Any], let type = envelope["type"] as? String else { return nil }
        let body = envelope["body"] as? [String: Any] ?? [:]
        func string(_ key: String) -> String? { body[key] as? String }
        func double(_ key: String) -> Double? {
            guard let value = (body[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return value
        }
        func int(_ key: String) -> Int? { (body[key] as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool { body[key] as? Bool ?? false }
        /// Empty strings from the page mean "none".
        func nonEmpty(_ key: String) -> String? { string(key).flatMap { $0.isEmpty ? nil : $0 } }

        switch type {
        case "ready":
            self = .ready
        case "firstRender":
            self = .firstRender
        case "opened":
            self = .opened(Opened(
                title: string("title") ?? "",
                author: string("author") ?? "",
                isFixedLayout: bool("fixedLayout"),
                isRightToLeft: string("dir") == "rtl",
                sectionFractions: (body["sectionFractions"] as? [NSNumber])?.map(\.doubleValue) ?? []))
        case "contents":
            let items = body["toc"] as? [[String: Any]] ?? []
            self = .contents(Contents(
                toc: items.enumerated().map { index, item in
                    ReaderState.TOCItem(id: index, label: item["label"] as? String ?? "",
                                        href: item["href"] as? String ?? "",
                                        depth: (item["depth"] as? NSNumber)?.intValue ?? 0)
                },
                sectionLabels: body["sectionLabels"] as? [String] ?? [],
                synthesised: bool("synthesised")))
        case "relocate":
            self = .relocate(Relocation(
                cfi: nonEmpty("cfi"), fraction: double("fraction"), chapter: string("chapter") ?? "",
                chapterHref: string("chapterHref"), pagesLeft: int("pagesLeft"), columns: int("columns") ?? 1))
        case "back":
            self = .back(label: string("label"))
        case "note":
            self = .note(open: bool("open"))
        case "pageBookmarked":
            self = .pageBookmarked(bool("bookmarked"))
        case "addBookmark":
            guard let cfi = nonEmpty("cfi") else { return nil }
            self = .addBookmark(BookmarkDraft(cfi: cfi, snippet: string("snippet") ?? "", chapter: nonEmpty("chapter"),
                                              page: string("page"), fraction: double("fraction")))
        case "removeBookmark":
            guard let cfi = nonEmpty("cfi") else { return nil }
            self = .removeBookmark(cfi: cfi)
        case "selection":
            let text = string("text") ?? ""
            self = .selection(text.isEmpty ? nil
                : ReaderState.Selection(text: text, chapter: string("chapter") ?? "", page: string("page")))
        case "searchResults":
            let items = body["items"] as? [[String: Any]] ?? []
            self = .searchResults(SearchResults(
                query: string("query") ?? "", label: string("label") ?? "",
                hits: items.map { item in
                    .init(cfi: item["cfi"] as? String ?? "", pre: item["pre"] as? String ?? "",
                          match: item["match"] as? String ?? "", post: item["post"] as? String ?? "")
                }))
        case "searchProgress":
            self = .searchProgress(query: string("query") ?? "", progress: double("progress") ?? 0)
        case "searchDone":
            self = .searchDone(query: string("query") ?? "")
        case "click":
            self = .click(string("zone").flatMap(ClickZone.init) ?? .centre)
        case "image":
            guard let base64 = string("data"), let data = Data(base64Encoded: base64) else { return nil }
            let rect = body["rect"] as? [String: Any] ?? [:]
            func number(_ key: String) -> CGFloat { CGFloat((rect[key] as? NSNumber)?.doubleValue ?? 0) }
            self = .image(Picture(data: data, mimeType: string("mimeType") ?? "", alt: string("alt") ?? "",
                                  rect: CGRect(x: number("x"), y: number("y"),
                                               width: number("width"), height: number("height"))))
        case "externalLink":
            // Only links a browser or Mail can open; anything else is dropped.
            guard let href = string("href"), let url = URL(string: href),
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            self = .externalLink(url)
        case "error":
            self = .failed(message: string("message") ?? "", stack: string("stack") ?? "")
        case "pageText":
            self = .pageText(text: string("text") ?? "", speak: bool("speak"))
        case "log":
            self = .log(string("message") ?? "")
        default:
            return nil
        }
    }
}

extension BookRecord {
    /// Adds the bookmark the page asked for (its first word, its text and
    /// where it is), keeping the list in reading order. Returns false if
    /// that place is already bookmarked.
    mutating func addBookmark(_ draft: ReaderMessage.BookmarkDraft) -> Bool {
        guard !bookmarks.contains(where: { $0.cfi == draft.cfi }) else { return false }
        bookmarks.append(Bookmark(cfi: draft.cfi, snippet: draft.snippet, chapter: draft.chapter,
                                  page: draft.page, fraction: draft.fraction))
        bookmarks.sort { ($0.fraction ?? 0) < ($1.fraction ?? 0) }
        return true
    }
}
