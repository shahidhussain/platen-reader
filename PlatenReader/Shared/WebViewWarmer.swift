import Foundation
import WebKit

/// Keeps one off-screen web view alive with the reader shell loaded, so the
/// WebKit content process and the shell's scripts are already warm when the
/// first book opens (spec: "Warm the WebKit content process at launch").
/// All web views in an app share one process pool, so every later reader
/// benefits. Each app calls `warm()` once, as it launches.
enum WebViewWarmer {
    private static var warmView: WKWebView?
    private static let handler = ReaderSchemeHandler()

    static func warm() {
        guard warmView == nil else { return }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: ReaderSchemeHandler.scheme)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
        view.load(URLRequest(url: ReaderSchemeHandler.shellURL))
        warmView = view
        RemoteContentBlocker.load { _ in } // compile the rule list early too
    }
}
