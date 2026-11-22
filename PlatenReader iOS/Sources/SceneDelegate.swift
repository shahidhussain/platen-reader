import UIKit

/// A window, whose root is Platen's own home screen
/// (`HomeViewController`); on iPad there can be several, each with a book
/// of its own (`BookWindows`). Books open from there ("Open Book…"), from Files
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

        // The book this window is for: the one it had open when iOS ended
        // the app (state restoration), or one handed to a new window ("Open
        // in New Window"). See BookWindows.
        let windowBook = BookWindows.bookmark(in: windowScene.session.stateRestorationActivity)
            ?? connectionOptions.userActivities.lazy.compactMap { BookWindows.bookmark(in: $0) }.first
        // Launched by opening a book from another app: straight to it.
        let launchedWithBook = !connectionOptions.urlContexts.isEmpty
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        // The debug book opens in the first window only, not in one opened
        // later (BookWindows), which has a book of its own.
        let debugBook = env["PLATEN_OPEN_PATH"] != nil && isOnlyWindow(windowScene)
        #else
        let debugBook = false
        #endif
        window.makeKeyAndVisible()

        // Going straight into a book, the start-up animation stays up with
        // the book's progress until the first page is on screen.
        let followBook = { [weak splash, weak home] in
            home?.onReaderCreated = { reader in
                splash?.follow(reader.state)
                home?.onReaderCreated = nil
            }
        }
        if launchedWithBook || debugBook {
            followBook()
        } else if let windowBook {
            log.info("window: reopening its own book")
            LastOpenBook.resolve(windowBook, timeout: 3) { [weak splash, weak home] url in
                guard let home else { return }
                if let url {
                    followBook()
                    home.openBook(at: url)
                } else {
                    splash?.finishSoon()
                }
            }
        } else if LastOpenBook.isSaved, isOnlyWindow(windowScene) {
            log.info("window: reopening the last book")
            // Back to the book that was open. Where it is now is found in
            // the background (it can hang; see LastOpenBook.find), with the
            // start-up animation still up; if it cannot be found in time,
            // the home screen instead.
            LastOpenBook.find(timeout: 3) { [weak self, weak splash, weak home] url in
                guard let home else { return }
                // A book opened from another app meanwhile wins.
                if let url, self?.openedSinceLaunch != true {
                    followBook()
                    home.openBook(at: url)
                } else {
                    splash?.finishSoon()
                }
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
        if let path = env["PLATEN_OPEN_PATH"], debugBook {
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
    /// True once a book has been opened from another app since launch, so
    /// the last book, found late, is not opened over it.
    private var openedSinceLaunch = false

    /// A book opened from another app while Platen is running. With
    /// LSSupportsOpeningDocumentsInPlace, the URL is the original file
    /// (security-scoped) where the provider allows it, not a copy in our
    /// Inbox.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let context = contexts.first else { return }
        openedSinceLaunch = true
        if let home { home.openBook(at: context.url) } else { pendingURL = context.url }
    }

    /// Launching goes back to the last book only in the first window; a
    /// window added later (iPad) starts at the home screen.
    private func isOnlyWindow(_ scene: UIWindowScene) -> Bool {
        !UIApplication.shared.connectedScenes.contains { $0 !== scene && $0.activationState != .unattached }
    }

    /// What iOS keeps to bring this window back if it ends the app in the
    /// background: the book open in it, if any (BookWindows).
    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let bookmark = home?.openBookmark else { return nil }
        return BookWindows.activity(bookmark: bookmark, title: (scene as? UIWindowScene)?.title ?? "")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // The app may be ended at any time once in the background.
        home?.reader?.savePositionNow()
    }
}
