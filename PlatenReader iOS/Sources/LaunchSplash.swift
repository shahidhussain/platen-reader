import Combine
import SwiftUI
import UIKit

/// The start-up animation: the app's open-book mark grows in with a small
/// spring and the name rises beneath it, on the system's background (the
/// launch screen's own, so there is no flash). If Platen is going straight
/// back to a book, the splash stays, with the loading bar and a line saying
/// what is happening, until the book's first page is on screen; then it
/// grows a little and fades, revealing the page. Otherwise it fades after
/// about a second, onto the home screen.
///
/// It has a window of its own above the app's (a reader presented at launch
/// would otherwise cover it), which goes once it has faded.
@MainActor
final class LaunchSplash {
    private let host: UIHostingController<LaunchSplashView>
    private var window: UIWindow?
    private let model = LaunchSplashModel()
    private var cancellables: Set<AnyCancellable> = []
    private var gone = false

    init(in appWindow: UIWindow) {
        host = UIHostingController(rootView: LaunchSplashView(model: model))
        host.view.backgroundColor = .systemBackground
        guard let scene = appWindow.windowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.rootViewController = host
        window.isHidden = false // shown, but the app's window stays key
        self.window = window
    }

    /// No book to wait for: go once the animation has played.
    func finishSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.finish() }
    }

    /// A book is opening: show its progress, and go when its first page is
    /// on screen (but not before the animation has played).
    func follow(_ state: ReaderState) {
        model.state = state
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
        let view = host.view!
        view.isUserInteractionEnabled = false
        let reduce = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduce ? 0.2 : 0.35, delay: 0, options: [.curveEaseIn]) {
            view.alpha = 0
            if !reduce { view.transform = CGAffineTransform(scaleX: 1.06, y: 1.06) }
        } completion: { _ in
            self.window?.isHidden = true
            self.window = nil
        }
    }
}

@MainActor
final class LaunchSplashModel: ObservableObject {
    /// The book being opened at launch, if any (for its progress).
    @Published var state: ReaderState?
}

struct LaunchSplashView: View {
    @ObservedObject var model: LaunchSplashModel
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "book")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
                .scaleEffect(shown || reduceMotion ? 1 : 0.6)
                .opacity(shown ? 1 : 0)
            Text("Platen Reader")
                .font(.largeTitle.weight(.semibold))
                .offset(y: shown || reduceMotion ? 0 : 12)
                .opacity(shown ? 1 : 0)
            Group {
                if let state = model.state {
                    OpeningProgressView(state: state)
                        .transition(.opacity)
                }
            }
            .frame(height: 40)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) { shown = true }
        }
    }
}
