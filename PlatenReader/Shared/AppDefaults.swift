import Foundation

/// Where Platen keeps its preferences (settings, first-run counters).
///
/// Normally that is the app's own preferences. In Debug builds, setting the
/// environment variable `PLATEN_TEST_HOME` (as the UI tests do) sends them to
/// a separate, throwaway set instead, cleared at every launch. So automated
/// tests always start from the same state and never change the settings of
/// the person running them. Reading positions and bookmarks follow the same
/// variable (see `PositionStore.defaultDirectory`).
enum AppDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PLATEN_TEST_HOME"] != nil,
           let suite = UserDefaults(suiteName: testSuiteName) {
            suite.removePersistentDomain(forName: testSuiteName)
            // Start as someone who has already seen the first-run tips (they
            // cover the page and take the first click), with instant page
            // turns so tests need not wait for animations.
            suite.register(defaults: [
                "readingControlsShownCount": 99,
                "readingModeSwitchExplainerCount": 99,
                "pageTurnStyle": "none",
            ])
            return suite
        }
        #endif
        return .standard
    }()

    #if DEBUG
    static let testSuiteName = "org.platenreader.tests"
    #endif
}
