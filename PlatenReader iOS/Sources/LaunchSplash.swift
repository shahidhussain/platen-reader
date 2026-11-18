import Combine
import SwiftUI
import UIKit

/// The start-up animation. It begins exactly where the launch screen
/// (LaunchScreen.storyboard) leaves off: the open-book mark, alone, where it
/// will sit over the name. Then the mark gives a small springy nod, the name
/// rises in beneath it and the version line fades in. If Platen is going
/// straight back to a book, the splash stays, with the loading bar and a
/// line saying what is happening, until the book's first page is on screen;
/// then it grows a little and fades, revealing the page. Otherwise it fades
/// after about a second, onto the home screen.
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
    private let root = UIViewController()
    private let mark = UIImageView()
    private let name = UILabel()
    private let version = UILabel()
    private var cancellables: Set<AnyCancellable> = []
    private var gone = false

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
    /// The lines are drawn over the symbol's picture, placed by where its
    /// pages are within it (measured from the "book" symbol: the picture is
    /// 85 × 68 at this size, the pages' insides run from x 12 to 40.5 and 44.5
    /// to 77, and from y 16 to 52), as fractions, so they follow the picture
    /// whatever its exact size.
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
        // Four lines a page, the last one short, as at a paragraph's end.
        let rows: [CGFloat] = [22.5, 29, 35.5, 42]
        let pages: [(from: CGFloat, to: CGFloat)] = [(16.5, 36.5), (48.5, 72.5)]
        var lines: [(CGPoint, CGPoint)] = []
        for page in pages {
            for (i, y) in rows.enumerated() {
                let end = i == rows.count - 1 ? page.from + (page.to - page.from) * 0.55 : page.to
                lines.append((point(page.from, y), point(end, y)))
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
        for (i, line) in lines.enumerated() {
            let layer = CAShapeLayer()
            let path = UIBezierPath()
            path.move(to: line.0)
            path.addLine(to: line.1)
            layer.path = path.cgPath
            layer.strokeColor = colour
            layer.lineWidth = 2
            layer.lineCap = .round
            layer.opacity = 0.75
            mark.layer.addSublayer(layer)

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

    /// No book to wait for: go once the animation has played.
    func finishSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.finish() }
    }

    /// A book is opening: show its progress, and go when its first page is
    /// on screen (but not before the animation has played).
    func follow(_ state: ReaderState) {
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
}
