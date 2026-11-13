import QuartzCore
import UIKit

/// The page turns that taps, swipes, the overlay's ‹ › buttons and the
/// keyboard ask for. "left" and "right" are sides of the screen (they turn
/// the right way in right-to-left books); "next" and "prev" are reading order.
enum PageTurnRequest: String {
    case left, right, next, prev

    /// The turn that undoes this one.
    var opposite: PageTurnRequest {
        switch self {
        case .left: .right
        case .right: .left
        case .next: .prev
        case .prev: .next
        }
    }
}

/// Draws page turns natively, over a reader's live page view (the book
/// reader's web view, or the PDF reader's PDFView), for both readers.
///
/// Why natively: the web page can only animate in JavaScript, which WebKit
/// runs at most 60 times a second and alongside everything else the page is
/// doing, so slides stuttered on a 120 Hz iPhone. Core Animation moves views
/// on its own thread at the screen's full rate. Every turn works the same way:
/// 1. take a picture of the page on screen and lay it over the live page;
/// 2. turn the live page underneath instantly, hidden by the picture;
/// 3. move the picture away (slide), or curl it away (Page Curl), showing
///    the new page.
///
/// Swipes in the book reader follow the finger (see `beginSwipe`). The PDF
/// reader's portrait swipes are PDFKit's own (already native).
final class PageTurnAnimator {
    enum Style { case none, slide, curl }

    /// Takes a picture of the page as it is on screen now.
    typealias Snapshot = (@escaping (UIImage?) -> Void) -> Void
    /// Turns the page underneath with no animation, then reports whether it
    /// moved (false at the start or end), once the new page is drawn.
    typealias TurnUnderneath = (PageTurnRequest, @escaping (Bool) -> Void) -> Void

    private unowned let host: UIViewController
    private let pageView: UIView
    private let snapshot: Snapshot
    private let turnUnderneath: TurnUnderneath

    /// How long a tap's slide takes (spec: page turns in 150–200 ms).
    private static let slideDuration: TimeInterval = 0.2

    init(host: UIViewController, pageView: UIView, snapshot: @escaping Snapshot, turnUnderneath: @escaping TurnUnderneath) {
        self.host = host
        self.pageView = pageView
        self.snapshot = snapshot
        self.turnUnderneath = turnUnderneath
    }

    /// True while a turn is being drawn or a finger is moving the page.
    var isBusy: Bool { cover != nil || pager != nil || swipe != nil }

    /// The picture of the old page, laid over the live page.
    private var cover: UIView?
    /// The system's page curl, while one runs.
    private var pager: UIPageViewController?
    /// Counts turns, so a late callback from an abandoned turn is ignored.
    private var generation = 0

    // MARK: - Taps, buttons and keys

    /// Turns a page in the given style. `leafMovesLeft`: the old page leaves
    /// towards the left (a forward turn in a left-to-right book).
    func turn(_ request: PageTurnRequest, leafMovesLeft: Bool, style: Style) {
        // A turn asked for while another is drawn (fast taps, a held arrow
        // key) skips the rest of that one and turns at once.
        if isBusy {
            finishNow()
            return turnUnderneath(request) { _ in }
        }
        switch style {
        case .none: turnUnderneath(request) { _ in }
        case .slide: slide(request, leafMovesLeft: leafMovesLeft)
        case .curl: curl(request, leafMovesLeft: leafMovesLeft)
        }
    }

    private func slide(_ request: PageTurnRequest, leafMovesLeft: Bool) {
        generation += 1
        let turn = generation
        let width = pageView.bounds.width
        // Holds the place until the picture is ready, so a second tap in the
        // meantime turns instantly instead of starting another slide.
        let placeholder = UIView()
        cover = placeholder
        snapshot { [weak self] image in
            guard let self, self.generation == turn else { return }
            guard let image else { self.cover = nil; return self.turnUnderneath(request) { _ in } }
            let cover = self.addCover(image)
            self.turnUnderneath(request) { moved in
                guard self.generation == turn else { return }
                guard moved else { return self.removeCover() }
                // The new page starts beside the old one, and both move
                // together, as paper on a table would.
                let offset = leafMovesLeft ? width : -width
                self.pageView.transform = CGAffineTransform(translationX: offset, y: 0)
                UIView.animate(withDuration: Self.slideDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    cover.transform = CGAffineTransform(translationX: -offset, y: 0)
                    self.pageView.transform = .identity
                } completion: { _ in
                    if self.generation == turn { self.removeCover() }
                }
            }
        }
    }

    private func curl(_ request: PageTurnRequest, leafMovesLeft: Bool) {
        generation += 1
        let turn = generation
        let pager = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                         options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
        pager.isDoubleSided = false
        pager.view.isUserInteractionEnabled = false
        pager.view.backgroundColor = .clear
        pager.view.frame = pageView.frame
        self.pager = pager

        snapshot { [weak self] before in
            guard let self, self.generation == turn else { return }
            guard let before else { self.pager = nil; return self.turnUnderneath(request) { _ in } }
            // Cover the live page with the page as it is now.
            pager.setViewControllers([self.picturePage(before)], direction: .forward, animated: false)
            self.host.addChild(pager)
            self.pageView.superview?.insertSubview(pager.view, aboveSubview: self.pageView)
            pager.didMove(toParent: self.host)

            // Turn underneath, then curl the old page away to show the new.
            self.turnUnderneath(request) { moved in
                guard self.generation == turn else { return }
                guard moved else { return self.removePager() } // at the start or end
                self.snapshot { after in
                    guard self.generation == turn, let after else { return self.removePager() }
                    let started = CACurrentMediaTime()
                    pager.setViewControllers([self.picturePage(after)],
                                             direction: leafMovesLeft ? .forward : .reverse, animated: true) { _ in
                        log.info("page curl took \(Int((CACurrentMediaTime() - started) * 1000)) ms")
                        if self.generation == turn { self.removePager() }
                    }
                }
            }
        }
    }

    // MARK: - Swipes that follow the finger (book reader)

    /// The swipe under way.
    private struct Swipe {
        var request: PageTurnRequest
        /// −1 when the old page leaves towards the left, +1 towards the right.
        var sign: CGFloat
        /// How far the finger has moved along that direction, in points.
        var distance: CGFloat = 0
        /// The picture of the old page is in place.
        var covered = false
        /// nil until the page underneath has turned; then whether it moved.
        var moved: Bool?
        /// Set when the finger lifts: whether to complete the turn.
        var commit: Bool?
        var velocity: CGFloat = 0
        /// Reduce Motion: no movement, just a turn when the finger lifts.
        var still: Bool
    }
    private var swipe: Swipe?

    /// A finger has started moving the page sideways. `leafMovesLeft` says
    /// which way it moves.
    func beginSwipe(_ request: PageTurnRequest, leafMovesLeft: Bool) {
        finishNow()
        generation += 1
        let turn = generation
        let still = UIAccessibility.isReduceMotionEnabled
        swipe = Swipe(request: request, sign: leafMovesLeft ? -1 : 1, still: still)
        if still { return }

        // Until the picture is ready (a few tens of milliseconds), the live
        // page itself follows the finger: it is still the old page.
        snapshot { [weak self] image in
            guard let self, self.generation == turn, var swipe = self.swipe else { return }
            guard let image else {
                // No picture: let go of the page and turn when the finger lifts.
                swipe.still = true
                self.swipe = swipe
                UIView.animate(withDuration: 0.2) { self.pageView.transform = .identity }
                return
            }
            let cover = self.addCover(image)
            cover.transform = self.pageView.transform
            swipe.covered = true
            self.swipe = swipe
            // Hide the live page while it turns: the strip the old page
            // uncovers shows the page colour until the new page is ready.
            self.pageView.alpha = 0
            self.pageView.transform = .identity
            self.turnUnderneath(swipe.request) { moved in
                guard self.generation == turn, self.swipe != nil else { return }
                self.swipe?.moved = moved
                if moved {
                    self.pageView.alpha = 1
                } else {
                    // At the start or end of the book: nothing to turn to.
                    // The live page (the same page) takes over again.
                    self.pageView.transform = cover.transform
                    self.pageView.alpha = 1
                    self.removeCover()
                }
                self.layoutSwipe()
                self.settleIfReady()
            }
        }
    }

    /// The finger moved: `translation` is its distance from where it began.
    func moveSwipe(translation: CGFloat) {
        guard var swipe else { return }
        // Only the chosen direction: the page cannot pass where it started.
        swipe.distance = max(0, translation * swipe.sign)
        self.swipe = swipe
        layoutSwipe()
    }

    /// The finger lifted (or the gesture was cancelled, `cancelled`).
    func endSwipe(velocity: CGFloat, cancelled: Bool) {
        guard var swipe else { return }
        let width = max(pageView.bounds.width, 1)
        let along = velocity * swipe.sign // positive: towards turning
        swipe.velocity = along
        // A flick turns however short it was; otherwise more than a fifth
        // of the way across turns, and less springs back.
        swipe.commit = !cancelled && (along > 300 || (along > -100 && swipe.distance > width * 0.2))
        self.swipe = swipe
        if swipe.still {
            self.swipe = nil
            if swipe.commit == true { turnUnderneath(swipe.request) { _ in } }
            return
        }
        settleIfReady()
    }

    /// Places the old page (the picture) and the new page (the live view)
    /// for the finger's current distance.
    private func layoutSwipe() {
        guard let swipe, !swipe.still else { return }
        let width = pageView.bounds.width
        let dx = swipe.distance * swipe.sign
        if !swipe.covered {
            pageView.transform = CGAffineTransform(translationX: dx, y: 0)
        } else if swipe.moved == false {
            // At the start or end: the page gives a little, then stops.
            pageView.transform = CGAffineTransform(translationX: dx * 0.25, y: 0)
        } else {
            cover?.transform = CGAffineTransform(translationX: dx, y: 0)
            if swipe.moved == true {
                pageView.transform = CGAffineTransform(translationX: dx - swipe.sign * width, y: 0)
            }
        }
    }

    /// Once the finger has lifted and the page underneath has turned (or not),
    /// finish the turn or put the old page back.
    private func settleIfReady() {
        guard let swipe, let commit = swipe.commit else { return }
        // The picture or the turn underneath are still on their way.
        if !swipe.covered || swipe.moved == nil {
            if !swipe.covered, !commit { springBack() } // nothing turned yet
            return
        }
        let turn = generation
        let width = pageView.bounds.width
        if swipe.moved == false { return springBack() }

        // The time it takes: what is left of the way, at the finger's speed,
        // within sensible limits.
        let remaining = commit ? width - swipe.distance : swipe.distance
        let speed = max(abs(swipe.velocity), 1)
        let duration = min(0.3, max(0.12, Double(remaining / speed)))
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            if commit {
                self.cover?.transform = CGAffineTransform(translationX: swipe.sign * width, y: 0)
                self.pageView.transform = .identity
            } else {
                self.cover?.transform = .identity
                self.pageView.transform = CGAffineTransform(translationX: -swipe.sign * width, y: 0)
            }
        } completion: { _ in
            guard self.generation == turn else { return }
            self.swipe = nil
            if commit {
                self.removeCover()
            } else {
                // The old page is back on top: turn the live page back
                // underneath it, then uncover.
                self.pageView.alpha = 0
                self.pageView.transform = .identity
                self.turnUnderneath(swipe.request.opposite) { _ in
                    guard self.generation == turn else { return }
                    self.pageView.alpha = 1
                    self.removeCover()
                }
            }
        }
    }

    /// Puts the live page back where it belongs, with no turn.
    private func springBack() {
        let turn = generation
        swipe = nil
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.pageView.transform = .identity
        } completion: { _ in
            if self.generation == turn { self.removeCover() }
        }
    }

    // MARK: - Helpers

    /// Ends whatever is being drawn at once, leaving the live page in place.
    /// Any turn underneath has already happened (or will, unseen).
    func finishNow() {
        generation += 1
        swipe = nil
        pageView.layer.removeAllAnimations()
        pageView.transform = .identity
        pageView.alpha = 1
        removeCover()
        removePager()
    }

    private func addCover(_ image: UIImage) -> UIView {
        let view = UIImageView(image: image)
        view.frame = pageView.frame
        view.contentMode = .scaleToFill
        view.backgroundColor = host.view.backgroundColor
        view.isUserInteractionEnabled = false
        pageView.superview?.insertSubview(view, aboveSubview: pageView)
        cover?.removeFromSuperview()
        cover = view
        return view
    }

    private func removeCover() {
        cover?.removeFromSuperview()
        cover = nil
    }

    private func removePager() {
        guard let pager else { return }
        self.pager = nil
        pager.willMove(toParent: nil)
        pager.view.removeFromSuperview()
        pager.removeFromParent()
    }

    private func picturePage(_ image: UIImage) -> UIViewController {
        let page = UIViewController()
        page.view.backgroundColor = host.view.backgroundColor
        let imageView = UIImageView(image: image)
        imageView.frame = page.view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleToFill
        page.view.addSubview(imageView)
        return page
    }
}
