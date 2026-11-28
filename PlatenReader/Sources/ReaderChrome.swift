import AppKit
import Combine
import SwiftUI

/// The controls over the page on the Mac, shared by the book reader and the
/// PDF reader: the overlay bar at the bottom, the title bar floating at the
/// top, and the timer that hides them again. (The iOS app has its own
/// ReaderChrome, laid out for touch.)
///
/// Chrome is hidden by default. It shows on a centre click, C, or a menu
/// command, and hides after 4 seconds unless it is in use. The title bar
/// alone also shows while the pointer is at the top edge.
final class ReaderChrome {
    let state: ReaderState
    private weak var root: NSView?
    private let overlayHost: NSHostingView<OverlayBar>
    /// Backing for the title when it is shown, drawn by us so the real title
    /// bar can stay transparent (see `applyVisibility`): a strip of glass the
    /// height of the title bar (the bar material before macOS 26), so the
    /// title reads over the page, which shows softly through it.
    private let titleBacking: TitleGlassView
    private var titleBackingHeight: NSLayoutConstraint!
    /// The strip under the (transparent) title bar that drags the window.
    private let dragStrip = WindowDragView()

    /// Whether the overlay bar is showing.
    private(set) var isVisible = false
    private var titleBarVisible = false
    private var hideTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Called (a moment later) when the contents popover closes, however it
    /// was closed: by us, Esc or a click outside it.
    var onSidebarClosed: (() -> Void)?

    /// The overlay bar, for placing other views under it and for telling
    /// whether the pointer is over it.
    var overlayView: NSView { overlayHost }
    /// The title's backing, for placing other views under it.
    var titleBackingView: NSView { titleBacking }

    init(state: ReaderState, actions: OverlayActions, sidebarActions: ContentsActions) {
        self.state = state
        overlayHost = NSHostingView(rootView: OverlayBar(state: state, actions: actions, sidebarActions: sidebarActions))
        titleBacking = TitleGlassView(rootView: TitleGlass())

        state.$sidebarVisible
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] open in
                guard !open else { return }
                DispatchQueue.main.async {
                    self?.onSidebarClosed?()
                    self?.restartHideTimer()
                }
            }
            .store(in: &cancellables)

        // When the Aa popover closes, the hide countdown restarts.
        state.$overlayPopoverOpen
            .removeDuplicates()
            .sink { [weak self] open in if !open { self?.restartHideTimer() } }
            .store(in: &cancellables)
    }

    /// Adds the controls to the reader's view, above what is already there,
    /// hidden.
    func install(in root: NSView) {
        self.root = root
        overlayHost.translatesAutoresizingMaskIntoConstraints = false
        overlayHost.alphaValue = 0
        overlayHost.isHidden = true
        // The bar is glass itself, with nothing behind it: the page shows
        // through it, as through the title bar.
        root.addSubview(overlayHost)

        titleBacking.alphaValue = 0
        titleBacking.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleBacking)
        titleBackingHeight = titleBacking.heightAnchor.constraint(equalToConstant: 28)

        // The page fills the whole window, title bar area included, and
        // neither a web view nor a PDF view lets a click move the window.
        // This strip, the height of the title bar, gives the window back
        // its drag handle.
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(dragStrip)

        NSLayoutConstraint.activate([
            overlayHost.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            overlayHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            overlayHost.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            overlayHost.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            overlayHost.widthAnchor.constraint(equalToConstant: 720).withPriority(.defaultHigh),

            titleBacking.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBacking.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBacking.topAnchor.constraint(equalTo: root.topAnchor),
            titleBackingHeight,

            dragStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dragStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dragStrip.topAnchor.constraint(equalTo: root.topAnchor),
            dragStrip.heightAnchor.constraint(equalTo: titleBacking.heightAnchor),
        ])
    }

    // MARK: - Showing and hiding

    func toggle() { setVisible(!isVisible) }

    func setVisible(_ visible: Bool) {
        // Popovers hang from the overlay, so they go with it.
        if !visible && state.sidebarVisible { state.sidebarVisible = false }
        isVisible = visible
        titleBarVisible = visible
        applyVisibility(animated: true)
        if visible { restartHideTimer() } else { hideTimer?.invalidate() }
    }

    /// With no page to read (the book could not be opened), the title bar
    /// stays, so the window can be closed.
    func keepTitleBarVisible() {
        titleBarVisible = true
        applyVisibility(animated: false)
    }

    /// The pointer moved: reveal the title bar at the top edge, and keep the
    /// overlay up while the pointer is moving.
    func pointerMoved(to point: NSPoint) {
        guard let root else { return }
        let nearTop = point.y > root.bounds.height - 36
        if nearTop != titleBarVisible && !isVisible {
            titleBarVisible = nearTop
            applyVisibility(animated: true)
        }
        if isVisible { restartHideTimer() }
    }

    /// Hide the overlay after 4 s without pointer movement, unless the
    /// pointer is over it (it is being used).
    func restartHideTimer() {
        hideTimer?.invalidate()
        guard isVisible else { return }
        // With VoiceOver, the controls stay until dismissed (C or Esc):
        // VoiceOver users move through them without the pointer, and the
        // bar vanishing mid-way sent VoiceOver's cursor elsewhere.
        if NSWorkspace.shared.isVoiceOverEnabled { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, self.isVisible else { return }
            // Never hide from under an open popover; closing it restarts this.
            if self.state.overlayPopoverOpen || self.state.sidebarVisible { return }
            if let window = self.root?.window {
                let point = self.overlayHost.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.overlayHost.bounds.contains(point) { return self.restartHideTimer() }
            }
            self.setVisible(false)
        }
    }

    func applyVisibility(animated: Bool) {
        guard let root, let window = root.window else { return }
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0
        // The title bar container holds the window buttons and title. Fading
        // it (rather than hiding it) keeps the top edge draggable.
        //
        // The title bar always stays transparent: an opaque title bar takes
        // its height away from the content, so the page would shrink and the
        // text re-flow every time the controls appeared. Instead it floats
        // over the page, on a backing view of our own (as in IINA).
        let titleBar = window.standardWindowButton(.closeButton)?.superview?.superview
        window.titleVisibility = titleBarVisible ? .visible : .hidden
        window.titlebarAppearsTransparent = true
        let fullScreen = window.styleMask.contains(.fullScreen)
        titleBackingHeight.constant = max(0, root.bounds.height - window.contentLayoutRect.height)
        if isVisible { overlayHost.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            titleBar?.animator().alphaValue = titleBarVisible || fullScreen ? 1 : 0
            titleBacking.animator().alphaValue = titleBarVisible && !fullScreen ? 1 : 0
            overlayHost.animator().alphaValue = isVisible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Hidden views take no clicks, so the page underneath gets them.
            // VoiceOver also skips the bar while it is hidden, and sees every
            // control in it when shown.
            self.overlayHost.isHidden = !self.isVisible
        })
    }

    // MARK: - Contents popover

    /// Opens or closes the contents popover, on a tab if one is given. It
    /// hangs from the Contents button in the overlay, so the overlay is
    /// shown first.
    func setSidebar(visible: Bool, tab: ReaderState.SidebarTab? = nil) {
        if let tab { state.sidebarTab = tab }
        guard visible != state.sidebarVisible else { return }
        if visible {
            let wasHidden = !isVisible
            setVisible(true)
            // The popover needs its button on screen to hang from.
            DispatchQueue.main.asyncAfter(deadline: .now() + (wasHidden ? 0.05 : 0)) { [weak self] in
                self?.state.sidebarVisible = true
            }
        } else {
            state.sidebarVisible = false
        }
    }
}
