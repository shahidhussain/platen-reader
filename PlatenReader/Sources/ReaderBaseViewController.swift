import AppKit
import Combine
import PlatenCore
import SwiftUI
import os

/// What every book window has, whatever it shows: the controls over the page
/// (ReaderChrome), the quiet progress indicator, the failure message, the
/// theme, the reading keys, the click zones and the menu commands.
///
/// `ReaderViewController` (books, drawn by the web view) and
/// `PDFReaderViewController` (PDFs, drawn by PDFKit) are its two subclasses.
/// Each adds its page view, says how to carry out the commands
/// (`commands`), and overrides the few hooks below.
class ReaderBaseViewController: NSViewController, NSMenuItemValidation {
    let document: BookDocument
    let state: ReaderState
    let settings = ReaderSettings.shared

    private(set) var chrome: ReaderChrome!
    private(set) var spinner: NSProgressIndicator!
    private(set) var failureHost: NSView?
    var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?

    init(document: BookDocument, state: ReaderState) {
        self.document = document
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - For subclasses

    /// Carries out the commands: the book's session, or the PDF reader.
    var commands: ReaderCommands { fatalError("subclasses say how commands are carried out") }
    /// The view that draws the page; it has keyboard focus while reading.
    var pageView: NSView { fatalError("subclasses provide the page view") }
    /// The book is open, so its commands can be used.
    var isReady: Bool { false }
    /// A page is on screen (until then, a slow open shows the spinner).
    var hasShownPage: Bool { false }
    /// The title when nothing could be opened and no better one is known.
    var failureFallbackTitle: String { String(localized: "This book could not be opened.") }

    /// A setting or the system's appearance changed: re-style.
    func applySettings() { applyWindowTheme() }
    /// A key the subclass handles before the common ones (return true if so).
    func handleOwnKey(_ event: NSEvent) -> Bool { false }
    /// ↑ or ↓ in Scroll layout. Return false to leave it to the page view.
    func scrollByKey(lines: Int) -> Bool { false }

    // MARK: - View setup

    /// Call at the end of `loadView`, once the page view is in `root`: adds
    /// the controls and the progress indicator above it.
    func installChrome(in root: ReaderRootView) {
        root.onMouseMoved = { [weak self] point in self?.chrome.pointerMoved(to: point) }

        let chrome = ReaderChrome(
            state: state,
            actions: OverlayActions(commands: commands,
                                    toggleContents: { [weak self] in self?.toggleContents(nil) },
                                    interacted: { [weak self] in self?.chrome.restartHideTimer() }),
            sidebarActions: ContentsActions(commands: commands))
        chrome.onSidebarClosed = { [weak self] in
            guard let self else { return }
            // Search highlights are temporary: they go when the panel closes.
            self.commands.searchPanelClosed()
            self.view.window?.makeFirstResponder(self.pageView)
        }
        chrome.install(in: root)
        self.chrome = chrome

        // Quiet progress indicator, shown only if opening takes > 500 ms.
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Re-style whenever a global setting changes (in any window). The
        // extra hop lets the setting take its new value first.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.applySettings() } }
            .store(in: &cancellables)

        // Scroll or pages, chosen in any window, applies to every book and PDF.
        settings.$defaultFlow
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] flow in self?.commands.followFlowSetting(flow) }
            .store(in: &cancellables)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.hasShownPage, self.failureHost == nil else { return }
            self.spinner.startAnimation(nil)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(pageView)
        chrome.applyVisibility(animated: false)
        applySettings()
        // Follow the system's light/dark switch (including Auto at sunset).
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applySettings() }
        }
    }

    // MARK: - For the window controller

    /// The book's own title, once known (used for the window title).
    var bookTitle: String? { state.title.isEmpty ? nil : state.title }
    func savePositionNow() {}
    /// The window became the front one (see FrontWindowLayout).
    func reportLayoutToSettings() {}
    func fullScreenChanged() { chrome.applyVisibility(animated: false) }

    // MARK: - Failure

    /// Shows why the book could not be opened, in place of the page.
    func showFailure(_ error: Error) {
        spinner.stopAnimation(nil)
        guard failureHost == nil else { return }
        let host = NSHostingView(rootView: OpenFailureView(error: error, fallback: failureFallbackTitle))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        failureHost = host
        #if DEBUG
        DebugHooks.snapshotView(view, name: document.fileURL?.deletingPathExtension().lastPathComponent ?? "book")
        #endif
        // With no page to read, show the title bar so the window can be closed.
        chrome.keepTitleBarVisible()
    }

    // MARK: - Theme

    /// Decided from the system's appearance, not the window's: the window's
    /// own appearance is forced to match the theme, so it cannot tell us
    /// when macOS switches between Light and Dark.
    var currentTheme: Theme { settings.theme(for: NSApp.effectiveAppearance) }

    func applyWindowTheme() {
        let theme = currentTheme
        view.window?.backgroundColor = theme.nsBackground
        // Chrome and the overlay follow the page's lightness.
        view.window?.appearance = theme.appearance
    }

    var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - Clicks and keys

    /// Click zones: in paginated mode the left side goes back, the right
    /// side forward and the centre toggles the overlay. In scroll mode any
    /// click toggles the overlay.
    func handleClick(zone: ClickZone) {
        if state.flow == .scrolled || zone == .centre {
            chrome.toggle()
        } else {
            commands.turn(zone == .left ? .left : .right)
        }
    }

    /// Keys that are not menu shortcuts. Returns true if handled.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        // C shows or hides the controls (by character, so it follows the
        // keyboard layout).
        if !shift, event.charactersIgnoringModifiers?.lowercased() == "c" {
            chrome.toggle()
            return true
        }
        if handleOwnKey(event) { return true }
        switch event.keyCode {
        case 49: commands.turn(shift ? .prev : .next) // space
        case 121: commands.turn(.next) // page down
        case 116: commands.turn(.prev) // page up
        case 123: commands.turn(.left) // ←
        case 124: commands.turn(.right) // →
        case 125: // ↓
            if state.flow == .scrolled { return scrollByKey(lines: 1) }
            commands.turn(.next)
        case 126: // ↑
            if state.flow == .scrolled { return scrollByKey(lines: -1) }
            commands.turn(.prev)
        case 53: return handleEscape()
        default: return false
        }
        return true
    }

    /// Esc closes the panel, then the overlay, then leaves full screen.
    /// Returns false if there was nothing to close.
    func handleEscape() -> Bool {
        if state.sidebarVisible {
            chrome.setSidebar(visible: false)
        } else if chrome.isVisible {
            chrome.setVisible(false)
        } else if view.window?.styleMask.contains(.fullScreen) == true {
            view.window?.toggleFullScreen(nil)
        } else {
            return false
        }
        return true
    }

    // MARK: - Menu actions (found through the responder chain)

    @objc func previousPageLeft(_ sender: Any?) { commands.turn(.left) }
    @objc func nextPageRight(_ sender: Any?) { commands.turn(.right) }
    @objc func previousChapter(_ sender: Any?) { commands.previousChapter() }
    @objc func nextChapter(_ sender: Any?) { commands.nextChapter() }
    @objc func goBackInHistory(_ sender: Any?) { commands.goBack() }
    @objc func toggleContents(_ sender: Any?) {
        // From the Search tab, "Show Contents" switches to Contents.
        chrome.setSidebar(visible: !(state.sidebarVisible && state.sidebarTab != .search),
                          tab: state.sidebarTab == .search ? .contents : nil)
    }
    @objc func showContentsFromMenu(_ sender: Any?) { chrome.setSidebar(visible: true, tab: .contents) }
    @objc func toggleBookmark(_ sender: Any?) { commands.toggleBookmark() }
    @objc func findInBook(_ sender: Any?) {
        chrome.setSidebar(visible: true, tab: .search)
        state.searchFocusRequest += 1
    }
    @objc func findNext(_ sender: Any?) { if !commands.stepThroughHits(by: 1) { findInBook(nil) } }
    @objc func findPrevious(_ sender: Any?) { if !commands.stepThroughHits(by: -1) { findInBook(nil) } }
    @objc func setLayoutFromMenu(_ sender: NSMenuItem) {
        if let layout = (sender.representedObject as? String).flatMap(ReadingLayout.init) { commands.setLayout(layout) }
    }
    @objc func toggleReaderControls(_ sender: Any?) { chrome.toggle() }
    @objc func setThemeFromMenu(_ sender: NSMenuItem) {
        if let choice = (sender.representedObject as? String).flatMap(AppearanceChoice.init) {
            settings.appearance = choice
        }
    }

    // Commands that only apply to books (text size, Copy with Citation, the
    // click-zone explainer) are in ReaderViewController alone, so the menu
    // disables them while a PDF is in front.

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let ready = isReady && failureHost == nil
        switch item.action {
        case #selector(setLayoutFromMenu(_:)):
            let layout = (item.representedObject as? String).flatMap(ReadingLayout.init)
            item.state = layout == ReadingLayout(flow: state.flow, pages: settings.pageLayout) ? .on : .off
            // Fixed-layout books cannot scroll (PDFs can).
            let cannotScroll = layout == .scroll && state.isFixedLayout && !state.isPDF
            item.toolTip = cannotScroll ? String(localized: "Fixed-layout books are always paginated.") : nil
            return ready && !cannotScroll
        case #selector(setThemeFromMenu(_:)):
            item.state = (item.representedObject as? String) == settings.appearance.rawValue ? .on : .off
            return true
        case #selector(goBackInHistory(_:)):
            return ready && state.backLabel != nil
        case #selector(toggleBookmark(_:)):
            item.title = state.isPageBookmarked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark This Page")
            return ready
        case #selector(toggleContents(_:)):
            item.title = state.sidebarVisible && state.sidebarTab != .search
                ? String(localized: "Hide Contents") : String(localized: "Show Contents")
            return ready
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return ready && !state.allHits.isEmpty
        case #selector(previousChapter(_:)), #selector(nextChapter(_:)):
            // A PDF's chapters are its outline's entries; it may have none.
            return ready && (!state.isPDF || !state.toc.isEmpty)
        case #selector(toggleReaderControls(_:)):
            item.title = chrome.isVisible ? String(localized: "Hide Controls") : String(localized: "Show Controls")
            item.toolTip = String(localized: "Or press C.")
            return ready
        default:
            return ready
        }
    }
}

/// Whether the front book window shows one page although Two Pages is
/// chosen (it is too narrow). Settings explains this under the Layout
/// picker. It is the state of a window, not a setting, so it lives here
/// rather than in ReaderSettings: changing it must not re-style every book.
final class FrontWindowLayout: ObservableObject {
    static let shared = FrontWindowLayout()
    @Published var tooNarrowForTwoPages = false
}
