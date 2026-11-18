import UIKit

/// The iOS app's entry point. Almost everything happens per window, in
/// `SceneDelegate`; the app delegate only names the scene configuration.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // The default text size follows Dynamic Type (spec, "Layout"): about
        // 20 points at the standard size, like Apple Books, scaled with the
        // system's text size until the reader picks a size of their own.
        Self.updateDefaultTextSize()
        // Start WebKit's content process now, so the first book opened does
        // not pay for it (spec: "Warm the WebKit content process at launch").
        // Just after the first frame, not before: it holds the main thread
        // for a few tenths of a second, which kept the launch screen up that
        // much longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { WebViewWarmer.warm() }
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
