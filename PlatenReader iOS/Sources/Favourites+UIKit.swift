import UIKit

extension Favourites {
    /// The iPhone's taps for favourites (called once at launch, AppDelegate):
    /// shared code cannot use UIKit, so it is handed these.
    static func installHaptics() {
        heartbeatHaptics = {
            // Taps in time with the heart's two beats: a firm tap and a
            // softer one, twice.
            let firm = UIImpactFeedbackGenerator(style: .medium)
            let soft = UIImpactFeedbackGenerator(style: .light)
            firm.prepare(); soft.prepare()
            // The menu takes a moment to close before the heart shows.
            let start = 0.3
            for (delay, generator, strength) in [(0.0, firm, 1.0), (0.24, soft, 0.8), (0.65, firm, 0.85), (0.89, soft, 0.6)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + start + delay) { generator.impactOccurred(intensity: strength) }
            }
        }
        removedHaptic = { UISelectionFeedbackGenerator().selectionChanged() }
    }
}
