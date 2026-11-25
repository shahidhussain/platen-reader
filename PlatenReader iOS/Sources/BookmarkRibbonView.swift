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
    /// The size it is drawn at (points): the picture's 20 by 30.
    static let size = CGSize(width: 20, height: 30)

    /// The ribbon itself, hinged at its top edge (its anchor), so it folds
    /// and swings about the page's edge without moving the view's frame.
    private let cloth = UIImageView()

    /// Whether it is drawn for a dark page.
    var isDark = false {
        didSet { if isDark != oldValue { cloth.image = Self.picture(dark: isDark) } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        cloth.image = Self.picture(dark: false)
        cloth.contentMode = .scaleToFill
        cloth.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        addSubview(cloth)
        // A very soft shadow on the page beneath: it sits on the paper.
        cloth.layer.shadowColor = UIColor.black.cgColor
        cloth.layer.shadowOpacity = 0.25
        cloth.layer.shadowRadius = 1.2
        cloth.layer.shadowOffset = CGSize(width: 0, height: 0.8)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { Self.size }

    override func layoutSubviews() {
        super.layoutSubviews()
        cloth.bounds = CGRect(origin: .zero, size: bounds.size)
        cloth.center = CGPoint(x: bounds.midX, y: 0) // the anchor is its top edge
    }

    /// The picture, from the web shell's folder (both apps carry it).
    private static func picture(dark: Bool) -> UIImage? {
        let name = "ribbon-\(dark ? "dark" : "light")@3x"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Web/ribbon"),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data, scale: 3)
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
