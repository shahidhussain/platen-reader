import Combine
import SwiftUI
import UIKit

/// The overlay on iOS, shared by the book reader and the PDF reader. Three
/// small pieces of glass float over the page, with no panel behind them:
/// - top left: a round Close button, and the title and chapter;
/// - just above the slider, within reach of a thumb: at the left, the
///   favourite heart and the bookmark (marks that bring the reader back);
///   at the right, Contents, Layout and Aa (ways of viewing the book);
/// - bottom: the slider between ‹ and ›, and where the reader is below it.
/// The buttons and the slider are the Mac bar's own (Shared/OverlayViews.swift,
/// drawn in parts). A centre tap shows and hides them all; they also hide
/// after 4 seconds unless they are in use.
///
/// The reader that owns this keeps the status bar and home indicator in step
/// by reading `isVisible` (see `prefersStatusBarHidden`).
final class ReaderChrome {
    private weak var owner: UIViewController?
    let state: ReaderState
    /// The slider, at the bottom.
    let bottom: UIHostingController<OverlayBar>
    /// Close, and the title.
    let top: UIHostingController<ReaderTopControls>
    /// The group of buttons at the bottom right, above the slider.
    let buttons: UIHostingController<OverlayBar>
    /// The heart and the bookmark, at the bottom left, above the slider.
    let marks: UIHostingController<OverlayBar>
    private var pieces: [UIView] { [bottom.view, top.view, buttons.view, marks.view] }
    private(set) var isVisible = false
    private var hideTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Called after the overlay is shown or hidden.
    var onVisibilityChanged: ((Bool) -> Void)?

    /// - Parameter sidebarClosed: called when the contents popover closes
    ///   (the reader clears search highlights).
    init(owner: UIViewController, state: ReaderState, actions: OverlayActions, sidebarActions: ContentsActions,
         close: @escaping () -> Void, sidebarClosed: @escaping () -> Void) {
        self.owner = owner
        self.state = state
        bottom = UIHostingController(rootView: OverlayBar(state: state, actions: actions, sidebarActions: sidebarActions,
                                                          part: .scrubber))
        top = UIHostingController(rootView: ReaderTopControls(state: state, close: close))
        buttons = UIHostingController(rootView: OverlayBar(state: state, actions: actions, sidebarActions: sidebarActions,
                                                           part: .buttons))
        marks = UIHostingController(rootView: OverlayBar(state: state, actions: actions, sidebarActions: sidebarActions,
                                                         part: .marks))

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

    /// Adds the pieces to the reader's view, hidden.
    func install(in root: UIView) {
        guard let owner else { return }
        // The hosting views take their size from the SwiftUI content, and let
        // the page show around it.
        for host in [bottom, top, buttons, marks] as [UIViewController] {
            (host as? UIHostingController<OverlayBar>)?.sizingOptions = [.intrinsicContentSize]
            (host as? UIHostingController<ReaderTopControls>)?.sizingOptions = [.intrinsicContentSize]
            // Their places already allow for the safe areas (updateEdges);
            // a hosting view would otherwise pad its content by however much
            // it overlaps them, undoing the placing.
            (host as? UIHostingController<OverlayBar>)?.safeAreaRegions = []
            (host as? UIHostingController<ReaderTopControls>)?.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.alpha = 0
            host.view.isHidden = true
            owner.addChild(host)
            root.addSubview(host.view)
            host.didMove(toParent: owner)
        }
        let safe = root.safeAreaLayoutGuide
        topEdge = top.view.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4)
        bottomEdge = bottom.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        NSLayoutConstraint.activate([topEdge!, bottomEdge!])
        NSLayoutConstraint.activate([
            bottom.view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottom.view.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 10),
            bottom.view.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -10),
            bottom.view.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -20).withPriority(.defaultHigh),
            // Not too wide on an iPad, so the buttons stay near the slider.
            bottom.view.widthAnchor.constraint(lessThanOrEqualToConstant: 760),

            top.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            top.view.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -12),

            // Right-aligned with the › button, just above it.
            buttons.view.trailingAnchor.constraint(equalTo: bottom.view.trailingAnchor),
            buttons.view.bottomAnchor.constraint(equalTo: bottom.view.topAnchor, constant: -8),
            // Left-aligned with the ‹ button, level with the others.
            marks.view.leadingAnchor.constraint(equalTo: bottom.view.leadingAnchor),
            marks.view.bottomAnchor.constraint(equalTo: buttons.view.bottomAnchor),
        ])
        // A long title truncates rather than running off the screen.
        top.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// The top and bottom controls' distance from the safe area's edges.
    private var topEdge: NSLayoutConstraint?
    private var bottomEdge: NSLayoutConstraint?

    /// Places the top and bottom controls for the screen's shape. In
    /// portrait the safe area keeps them clear of the Dynamic Island and the
    /// home indicator. On an iPhone in landscape its top is the screen's
    /// edge, which put the top controls almost against it, and its bottom
    /// leaves a deep strip for the home indicator, which held the bottom
    /// controls high: there, the top controls sit 14 points down, and the
    /// bottom ones lower, the location line just clear of the indicator.
    /// Called by the reader whenever its layout changes.
    func updateEdges(in root: UIView) {
        let insets = root.safeAreaInsets
        let landscapePhone = root.bounds.width > root.bounds.height && insets.top < 20
        let top: CGFloat = landscapePhone ? max(4, 14 - insets.top) : 4
        let bottom: CGFloat = landscapePhone ? max(0, insets.bottom - 9) : 0
        if topEdge?.constant != top { topEdge?.constant = top }
        if bottomEdge?.constant != bottom { bottomEdge?.constant = bottom }
    }

    /// Light or dark controls, whatever the reader's own style is. The PDF
    /// reader asks for light: its pages are white in every theme, and the
    /// controls often sit over them.
    func setInterfaceStyle(_ style: UIUserInterfaceStyle) {
        for host in [bottom, buttons, marks] as [UIViewController] { host.overrideUserInterfaceStyle = style }
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
        buttons.view.removeFromSuperview()
        marks.view.removeFromSuperview()
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

/// The top of the overlay on iOS: a round Close button and the book's title
/// and chapter, floating at the top left (no navigation bar).
struct ReaderTopControls: View {
    @ObservedObject var state: ReaderState
    let close: () -> Void

    var body: some View {
        // One glass container, so the two pieces blend as the system's own
        // controls do (on iOS 26 and later).
        #if compiler(>=6.2) // the iOS 26 SDK (see GlassSurface.swift)
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 10) { controls }
        } else {
            controls
        }
        #else
        controls
        #endif
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .overlaySurface(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close Book"))

            if !state.title.isEmpty {
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
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .overlaySurface(Capsule())
                .accessibilityElement(children: .combine)
            }
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
