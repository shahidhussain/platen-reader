import SwiftUI
import UIKit

/// One window. Its home screen is the system document browser; books open
/// from there, from Files ("Open in Platen Reader") or from other apps'
/// share sheets, always in place (see `DocumentBrowserViewController`).
///
/// The first time Platen is opened, a welcome screen comes first (the same
/// as the Mac's, full screen): the app's name and one "Open Book…" button,
/// so the reader knows where they are before the browser appears.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var browser: DocumentBrowserViewController?
    /// The welcome screen while it is up, laid over the browser.
    private var welcome: UIViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let browser = DocumentBrowserViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = browser
        self.window = window
        self.browser = browser

        // Launched by opening a book from another app: straight to it.
        let launchedWithBook = !connectionOptions.urlContexts.isEmpty
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        let debugBook = env["PLATEN_OPEN_PATH"] != nil
        #else
        let debugBook = false
        #endif
        window.makeKeyAndVisible()
        if !Self.hasWelcomed, !launchedWithBook, !debugBook {
            // Laid over the browser rather than in its place, so the browser
            // (slow to start) is ready behind it when the welcome fades.
            let welcome = UIHostingController(rootView: WelcomeView(open: { [weak self] in self?.leaveWelcome() }))
            welcome.view.frame = window.bounds
            welcome.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            welcome.view.backgroundColor = .systemBackground
            window.addSubview(welcome.view)
            self.welcome = welcome
        }

        if let context = connectionOptions.urlContexts.first {
            open(context)
        }
        #if DEBUG
        // Testing: PLATEN_OPEN_PATH opens a book straight away (see
        // DebugHooks.swift).
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

    // MARK: - Welcome

    /// Whether the welcome screen has been seen (and left), in this or an
    /// earlier launch. It shows only until then.
    private static var hasWelcomed: Bool {
        get { AppDefaults.store.bool(forKey: "hasSeenWelcome") }
        set { AppDefaults.store.set(newValue, forKey: "hasSeenWelcome") }
    }

    /// Open Book… (or a book arriving from elsewhere): the welcome fades,
    /// showing the document browser behind it.
    private func leaveWelcome() {
        Self.hasWelcomed = true
        guard let welcome else { return }
        self.welcome = nil
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3) {
            welcome.view.alpha = 0
        } completion: { _ in
            welcome.view.removeFromSuperview()
        }
    }

    private func open(_ context: UIOpenURLContext) {
        leaveWelcome()
        // With LSSupportsOpeningDocumentsInPlace, "open in place" means the
        // URL is the original file (security-scoped), not a copy in our Inbox.
        browser?.openBook(at: context.url, revealFirst: context.options.openInPlace)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // The app may be ended at any time once in the background.
        browser?.reader?.savePositionNow()
    }
}
