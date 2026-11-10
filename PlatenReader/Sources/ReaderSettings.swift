import AppKit
import Combine

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

/// How many pages to show side by side.
enum PageLayout: String, CaseIterable, Identifiable {
    case automatic, one, two
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .one: return String(localized: "One Page")
        case .two: return String(localized: "Two Pages")
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
    case light, sepia, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return String(localized: "Light")
        case .sepia: return String(localized: "Sepia")
        case .dark: return String(localized: "Dark")
        }
    }

    var background: String {
        switch self {
        case .light: return "#ffffff"
        case .sepia: return "#f5ecd7"
        case .dark: return "#1e1e20" // near-black, not pure black
        }
    }

    var foreground: String {
        switch self {
        case .light: return "#1c1c1e"
        case .sepia: return "#5b4636"
        case .dark: return "#d4d4d4"
        }
    }

    var link: String {
        switch self {
        case .light: return "#0b57d0"
        case .sepia: return "#8a4b1f"
        case .dark: return "#8ab4f8"
        }
    }

    var isDark: Bool { self == .dark }

    var nsBackground: NSColor { NSColor(hex: background) }

    /// The AppKit appearance that matches, so window chrome and the overlay
    /// look right over the page.
    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

/// The one Appearance setting: follow the system (Light by day, Dark by
/// night), or always use one theme.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case automatic, light, sepia, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .light: return String(localized: "Light")
        case .sepia: return String(localized: "Sepia")
        case .dark: return String(localized: "Dark")
        }
    }
}

/// Global reader settings (the spec allows no per-book settings beyond
/// position and bookmarks). Stored in UserDefaults; every open window observes
/// this object and re-styles itself when anything changes.
final class ReaderSettings: ObservableObject {
    static let shared = ReaderSettings()

    /// About 12 steps, per the spec. The default (18) suits a Retina laptop.
    static let fontSizes: [Double] = [12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 27, 30]
    static let defaultFontSizeIndex = 6
    /// 0 means "publisher default".
    static let lineHeights: [Double] = [0, 1.2, 1.35, 1.5, 1.65, 1.8, 2.0]
    /// "" means "publisher default". The curated list; any installed font can
    /// also be typed in Settings later.
    static let curatedFonts = ["", "Iowan Old Style", "Georgia", "Palatino", "Charter", "New York",
                               "Baskerville", "Avenir Next", "Helvetica Neue"]

    private let defaults = UserDefaults.standard

    @Published var defaultFlow: ReadingFlow { didSet { save("defaultFlow", defaultFlow.rawValue) } }
    @Published var pageLayout: PageLayout { didSet { save("pageLayout", pageLayout.rawValue) } }
    @Published var animatePageTurns: Bool { didSet { save("animatePageTurns", animatePageTurns) } }
    @Published var appearance: AppearanceChoice { didSet { save("appearance", appearance.rawValue) } }
    @Published var fontSizeIndex: Int { didSet { save("fontSizeIndex", fontSizeIndex) } }
    @Published var lineHeight: Double { didSet { save("lineHeight", lineHeight) } }
    @Published var lineWidth: LineWidth { didSet { save("lineWidth", lineWidth.rawValue) } }
    @Published var fontFamily: String { didSet { save("fontFamily", fontFamily) } }
    @Published var hyphenate: Bool { didSet { save("hyphenate", hyphenate) } }
    /// Optional "N pages left in chapter" in the location line (paginated).
    @Published var showPagesLeftInChapter: Bool { didSet { save("showPagesLeftInChapter", showPagesLeftInChapter) } }

    private init() {
        func string(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
        }
        defaultFlow = string("defaultFlow").flatMap(ReadingFlow.init) ?? .paginated
        pageLayout = string("pageLayout").flatMap(PageLayout.init) ?? .automatic
        animatePageTurns = bool("animatePageTurns", true)
        appearance = string("appearance").flatMap(AppearanceChoice.init) ?? .automatic
        let index = UserDefaults.standard.object(forKey: "fontSizeIndex") as? Int ?? Self.defaultFontSizeIndex
        fontSizeIndex = min(max(index, 0), Self.fontSizes.count - 1)
        lineHeight = UserDefaults.standard.double(forKey: "lineHeight")
        lineWidth = string("lineWidth").flatMap(LineWidth.init) ?? .medium
        fontFamily = string("fontFamily") ?? ""
        hyphenate = bool("hyphenate", true)
        showPagesLeftInChapter = bool("showPagesLeftInChapter", false)
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    var fontSize: Double { Self.fontSizes[fontSizeIndex] }

    /// The theme to use under a given system appearance.
    func theme(for systemAppearance: NSAppearance) -> Theme {
        switch appearance {
        case .automatic:
            return systemAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        case .light: return .light
        case .sepia: return .sepia
        case .dark: return .dark
        }
    }

    func biggerText() { fontSizeIndex = min(fontSizeIndex + 1, Self.fontSizes.count - 1) }
    func smallerText() { fontSizeIndex = max(fontSizeIndex - 1, 0) }
    func defaultTextSize() { fontSizeIndex = Self.defaultFontSizeIndex }

    /// The settings object passed to reader.js (`platen.setSettings`).
    func webPayload(theme: Theme, flow: ReadingFlow) -> [String: Any] {
        [
            "flow": flow.rawValue,
            "pageLayout": pageLayout.rawValue,
            "animated": animatePageTurns,
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

extension NSColor {
    /// "#rrggbb" → NSColor (sRGB).
    convenience init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
