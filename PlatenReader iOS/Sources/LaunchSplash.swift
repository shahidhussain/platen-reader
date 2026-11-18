import Combine
import SwiftUI
import UIKit

/// The start-up animation. It begins exactly where the launch screen
/// (LaunchScreen.storyboard) leaves off: the open-book mark, alone, where it
/// will sit over the name. Then the mark gives a small springy nod, the name
/// rises in beneath it and the version line fades in. If Platen is going
/// straight back to a book, the splash stays, with the loading bar and a
/// line saying what is happening, until the book's first page is on screen;
/// then it grows a little and fades, revealing the page. Otherwise, after
/// about a second, the mark, name and version glide to where the welcome
/// screen has them, and the splash fades onto it (or simply fades, if the
/// home screen is a folder's covers).
///
/// iOS shows the launch screen, a still picture, until the app's own code
/// runs; nothing can move before then. Making that picture the animation's
/// first frame means there is no blank screen and no jump. The animation is
/// UIKit's (Core Animation, drawn outside the app's main thread), so the
/// work of opening a book at the same time cannot make it stutter; a
/// SwiftUI animation here was drawn on the busy main thread and came out as
/// a jerk at the end.
///
/// It has a window of its own above the app's (a reader presented at launch
/// would otherwise cover it), which goes once it has faded.
@MainActor
final class LaunchSplash {
    /// Shared with LaunchScreen.storyboard: change one, change the other.
    private enum Layout {
        static let markSize: CGFloat = 64
        static let spacing: CGFloat = 16
        static let nameSize: CGFloat = 34
    }

    private var window: UIWindow?
    private let root = SplashRoot()
    private let mark = UIImageView()
    private let name = UILabel()
    private let version = UILabel()
    private var cancellables: Set<AnyCancellable> = []
    private var gone = false
    /// True while a book is opening under the splash (`follow`).
    private var following = false
    /// The text lines on the book's pages (`writeOnPages`).
    private var lineLayers: [CAShapeLayer] = []

    init(in scene: UIWindowScene) {
        let view = root.view!
        view.backgroundColor = .systemBackground

        // As the launch screen: the mark over the name, centred together.
        mark.image = UIImage(systemName: "book",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.markSize, weight: .light))
        mark.tintColor = .secondaryLabel
        mark.contentMode = .scaleAspectFit
        mark.setContentHuggingPriority(.defaultHigh, for: .vertical)
        mark.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        name.text = "Platen Reader"
        name.font = .systemFont(ofSize: Layout.nameSize, weight: .semibold)
        name.textColor = .label
        name.textAlignment = .center
        name.alpha = 0
        let stack = UIStackView(arrangedSubviews: [mark, name])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Layout.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // Below the pair, out of the centring: the version.
        version.text = AppVersion.line
        version.font = .preferredFont(forTextStyle: .footnote)
        version.adjustsFontForContentSizeCategory = true
        version.textColor = .secondaryLabel
        version.textAlignment = .center
        version.alpha = 0
        version.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(version)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            version.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            version.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 6),
        ])
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Platen Reader"
        view.accessibilityValue = AppVersion.line

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.rootViewController = root
        window.isHidden = false // shown, but the app's window becomes key
        self.window = window
        // Laid out now, so the first frame matches the launch screen, and
        // the animation set off at once: it plays out on its own while the
        // app gets on with starting up.
        view.layoutIfNeeded()
        play()
    }

    private func play() {
        writeOnPages()
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.3, delay: 0.05, options: [.allowUserInteraction]) {
                self.name.alpha = 1
                self.version.alpha = 1
            }
            return
        }
        // The mark nods: a small grow, then settles back with a spring.
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            self.mark.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
        } completion: { _ in
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0) {
                self.mark.transform = .identity
            }
        }
        // The name rises in beneath it.
        name.transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animate(withDuration: 0.55, delay: 0.08, usingSpringWithDamping: 0.75, initialSpringVelocity: 0) {
            self.name.transform = .identity
            self.name.alpha = 1
        }
        // Then the version, quietly.
        UIView.animate(withDuration: 0.3, delay: 0.3, options: [.curveEaseOut]) {
            self.version.alpha = 1
        }
    }

    /// Platen's loading throbber: lines of text write themselves across the
    /// book's pages, the left page and then the right, line by line, as a
    /// reader's eye goes; they rest a moment, fade, and start again, for as
    /// long as the splash is up. Under Reduce Motion the lines only fade in
    /// and out.
    ///
    /// The lines are drawn over the symbol's picture, as curves that follow
    /// its pages. Each page of the "book" symbol is an arch: its top and
    /// bottom edges rise towards the middle of the page and fall towards the
    /// spine and the outer edge. Measured from the symbol (its picture is
    /// 85 × 68 at this size), the insides of the left page's edges are close
    /// to the parabolas y = 9.6 + 0.0285 (x − 26)² (top) and
    /// y = 51.45 + 0.0212 (x − 26)² (bottom), between x 12 and 40.5; the
    /// right page is its mirror image (x → 85 − x). A line of text a fraction
    /// `t` of the way down the page lies that fraction of the way from one
    /// edge to the other, so it bends a little less than the top and a little
    /// more than the bottom, as text on an open book's page does. Everything
    /// is in the picture's units, scaled to the picture on screen, so the
    /// lines follow it whatever its exact size.
    private func writeOnPages() {
        guard let image = mark.image else { return }
        // The whole picture in the mark's coordinates: the image view is
        // the size of the symbol's alignment rectangle, and the picture
        // reaches past it by the alignment insets.
        let insets = image.alignmentRectInsets
        let picture = mark.bounds.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left,
                                                         bottom: -insets.bottom, right: -insets.right))
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: picture.minX + picture.width * x / 85, y: picture.minY + picture.height * y / 68)
        }
        // A line's height on the left page at x, `t` of the way down; and
        // its slope there (for the curve's control point).
        let peak: CGFloat = 26
        func height(_ x: CGFloat, _ t: CGFloat) -> CGFloat {
            let d = (x - peak) * (x - peak)
            return (9.6 + 0.0285 * d) * (1 - t) + (51.45 + 0.0212 * d) * t
        }
        func slope(_ x: CGFloat, _ t: CGFloat) -> CGFloat {
            2 * (x - peak) * (0.0285 * (1 - t) + 0.0212 * t)
        }
        /// One line on the left page from x0 to x1, as a quadratic Bézier
        /// curve, which draws a parabola exactly: its control point is where
        /// the tangents at the two ends meet, halfway across.
        func leftLine(_ x0: CGFloat, _ x1: CGFloat, _ t: CGFloat) -> (CGPoint, CGPoint, CGPoint) {
            let y0 = height(x0, t)
            let mid = (x0 + x1) / 2
            return (CGPoint(x: x0, y: y0), CGPoint(x: mid, y: y0 + slope(x0, t) * (mid - x0)),
                    CGPoint(x: x1, y: height(x1, t)))
        }

        // Four lines a page (how far down each sits), the last one short, as
        // at a paragraph's end. Each runs from the side text starts on: the
        // outer edge on the left page, the spine on the right.
        let rows: [CGFloat] = [0.31, 0.46, 0.62, 0.77]
        let from: CGFloat = 16.5, to: CGFloat = 36.5
        var lines: [UIBezierPath] = []
        for rightPage in [false, true] {
            for (i, t) in rows.enumerated() {
                let short = i == rows.count - 1
                // On the right page text starts at the spine, which mirrors
                // to the left page's inner end.
                let (x0, x1) = rightPage ? (to, short ? to - (to - from) * 0.55 : from)
                                         : (from, short ? from + (to - from) * 0.55 : to)
                let (a, c, b) = leftLine(x0, x1, t)
                func place(_ p: CGPoint) -> CGPoint { point(rightPage ? 85 - p.x : p.x, p.y) }
                let path = UIBezierPath()
                path.move(to: place(a))
                path.addQuadCurve(to: place(b), controlPoint: place(c))
                lines.append(path)
            }
        }

        let colour = UIColor.secondaryLabel.resolvedColor(with: mark.traitCollection).cgColor
        let reduce = UIAccessibility.isReduceMotionEnabled
        let cycle: CFTimeInterval = 2.2
        // Each cycle starts with the page blank for `lead` seconds (the
        // first time, while the mark nods). The animations begin when the
        // splash is first drawn (a begin time of 0), however long start-up
        // keeps that waiting, so the writing is always seen from its start.
        let lead = 0.3
        for (i, path) in lines.enumerated() {
            let layer = CAShapeLayer()
            layer.path = path.cgPath
            layer.strokeColor = colour
            layer.fillColor = nil // a curve has an inside, filled black by default
            layer.lineWidth = 2
            layer.lineCap = .round
            layer.opacity = 0.75
            mark.layer.addSublayer(layer)
            lineLayers.append(layer)

            let group = CAAnimationGroup()
            if reduce {
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 0.75, 0.75, 0]
                fade.keyTimes = [0, 0.3, 0.75, 1]
                group.animations = [fade]
                group.duration = cycle * 1.2
            } else {
                // Written in 0.12 s, one after another; all rest, then fade
                // together, and the page is blank briefly before the next.
                let begins = lead + Double(i) * 0.15
                let write = CAKeyframeAnimation(keyPath: "strokeEnd")
                write.values = [0, 0, 1, 1]
                write.keyTimes = [0, begins / cycle, (begins + 0.12) / cycle, 1].map { NSNumber(value: $0) }
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0.75, 0.75, 0, 0]
                fade.keyTimes = [0, (lead + 1.45) / cycle, (lead + 1.7) / cycle, 1].map { NSNumber(value: $0) }
                group.animations = [write, fade]
                group.duration = cycle
                layer.strokeEnd = 0
            }
            group.repeatCount = .infinity
            layer.add(group, forKey: "write")
        }
    }

    /// Calls `action` once the splash is on screen (its first frame handed
    /// to the screen), for the rest of start-up to begin.
    func whenShown(_ action: @escaping () -> Void) {
        var done = false
        let once = {
            guard !done else { return }
            done = true
            action()
        }
        root.onAppear = {
            // Hand the first frame over now, then carry on in the next turn
            // of the run loop, so nothing that follows can hold it back.
            CATransaction.flush()
            DispatchQueue.main.async(execute: once)
        }
        // Should the splash never appear (it always does), start anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: once)
    }

    /// No book to wait for: go once the animation has played.
    func finishSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.finish() }
    }

    /// A book is opening: show its progress, and go when its first page is
    /// on screen (but not before the animation has played).
    func follow(_ state: ReaderState) {
        following = true
        let progress = UIHostingController(rootView: OpeningProgressView(state: state))
        progress.view.backgroundColor = .clear
        progress.view.translatesAutoresizingMaskIntoConstraints = false
        progress.view.alpha = 0
        root.addChild(progress)
        root.view.addSubview(progress.view)
        NSLayoutConstraint.activate([
            progress.view.centerXAnchor.constraint(equalTo: root.view.centerXAnchor),
            progress.view.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 22),
        ])
        progress.didMove(toParent: root)
        UIView.animate(withDuration: 0.25, delay: 0.2) { progress.view.alpha = 1 }

        let shown = Date()
        state.$opening
            .filter { $0 == nil }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                let wait = max(0, 0.9 - Date().timeIntervalSince(shown))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self?.finish() }
            }
            .store(in: &cancellables)
        // Never stay up for good (a book that cannot be opened says so in
        // the reader, under the splash).
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish() }
    }

    func finish() {
        guard !gone else { return }
        gone = true
        let view = root.view!
        view.isUserInteractionEnabled = false
        let reduce = UIAccessibility.isReduceMotionEnabled
        if !following, !reduce, glideToWelcome() { return }
        // In two steps: the mark and words go first (growing a little), then
        // the plain background, revealing what is underneath. Fading all at
        // once showed the splash's title over the home screen's own, a
        // little apart, for a moment: a muddle.
        let content = view.subviews
        UIView.animate(withDuration: reduce ? 0.15 : 0.2, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            for subview in content {
                subview.alpha = 0
                if !reduce { subview.transform = CGAffineTransform(scaleX: 1.06, y: 1.06) }
            }
        }
        UIView.animate(withDuration: 0.25, delay: reduce ? 0.1 : 0.15, options: [.curveEaseInOut]) {
            view.alpha = 0
        } completion: { _ in
            self.window?.isHidden = true
            self.window = nil
        }
    }

    /// Ends on the welcome screen: the mark, name and version glide to where
    /// the welcome has its own (the mark shrinking to the welcome's smaller
    /// one, its lines of text fading), and then the splash fades, showing
    /// the same things in the same places, and the rest of the welcome
    /// around them. False if the welcome is not on screen.
    private func glideToWelcome() -> Bool {
        let targets = WelcomeLayout.current
        guard let window, let markTarget = targets.mark, markTarget.width > 0 else { return false }
        let view = root.view!
        view.isUserInteractionEnabled = false

        /// The transform that puts `item` over `target` (window
        /// coordinates), scaled to the target's width if `scale`.
        func transform(_ item: UIView, to target: CGRect?, scale: Bool) -> CGAffineTransform? {
            guard let target, target.width > 0 else { return nil }
            let frame = item.convert(item.bounds, to: window)
            let factor = scale ? target.width / max(frame.width, 1) : 1
            return CGAffineTransform(translationX: target.midX - frame.midX, y: target.midY - frame.midY)
                .scaledBy(x: factor, y: factor)
        }
        // Settled first (the nod may still be springing), so the sums use
        // the mark at its own size.
        for item in [mark, name, version] { item.layer.removeAllAnimations(); item.transform = .identity }
        let moves: [(UIView, CGAffineTransform)] = [
            (mark, transform(mark, to: markTarget, scale: true)),
            (name, transform(name, to: targets.title, scale: true)),
            (version, transform(version, to: targets.version, scale: false)),
        ].compactMap { item, move in move.map { (item, $0) } }

        // The lines fade from wherever they have got to.
        for layer in lineLayers {
            if let now = layer.presentation() {
                layer.strokeEnd = now.strokeEnd
                layer.opacity = now.opacity
            }
            layer.removeAllAnimations()
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        for layer in lineLayers { layer.opacity = 0 }
        CATransaction.commit()

        UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            for (item, move) in moves {
                item.transform = move
                item.alpha = 1
            }
        } completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
                view.alpha = 0
            } completion: { _ in
                self.window?.isHidden = true
                self.window = nil
            }
        }
        return true
    }
}

/// The splash's root, which says when it has first appeared.
private final class SplashRoot: UIViewController {
    var onAppear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
        onAppear = nil
    }
}
