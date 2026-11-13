import Foundation
import PlatenCore
import WebKit

/// Serves everything the reader web view loads, under one origin:
///
///   platen://reader/app/<path>   the reader shell and foliate-js, from the
///                                app bundle's Web folder
///   platen://reader/book/<path>  files inside the open book, from memory
///
/// Using one origin means the shell can `fetch()` book files without CORS.
/// Because nothing else is reachable (remote loads are also blocked by a
/// content rule list), the web view has no access to the network or the
/// file system beyond this handler.
final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "platen"
    static let shellURL = URL(string: "platen://reader/app/reader.html")!

    /// Set once the book has loaded. Read on background queues, written on
    /// the main thread before any book request can arrive.
    var book: Book?

    /// Tasks still running, retained so WebKit's `stop` can be honoured:
    /// calling a task after it was stopped raises an exception.
    private var activeTasks: [ObjectIdentifier: WKURLSchemeTask] = [:]

    /// The shell's Content-Security-Policy. Scripts may only come from the
    /// app itself, so any <script> in book content (which foliate-js loads
    /// into blob: iframes that inherit this policy) does not run.
    private static let contentSecurityPolicy = [
        "default-src 'self' platen: blob: data:",
        "script-src 'self' platen:",
        "style-src 'self' platen: blob: data: 'unsafe-inline'",
        "img-src 'self' platen: blob: data:",
        "font-src 'self' platen: blob: data:",
        "media-src 'self' platen: blob: data:",
        "connect-src 'self' platen: blob: data:",
        "frame-src 'self' platen: blob: data:",
        "object-src 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    private static let webRoot = Bundle.main.resourceURL!
        .appendingPathComponent("Web", isDirectory: true).standardizedFileURL

    /// Shell files are small and immutable; keep them in memory after the
    /// first read so every window after the first opens faster.
    private static var shellCache: [String: Data] = [:]
    private static let shellCacheLock = NSLock()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        activeTasks[id] = task
        guard let url = task.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return finish(id, status: 400, data: Data(), mime: "text/plain") }

        // Decode exactly once: reader.js encodes each path segment once.
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
        let book = self.book

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let response: (Int, Data, String, [String: String])
            if path.hasPrefix("/app/") {
                response = Self.shellFile(String(path.dropFirst("/app/".count)))
            } else if path.hasPrefix("/book/"), let book {
                do {
                    let resource = try book.resource(at: String(path.dropFirst("/book/".count)))
                    response = (200, resource.data, resource.mimeType, [:])
                } catch {
                    NSLog("Platen: \(error.localizedDescription)")
                    response = (404, Data(), "text/plain", [:])
                }
            } else {
                response = (404, Data(), "text/plain", [:])
            }
            DispatchQueue.main.async {
                self?.finish(id, status: response.0, data: response.1, mime: response.2, headers: response.3)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        activeTasks[ObjectIdentifier(task)] = nil
    }

    private func finish(_ id: ObjectIdentifier, status: Int, data: Data, mime: String, headers: [String: String] = [:]) {
        guard let task = activeTasks.removeValue(forKey: id), let url = task.request.url else { return }
        var fields = headers
        fields["Content-Type"] = mime
        fields["Content-Length"] = String(data.count)
        fields["Cache-Control"] = "no-store"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// Reads a file from the bundle's Web folder, refusing anything that
    /// would escape it (e.g. "../../").
    private static func shellFile(_ relative: String) -> (Int, Data, String, [String: String]) {
        let fileURL = webRoot.appendingPathComponent(relative).standardizedFileURL
        guard fileURL.path.hasPrefix(webRoot.path + "/") else { return (403, Data(), "text/plain", [:]) }

        shellCacheLock.lock()
        var data = shellCache[relative]
        shellCacheLock.unlock()
        if data == nil {
            data = try? Data(contentsOf: fileURL)
            if let data {
                shellCacheLock.lock()
                shellCache[relative] = data
                shellCacheLock.unlock()
            }
        }
        guard let data else { return (404, Data(), "text/plain", [:]) }

        var headers: [String: String] = [:]
        if relative.hasSuffix(".html") { headers["Content-Security-Policy"] = contentSecurityPolicy }
        let mime = MIMEType.forPath(relative) == "text/html" ? "text/html; charset=utf-8" : MIMEType.forPath(relative)
        return (200, data, mime, headers)
    }
}

/// Blocks every remote load (books sometimes reference web fonts, trackers or
/// remote images). Compiled once, then shared by all windows.
enum RemoteContentBlocker {
    private static var compiled: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void] = []
    private static var compiling = false

    // Content blocker regexes do not support "|", hence one rule per scheme.
    private static let rules = """
    [
      {"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^ftp://"}, "action": {"type": "block"}}
    ]
    """

    /// Calls back on the main thread with the rule list (or nil if WebKit
    /// could not compile it, in which case the CSP still blocks remote loads).
    static func load(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { return completion(compiled) }
        waiting.append(completion)
        guard !compiling else { return }
        compiling = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PlatenBlockRemote", encodedContentRuleList: rules
        ) { list, error in
            DispatchQueue.main.async {
                if let error { NSLog("Platen: content blocker failed to compile: \(error)") }
                compiled = list
                compiling = false
                let callbacks = waiting
                waiting = []
                callbacks.forEach { $0(list) }
            }
        }
    }
}

/// WKUserContentController retains its message handlers strongly; this proxy
/// breaks the cycle so reader windows can be deallocated.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
