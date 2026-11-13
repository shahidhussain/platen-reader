import SwiftUI

/// The click-zone explainer: three translucent zones over the real page,
/// labelled "Previous Page", "Show Controls" and "Next Page" (one zone in
/// scroll mode). The side zones are wider, since most clicks turn pages.
/// Shown the first time any book opens, briefly when switching modes (first
/// three switches only), and from Help > Show Reading Controls.
struct ReadingControlsExplainer: View {
    /// How many book opens show the zones (spec feedback: the first five).
    static let opensToShow = 5
    static let shownCountKey = "readingControlsShownCount"
    static let switchCountKey = "readingModeSwitchExplainerCount"

    static func resetTips() {
        AppDefaults.store.removeObject(forKey: shownCountKey)
        AppDefaults.store.removeObject(forKey: "hasSeenReadingControls") // older key
        AppDefaults.store.removeObject(forKey: switchCountKey)
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
