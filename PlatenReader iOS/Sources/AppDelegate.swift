import UIKit

/// The iOS app's entry point. Almost everything happens per window, in
/// `SceneDelegate`; the app delegate only names the scene configuration.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Keeps the diagnostics file the reader can share from Settings
        // (DiagnosticLog), and logs to it any moment the app is too busy to
        // answer a tap (HangWatch).
        DiagnosticLog.shared.start()
        // Folders on this device are "On My iPad" on an iPad, as Files says.
        if UIDevice.current.userInterfaceIdiom == .pad {
            StoragePlace.thisDevice = String(localized: "On My iPad")
        }
        // Read aloud's natural voice: whether its download can be offered,
        // and where it is if it has been downloaded (KokoroDownload).
        KokoroDownload.prepare()
        // The download keeps going for a while if the reader leaves the app.
        KokoroDownload.keepRunning = {
            let task = UIApplication.shared.beginBackgroundTask(withName: "Natural voice download")
            return { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        }
        // Apple's voice list is slow to read: read it now, in the background.
        AppleSpeechEngine.prepareVoices()
        // The phone's taps when a favourite is marked (shared code has no UIKit).
        Favourites.installHaptics()
        // Favourites kept elsewhere are copied to the device (and copies
        // of books no longer favourites deleted), from now on.
        OfflineCopies.shared.start()
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { OfflineCopies.shared.sync() }
        }
        HangWatch.shared.start()
        // The default text size follows Dynamic Type (spec, "Layout"): about
        // 20 points at the standard size, like Apple Books, scaled with the
        // system's text size until the reader picks a size of their own.
        Self.updateDefaultTextSize()
        // A phone's narrow column reads better ragged right (Justify Text
        // starts off there; on an iPad it starts on, as on the Mac).
        ReaderSettings.justifyByDefault = UIDevice.current.userInterfaceIdiom != .phone
        // WebKit is warmed once the start-up animation is up (SceneDelegate).
        NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification,
                                               object: nil, queue: .main) { _ in
            Self.updateDefaultTextSize()
            ReaderSettings.shared.followDefaultFontSize()
        }
        return true
    }

    private static func updateDefaultTextSize() {
        ReaderSettings.preferredDefaultFontSize = Double(UIFontMetrics(forTextStyle: .body).scaledValue(for: 20))
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: session.role)
    }
}
