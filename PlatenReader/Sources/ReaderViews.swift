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
    /// The web view, left out of what VoiceOver sees: VoiceOver meets the
    /// book as `bookPage` instead (see BookPageAccessibilityView).
    weak var hiddenFromAccessibility: NSView?

    override func accessibilityChildren() -> [Any]? {
        super.accessibilityChildren()?.filter { ($0 as AnyObject) !== hiddenFromAccessibility }
    }

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
    /// What VoiceOver finds in place of the web content (the book page).
    /// Pointing at the page, or the page having keyboard focus, lands
    /// VoiceOver on this rather than on WebKit's "web area".
    weak var accessibilityStandIn: NSView?

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        accessibilityStandIn ?? super.accessibilityHitTest(point)
    }

    override var accessibilityFocusedUIElement: Any? {
        accessibilityStandIn ?? super.accessibilityFocusedUIElement
    }

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

/// How VoiceOver meets the book: one block of text holding exactly what is
/// on screen (both pages in a two-page spread), described as a "page".
///
/// The book itself is drawn by a web view, which VoiceOver would announce as
/// "web content" with a hint about entering the "web area", and whose text
/// runs on past the page into the rest of the chapter. This stand-in sits
/// over the web view, takes no clicks, and is updated on every page turn
/// (see accessibility.js), so VoiceOver reads the page you are looking at,
/// word by word or character by character if you like.
final class BookPageAccessibilityView: NSView {
    /// The text on screen.
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
    /// Spoken before the text, e.g. the book's title.
    var name = ""

    private var string: NSString { text as NSString }
    private func clamp(_ range: NSRange) -> NSRange {
        NSIntersectionRange(range, NSRange(location: 0, length: string.length))
    }

    // Clicks go straight through to the page underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityRoleDescription() -> String? { String(localized: "page") }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityValue() -> Any? { text.isEmpty ? String(localized: "No text on this page") : text }

    // Ranges let VoiceOver move through the text by word and character.
    override func accessibilityNumberOfCharacters() -> Int { string.length }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: string.length) }
    override func accessibilityString(for range: NSRange) -> String? { string.substring(with: clamp(range)) }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        NSAttributedString(string: string.substring(with: clamp(range)))
    }
    override func accessibilityLine(for index: Int) -> Int { 0 }
    override func accessibilityRange(forLine line: Int) -> NSRange { NSRange(location: 0, length: string.length) }
    override func accessibilityFrame(for range: NSRange) -> NSRect { accessibilityFrame() }
}
