import Combine
import SwiftUI
import UIKit

/// The overlay on iOS, shared by the book reader and the PDF reader. Three
/// small pieces of glass float over the page, with no panel behind them:
/// - top left: a round Close button, and the title and chapter;
/// - top right: Contents, Bookmark, Layout, Aa and Settings in one group;
/// - bottom: where the reader is, and the slider between ‹ and ›.
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
    /// The group of buttons at the top right.
    let buttons: UIHostingController<OverlayBar>
    private var pieces: [UIView] { [bottom.view, top.view, buttons.view] }
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
        for host in [bottom, top, buttons] as [UIViewController] {
            (host as? UIHostingController<OverlayBar>)?.sizingOptions = [.intrinsicContentSize]
            (host as? UIHostingController<ReaderTopControls>)?.sizingOptions = [.intrinsicContentSize]
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.alpha = 0
            host.view.isHidden = true
            owner.addChild(host)
            root.addSubview(host.view)
            host.didMove(toParent: owner)
        }
        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bottom.view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottom.view.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 10),
            bottom.view.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -10),
            bottom.view.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -20).withPriority(.defaultHigh),
            bottom.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -6),

            top.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            top.view.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            // The title gives way (it truncates) before the buttons do.
            top.view.trailingAnchor.constraint(lessThanOrEqualTo: buttons.view.leadingAnchor, constant: -8),

            buttons.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            buttons.view.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
        ])
        top.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.view.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// Light or dark controls, whatever the reader's own style is. The PDF
    /// reader asks for light: its pages are white in every theme, and the
    /// controls often sit over them.
    func setInterfaceStyle(_ style: UIUserInterfaceStyle) {
        for host in [bottom, buttons] as [UIViewController] { host.overrideUserInterfaceStyle = style }
        top.overrideUserInterfaceStyle = style
    }

    func toggle() { setVisible(!isVisible) }

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

extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

extension UIViewController {
    /// The settings sheet (gear button), shared by both readers.
    func presentReaderSettings(isFixedLayout: Bool, chrome: ReaderChrome?) {
        chrome?.stopHideTimer()
        let sheet = UIHostingController(rootView: ReaderSettingsView(isFixedLayout: isFixedLayout) { [weak self, weak chrome] in
            self?.dismiss(animated: true) { chrome?.restartHideTimer() }
        })
        sheet.modalPresentationStyle = .pageSheet
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        present(sheet, animated: true)
    }
}
