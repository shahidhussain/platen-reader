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
            host: self, pageView: pageArea,
            snapshot: { [weak self] done in
                guard let self else { return done(nil) }
                // The page with its glow and native picture, if it has them.
                self.pageSnapshot(nil, withGlow: true, done: done)
            },
            turnUnderneath: { [weak self] request, done in
                guard let self else { return done(false) }
                self.session.turnInstantly(request) { moved, _ in
                    // The new page's glow before the animation, so the page
                    // arrives with it rather than the glow appearing after.
                    guard moved else { return done(false) }
                    self.settleLonePicture { self.makeGlowNow { done(true) } }
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

    /// The session asks for a page turn (a tap, a button or a key): drawn
    /// in the chosen style.
    func animateTurn(_ turn: PageTurn) {
        pageTurner.turn(turn, leafMovesLeft: turn.leafMovesLeft(rightToLeft: state.isRightToLeft), style: turnStyle)
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
        guard session.hasRendered, failureHost == nil, state.flow == .paginated, !hasSelection, !state.noteOpen
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
            let request: PageTurn = (dx != 0 ? dx : pan.velocity(in: webView).x) < 0 ? .right : .left
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
