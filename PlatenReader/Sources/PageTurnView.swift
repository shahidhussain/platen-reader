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
        if twoPages { return runSpread(before: a, after: b, forward: direction == .towardLeft) }
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

    // MARK: Two pages: a bending leaf

    /// The two-page turn, modelled on a real leaf of paper.
    ///
    /// - The leaf (the right page when turning forward) is hinged at the
    ///   spine and swings over to the other side in one smooth, eased motion.
    /// - It bends as it goes: the leaf is a chain of narrow strips, each
    ///   hinged to the next, so it can take any curve. The outer edge leads,
    ///   so the page peels up from its edge, arcs over, and settles flat.
    /// - Each strip is shaded by how steeply it faces away from the reader,
    ///   so the curve reads as a curve.
    /// - The lifted leaf casts a soft shadow on the page it uncovers, and on
    ///   the page it is about to cover.
    /// - Its back is the facing page of the new spread, which lands exactly
    ///   where the real page is, so removing the animation is seamless.
    private func runSpread(before a: CGImage, after b: CGImage, forward: Bool) {
        let width = bounds.width, height = bounds.height
        let spine = width / 2
        let strips = 20
        let stripWidth = spine / CGFloat(strips)
        // +1: the leaf lies to the right of the spine (turning forward);
        // -1: to the left (turning back).
        let side: CGFloat = forward ? 1 : -1
        let duration: CFTimeInterval = 0.5
        let samples = 60

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.sublayers = nil
        // Gentle perspective: the eye is well back from the page, so the
        // lifted leaf does not balloon towards the reader.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (width * 3.2)
        container.sublayerTransform = perspective

        // The page the leaf will land on stays as it was (from snapshot A)
        // until the leaf covers it. The page it uncovers is the real one
        // underneath (already turned).
        let landing: ClosedRange<CGFloat> = forward ? 0...0.5 : 0.5...1
        container.addSublayer(imageLayer(a, part: landing, anchorX: 0.5))

        // Shadows on the two pages, darkest at the spine.
        let uncoveredShadow = gutterShadow(onLeft: !forward)
        let landingShadow = gutterShadow(onLeft: forward)
        container.addSublayer(uncoveredShadow)
        container.addSublayer(landingShadow)

        // The leaf: a chain of strips, the first hinged at the spine.
        var parent: CALayer = container
        var chain: [CATransformLayer] = []
        var faces: [(front: CALayer, back: CALayer)] = []
        for i in 0..<strips {
            let strip = CATransformLayer()
            strip.bounds = CGRect(x: 0, y: 0, width: stripWidth, height: height)
            strip.anchorPoint = CGPoint(x: forward ? 0 : 1, y: 0.5)
            if i == 0 {
                strip.position = CGPoint(x: spine, y: height / 2)
            } else {
                // Hinged to the outer edge of the strip before it.
                strip.position = CGPoint(x: forward ? stripWidth : 0, y: height / 2)
            }
            // Which slice of each snapshot this strip shows. Front: the
            // slice of A it covers now. Back: the mirror-image slice of B,
            // where the strip lands.
            let inner = CGFloat(i) * stripWidth, outer = CGFloat(i + 1) * stripWidth
            let frontRange = forward ? (spine + inner)...(spine + outer) : (spine - outer)...(spine - inner)
            let backRange = forward ? (spine - outer)...(spine - inner) : (spine + inner)...(spine + outer)
            let front = face(a, x: frontRange, width: width, size: strip.bounds.size, back: false)
            let back = face(b, x: backRange, width: width, size: strip.bounds.size, back: true)
            strip.addSublayer(front)
            strip.addSublayer(back)
            parent.addSublayer(strip)
            parent = strip
            chain.append(strip)
            faces.append((front, back))
        }
        CATransaction.commit()

        // The motion. Two angles, measured from flat towards the reader:
        // the leaf at the spine and at its outer edge. Each follows a smooth
        // ease that starts and ends at rest, and the outer edge runs a little
        // ahead (you turn a page by its edge), so the paper curves between
        // them. The strips in between follow a curve whose bend sits near
        // the outer edge as the page peels up and spreads evenly as it
        // settles, so the leaf lands without a jolt.
        func ease(_ x: Double) -> Double { (1 - cos(Double.pi * min(max(x, 0), 1))) / 2 }
        let lead = 0.2 // how far the outer edge runs ahead, as a share of the turn
        var angles: [[Double]] = Array(repeating: [], count: strips) // [strip][sample]
        var times: [NSNumber] = []
        var middle: [Double] = []
        for k in 0...samples {
            let t = Double(k) / Double(samples)
            let spineAngle = Double.pi * ease((t - lead) / (1 - lead))
            let edgeAngle = Double.pi * ease(t / (1 - lead))
            let peel = 2 - t // 2: bend near the edge; 1: an even curve
            for i in 0..<strips {
                let along = Double(i) / Double(strips - 1)
                angles[i].append(spineAngle + (edgeAngle - spineAngle) * pow(along, peel))
            }
            middle.append(angles[strips / 2][k])
            times.append(NSNumber(value: t))
        }
        // Rotating about the vertical axis: a leaf on the right lifts towards
        // the reader with a negative angle, one on the left with a positive one.
        let sign = -Double(side)
        // Animated as a plain angle ("transform.rotation.y"), not as a
        // matrix: Core Animation interpolates matrices by breaking them into
        // rotation and scale, and a turn of nearly 180° can break down the
        // other way round (a flip with no turn), which made the leaf jump
        // back up just before it landed.
        func rotation(_ angle: Double) -> NSNumber { NSNumber(value: sign * angle) }

        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finish() }
        for (i, strip) in chain.enumerated() {
            // Each strip is hinged to the one before, so it turns by the
            // difference between their angles.
            let values = (0...samples).map { k in rotation(i == 0 ? angles[0][k] : angles[i][k] - angles[i - 1][k]) }
            strip.add(keyframes("transform.rotation.y", values, times, now, duration), forKey: "turn")
            strip.setValue(values.last, forKeyPath: "transform.rotation.y")

            // Shading: a strip facing the reader is unshaded; edge-on it is
            // darkest. Its absolute angle is θ plus the bends before it.
            let shade = (0...samples).map { k in NSNumber(value: 0.45 * abs(sin(angles[i][k]))) }
            for layer in [faces[i].front, faces[i].back] {
                if let shadeLayer = layer.sublayers?.first {
                    shadeLayer.add(keyframes("opacity", shade, times, now, duration), forKey: "shade")
                    shadeLayer.opacity = 0
                }
            }
        }
        // The uncovered page is shadowed while the leaf is low over it; the
        // landing page as the leaf comes down onto it.
        let uncovered = middle.map { NSNumber(value: $0 < .pi / 2 ? 0.4 * sin(2 * $0) : 0) }
        let landed = middle.map { NSNumber(value: $0 > .pi / 2 ? 0.4 * sin(2 * ($0 - .pi / 2)) : 0) }
        uncoveredShadow.add(keyframes("opacity", uncovered, times, now, duration), forKey: "shadow")
        landingShadow.add(keyframes("opacity", landed, times, now, duration), forKey: "shadow")
        uncoveredShadow.opacity = 0
        landingShadow.opacity = 0
        CATransaction.commit()
    }

    /// One face of a leaf strip: a slice of a snapshot, with a shading layer.
    /// The back face is turned round so it shows once the leaf is over.
    private func face(_ image: CGImage, x: ClosedRange<CGFloat>, width: CGFloat, size: CGSize, back: Bool) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = window?.backingScaleFactor ?? 2
        layer.contentsRect = CGRect(x: x.lowerBound / width, y: 0, width: (x.upperBound - x.lowerBound) / width, height: 1)
        // A hair wider than the strip, so no seams show between strips.
        layer.frame = CGRect(x: -0.25, y: 0, width: size.width + 0.5, height: size.height)
        layer.isDoubleSided = false
        layer.allowsEdgeAntialiasing = true
        if back { layer.transform = CATransform3DMakeRotation(.pi, 0, 1, 0) }
        let shade = CALayer()
        shade.frame = layer.bounds
        shade.backgroundColor = NSColor.black.cgColor
        shade.opacity = 0
        shade.isDoubleSided = false
        layer.addSublayer(shade)
        return layer
    }

    /// A soft shadow over one page, darkest at the spine.
    private func gutterShadow(onLeft: Bool) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.frame = CGRect(x: onLeft ? 0 : bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
        layer.colors = [NSColor.black.withAlphaComponent(0.9).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        layer.startPoint = CGPoint(x: onLeft ? 1 : 0, y: 0.5)
        layer.endPoint = CGPoint(x: onLeft ? 0.35 : 0.65, y: 0.5)
        layer.opacity = 0
        return layer
    }

    private func keyframes(_ keyPath: String, _ values: [Any], _ times: [NSNumber],
                           _ begin: CFTimeInterval, _ duration: CFTimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.beginTime = begin
        animation.duration = duration
        animation.calculationMode = .linear // the easing is in the values
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
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
