import AppKit
import QuartzCore

/// A quick page-turn animation, drawn over the web view from two snapshots:
/// the page before the turn (A) and after it (B).
///
/// The page underneath is turned instantly, so the web view already shows B.
/// Over it, the leaf being turned swings round the spine like the page of a
/// book, darkening as it lifts, and its back (the facing page of B) settles
/// into place on the other side.
///
/// - Two pages side by side: the spine is the middle of the window. Turning
///   forward, the right page lifts and swings over to the left.
/// - One page: the spine is the left edge (right edge when turning back).
///
/// It is deliberately short (about a quarter of a second) and simple.
final class PageTurnView: NSView {
    enum Direction {
        /// The leaf moves from right to left (forward in left-to-right books).
        case towardLeft
        /// The leaf moves from left to right.
        case towardRight
    }

    private let container = CALayer()
    private var finished: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting: we manage the layer tree ourselves.
        layer = container
        wantsLayer = true
        container.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Clicks go straight through to the page: a click during a turn starts
    // the next one.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Covers the page with snapshot A until the animation starts, so the
    /// instant turn underneath is not seen.
    func cover(with before: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.sublayers = nil
        let cover = imageLayer(before, part: 0...1, anchorX: 0.5)
        container.addSublayer(cover)
        CATransaction.commit()
    }

    /// Runs the turn. With two pages side by side the spine is the middle
    /// of the window.
    func run(before a: CGImage, after b: CGImage, direction: Direction, twoPages: Bool,
             completion: @escaping () -> Void) {
        finished = completion
        let leftward = direction == .towardLeft
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.sublayers = nil
        // Perspective, so the lifted edge of the leaf comes towards the reader.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / max(bounds.width * 2.2, 800)
        container.sublayerTransform = perspective

        // The parts of the window that make up each layer (as fractions of
        // the width) and the side of each leaf that is fixed to the spine.
        let staticPart: ClosedRange<CGFloat>?
        let front: (part: ClosedRange<CGFloat>, anchor: CGFloat)?
        let back: (part: ClosedRange<CGFloat>, anchor: CGFloat)?
        if twoPages {
            staticPart = leftward ? 0...0.5 : 0.5...1
            front = leftward ? (0.5...1, 0) : (0...0.5, 1)
            back = leftward ? (0...0.5, 1) : (0.5...1, 0)
        } else if leftward {
            // Forward: page A swings away to the left, revealing B.
            staticPart = nil
            front = (0...1, 0)
            back = nil
        } else {
            // Back: page B swings in from the left, over A.
            staticPart = 0...1
            front = nil
            back = (0...1, 0)
        }

        if let staticPart { container.addSublayer(imageLayer(a, part: staticPart, anchorX: 0.5)) }
        let frontLayer = front.map { imageLayer(a, part: $0.part, anchorX: $0.anchor) }
        let backLayer = back.map { imageLayer(b, part: $0.part, anchorX: $0.anchor) }
        frontLayer.map(container.addSublayer)
        backLayer.map(container.addSublayer)
        // The back of the leaf is edge-on (invisible) until its half of the
        // turn begins.
        if let backLayer, let back { backLayer.transform = rotation(lifted: back.anchor) }
        CATransaction.commit()

        // Timing: both halves together take about a quarter of a second.
        let half: CFTimeInterval = (front != nil && back != nil) ? 0.12 : 0.2
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finish() }
        if let frontLayer, let front {
            animate(frontLayer, from: CATransform3DIdentity, to: rotation(lifted: front.anchor),
                    shade: (0, 0.35), begin: now, duration: half, timing: .easeIn)
        }
        if let backLayer, let back {
            animate(backLayer, from: rotation(lifted: back.anchor), to: CATransform3DIdentity,
                    shade: (0.35, 0), begin: front == nil ? now : now + half, duration: half, timing: .easeOut)
        }
        CATransaction.commit()
    }

    /// Ends the animation at once (e.g. another turn was asked for).
    func finish() {
        guard let finished else { return }
        self.finished = nil
        finished()
    }

    // MARK: Layers

    /// A layer showing part of a snapshot, in the same place on screen.
    private func imageLayer(_ image: CGImage, part: ClosedRange<CGFloat>, anchorX: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = window?.backingScaleFactor ?? 2
        layer.contentsRect = CGRect(x: part.lowerBound, y: 0, width: part.upperBound - part.lowerBound, height: 1)
        let frame = CGRect(x: bounds.width * part.lowerBound, y: 0,
                           width: bounds.width * (part.upperBound - part.lowerBound), height: bounds.height)
        layer.anchorPoint = CGPoint(x: anchorX, y: 0.5)
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.minX + frame.width * anchorX, y: frame.midY)
        layer.isDoubleSided = false
        // A shadow layer that darkens the leaf as it lifts.
        let shade = CALayer()
        shade.name = "shade"
        shade.frame = layer.bounds
        shade.backgroundColor = NSColor.black.cgColor
        shade.opacity = 0
        layer.addSublayer(shade)
        return layer
    }

    /// The leaf turned edge-on. A leaf fixed by its left edge (anchor 0)
    /// lifts its right edge towards the reader, and the other way round.
    private func rotation(lifted anchorX: CGFloat) -> CATransform3D {
        CATransform3DMakeRotation(anchorX == 0 ? -.pi / 2 : .pi / 2, 0, 1, 0)
    }

    private func animate(_ layer: CALayer, from: CATransform3D, to: CATransform3D, shade: (Float, Float),
                         begin: CFTimeInterval, duration: CFTimeInterval, timing: CAMediaTimingFunctionName) {
        let turn = CABasicAnimation(keyPath: "transform")
        turn.fromValue = from
        turn.toValue = to
        turn.beginTime = begin
        turn.duration = duration
        turn.timingFunction = CAMediaTimingFunction(name: timing)
        turn.fillMode = .both
        turn.isRemovedOnCompletion = false
        layer.add(turn, forKey: "turn")
        layer.transform = to

        if let shadeLayer = layer.sublayers?.first(where: { $0.name == "shade" }) {
            let dim = CABasicAnimation(keyPath: "opacity")
            dim.fromValue = shade.0
            dim.toValue = shade.1
            dim.beginTime = begin
            dim.duration = duration
            dim.timingFunction = CAMediaTimingFunction(name: timing)
            dim.fillMode = .both
            dim.isRemovedOnCompletion = false
            shadeLayer.add(dim, forKey: "shade")
            shadeLayer.opacity = shade.1
        }
    }
}
