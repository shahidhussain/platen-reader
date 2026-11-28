import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Updates for the direct-download Mac app, by Sparkle (spec, "Decisions
/// made": Updates; docs/updates.md). The App Store builds, iOS and the later
/// Mac App Store one, update through the store and contain no Sparkle code.
///
/// - Sparkle looks at the appcast (`SUFeedURL` in Info.plist: a small file on
///   the project's website listing the latest version) about once a day, if
///   "Check for updates automatically" is on (Settings › Advanced; on by
///   default), and whenever the reader chooses Platen Reader › Check for
///   Updates…. It sends nothing about the Mac (`SUEnableSystemProfiling` is
///   off): the request is the agreed network exception (CLAUDE.md).
/// - An update is a new notarised disk image, signed with the project's
///   EdDSA key (`SUPublicEDKey`), which Sparkle checks before installing.
///
/// It runs only in Release builds: a Debug build's build number (1) is lower
/// than every release, so it would always be offered one. Nor in automated
/// runs (`PLATEN_TEST_HOME`), which must make no network requests. Until the
/// Sparkle package is added to the project (docs/updates.md, "Setting up"),
/// none of this is compiled in and the menu item and setting do not show.
@MainActor
final class Updates: NSObject {
    static let shared = Updates()

    #if canImport(Sparkle)
    /// Sparkle's standard updater: its own windows for "an update is
    /// available", the download and the restart. Started in `start()`.
    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                          userDriverDelegate: nil)
    #endif

    /// Whether this build checks for updates at all.
    nonisolated var isAvailable: Bool {
        #if canImport(Sparkle) && !DEBUG
        return ProcessInfo.processInfo.environment["PLATEN_TEST_HOME"] == nil && Self.hasPublicKey
        #else
        return false
        #endif
    }

    /// The signing key is in Info.plist (not the placeholder): without it
    /// Sparkle refuses every update, so it is not started.
    private nonisolated static var hasPublicKey: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.isEmpty && !key.hasPrefix("REPLACE")
    }

    /// At launch (AppDelegate).
    func start() {
        #if canImport(Sparkle)
        guard isAvailable else { return }
        do {
            try controller.updater.start()
        } catch {
            log.error("updates: Sparkle did not start: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Platen Reader › Check for Updates….
    @objc func checkForUpdates(_ sender: Any?) {
        #if canImport(Sparkle)
        controller.checkForUpdates(sender)
        #endif
    }

    /// Settings › Advanced › Check for updates automatically.
    var checksAutomatically: Bool {
        get {
            #if canImport(Sparkle)
            return controller.updater.automaticallyChecksForUpdates
            #else
            return false
            #endif
        }
        set {
            #if canImport(Sparkle)
            controller.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }
}
