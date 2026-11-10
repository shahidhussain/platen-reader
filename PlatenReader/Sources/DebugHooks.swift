#if DEBUG
import AppKit
import WebKit
import os

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

/// Runs one scripted step (see PLATEN_STEPS above).
extension ReaderViewController {
    func runDebugStep(_ step: String) {
        if step.hasPrefix("@tab:"), let tab = ReaderState.SidebarTab(rawValue: String(step.dropFirst(5))) {
            self.setSidebar(visible: true, tab: tab)
        } else if step.hasPrefix("@search:") {
            self.setSidebar(visible: true, tab: .search)
            self.startSearch(String(step.dropFirst("@search:".count)))
        } else if step.hasPrefix("@key:") {
            // "@key:cmd+w": a real keystroke, through the app's
            // normal key handling (menus first).
            let spec = String(step.dropFirst(5)).lowercased()
            var flags: NSEvent.ModifierFlags = []
            if spec.contains("cmd+") { flags.insert(.command) }
            if spec.contains("shift+") { flags.insert(.shift) }
            let key = String(spec.split(separator: "+").last ?? "")
            if let window = self.view.window,
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: key, charactersIgnoringModifiers: key,
                                            isARepeat: false,
                                            keyCode: ["w": 13, "q": 12, "t": 17, "f": 3, "d": 2, "c": 8, "k": 40][key] ?? 0) {
                NSApp.sendEvent(event)
            }
        } else if step.hasPrefix("@") {
            // Through this window's responder chain, as a menu shortcut
            // would be (the app may not be frontmost during checks).
            let action = NSSelectorFromString(String(step.dropFirst()))
            if self.view.window?.firstResponder?.tryToPerform(action, with: nil) != true {
                NSApp.sendAction(action, to: self, from: nil)
            }
        } else {
            self.webView.evaluateJavaScript(step) { result, error in
                if let result = result as? String { log.info("step result: \(result, privacy: .public)") }
                // Steps often return a Promise, which WebKit cannot pass back; that is fine.
                if let error = error as? NSError, error.code != 5 {
                    log.error("step failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
#endif
