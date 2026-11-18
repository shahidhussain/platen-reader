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
