import UIKit

/// The bookmark ribbon on a bookmarked PDF page, the same as the books' one
/// (PlatenReader/Web/modules/bookmarks.js): the drawn ribbon of orange
/// grosgrain with stitched edges and a swallowtail notch
/// (design/ribbon/make-ribbon.swift; deeper on a dark page), with a very
/// soft shadow on the page beneath. It is placed over the page's top edge,
/// as a real ribbon lies on the page (see `PDFReaderViewController.placeRibbon`).
///
/// Adding a bookmark lays it down (`layDown`); removing one lifts it off
/// (`liftOff`); turning onto a bookmarked page shows it simply there. The
/// timings are PlatenMotion.Ribbon's (PlatenPress.swift).
final class BookmarkRibbonView: UIView {
    /// The size it is drawn at (points): half as big again as the drawing's
    /// 20 points across, to be seen at a glance. While the controls are up
    /// it is pulled longer, the same width (`PDFReaderViewController`).
    static let size = CGSize(width: 30, height: 45)

    /// The ribbon itself, hinged at its top edge (its anchor), so it folds
    /// and swings about the page's edge without moving the view's frame: a
    /// strip of cloth repeating down its length, and the notched end.
    private let cloth = UIView()
    private let strip = UIImageView()
    private let end = UIImageView()

    /// Whether it is drawn for a dark page.
    var isDark = false {
        didSet { if isDark != oldValue { loadPictures() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        cloth.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        cloth.addSubview(strip)
        cloth.addSubview(end)
        end.contentMode = .scaleToFill
        addSubview(cloth)
        loadPictures()
        // A very soft shadow on the page beneath: it sits on the paper.
        cloth.layer.shadowColor = UIColor.black.cgColor
        cloth.layer.shadowOpacity = 0.25
        cloth.layer.shadowRadius = 1.2
        cloth.layer.shadowOffset = CGSize(width: 0, height: 0.8)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { Self.size }

    /// The ribbon as drawn now, at its size (for pictures of the page). Drawn
    /// from its layers, so it comes out even while the page is hidden.
    var picture: UIImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return UIGraphicsImageRenderer(size: bounds.size).image { context in
            cloth.layer.render(in: context.cgContext)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cloth.bounds = CGRect(origin: .zero, size: bounds.size)
        cloth.center = CGPoint(x: bounds.midX, y: 0) // the anchor is its top edge
        // The end is half as long as the ribbon is wide; the strip fills
        // the rest, repeating.
        let endLength = min(bounds.height, bounds.width / 2)
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - endLength)
        end.frame = CGRect(x: 0, y: bounds.height - endLength, width: bounds.width, height: endLength)
    }

    /// The pieces, from the web shell's folder (both apps carry them),
    /// sized so a repeat of the strip is as wide as the ribbon.
    private func loadPictures() {
        let shade = isDark ? "dark" : "light"
        func picture(_ piece: String) -> UIImage? {
            guard let url = Bundle.main.url(forResource: "ribbon-\(piece)-\(shade)@3x", withExtension: "png",
                                            subdirectory: "Web/ribbon"),
                  let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
            let scale = image.size.width / Self.size.width
            return image.cgImage.map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
        }
        strip.image = picture("strip")?.resizableImage(withCapInsets: .zero, resizingMode: .tile)
        end.image = picture("end")
    }

    private static func pose(fold: Double, turn: Double) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 160
        transform = CATransform3DRotate(transform, turn * .pi / 180, 0, 0, 1)
        return CATransform3DRotate(transform, fold * .pi / 180, 1, 0, 0)
    }

    /// Laid onto the page: it folds down about the page's top edge from
    /// nearly end-on, coming in from the page's outer side and
    /// straightening as it lands, slowing to a stop (no bounce), then a
    /// tiny swing dies away. With Reduce Motion, a fade. On iPhone, a light
    /// tap as it comes to rest.
    func layDown(outerIsLeft: Bool) {
        let motion = PlatenMotion.Ribbon.self
        finishMotion()
        if UIAccessibility.isReduceMotionEnabled {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = motion.reducedDuration
            cloth.layer.add(fade, forKey: "ribbon")
        } else {
            let swing = outerIsLeft ? 1.0 : -1.0
            let total = motion.layDuration + motion.settleDuration
            let landed = motion.layDuration / total
            let animation = CAKeyframeAnimation(keyPath: "transform")
            animation.values = [
                Self.pose(fold: motion.layStartFold, turn: swing * motion.layStartSwing),
                Self.pose(fold: 0, turn: 0),
                Self.pose(fold: 0, turn: -swing * motion.settleSwing),
                Self.pose(fold: 0, turn: swing * motion.settleSwing * 0.35),
                Self.pose(fold: 0, turn: 0),
            ].map { NSValue(caTransform3D: $0) }
            let after = 1 - landed
            animation.keyTimes = [0, landed, landed + after * 0.35, landed + after * 0.7, 1].map { NSNumber(value: $0) }
            animation.timingFunctions = [
                CAMediaTimingFunction(controlPoints: 0.15, 0.6, 0.3, 1), // slows to a stop on the page
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            animation.duration = total
            cloth.layer.add(animation, forKey: "ribbon")
        }
        Self.tapAsItLands()
    }

    /// The light tap as the ribbon comes to rest (phones only).
    static func tapAsItLands() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.prepare()
        let delay = UIAccessibility.isReduceMotionEnabled ? PlatenMotion.Ribbon.reducedDuration : PlatenMotion.Ribbon.layDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { haptic.impactOccurred() }
    }

    /// Lifted off the page: a copy of the ribbon folds back up over the top
    /// edge, out of sight, and goes (the ribbon itself is simply hidden).
    /// No swing. With Reduce Motion, a fade.
    func liftOff() {
        guard !isHidden, let superview, let ghost = snapshotView(afterScreenUpdates: false) else { return }
        ghost.frame = frame
        superview.addSubview(ghost)
        let motion = PlatenMotion.Ribbon.self
        let reduce = UIAccessibility.isReduceMotionEnabled
        ghost.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        ghost.layer.position = CGPoint(x: frame.midX, y: frame.minY)
        UIView.animate(withDuration: reduce ? motion.reducedDuration : motion.liftDuration, delay: 0,
                       options: [.curveEaseIn]) {
            ghost.alpha = 0
            if !reduce { ghost.layer.transform = Self.pose(fold: 88, turn: 0) }
        } completion: { _ in
            ghost.removeFromSuperview()
        }
    }

    /// Any motion jumps to its end.
    func finishMotion() {
        cloth.layer.removeAnimation(forKey: "ribbon")
    }
}
