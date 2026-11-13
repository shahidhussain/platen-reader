import UIKit

/// One window. Its home screen is the system document browser; books open
/// from there, from Files ("Open in Platen Reader") or from other apps'
/// share sheets, always in place (see `DocumentBrowserViewController`).
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var browser: DocumentBrowserViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let browser = DocumentBrowserViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window
        self.browser = browser

        // Launched by opening a book from another app.
        if let context = connectionOptions.urlContexts.first {
            open(context)
        }
        #if DEBUG
        // Testing: PLATEN_OPEN_PATH opens a book straight away (see
        // DebugHooks.swift).
        let env = ProcessInfo.processInfo.environment
        if let path = env["PLATEN_OPEN_PATH"] {
            let delay = Double(env["PLATEN_OPEN_DELAY"] ?? "") ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                browser.openBook(at: URL(fileURLWithPath: path), revealFirst: false)
            }
        }
        #endif
    }

    /// A book opened from another app while Platen is running.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let context = contexts.first { open(context) }
    }

    private func open(_ context: UIOpenURLContext) {
        // With LSSupportsOpeningDocumentsInPlace, "open in place" means the
        // URL is the original file (security-scoped), not a copy in our Inbox.
        browser?.openBook(at: context.url, revealFirst: context.options.openInPlace)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // The app may be ended at any time once in the background.
        browser?.reader?.savePositionNow()
    }
}
