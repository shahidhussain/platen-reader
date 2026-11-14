import AppKit
import Combine
import PlatenCore
import SwiftUI
import WebKit
import os

// The trackpad and the scroll wheel. (Click zones and keys are in
// ReaderBaseViewController; the keys only books have are overrides in
// ReaderViewController.swift.)

// MARK: - Trackpad and scroll wheel

extension ReaderViewController {
    /// Scroll events are read here rather than in the page because AppKit
    /// says when the fingers touch and lift (`phase`) and which events are
    /// momentum after they lift (`momentumPhase`). The web only sees a stream
    /// of wheel events, which is what made swipes unpredictable.
    func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.view.window else { return event }
            return self.handleScroll(event) ? nil : event
        }
        // Reading keys (C, space, arrows, Esc…) are taken here, before
        // WebKit, which does not always pass key presses on to its view.
        // Only while the page itself has focus, so typing in a search field
        // or popover is never affected.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.view.window,
                  let responder = event.window?.firstResponder as? NSView,
                  responder === self.webView || responder.isDescendant(of: self.webView) else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Returns true if the event was used (and must not reach WebKit).
    func handleScroll(_ event: NSEvent) -> Bool {
        guard session.isOpenInPage, failureHost == nil else { return false }
        if imageZoom != nil { return true }
        // Scroll mode uses WebKit's own scrolling, unchanged.
        guard state.flow == .paginated || state.isFixedLayout else { return false }
        // Only over the page: the contents panel and overlay scroll normally.
        let point = view.convert(event.locationInWindow, from: nil)
        if chrome.isVisible && chrome.overlayView.frame.contains(point) { return false }

        // Momentum after the fingers lift never turns another page: one
        // gesture is one page at most.
        if event.momentumPhase != [] { return true }

        // A mouse wheel (no phases): one page per notch, with a short pause
        // so a fast spin does not race through the book.
        if event.phase == [] {
            let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? -event.scrollingDeltaY : -event.scrollingDeltaX
            guard delta != 0, event.timestamp >= swipe.wheelQuietUntil else { return true }
            swipe.wheelQuietUntil = event.timestamp + 0.25
            session.turn(delta > 0 ? .next : .prev)
            return true
        }

        // Trackpad: content follows the fingers (`scrollingDelta` already
        // includes the natural-scrolling preference).
        let dx = -event.scrollingDeltaX, dy = -event.scrollingDeltaY
        switch event.phase {
        case .began, .mayBegin:
            swipe.reset()
            if event.phase == .began { swipe.active = true }
        case .changed:
            swipe.active = true
            if swipe.axis == nil {
                guard abs(dx) + abs(dy) > 1 else { return true }
                swipe.axis = abs(dx) > abs(dy) ? .horizontal : .vertical
            }
            if swipe.axis == .horizontal && !state.isFixedLayout {
                // The page moves with the fingers.
                swipe.add(dx, at: event.timestamp)
                session.swipeMove(by: Double(dx))
            } else if !swipe.turned {
                // Vertical (or fixed layout): one page once past a threshold.
                swipe.total += swipe.axis == .horizontal ? dx : dy
                if abs(swipe.total) > 30 {
                    swipe.turned = true
                    let forward = swipe.total > 0
                    if swipe.axis == .horizontal { session.turn(forward ? .right : .left) }
                    else { session.turn(forward ? .next : .prev) }
                }
            }
        case .ended, .cancelled:
            if swipe.active && swipe.axis == .horizontal && !state.isFixedLayout {
                session.swipeEnd(direction: event.phase == .cancelled ? 0 : swipe.flickDirection(at: event.timestamp))
            }
            swipe.reset()
        default:
            break
        }
        return true
    }
}

/// State of one trackpad gesture.
struct SwipeTracker {
    enum Axis { case horizontal, vertical }
    var active = false
    var axis: Axis?
    var total: CGFloat = 0
    var turned = false
    /// Recent movement, for the speed when the fingers lift.
    var recent: [(time: TimeInterval, dx: CGFloat)] = []
    var wheelQuietUntil: TimeInterval = 0

    mutating func reset() {
        active = false; axis = nil; total = 0; turned = false; recent = []
    }

    mutating func add(_ dx: CGFloat, at time: TimeInterval) {
        total += dx
        recent.append((time, dx))
        recent.removeAll { time - $0.time > 0.1 }
    }

    /// 1 or -1 if the fingers were moving quickly when they lifted (a flick,
    /// which turns the page however short it was), else 0: the page then
    /// settles on whichever page is mostly in view, so a short, slow drag
    /// springs back.
    func flickDirection(at time: TimeInterval) -> Int {
        let window = recent.filter { time - $0.time <= 0.08 }
        guard let first = window.first, abs(total) > 20 else { return 0 }
        let distance = window.reduce(0) { $0 + $1.dx }
        let duration = max(time - first.time, 0.016)
        let speed = distance / CGFloat(duration) // points per second
        guard abs(speed) > 350, (speed > 0) == (total > 0) else { return 0 }
        return speed > 0 ? 1 : -1
    }
}
