import AppKit
import Combine
import PlatenCore
import SwiftUI
import WebKit
import os

// MARK: - Turning pages

/// A page turn: by the side of the window (left/right, as clicked or as the
/// arrow keys say) or in reading order (next/previous).
enum PageTurn: String {
    case left, right, next, prev
}

extension ReaderViewController {
    /// Turns a page, with the page curl when chosen (Settings > General >
    /// Page turn animation; not with Reduce Motion). Slide and None are
    /// foliate-js's own turn, animated or not. In scroll
    /// mode "next" and "previous" move by a screen instead.
    func turn(_ command: PageTurn) {
        guard bookSentToShell else { return }
        let paginated = state.flow == .paginated || state.isFixedLayout
        guard paginated, settings.pageTurnStyle == .curl, !reducedMotion, imageZoom == nil else {
            return js(Self.turnScript[command]!)
        }
        // Which way the leaf travels on screen.
        let leafMovesLeft: Bool
        switch command {
        case .right: leafMovesLeft = true
        case .left: leafMovesLeft = false
        case .next: leafMovesLeft = !state.isRightToLeft
        case .prev: leafMovesLeft = state.isRightToLeft
        }

        // Pressing keys quickly (or holding one down) flips through pages:
        // while turns come faster than a curl takes, they are instant. The
        // curl returns as soon as the reader slows down.
        let now = ProcessInfo.processInfo.systemUptime
        let rapid = now - lastTurnRequest < 0.45
        lastTurnRequest = now
        if rapid {
            turnGeneration += 1
            if let previous = pageTurn {
                previous.finish()
                previous.removeFromSuperview()
                pageTurn = nil
            }
            return js(Self.turnScript[command]!)
        }

        // A turn already under way ends at once; this one starts afresh.
        if let previous = pageTurn {
            previous.finish()
            previous.removeFromSuperview()
            pageTurn = nil
        }
        turnGeneration += 1
        let generation = turnGeneration

        // 1. Snapshot the page as it is (A).
        webView.takeSnapshot(with: nil) { [weak self] before, _ in
            // Overtaken by a newer turn: that one has already moved the page.
            guard let self, generation == self.turnGeneration else { return }
            guard let a = before?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.js(Self.turnScript[command]!) // no snapshot: turn without the curl
                return
            }
            // 2. Cover the page with A, then turn the real page instantly.
            let overlay = PageTurnView(frame: self.webView.frame)
            overlay.autoresizingMask = [.width, .height]
            self.view.addSubview(overlay, positioned: .above, relativeTo: self.webView)
            overlay.cover(with: a)
            self.pageTurn = overlay
            let remove = { [weak self, weak overlay] in
                overlay?.removeFromSuperview()
                if self?.pageTurn === overlay { self?.pageTurn = nil }
            }
            self.webView.callAsyncJavaScript("return await platen.turnInstantly(d)", arguments: ["d": command.rawValue],
                                             in: nil, in: .page) { result in
                guard generation == self.turnGeneration,
                      case .success(let value) = result, let info = value as? [String: Any],
                      info["moved"] as? Bool == true else { return remove() }
                let twoPages = (info["columns"] as? NSNumber)?.intValue ?? 1 >= 2
                // 3. Snapshot the new page (B) and animate from A to B.
                self.webView.takeSnapshot(with: nil) { after, _ in
                    guard generation == self.turnGeneration,
                          let b = after?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return remove() }
                    log.debug("page turn: animating (\(twoPages ? "two pages" : "one page", privacy: .public))")
                    overlay.run(before: a, after: b, direction: leafMovesLeft ? .towardLeft : .towardRight,
                                twoPages: twoPages, completion: remove)
                }
            }
        }
    }

    static let turnScript: [PageTurn: String] = [
        .left: "platen.goLeft()", .right: "platen.goRight()", .next: "platen.next()", .prev: "platen.prev()",
    ]
}
