import AppKit
import SwiftUI
import WebKit

// Small views used by the reader window.


/// Lets the window be dragged by its top edge (and zoomed with a double
/// click, following the user's Dock setting), as a title bar would.
final class WindowDragView: NSView {
    // The drag is done explicitly in mouseDown. (Also letting AppKit move the
    // window by itself, through mouseDownCanMoveWindow, made two mechanisms
    // compete for the same click, so the drag only sometimes took.)
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.performMiniaturize(nil) }
            else if action != "None" { window.performZoom(nil) }
        } else {
            window.performDrag(with: event)
        }
    }
}

/// A visual-effect view that never takes clicks, so the page underneath
/// still gets them.
final class PassThroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The root view: tracks the pointer so the title bar can be revealed at the
/// top edge and the overlay kept alive while the pointer moves.
final class ReaderRootView: NSView {
    var onMouseMoved: ((NSPoint) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }
}

/// A WKWebView that lets the reader handle page-turn keys before WebKit
/// (which would otherwise try to scroll the shell page).
final class ReaderWebView: WKWebView {
    var keyHandler: ((NSEvent) -> Bool)?
    var menuCustomiser: ((NSMenu) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menuCustomiser?(menu)
        super.willOpenMenu(menu, with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

/// Hosts the click-zone explainer; any click dismisses it.
final class ExplainerHostView: NSHostingView<ReadingControlsExplainer> {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Take every click inside our bounds, rather than letting SwiftUI pass
        // clicks on empty areas through to the page.
        frame.contains(point) ? self : nil
    }
}
