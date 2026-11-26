import Combine
import SwiftUI
import UIKit

/// The overlay on iOS, shared by the book reader and the PDF reader: two
/// bars across the screen, in the way of Apple Books.
/// - At the top: Close, and the book's title with the chapter under it.
/// - At the bottom: where the reader is (or "Back to …" after a jump), the
///   slider, then one row of buttons: Contents, Bookmark, Layout and Aa.
/// Each bar sits on a band of the page's own colour that fades into the page
/// (`PageBand`), so no text ever shows behind a control. Pages turn by
/// tapping or swiping the page's edges. The buttons and the slider are the
/// Mac bar's own (Shared/OverlayViews.swift). A centre tap shows and hides
/// both bars; they also hide after 4 seconds unless they are in use.
///
/// The reader that owns this keeps the status bar and home indicator in step
/// by reading `isVisible` (see `prefersStatusBarHidden`).
final class ReaderChrome {
    private weak var owner: UIViewController?
    let state: ReaderState
    /// The bottom bar.
    let bottom: UIHostingController<ReaderBottomBar>
    /// The top bar: Close, and the title.
    let top: UIHostingController<ReaderTopBar>
    /// How far each bar's controls sit from the screen's edges (the safe
    /// area, adjusted in `updateEdges`): the bars themselves, and their
    /// bands, reach the edges.
    let insets = ChromeInsets()
    private var pieces: [UIView] { [bottom.view, top.view] }
    private(set) var isVisible = false
    private var hideTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Called after the overlay is shown or hidden.
    var onVisibilityChanged: ((Bool) -> Void)?

    /// - Parameter sidebarClosed: called when the contents popover closes
    ///   (the reader clears search highlights).
    init(owner: UIViewController, state: ReaderState, actions: OverlayActions, sidebarActions: ContentsActions,
         close: @escaping () -> Void, readAloud: ReadAloudButtonActions? = nil, sidebarClosed: @escaping () -> Void) {
        self.owner = owner
        self.state = state
        // The speaker button is in the bottom bar, in the middle of its
        // row, with the other things a reader does to the book; the top
        // bar is Close and the title (reader's request, 25 Nov 2026).
        var actions = actions
        if let readAloud { actions.readAloud = readAloud }
        bottom = UIHostingController(rootView: ReaderBottomBar(
            state: state, insets: insets,
            bar: OverlayBar(state: state, actions: actions, sidebarActions: sidebarActions, part: .bottomBar)))
        top = UIHostingController(rootView: ReaderTopBar(state: state, insets: insets, close: close))

        // When the contents popover closes, the hide countdown starts again.
        state.$sidebarVisible
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] open in
                guard !open else { return }
                DispatchQueue.main.async {
                    sidebarClosed()
                    self?.restartHideTimer()
                }
            }
            .store(in: &cancellables)
        state.$overlayPopoverOpen
            .removeDuplicates()
            .sink { [weak self] open in if !open { self?.restartHideTimer() } }
            .store(in: &cancellables)
    }

    /// Where the top bar's buttons and title end (the band's fade below them
    /// left out), in the reader's view.
    var headerBottom: CGFloat { max(0, top.view.frame.maxY - 20) }

    /// Adds the bars to the reader's view, hidden.
    func install(in root: UIView) {
        guard let owner else { return }
        // The bars take their height from the SwiftUI content and reach the
        // screen's edges; their content keeps clear of the Dynamic Island
        // and the home indicator by `insets` (a hosting view would otherwise
        // pad its content by the safe area itself, twice over).
        bottom.sizingOptions = [.intrinsicContentSize]
        top.sizingOptions = [.intrinsicContentSize]
        bottom.safeAreaRegions = []
        top.safeAreaRegions = []
        for host in [bottom, top] as [UIViewController] {
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.alpha = 0
            host.view.isHidden = true
            owner.addChild(host)
            root.addSubview(host.view)
            host.didMove(toParent: owner)
        }
        NSLayoutConstraint.activate([
            top.view.topAnchor.constraint(equalTo: root.topAnchor),
            top.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottom.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
    }

    /// Places the controls for the screen's shape. In portrait the safe area
    /// keeps them clear of the Dynamic Island and the home indicator. On an
    /// iPhone in landscape its top is the screen's edge, which put the top
    /// controls almost against it, and its bottom leaves a deep strip for
    /// the home indicator, which held the bottom controls high: there, the
    /// top controls sit 14 points down, and the bottom ones lower. Called by
    /// the reader whenever its layout changes.
    func updateEdges(in root: UIView) {
        let safe = root.safeAreaInsets
        let landscapePhone = root.bounds.width > root.bounds.height && safe.top < 20
        let edges = EdgeInsets(top: landscapePhone ? 14 : safe.top + 2,
                               leading: safe.left + 12,
                               bottom: landscapePhone ? max(4, safe.bottom - 9) : max(safe.bottom, 8),
                               trailing: safe.right + 12)
        if insets.edges != edges { insets.edges = edges }
    }

    /// Light or dark controls, whatever the reader's own style is. The PDF
    /// reader asks for light: its pages are white in every theme, and the
    /// controls often sit over them.
    func setInterfaceStyle(_ style: UIUserInterfaceStyle) {
        bottom.overrideUserInterfaceStyle = style
        top.overrideUserInterfaceStyle = style
    }

    func toggle() { setVisible(!isVisible) }

    // MARK: - Notices

    private var notice: UIView?
    private var noticeTimer: Timer?

    /// A short message in the middle of the page that fades away, such as
    /// "End of book" when a turn finds nowhere to go. VoiceOver reads it.
    func showNotice(_ text: String) {
        guard let owner, let root = owner.view else { return }
        noticeTimer?.invalidate()
        notice?.removeFromSuperview()
        let host = UIHostingController(rootView: NoticeView(text: text))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = [.intrinsicContentSize]
        host.overrideUserInterfaceStyle = top.overrideUserInterfaceStyle
        root.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        notice = host.view
        let fade = UIAccessibility.isReduceMotionEnabled ? 0 : 0.2
        host.view.alpha = 0
        UIView.animate(withDuration: fade) { host.view.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: text)
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: fade, animations: { host.view.alpha = 0 }) { _ in
                host.view.removeFromSuperview()
                if self?.notice === host.view { self?.notice = nil }
            }
        }
    }

    func setVisible(_ visible: Bool) {
        // Popovers hang from the overlay, so they go with it.
        if !visible && state.sidebarVisible { state.sidebarVisible = false }
        isVisible = visible
        let views = pieces
        if visible { views.forEach { $0.isHidden = false } }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15, animations: {
            views.forEach { $0.alpha = visible ? 1 : 0 }
            self.owner?.setNeedsStatusBarAppearanceUpdate()
        }, completion: { _ in
            // Hidden views take no taps, so the page underneath gets them.
            views.forEach { $0.isHidden = !self.isVisible }
        })
        owner?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        onVisibilityChanged?(visible)
        if visible { restartHideTimer() } else { hideTimer?.invalidate() }
    }

    /// When nothing could be opened: only the Close button, kept on screen.
    func showCloseOnly() {
        hideTimer?.invalidate()
        bottom.view.removeFromSuperview()
        top.view.isHidden = false
        top.view.alpha = 1
        isVisible = true
        owner?.setNeedsStatusBarAppearanceUpdate()
    }

    /// Hide the overlay after 4 s without use, unless a popover or a sheet
    /// is open (closing them restarts this).
    func restartHideTimer() {
        hideTimer?.invalidate()
        guard isVisible, !UIAccessibility.isVoiceOverRunning else { return }
        #if DEBUG
        // Testing: PLATEN_KEEP_CONTROLS keeps the controls up (DebugHooks).
        if ProcessInfo.processInfo.environment["PLATEN_KEEP_CONTROLS", default: ""].isEmpty == false { return }
        #endif
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, self.isVisible else { return }
            if self.state.overlayPopoverOpen || self.state.sidebarVisible || self.owner?.presentedViewController != nil { return }
            self.setVisible(false)
        }
    }

    func stopHideTimer() { hideTimer?.invalidate() }
}

/// How far the bars' controls sit from the screen's edges (ReaderChrome's
/// `updateEdges`).
final class ChromeInsets: ObservableObject {
    @Published var edges = EdgeInsets(top: 54, leading: 12, bottom: 34, trailing: 12)
}

/// The top bar on iOS: Close at the left, read aloud at the right, and the
/// book's title with the chapter under it in the middle, on a band of the page's colour that
/// reaches up behind the status bar.
struct ReaderTopBar: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var insets: ChromeInsets
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close Book"))

            // Beside Close, left-aligned: with one button only, a centred
            // title sat oddly apart from it.
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !state.chapter.isEmpty {
                    Text(state.chapter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
            .accessibilityElement(children: .combine)
        }
        .padding(.top, insets.edges.top)
        .padding(.leading, insets.edges.leading)
        .padding(.trailing, insets.edges.trailing)
        .padding(.bottom, 20) // the band's fade, below the controls
        .background {
            // In the colour of what is behind it, as see-through as the title
            // can stand (GlowBand.backing): none at all where it reads as it is.
            // The fade (an S-curve) reaches 28 points past the bar, below
            // its touch area.
            PageBand(colour: state.topBandColour ?? state.pageColour, edge: .top, fade: 48)
                .padding(.bottom, -28)
                .opacity(state.topBandOpacity)
                .animation(.easeInOut(duration: 0.35), value: state.topBandColour)
                .animation(.easeInOut(duration: 0.3), value: state.topBandOpacity)
        }
    }
}

/// The bottom bar on iOS (OverlayBar's `.bottomBar`), on a band of the
/// page's colour that reaches down behind the home indicator.
struct ReaderBottomBar: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var insets: ChromeInsets
    let bar: OverlayBar

    var body: some View {
        bar
            .padding(.top, 24) // the band's fade, above the controls
            .padding(.leading, insets.edges.leading + 8)
            .padding(.trailing, insets.edges.trailing + 8)
            .padding(.bottom, insets.edges.bottom)
            .frame(maxWidth: .infinity)
            .background {
                PageBand(colour: state.bottomBandColour ?? state.pageColour, edge: .bottom, fade: 52)
                    .padding(.top, -28)
                    .opacity(state.bottomBandOpacity)
                    .animation(.easeInOut(duration: 0.35), value: state.bottomBandColour)
                    .animation(.easeInOut(duration: 0.3), value: state.bottomBandOpacity)
            }
    }
}

/// The notice's look: a capsule of glass with one line of text.
struct NoticeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .frame(minHeight: 40)
            .overlaySurface(Capsule())
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

