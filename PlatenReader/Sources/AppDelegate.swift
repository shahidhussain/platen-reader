import AppKit
import WebKit

/// App lifecycle: builds the menu bar, warms WebKit, and behaves like Preview
/// when launched with nothing to open (shows the Open panel).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindowController: SettingsWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        // Start WebKit's content process now, so the first open does not pay
        // for it (spec: "Warm the WebKit content process at launch").
        WebViewWarmer.warm()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If nothing was opened from Finder and no windows were restored,
        // offer the Open panel, as Preview does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSDocumentController.shared.documents.isEmpty, NSApp.windows.allSatisfy({ !$0.isVisible }) {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    // Platen has no "new document".
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

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
