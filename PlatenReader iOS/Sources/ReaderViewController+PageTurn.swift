import UIKit
import WebKit

// Page turns in the book reader, drawn natively by PageTurnAnimator (see
// there for why). The web page only ever turns instantly
// (platen.turnInstantly); the slide and the curl are pictures of the page
// moved by Core Animation, at the screen's full rate.
//
// Swipes are recognised here too, not by foliate-js: the page follows the
// finger as a picture, which stays smooth however busy the page is.
// foliate's own touch dragging is switched off (the `nativeSwipe` setting;
// see the patch in foliate/paginator.js).
extension ReaderViewController {
    func makePageTurnAnimator() -> PageTurnAnimator {
        let animator = PageTurnAnimator(
            host: self, pageView: webView,
            snapshot: { [weak self] done in
                guard let self else { return done(nil) }
                self.webView.takeSnapshot(with: nil) { image, _ in done(image) }
            },
            turnUnderneath: { [weak self] request, done in
                guard let self else { return done(false) }
                self.webView.callAsyncJavaScript("return await platen.turnInstantly(direction)",
                                                 arguments: ["direction": request.rawValue], in: nil, in: .page) { result in
                    done(((try? result.get()) as? [String: Any])?["moved"] as? Bool ?? false)
                }
            })
        // A turn past the start or end of the book says so, rather than
        // just not moving.
        animator.onEdge = { [weak self] request in
            guard let self else { return }
            let forward: Bool
            switch request {
            case .next: forward = true
            case .prev: forward = false
            case .right: forward = !self.state.isRightToLeft
            case .left: forward = self.state.isRightToLeft
            }
            self.chrome?.showNotice(forward ? String(localized: "End of book") : String(localized: "Start of book"))
        }
        return animator
    }

    /// The style for taps, buttons and keys: Page Turn in Settings, with no
    /// movement under Reduce Motion, and none in scroll mode (where the
    /// page moves by a screenful).
    private var turnStyle: PageTurnAnimator.Style {
        guard state.flow == .paginated, !UIAccessibility.isReduceMotionEnabled else { return .none }
        switch settings.pageTurnStyle {
        case .none: return .none
        case .slide: return .slide
        case .curl: return .curl
        }
    }

    /// Which way the old page leaves for a turn: towards the left is a
    /// forward turn in a left-to-right book.
    private func leafMovesLeft(_ request: PageTurnRequest) -> Bool {
        switch request {
        case .right: true
        case .left: false
        case .next: !state.isRightToLeft
        case .prev: state.isRightToLeft
        }
    }

    func turn(_ request: PageTurnRequest) {
        guard bookSentToShell else { return }
        pageTurner.turn(request, leafMovesLeft: leafMovesLeft(request), style: turnStyle)
    }

    // MARK: - Swipes

    func installSwipeRecogniser() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pagePanned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = self
        webView.addGestureRecognizer(pan)
        swipeRecogniser = pan
    }

    /// Whether a pan may start: a sideways one-finger drag on a paginated
    /// page, not one that is selecting text.
    func swipeShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard hasRendered, failureHost == nil, state.flow == .paginated, !hasSelection, !state.noteOpen
        else { return false }
        // A finger held still first is selecting text, not turning.
        if let down = touchDownTime, CACurrentMediaTime() - down > 0.35 { return false }
        let velocity = pan.velocity(in: webView)
        return abs(velocity.x) > abs(velocity.y) * 1.2
    }

    @objc private func pagePanned(_ pan: UIPanGestureRecognizer) {
        let dx = pan.translation(in: webView).x
        switch pan.state {
        case .began:
            // The finger moving left brings in the page on the right.
            let request: PageTurnRequest = (dx != 0 ? dx : pan.velocity(in: webView).x) < 0 ? .right : .left
            pageTurner.beginSwipe(request, leafMovesLeft: request == .right)
            pageTurner.moveSwipe(translation: dx)
        case .changed:
            pageTurner.moveSwipe(translation: dx)
        case .ended:
            pageTurner.endSwipe(velocity: pan.velocity(in: webView).x, cancelled: false)
        case .cancelled, .failed:
            pageTurner.endSwipe(velocity: 0, cancelled: true)
        default:
            break
        }
    }
}
