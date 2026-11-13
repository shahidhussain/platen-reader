import AppKit

// The Mac-only parts of the shared settings model (PlatenReader/Shared/
// ReaderSettings.swift): turning themes into AppKit colours and appearances,
// and reading the system's Light or Dark mode from an NSAppearance.

extension Theme {
    var nsBackground: NSColor { NSColor(hex: background) }

    /// The AppKit appearance that matches, so window chrome and the overlay
    /// look right over the page.
    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

extension ReaderSettings {
    /// The theme to use under a given system appearance.
    func theme(for systemAppearance: NSAppearance) -> Theme {
        theme(systemIsDark: systemAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
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
