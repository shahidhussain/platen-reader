import PlatenCore
import SwiftUI
import UIKit

// The overlay's actions for books on iOS. The overlay itself (showing,
// hiding, the 4-second timer) is ReaderChrome, shared with the PDF reader.
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
            previousPage: { [weak self] in self?.turn(.prev) },
            nextPage: { [weak self] in self?.turn(.next) },
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

        let chrome = ReaderChrome(owner: self, state: state, actions: actions, sidebarActions: sidebarActions,
                                  close: { [weak self] in self?.close() },
                                  sidebarClosed: { [weak self] in
                                      // Search highlights are temporary: they go
                                      // when the panel closes.
                                      guard let self else { return }
                                      if !self.state.searchGroups.isEmpty || self.state.sidebarTab == .search {
                                          self.js("platen.clearSearch()")
                                      }
                                  })
        // The bookmark corner shows a faint ribbon while the controls are up
        // (there is no hover on touch screens).
        chrome.onVisibilityChanged = { [weak self] visible in self?.callPlaten("setCornerHints", visible) }
        chrome.install(in: root)
        self.chrome = chrome
    }

    func setOverlay(visible: Bool) { chrome?.setVisible(visible) }
    func restartHideTimer() { chrome?.restartHideTimer() }

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
        presentReaderSettings(isFixedLayout: state.isFixedLayout, chrome: chrome)
    }
}
