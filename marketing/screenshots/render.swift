// Renders an HTML file to a PNG with WebKit (the engine Safari uses), for
// the App Store screenshots' compose stage (compose.py). No browser to
// install: WebKit is part of macOS.
//
// Usage: swift render.swift <page.html> <width> <height> <out.png>
//
// The page is laid out at <width> × <height> CSS pixels and snapshotted at
// the screen's scale (2× on a Retina Mac); compose.py then scales the
// picture to exactly <width> × <height> and removes its alpha channel, as
// App Store Connect requires.

import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count == 5, let width = Double(arguments[2]), let height = Double(arguments[3]) else {
    FileHandle.standardError.write("usage: render.swift <page.html> <width> <height> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let page = URL(fileURLWithPath: arguments[1])
let out = URL(fileURLWithPath: arguments[4])

/// Loads the page, waits for its fonts and pictures, snapshots it and quits.
final class Renderer: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let window: NSWindow

    init(size: NSSize) {
        view = WKWebView(frame: NSRect(origin: .zero, size: size))
        // A window off screen: WebKit draws only views that are in one.
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.contentView = view
        window.orderBack(nil)
        view.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Fonts and pictures load after the page itself. Wait until the
        // fonts are ready and every picture is decoded, then a moment for
        // them to be drawn. (callAsyncJavaScript waits for the `await`s;
        // evaluateJavaScript would not wait for a promise, and the large
        // iPad screenshots were sometimes not drawn yet: empty frames. Not
        // requestAnimationFrame: WebKit pauses it in a window off screen.)
        let wait = """
            await document.fonts.ready;
            await Promise.all([...document.images].map(i => i.decode()));
            await new Promise(r => setTimeout(r, 300));
            return [...document.images].every(i => i.complete && i.naturalWidth > 0);
            """
        webView.callAsyncJavaScript(wait, arguments: [:], in: nil, in: .page) { result in
            guard case .success(let value) = result, value as? Bool == true else {
                self.fail("a picture did not load: \(result)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.snapshot() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("could not load the page: \(error.localizedDescription)")
    }

    func snapshot() {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        view.takeSnapshot(with: configuration) { image, error in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.fail("no snapshot: \(error?.localizedDescription ?? "unknown")")
                return
            }
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            do { try png.write(to: out) } catch { self.fail("could not save: \(error)") }
            exit(0)
        }
    }

    func fail(_ message: String) {
        FileHandle.standardError.write("render.swift: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // no Dock icon, never takes focus
let renderer = Renderer(size: NSSize(width: width, height: height))
// Pages read their screenshots and fonts from beside them.
renderer.view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent().deletingLastPathComponent())
// Give up rather than hang if WebKit never answers.
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { renderer.fail("timed out") }
app.run()
