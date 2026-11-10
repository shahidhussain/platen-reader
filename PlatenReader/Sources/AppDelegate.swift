import AppKit
import WebKit

/// App lifecycle: builds the menu bar, warms WebKit, keeps to one running
/// copy of the app, and shows the welcome window when there is nothing to
/// read.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindowController: SettingsWindowController?
    private var keyMonitor: Any?

    /// Another copy of Platen that was already running when this one
    /// started (say, a second build in another folder). This copy hands it
    /// any books it was asked to open, brings it forward and quits.
    private var existingInstance: NSRunningApplication?

    func applicationWillFinishLaunching(_ notification: Notification) {
        existingInstance = Self.otherRunningInstance()
        if existingInstance != nil { return }
        NSApp.mainMenu = MainMenu.build()
        // Start WebKit's content process now, so the first open does not pay
        // for it (spec: "Warm the WebKit content process at launch").
        WebViewWarmer.warm()
        installCloseShortcut()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let existing = existingInstance {
            // Give macOS a moment to deliver any "open these books" request
            // (handled below), then hand over and quit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                existing.activate()
                NSApp.terminate(nil)
            }
            return
        }
        // If nothing was opened from Finder and no windows were restored,
        // show the welcome window with its Open button.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSDocumentController.shared.documents.isEmpty, NSApp.windows.allSatisfy({ !$0.isVisible }) {
                WelcomeWindowController.shared.show()
            }
        }
    }

    /// Books opened from Finder, the Dock or `open`. Handled here (rather
    /// than left to AppKit) so a second copy of the app can pass them on.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let existing = existingInstance, let appURL = existing.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration)
            return
        }
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    /// Set once the app starts quitting, so closing book windows on the way
    /// out does not bring the welcome window back.
    static var isQuitting = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.isQuitting = true
        return .terminateNow
    }

    // Platen has no "new document".
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WelcomeWindowController.shared.show() }
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// A copy handing over to the running one must not restore windows.
    func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        existingInstance == nil
    }

    private static func otherRunningInstance() -> NSRunningApplication? {
        #if DEBUG
        // The automated checks (scripts/run-debug.sh) launch their own copy.
        if ProcessInfo.processInfo.environment["PLATEN_SNAPSHOT_DIR"] != nil { return nil }
        #endif
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0 != NSRunningApplication.current && !$0.isTerminated }
    }

    /// ⌘W closes the front window, whatever inside it has keyboard focus.
    /// (The File > Close menu item does the same, but a web view or popover
    /// holding focus can keep the shortcut from reaching it.)
    private func installCloseShortcut() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w",
                  let window = event.window ?? NSApp.keyWindow, window.styleMask.contains(.closable),
                  window.attachedSheet == nil, !(window is NSPanel) else { return event }
            window.performClose(nil)
            return nil
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController() }
        settingsWindowController?.showWindow(sender)
        settingsWindowController?.window?.makeKeyAndOrderFront(sender)
    }
}

/// Keeps one off-screen web view alive with the reader shell loaded, so the
/// WebKit content process and the shell's scripts are already warm. (All
/// web views in an app share one process pool, so later windows benefit.)
enum WebViewWarmer {
    private static var warmView: WKWebView?
    private static let handler = ReaderSchemeHandler()

    static func warm() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: ReaderSchemeHandler.scheme)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
        view.load(URLRequest(url: ReaderSchemeHandler.shellURL))
        warmView = view
        RemoteContentBlocker.load { _ in } // compile the rule list early too
    }
}
