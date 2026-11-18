import UIKit

/// One window, whose root is Platen's own home screen
/// (`HomeViewController`). Books open from there ("Open Book…"), from Files
/// ("Open in Platen Reader") or from other apps' share sheets, always in
/// place.
///
/// Launching goes back to the book that was open when Platen was last left;
/// if that book was closed (or there is none), the home screen shows the
/// welcome. A book opened from another app goes straight to that book.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var home: HomeViewController?
    /// The start-up animation, while it is up (LaunchSplash).
    private var splash: LaunchSplash?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // The start-up animation goes up alone, and the rest of start-up
        // waits until it is on screen. Its first frame is then cheap to
        // draw, so it replaces the launch screen at once and starts moving;
        // building the home screen (and warming WebKit) first held that
        // frame back by a second or more on a phone, so the mark sat still.
        let splash = LaunchSplash(in: windowScene)
        self.splash = splash
        splash.whenShown { [weak self] in self?.start(windowScene, connectionOptions) }
    }

    /// Everything else at launch: the home screen, and the book to go back
    /// to, if any.
    private func start(_ windowScene: UIWindowScene, _ connectionOptions: UIScene.ConnectionOptions) {
        guard let splash else { return }
        let home = HomeViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = home
        self.window = window
        self.home = home

        // Launched by opening a book from another app: straight to it.
        let launchedWithBook = !connectionOptions.urlContexts.isEmpty
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        let debugBook = env["PLATEN_OPEN_PATH"] != nil
        #else
        let debugBook = false
        #endif
        // Back to the book that was open, if there was one. (The book is
        // presented once the home screen is in the window; until then a page
        // in the theme's colour stands in, so the welcome does not flash.)
        let reopen = launchedWithBook || debugBook ? nil : LastOpenBook.url
        if let reopen { home.openBook(at: reopen) }
        window.makeKeyAndVisible()

        // Going straight into a book, the start-up animation stays up with
        // the book's progress until the first page is on screen.
        if reopen != nil || launchedWithBook || debugBook {
            home.onReaderCreated = { [weak splash, weak home] reader in
                splash?.follow(reader.state)
                home?.onReaderCreated = nil
            }
        } else {
            splash.finishSoon()
        }

        if let url = connectionOptions.urlContexts.first?.url ?? pendingURL {
            home.openBook(at: url)
        }
        pendingURL = nil
        #if DEBUG
        // Testing: PLATEN_FOLDER_PATH chooses the folder for the folder view
        // without the picker (see DebugHooks.swift).
        if let folder = env["PLATEN_FOLDER_PATH"] {
            home.showChosenFolder(URL(fileURLWithPath: folder, isDirectory: true))
        }
        // Testing: PLATEN_OPEN_PATH opens a book straight away (see
        // DebugHooks.swift).
        if let path = env["PLATEN_OPEN_PATH"] {
            let delay = Double(env["PLATEN_OPEN_DELAY"] ?? "") ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                home.openBook(at: URL(fileURLWithPath: path))
            }
        }
        #endif

        // Start WebKit's content process now, so the first book opened does
        // not pay for it (spec: "Warm the WebKit content process at launch").
        // It holds the main thread for a few tenths of a second, so it comes
        // after everything above; the start-up animation plays on regardless
        // (Core Animation draws it).
        DispatchQueue.main.async { WebViewWarmer.warm() }
    }

    /// A book opened from another app before the home screen was built
    /// (see `start`).
    private var pendingURL: URL?

    /// A book opened from another app while Platen is running. With
    /// LSSupportsOpeningDocumentsInPlace, the URL is the original file
    /// (security-scoped) where the provider allows it, not a copy in our
    /// Inbox.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let context = contexts.first else { return }
        if let home { home.openBook(at: context.url) } else { pendingURL = context.url }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // The app may be ended at any time once in the background.
        home?.reader?.savePositionNow()
    }
}
