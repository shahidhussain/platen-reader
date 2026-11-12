import PlatenCore
import SwiftUI
import UIKit

// The overlay on iOS: the same bar as on the Mac (Shared/OverlayViews.swift)
// at the bottom, and a floating Close button with the title at the top left.
// A centre tap shows and hides both; they also hide after 4 seconds unless
// they are being used.
extension ReaderViewController {
    // MARK: - Building the overlay

    func installOverlay(in root: UIView) {
        let sidebarActions = ContentsActions(
            // Choosing a chapter or bookmark closes the popover; search
            // results keep it open so the reader can step through them.
            goToTOCItem: { [weak self] item in self?.jump(to: item.href); self?.state.sidebarVisible = false },
            goToBookmark: { [weak self] bookmark in self?.jump(to: bookmark.cfi); self?.state.sidebarVisible = false },
            removeBookmark: { [weak self] bookmark in self?.removeBookmark(cfi: bookmark.cfi) },
            search: { [weak self] query in self?.startSearch(query) },
            goToHit: { [weak self] hit in self?.goToHit(hit) },
            close: { [weak self] in self?.state.sidebarVisible = false }
        )
        let actions = OverlayActions(
            previousPage: { [weak self] in self?.js("platen.prev()") },
            nextPage: { [weak self] in self?.js("platen.next()") },
            goToFraction: { [weak self] f in self?.callPlaten("jumpToFraction", f) },
            goBack: { [weak self] in self?.js("platen.goBack()") },
            toggleContents: { [weak self] in
                guard let self else { return }
                self.state.sidebarVisible.toggle()
                self.restartHideTimer()
            },
            setLayout: { [weak self] layout in self?.setLayout(layout) },
            toggleBookmark: { [weak self] in self?.js("platen.toggleBookmark()") },
            interacted: { [weak self] in self?.restartHideTimer() },
            openSettings: { [weak self] in self?.showSettings() }
        )

        let bottom = UIHostingController(rootView: OverlayBar(state: state, actions: actions, sidebarActions: sidebarActions))
        let top = UIHostingController(rootView: ReaderTopControls(state: state, close: { [weak self] in self?.close() }))
        // The hosting views take their size from the SwiftUI content, and let
        // the page show around it.
        bottom.sizingOptions = [.intrinsicContentSize]
        top.sizingOptions = [.intrinsicContentSize]
        for host in [bottom, top] as [UIViewController] {
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.alpha = 0
            host.view.isHidden = true
            addChild(host)
            root.addSubview(host.view)
            host.didMove(toParent: self)
        }
        overlayHost = bottom
        topControlsHost = top

        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bottom.view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottom.view.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 10),
            bottom.view.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -10),
            bottom.view.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -20).withPriority(.defaultHigh),
            bottom.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -6),

            top.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            top.view.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -12),
            top.view.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
        ])

        // When the contents popover closes, search highlights go, and the
        // hide countdown starts again.
        state.$sidebarVisible
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] open in
                guard let self, !open else { return }
                DispatchQueue.main.async {
                    if !self.state.searchGroups.isEmpty || self.state.sidebarTab == .search { self.js("platen.clearSearch()") }
                    self.restartHideTimer()
                }
            }
            .store(in: &cancellables)
        state.$overlayPopoverOpen
            .removeDuplicates()
            .sink { [weak self] open in if !open { self?.restartHideTimer() } }
            .store(in: &cancellables)
    }

    // MARK: - Showing and hiding

    func setOverlay(visible: Bool) {
        // Popovers hang from the overlay, so they go with it.
        if !visible && state.sidebarVisible { state.sidebarVisible = false }
        overlayVisible = visible
        let views = [overlayHost?.view, topControlsHost?.view].compactMap { $0 }
        if visible { views.forEach { $0.isHidden = false } }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15, animations: {
            views.forEach { $0.alpha = visible ? 1 : 0 }
            self.setNeedsStatusBarAppearanceUpdate()
        }, completion: { _ in
            // Hidden views take no taps, so the page underneath gets them.
            views.forEach { $0.isHidden = !self.overlayVisible }
        })
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        // The bookmark corner shows a faint ribbon while the controls are up
        // (there is no hover on touch screens).
        callPlaten("setCornerHints", visible)
        if visible { restartHideTimer() } else { hideTimer?.invalidate() }
    }

    /// Hide the overlay after 4 s without use, unless a popover or the
    /// settings sheet is open (closing them restarts this).
    func restartHideTimer() {
        hideTimer?.invalidate()
        guard overlayVisible, !UIAccessibility.isVoiceOverRunning else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, self.overlayVisible else { return }
            if self.state.overlayPopoverOpen || self.state.sidebarVisible || self.presentedViewController != nil { return }
            self.setOverlay(visible: false)
        }
    }

    // MARK: - Actions

    /// A jump through the contents, a bookmark or a search result: reader.js
    /// remembers where the reader was, for the Back button.
    func jump(to target: String, keepOrigin: Bool = false) {
        callPlaten("jumpTo", target, keepOrigin)
    }

    func setLayout(_ layout: ReadingLayout) {
        if let pages = layout.pages, pages != settings.pageLayout { settings.pageLayout = pages }
        guard !state.isFixedLayout, layout.flow != state.flow else { return }
        state.flow = layout.flow
        pushSettings()
    }

    func startSearch(_ query: String) {
        state.beginSearch(query)
        callPlaten("search", state.activeSearchQuery)
    }

    func goToHit(_ hit: ReaderState.SearchHit) {
        let keep = state.currentHitID != nil // Back returns to before the first result
        state.currentHitID = hit.id
        jump(to: hit.cfi, keepOrigin: keep)
    }

    func addBookmark(from body: [String: Any]) {
        guard var record, record.addBookmark(from: body) else { return }
        saveBookmarks(record)
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Bookmark added"))
    }

    func removeBookmark(cfi: String) {
        guard var record else { return }
        record.bookmarks.removeAll { $0.cfi == cfi }
        saveBookmarks(record)
    }

    func saveBookmarks(_ record: BookRecord) {
        self.record = record
        state.bookmarks = record.bookmarks
        PositionStore.shared.saveNow(record) // bookmarks are saved at once
        sendBookmarksToPage()
    }

    func sendBookmarksToPage() {
        callPlaten("setBookmarks", state.bookmarks.map { ["cfi": $0.cfi] })
    }

    func showSettings() {
        hideTimer?.invalidate()
        let sheet = UIHostingController(rootView: ReaderSettingsView(isFixedLayout: state.isFixedLayout) { [weak self] in
            self?.dismiss(animated: true) { self?.restartHideTimer() }
        })
        sheet.modalPresentationStyle = .pageSheet
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        present(sheet, animated: true)
    }
}

/// The top of the overlay on iOS: a round Close button and the book's title
/// and chapter, floating at the top left (no navigation bar).
struct ReaderTopControls: View {
    @ObservedObject var state: ReaderState
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
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
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
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
