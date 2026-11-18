import Foundation

/// The version line on the start-up screens ("Version 0.8.1 · 3f2a9c1"),
/// so it is clear which build a device is running while the app is being
/// tested. The last part is the git commit the build was made from, written
/// into the built app's Info.plist by the iOS target's "Record Git Commit"
/// build phase (a trailing + means there were uncommitted changes); builds
/// without it show only the version.
enum AppVersion {
    static var line: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        // Not the build number: it stays 1 here (only release builds number
        // their builds), so it said nothing.
        var number = version
        if let commit = info["PlatenCommit"] as? String, !commit.isEmpty { number += " · \(commit)" }
        return String(localized: "Version \(number)",
                      comment: "The app's version on the start-up screens, such as “Version 0.8.1 · 3f2a9c1”.")
    }
}
