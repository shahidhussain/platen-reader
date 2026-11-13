import Combine
import Foundation

// Shared by the Mac and iOS apps. Platform colour and appearance helpers live
// in ReaderSettings+AppKit.swift (Mac) and ReaderSettings+UIKit.swift (iOS).

/// Paginated (pages turn left and right) or continuous vertical scroll.
enum ReadingFlow: String, CaseIterable, Identifiable {
    case paginated, scrolled
    var id: String { rawValue }
    var label: String {
        switch self {
        case .paginated: return String(localized: "Paginated")
        case .scrolled: return String(localized: "Scroll")
        }
    }
}

/// How many pages to show side by side in paginated mode.
enum PageLayout: String {
    case one, two
}

/// The one Layout choice the reader sees: one page, two pages (side by side
/// when the window is wide enough) or continuous scroll. It is stored as two
/// parts: paginated or scroll (remembered per book) and one or two pages
/// (a global setting). The order matches the shortcuts ⌘1, ⌘2 and ⌘3.
enum ReadingLayout: String, CaseIterable, Identifiable {
    case onePage, twoPages, scroll
    var id: String { rawValue }

    init(flow: ReadingFlow, pages: PageLayout) {
        self = flow == .scrolled ? .scroll : pages == .one ? .onePage : .twoPages
    }

    var flow: ReadingFlow { self == .scroll ? .scrolled : .paginated }
    var pages: PageLayout? {
        switch self {
        case .onePage: return .one
        case .twoPages: return .two
        case .scroll: return nil
        }
    }

    var label: String {
        switch self {
        case .onePage: return String(localized: "One Page")
        case .twoPages: return String(localized: "Two Pages")
        case .scroll: return String(localized: "Scroll")
        }
    }

    var shortcut: String {
        switch self {
        case .onePage: return "1"
        case .twoPages: return "2"
        case .scroll: return "3"
        }
    }
}

enum LineWidth: String, CaseIterable, Identifiable {
    case narrow, medium, wide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .narrow: return String(localized: "Narrow")
        case .medium: return String(localized: "Medium")
        case .wide: return String(localized: "Wide")
        }
    }
}

/// The three reading themes (see spec, "Themes").
enum Theme: String, CaseIterable, Identifiable {
    /// Black is Dark with a true black background, for OLED screens.
    case light, sepia, dark, black
    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return String(localized: "Light")
        case .sepia: return String(localized: "Sepia")
        case .dark: return String(localized: "Dark")
        case .black: return String(localized: "Black")
        }
    }

    var background: String {
        switch self {
        case .light: return "#ffffff"
        case .sepia: return "#f5ecd7"
        case .dark: return "#1e1e20" // near-black, not pure black
        case .black: return "#000000"
        }
    }

    var foreground: String {
        switch self {
        case .light: return "#1c1c1e"
        case .sepia: return "#5b4636"
        case .dark: return "#d4d4d4"
        case .black: return "#c8c8c8" // a little dimmer: white on black glares
        }
    }

    var link: String {
        switch self {
        case .light: return "#0b57d0"
        case .sepia: return "#8a4b1f"
        case .dark, .black: return "#8ab4f8"
        }
    }

    var isDark: Bool { self == .dark || self == .black }
}

/// How a page turn (click, key or wheel) is animated. Trackpad swipes always
/// slide: the page follows the fingers.
enum PageTurnStyle: String, CaseIterable, Identifiable {
    case curl, slide, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .curl: return String(localized: "Page Curl")
        case .slide: return String(localized: "Slide")
        case .none: return String(localized: "None")
        }
    }
}

/// The one Appearance setting: follow the system (Light by day, Dark by
/// night), or always use one theme.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case automatic, light, sepia, dark, black
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .light: return String(localized: "Light")
        case .sepia: return String(localized: "Sepia")
        case .dark: return String(localized: "Dark")
        case .black: return String(localized: "Black")
        }
    }
}

/// Global reader settings (the spec allows no per-book settings beyond
/// position and bookmarks). Stored in UserDefaults; every open window observes
/// this object and re-styles itself when anything changes.
final class ReaderSettings: ObservableObject {
    static let shared = ReaderSettings()

    /// About 12 steps, per the spec.
    static let fontSizes: [Double] = [12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 27, 30]

    /// The size text starts at until the reader picks one. 18 suits a Retina
    /// laptop (the Mac has no system text-size setting to follow); the iOS
    /// app sets it from Dynamic Type at launch, before `shared` is first used.
    static var preferredDefaultFontSize: Double = 18

    /// The step nearest the preferred default size.
    static var defaultFontSizeIndex: Int {
        fontSizes.indices.min { abs(fontSizes[$0] - preferredDefaultFontSize) < abs(fontSizes[$1] - preferredDefaultFontSize) } ?? 6
    }
    /// 0 means "publisher default".
    static let lineHeights: [Double] = [0, 1.2, 1.35, 1.5, 1.65, 1.8, 2.0]
    /// "" means "publisher default". The curated list; any installed font can
    /// also be typed in Settings later.
    static let curatedFonts = ["", "Iowan Old Style", "Georgia", "Palatino", "Charter", "New York",
                               "Baskerville", "Avenir Next", "Helvetica Neue"]

    private let defaults = AppDefaults.store

    @Published var defaultFlow: ReadingFlow { didSet { save("defaultFlow", defaultFlow.rawValue) } }
    @Published var pageLayout: PageLayout { didSet { save("pageLayout", pageLayout.rawValue) } }
    @Published var pageTurnStyle: PageTurnStyle { didSet { save("pageTurnStyle", pageTurnStyle.rawValue) } }
    @Published var appearance: AppearanceChoice { didSet { save("appearance", appearance.rawValue) } }
    @Published var fontSizeIndex: Int { didSet { save("fontSizeIndex", fontSizeIndex) } }
    @Published var lineHeight: Double { didSet { save("lineHeight", lineHeight) } }
    @Published var lineWidth: LineWidth { didSet { save("lineWidth", lineWidth.rawValue) } }
    @Published var fontFamily: String { didSet { save("fontFamily", fontFamily) } }
    @Published var hyphenate: Bool { didSet { save("hyphenate", hyphenate) } }
    /// Optional "N pages left in chapter" in the location line (paginated).
    @Published var showPagesLeftInChapter: Bool { didSet { save("showPagesLeftInChapter", showPagesLeftInChapter) } }
    /// Not saved: whether the front book window shows one page although Two
    /// Pages is chosen (it is too narrow). Settings explains this.
    @Published var frontWindowTooNarrowForTwoPages = false

    private init() {
        func string(_ key: String) -> String? { AppDefaults.store.string(forKey: key) }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            AppDefaults.store.object(forKey: key) == nil ? fallback : AppDefaults.store.bool(forKey: key)
        }
        defaultFlow = string("defaultFlow").flatMap(ReadingFlow.init) ?? .paginated
        pageLayout = string("pageLayout").flatMap(PageLayout.init) ?? .two
        // Older versions had an on/off switch; off becomes None.
        pageTurnStyle = string("pageTurnStyle").flatMap(PageTurnStyle.init)
            ?? (bool("animatePageTurns", true) ? .curl : .none)
        appearance = string("appearance").flatMap(AppearanceChoice.init) ?? .automatic
        let index = AppDefaults.store.object(forKey: "fontSizeIndex") as? Int ?? Self.defaultFontSizeIndex
        fontSizeIndex = min(max(index, 0), Self.fontSizes.count - 1)
        lineHeight = AppDefaults.store.double(forKey: "lineHeight")
        lineWidth = string("lineWidth").flatMap(LineWidth.init) ?? .medium
        fontFamily = string("fontFamily") ?? ""
        hyphenate = bool("hyphenate", true)
        showPagesLeftInChapter = bool("showPagesLeftInChapter", false)
    }

    /// Set while the text size follows the default (see
    /// `followDefaultFontSize`), so that is not saved as the reader's choice.
    private var followingDefault = false

    private func save(_ key: String, _ value: Any) {
        guard !followingDefault else { return }
        defaults.set(value, forKey: key)
    }

    /// Whether the reader has chosen a text size. Until they do, it follows
    /// the default (on iOS, the system's Dynamic Type size).
    var hasChosenFontSize: Bool { defaults.object(forKey: "fontSizeIndex") != nil }

    /// Moves the text size to the current default, if the reader has not
    /// chosen one (iOS calls this when the Dynamic Type size changes).
    func followDefaultFontSize() {
        guard !hasChosenFontSize, fontSizeIndex != Self.defaultFontSizeIndex else { return }
        followingDefault = true
        fontSizeIndex = Self.defaultFontSizeIndex
        followingDefault = false
    }

    var fontSize: Double { Self.fontSizes[fontSizeIndex] }

    /// The layout new books open in (Settings > General).
    var defaultLayout: ReadingLayout {
        get { ReadingLayout(flow: defaultFlow, pages: pageLayout) }
        set {
            defaultFlow = newValue.flow
            if let pages = newValue.pages { pageLayout = pages }
        }
    }

    /// The theme to use when the system is in Light (false) or Dark (true)
    /// mode. Each platform asks its own way (see the +AppKit and +UIKit files).
    func theme(systemIsDark: Bool) -> Theme {
        switch appearance {
        case .automatic:
            return systemIsDark ? .dark : .light
        case .light: return .light
        case .sepia: return .sepia
        case .dark: return .dark
        case .black: return .black
        }
    }

    func biggerText() { fontSizeIndex = min(fontSizeIndex + 1, Self.fontSizes.count - 1) }
    func smallerText() { fontSizeIndex = max(fontSizeIndex - 1, 0) }
    /// ⌘0: back to the default size, which then follows the system again.
    func defaultTextSize() {
        fontSizeIndex = Self.defaultFontSizeIndex
        defaults.removeObject(forKey: "fontSizeIndex")
    }

    /// The settings object passed to reader.js (`platen.setSettings`).
    func webPayload(theme: Theme, flow: ReadingFlow) -> [String: Any] {
        [
            "flow": flow.rawValue,
            "pageLayout": pageLayout.rawValue,
            // foliate-js's own slide animation, for Slide (the curl is drawn
            // natively, and swipes always slide; see reader.js).
            "animated": pageTurnStyle == .slide,
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
    }
}
