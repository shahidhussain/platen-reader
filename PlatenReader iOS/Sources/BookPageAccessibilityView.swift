import UIKit

/// What VoiceOver sees of a book's page on iOS: one element holding exactly
/// the text on screen, as the Mac's `BookPageAccessibilityView` does.
///
/// The book is shown in a web view, and in page mode foliate lays the whole
/// chapter out side by side with one page showing, so VoiceOver reading the
/// web view itself would wander into pages not on screen. So the web view is
/// hidden from VoiceOver, and this view lies over it in its place. The text
/// comes from the shell after every move (`sessionPageText`).
///
/// - Read All (two-finger swipe down) reads the page, and at its end turns
///   it and reads on: the page carries the "causes page turn" trait, so
///   VoiceOver asks it to scroll on (`accessibilityScroll`) when it has read
///   it all, and the page tells VoiceOver it has turned once the next page's
///   text is in (`pageTurned`).
/// - A three-finger swipe turns the page either way, the same way.
/// - A double tap shows or hides the reader's controls.
///
/// Taps never stop here (VoiceOver off, it is invisible to them): the page
/// underneath handles them as before.
final class BookPageAccessibilityView: UIView {
    /// The text on screen; "No text on this page" when there is none (a
    /// picture).
    var text = "" {
        didSet { accessibilityLabel = text.isEmpty ? String(localized: "No text on this page") : text }
    }
    /// Turns the page: true for forwards. Returns false if it cannot (the
    /// end of the book).
    var turn: ((_ forwards: Bool) -> Bool)?
    /// Shows or hides the reader's controls.
    var toggleControls: (() -> Void)?

    /// A turn asked for by VoiceOver, waiting for the next page's text.
    private var awaitingTurn = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .causesPageTurn]
        accessibilityLabel = String(localized: "No text on this page")
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Taps go straight through to the page underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let forwards: Bool
        switch direction {
        case .next, .left, .down: forwards = true // a swipe to the left brings the next page
        case .previous, .right, .up: forwards = false
        @unknown default: return false
        }
        guard turn?(forwards) == true else { return false }
        awaitingTurn = true
        // If no new text comes (a page with the same text), say so anyway,
        // so VoiceOver does not wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.pageTurned() }
        return true
    }

    override func accessibilityActivate() -> Bool {
        toggleControls?()
        return true
    }

    /// The next page's text is in: if VoiceOver turned the page, it is told
    /// so, and reads on (Read All) or reads the new page.
    func pageTurned() {
        guard awaitingTurn else { return }
        awaitingTurn = false
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        log.info("VoiceOver: page turned")
    }

    /// The page turned some other way (a tap or swipe with VoiceOver on):
    /// VoiceOver moves to it and reads it.
    func readNow() {
        UIAccessibility.post(notification: .layoutChanged, argument: self)
    }

    /// Whether a turn VoiceOver asked for is still waiting for its text.
    var isAwaitingTurn: Bool { awaitingTurn }
}
