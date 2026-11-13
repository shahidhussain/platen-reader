import UIKit

// The iOS-only parts of the shared settings model (PlatenReader/Shared/
// ReaderSettings.swift): themes as UIKit colours, and the system's Light or
// Dark mode read from a trait collection.

extension Theme {
    var uiBackground: UIColor { UIColor(hex: background) }

    /// Light or dark, so the status bar and system controls stay legible
    /// over the page.
    var interfaceStyle: UIUserInterfaceStyle { isDark ? .dark : .light }
}

extension ReaderSettings {
    /// The theme to use under the given traits (Automatic follows them).
    func theme(for traits: UITraitCollection) -> Theme {
        theme(systemIsDark: traits.userInterfaceStyle == .dark)
    }
}

extension UIColor {
    /// "#rrggbb" → UIColor (sRGB).
    convenience init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
