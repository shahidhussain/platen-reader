#if DEBUG
import AppKit
import WebKit

/// Debug-only hooks for automated checks without screen-recording access.
///
/// - PLATEN_SNAPSHOT_DIR: after the first page renders, write PNG snapshots
///   of the web view there (`<book>-0.png`, then one per scripted step).
/// - PLATEN_STEPS: semicolon-separated steps run one per second after the
///   first render, each followed by a snapshot. A step is JavaScript (e.g.
///   "platen.next()"), or a reader command starting with "@": "@<selector>"
///   sends a menu action (e.g. "@toggleContents:"), "@search:<query>" runs a
///   search, "@tab:<contents|bookmarks|search>" opens the panel on a tab. Each step also writes "<book>-<n>-native.png" of the native views
///   (sidebar, overlay), which web snapshots do not include.
enum DebugHooks {
    static func afterFirstRender(webView: WKWebView, bookName: String, root: NSView, run: @escaping (String) -> Void) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["PLATEN_SNAPSHOT_DIR"] else { return }
        let steps = (env["PLATEN_STEPS"] ?? "").split(separator: ";").map(String.init)
        func snap(_ index: Int) {
            webView.takeSnapshot(with: nil) { image, _ in
                guard let image, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(bookName)-\(index).png")
                try? png.write(to: url)
            }
            snapshotView(root, name: "\(bookName)-\(index)-native", suffix: "")
        }
        func step(_ i: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                snap(i)
                guard i < steps.count else { return }
                run(steps[i])
                step(i + 1)
            }
        }
        step(0)
    }

    /// Snapshot of native views (e.g. the failure message), which
    /// `WKWebView.takeSnapshot` cannot capture.
    static func snapshotView(_ view: NSView, name: String, suffix: String = "-failure") {
        guard let dir = ProcessInfo.processInfo.environment["PLATEN_SNAPSHOT_DIR"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(suffix).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
#endif
