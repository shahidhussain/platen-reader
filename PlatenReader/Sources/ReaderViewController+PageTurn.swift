import AppKit
import Combine
import PlatenCore
import SwiftUI
import WebKit
import os

// MARK: - Turning pages

extension ReaderViewController {
    /// Turns a page, with the page curl when chosen (Settings > General >
    /// Page turn animation; not with Reduce Motion). Slide and None are
    /// foliate-js's own turn, animated or not. In scroll
    /// mode "next" and "previous" move by a screen instead.
    func animateTurn(_ command: PageTurn) {
        let paginated = state.flow == .paginated || state.isFixedLayout
        guard paginated, settings.pageTurnStyle == .curl, !reducedMotion, imageZoom == nil else {
            // The page animates this turn itself: a picture shown full size
            // goes back to the page first, so it moves with it.
            releaseLonePictureForTurn()
            return session.turnPlainly(command)
        }
        // Which way the leaf travels on screen.
        let leafMovesLeft = command.leafMovesLeft(rightToLeft: state.isRightToLeft)

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
            releaseLonePictureForTurn()
            return session.turnPlainly(command)
        }

        // A turn already under way ends at once; this one starts afresh.
        if let previous = pageTurn {
            previous.finish()
            previous.removeFromSuperview()
            pageTurn = nil
        }
        turnGeneration += 1
        let generation = turnGeneration

        // 1. Snapshot the page as it is (A), as the reader sees it: with its
        // glow, and a picture-only page's picture.
        pageSnapshot { [weak self] before in
            // Overtaken by a newer turn: that one has already moved the page.
            guard let self, generation == self.turnGeneration else { return }
            guard let a = before else {
                self.session.turnPlainly(command) // no snapshot: turn without the curl
                return
            }
            // 2. Cover the page with A, then turn the real page instantly.
            let overlay = PageTurnView(frame: self.webView.frame)
            overlay.autoresizingMask = [.width, .height]
            // (Over the picture-only page's picture too, which is in A.)
            self.view.addSubview(overlay, positioned: .above, relativeTo: self.lonePictureView)
            overlay.cover(with: a)
            self.pageTurn = overlay
            let remove = { [weak self, weak overlay] in
                overlay?.removeFromSuperview()
                if self?.pageTurn === overlay { self?.pageTurn = nil }
            }
            self.session.turnInstantly(command) { moved, columns in
                guard generation == self.turnGeneration, moved else { return remove() }
                let twoPages = columns >= 2
                // 3. Snapshot the new page (B), once a picture-only page's
                // picture is on show, and animate from A to B.
                self.settleLonePicture {
                self.pageSnapshot { after in
                    guard generation == self.turnGeneration, let b = after else { return remove() }
                    log.debug("page turn: animating (\(twoPages ? "two pages" : "one page", privacy: .public))")
                    overlay.run(before: a, after: b, direction: leafMovesLeft ? .towardLeft : .towardRight,
                                twoPages: twoPages, completion: remove)
                }
                }
            }
        }
    }
}
