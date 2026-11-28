import AppKit
import QuartzCore

/// The bookmark ribbon on a bookmarked PDF page on the Mac, the same as the
/// books' one (PlatenReader/Web/modules/bookmarks.js) and iOS's PDF one
/// (BookmarkRibbonView): the drawn ribbon of orange grosgrain with stitched
/// edges and a swallowtail notch (design/ribbon/make-ribbon.swift; deeper on
/// a dark page), with a very soft shadow on the page beneath, over the
/// page's top edge as a real ribbon lies on the page.
///
/// Adding a bookmark lays it down (`layDown`); removing one lifts it off
/// (`liftOff`); turning onto a bookmarked page shows it simply there. The
/// timings are PlatenMotion.Ribbon's (PlatenPress.swift).
final class PDFRibbonView: NSView {
    /// The size it is drawn at (points), as on iOS.
    static let size = CGSize(width: 30, height: 45)

    /// The ribbon itself, hinged at its top edge so it folds about the
    /// page's edge: a strip of cloth repeating down its length, and the
    /// notched end.
    private let cloth = CALayer()
    private let strip = CALayer()
    private let end = CALayer()

    /// Whether it is drawn for a dark page.
    var isDark = false {
        didSet { if isDark != oldValue { loadPictures() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        cloth.addSublayer(strip)
        cloth.addSublayer(end)
        // Hinged at its top edge (the layer's y counts up from the bottom).
        cloth.anchorPoint = CGPoint(x: 0.5, y: 1)
        cloth.shadowColor = NSColor.black.cgColor
        cloth.shadowOpacity = 0.25
        cloth.shadowRadius = 1.2
        cloth.shadowOffset = CGSize(width: 0, height: -0.8)
        layer?.addSublayer(cloth)
        loadPictures()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Clicks go through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cloth.bounds = CGRect(origin: .zero, size: bounds.size)
        cloth.position = CGPoint(x: bounds.midX, y: bounds.maxY) // the hinge: its top edge
        // The end is half as long as the ribbon is wide; the strip fills the
        // rest above it, repeating.
        let endLength = min(bounds.height, bounds.width / 2)
        end.frame = CGRect(x: 0, y: 0, width: bounds.width, height: endLength)
        strip.frame = CGRect(x: 0, y: endLength, width: bounds.width, height: bounds.height - endLength)
        CATransaction.commit()
    }

    /// The pieces, from the web shell's folder (both apps carry them).
    private func loadPictures() {
        let shade = isDark ? "dark" : "light"
        func picture(_ piece: String) -> CGImage? {
            guard let url = Bundle.main.url(forResource: "ribbon-\(piece)-\(shade)@2x", withExtension: "png",
                                            subdirectory: "Web/ribbon"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        end.contents = picture("end")
        end.contentsGravity = .resize
        // The strip repeats down the ribbon, a repeat as wide as the ribbon.
        if let tile = picture("strip") {
            let scale = CGFloat(tile.width) / Self.size.width
            let pattern = NSImage(cgImage: tile, size: NSSize(width: Self.size.width, height: CGFloat(tile.height) / scale))
            strip.backgroundColor = NSColor(patternImage: pattern).cgColor
        }
    }

    /// Its pose part-way through laying it down or lifting it off (a weak
    /// perspective, as on iOS).
    private func pose(fold: Double, turn: Double) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / max(600, bounds.height * 10)
        transform = CATransform3DRotate(transform, turn * .pi / 180, 0, 0, 1)
        return CATransform3DRotate(transform, -fold * .pi / 180, 1, 0, 0)
    }

    /// Laid onto the page: it folds down about the page's top edge from
    /// nearly end-on, coming in from the page's outer side and straightening
    /// as it lands, then a tiny swing dies away. With Reduce Motion, a fade.
    func layDown(outerIsLeft: Bool) {
        let motion = PlatenMotion.Ribbon.self
        finishMotion()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = motion.reducedDuration
            cloth.add(fade, forKey: "ribbon")
            return
        }
        // (Turns count anticlockwise here, the other way from iOS.)
        let swing = outerIsLeft ? -1.0 : 1.0
        let total = motion.layDuration + motion.settleDuration
        let landed = motion.layDuration / total
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [
            pose(fold: motion.layStartFold, turn: swing * motion.layStartSwing),
            pose(fold: 0, turn: 0),
            pose(fold: 0, turn: -swing * motion.settleSwing),
            pose(fold: 0, turn: swing * motion.settleSwing * 0.35),
            pose(fold: 0, turn: 0),
        ].map { NSValue(caTransform3D: $0) }
        let after = 1 - landed
        animation.keyTimes = [0, landed, landed + after * 0.35, landed + after * 0.7, 1].map { NSNumber(value: $0) }
        animation.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.15, 0.6, 0.3, 1),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        animation.duration = total
        cloth.add(animation, forKey: "ribbon")
    }

    /// Lifted off the page: laying it down played backwards, fading only at
    /// the very end; then hidden. With Reduce Motion, a fade.
    func liftOff(outerIsLeft: Bool, then done: @escaping () -> Void) {
        let motion = PlatenMotion.Ribbon.self
        finishMotion()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.cloth.removeAnimation(forKey: "lift")
            done()
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        let group = CAAnimationGroup()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fade.values = [1, 0]
            group.animations = [fade]
            group.duration = motion.reducedDuration
        } else {
            let swing = outerIsLeft ? -1.0 : 1.0
            let fold = CAKeyframeAnimation(keyPath: "transform")
            fold.values = [pose(fold: 0, turn: 0), pose(fold: motion.layStartFold, turn: swing * motion.layStartSwing)]
                .map { NSValue(caTransform3D: $0) }
            fold.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.7, 0, 0.85, 0.4)]
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.8, 1]
            group.animations = [fold, fade]
            group.duration = motion.liftDuration
        }
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        cloth.add(group, forKey: "lift")
        CATransaction.commit()
    }

    /// Any motion jumps to its end.
    func finishMotion() {
        cloth.removeAnimation(forKey: "ribbon")
        cloth.removeAnimation(forKey: "lift")
    }
}
