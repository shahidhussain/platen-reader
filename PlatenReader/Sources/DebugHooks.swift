#if DEBUG
import AppKit
import SwiftUI
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
///   search, "@tab:<contents|bookmarks|search>" opens the panel on a tab,
///   "@resize:<w>x<h>" resizes the window and logs the re-layout time,
///   "@theme:<light|sepia|dark|black>" sets the page theme. Each step also writes "<book>-<n>-native.png" of the native views
///   (sidebar, overlay), which web snapshots do not include.
/// - PLATEN_PRESS_FREEZE=<0…1>: the platen press (PlatenPress.swift) holds
///   still at that point and stays up, to look at its poses.
enum DebugHooks {
    /// When an "@resize:" step changed the window size; the next page
    /// position report (sent once the text is laid out again) logs the time.
    static var resizeStarted: CFAbsoluteTime?

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
            // The native views over the page, half a second later (once
            // animations have settled): the page from the web view's own
            // snapshot, then the native views drawn over it with the web
            // view hidden. (Drawing the window directly can show the web
            // view black, once SwiftUI views are layered over it.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                webView.takeSnapshot(with: nil) { page, _ in
                    guard let page else { return }
                    webView.isHidden = true
                    defer { webView.isHidden = false }
                    guard let native = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
                    root.cacheDisplay(in: root.bounds, to: native)
                    let size = root.bounds.size
                    let out = NSImage(size: size)
                    out.lockFocus()
                    NSColor.black.setFill()
                    NSRect(origin: .zero, size: size).fill()
                    page.draw(in: webView.convert(webView.bounds, to: root))
                    native.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver,
                                fraction: 1, respectFlipped: true, hints: nil)
                    out.unlockFocus()
                    guard let tiff = out.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(bookName)-\(index)-native.png"))
                }
            }
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

    /// Every visible window, popovers and Settings included, drawn from its
    /// own views ("@snapwindows"): `<name>-window-<kind>.png`, where kind is
    /// the window's title or class. (Glass does not draw this way; check it
    /// on screen.)
    static func snapshotWindows(name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PLATEN_SNAPSHOT_DIR"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let kind = window.title.isEmpty ? String(describing: type(of: window)) : window.title
                let safe = kind.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-window-\(index)-\(safe).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                log.info("snapshot: \(url.lastPathComponent, privacy: .public)")
            }
        }
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

/// Read aloud's scripted steps, for books and PDFs alike: "@readaloud" (the
/// speaker; the once-only note about better voices is taken as read, so a
/// scripted start reads at once), "@readaloud:stop", "@voice:<kokoro|apple|
/// undecided>" (the choice for English books), "@skip:<±1>" (the media
/// keys' next and previous). Returns false for any other step.
extension ReaderBaseViewController {
    func runReadAloudDebugStep(_ step: String) -> Bool {
        if step == "@readaloud" {
            if let source = readAloudSource {
                AppDefaults.store.set(true, forKey: ReadAloudStarter.noteShownKey(AppleVoices.baseLanguage(source.readAloudLanguage)))
            }
            readAloudStarter.toggle()
        } else if step == "@readaloud:stop" {
            readAloudStarter.stop()
        } else if step.hasPrefix("@voice:"), let choice = ReadAloudVoiceChoice(rawValue: String(step.dropFirst(7))) {
            ReadAloudSettings.shared.choice = choice
        } else if step.hasPrefix("@skip:"), let delta = Int(step.dropFirst(6)) {
            readAloudSource?.skipReadAloud(by: delta)
        } else {
            return false
        }
        log.info("read aloud: \(String(describing: self.state.readAloud), privacy: .public)")
        return true
    }
}

/// Runs one scripted step (see PLATEN_STEPS above).
extension ReaderViewController {
    func runDebugStep(_ step: String) {
        if step.hasPrefix("@theme:"), let choice = AppearanceChoice(rawValue: String(step.dropFirst(7))) {
            // "@theme:sepia": the page theme, as the View menu would set it.
            settings.appearance = choice
        } else if step.hasPrefix("@tab:"), let tab = ReaderState.SidebarTab(rawValue: String(step.dropFirst(5))) {
            self.chrome.setSidebar(visible: true, tab: tab)
        } else if step.hasPrefix("@search:") {
            self.chrome.setSidebar(visible: true, tab: .search)
            self.session.search(String(step.dropFirst("@search:".count)))
        } else if step.hasPrefix("@resize:") {
            // "@resize:900x700": resize the window (content size, in points)
            // and log how long until the text has been laid out again.
            let parts = step.dropFirst("@resize:".count).split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, let window = self.view.window {
                DebugHooks.resizeStarted = CFAbsoluteTimeGetCurrent()
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
            }
        } else if step == "@about" {
            // "@about": the About window (snapshot it with "@snapwindows").
            AboutWindowController.shared.show()
            let window = AboutWindowController.shared.window
            log.info("about: visible \(window?.isVisible == true, privacy: .public), \(String(describing: window?.frame), privacy: .public)")
        } else if step == "@acknowledgements" {
            AcknowledgementsWindowController.shared.show()
            let list = Acknowledgements.bundled
            log.info("acknowledgements: \(list.components.count, privacy: .public) components, \(list.texts.count, privacy: .public) licence texts")
        } else if step == "@snapwindows" {
            DebugHooks.snapshotWindows(name: "windows")
        } else if step.hasPrefix("@settings:"), let tab = Int(step.dropFirst("@settings:".count)) {
            // "@settings:0": Settings, on its first tab (Appearance).
            (NSApp.delegate as? AppDelegate)?.showSettings(tab: tab)
        } else if step == "@ax" {
            // What VoiceOver sees in this window: the accessibility tree,
            // walked in-process, plus where focus and hit-testing land.
            func describe(_ element: Any) -> String {
                guard let e = element as? NSAccessibilityProtocol else { return "\(type(of: element))" }
                let value = (e.accessibilityValue() as? String).map { " = " + String($0.prefix(60)) } ?? ""
                return "\(e.accessibilityRole()?.rawValue ?? "?") [\(e.accessibilityRoleDescription() ?? "")] "
                    + "\(e.accessibilityLabel() ?? "")\(value) (\(type(of: element)))"
            }
            func walk(_ element: Any, _ depth: Int) {
                log.info("ax: \(String(repeating: "  ", count: depth), privacy: .public)\(describe(element), privacy: .public)")
                guard depth < 12, let e = element as? NSAccessibilityProtocol else { return }
                for child in e.accessibilityChildren() ?? [] { walk(child, depth + 1) }
            }
            if let content = self.view.window?.contentView { walk(content, 0) }
            log.info("ax focused: \(describe(self.webView.accessibilityFocusedUIElement as Any), privacy: .public)")
            let middle = NSPoint(x: self.view.window!.frame.midX, y: self.view.window!.frame.midY)
            log.info("ax hit: \(describe(self.view.window?.contentView?.accessibilityHitTest(middle) as Any), privacy: .public)")
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
        } else if runReadAloudDebugStep(step) {
            // Read aloud's steps (ReaderBaseViewController).
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
