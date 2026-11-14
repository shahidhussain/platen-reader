import Foundation
import PlatenCore
import SwiftUI

/// What a reader can be asked to do, whatever it is showing: a book (through
/// `BookSession` and reader.js) or a PDF (through PDFKit). The overlay, the
/// contents panel, the menus and the keyboard all speak to a reader through
/// this, so each is written once and works for both.
protocol ReaderCommands: AnyObject {
    var state: ReaderState { get }

    func turn(_ turn: PageTurn)
    /// A jump through the contents, a bookmark or a search result. The reader
    /// remembers where it was, for the Back button. `keepOrigin`: stepping
    /// through search results keeps Back pointing at where the reader was
    /// before the first result.
    func jump(to target: String, keepOrigin: Bool)
    /// A jump with the slider, to a fraction of the way through.
    func jump(toFraction fraction: Double)
    /// Back to where the reader was before the latest jump.
    func goBack()
    func previousChapter()
    func nextChapter()
    func toggleBookmark()
    func removeBookmark(cfi: String)
    func search(_ query: String)
    func goToHit(_ hit: ReaderState.SearchHit)
    /// The contents panel closed: search highlights are temporary and go.
    func searchPanelClosed()
    /// The Layout choice. Scroll or pages is one setting for every book and
    /// PDF (spec, "Reading modes and layout"), so this changes the setting;
    /// every open reader then follows it (`followFlowSetting`).
    func setLayout(_ layout: ReadingLayout)
    /// The reading-mode setting changed (in this reader or another): show
    /// this book or PDF that way.
    func followFlowSetting(_ flow: ReadingFlow)
}

extension ReaderCommands {
    /// Find Next / Find Previous: moves through the search results, wrapping
    /// round. Returns false when there are none (the caller then opens the
    /// search panel instead).
    @discardableResult
    func stepThroughHits(by step: Int) -> Bool {
        let hits = state.allHits
        guard !hits.isEmpty else { return false }
        let current = hits.firstIndex { $0.id == state.currentHitID }
        let next = current.map { ($0 + step + hits.count) % hits.count } ?? (step > 0 ? 0 : hits.count - 1)
        goToHit(hits[next])
        return true
    }
}

extension OverlayActions {
    /// The overlay's buttons and slider, wired to a reader. Showing the
    /// contents panel and keeping the overlay up are the app's own business
    /// (they differ between the Mac and iOS), so they are passed in, as is
    /// what the gear button's popover shows (iOS only).
    init(commands: ReaderCommands, toggleContents: @escaping () -> Void, interacted: @escaping () -> Void,
         settingsContent: (() -> AnyView)? = nil) {
        self.init(
            previousPage: { [weak commands] in commands?.turn(.prev) },
            nextPage: { [weak commands] in commands?.turn(.next) },
            goToFraction: { [weak commands] fraction in commands?.jump(toFraction: fraction) },
            goBack: { [weak commands] in commands?.goBack() },
            toggleContents: toggleContents,
            setLayout: { [weak commands] layout in commands?.setLayout(layout) },
            toggleBookmark: { [weak commands] in commands?.toggleBookmark() },
            interacted: interacted,
            settingsContent: settingsContent)
    }
}

extension ContentsActions {
    /// The contents panel, wired to a reader. Choosing a chapter or bookmark
    /// closes the panel; search results keep it open so the reader can step
    /// through them.
    init(commands: ReaderCommands) {
        let state = commands.state
        self.init(
            goToTOCItem: { [weak commands, weak state] item in
                commands?.jump(to: item.href, keepOrigin: false)
                state?.sidebarVisible = false
            },
            goToBookmark: { [weak commands, weak state] bookmark in
                commands?.jump(to: bookmark.cfi, keepOrigin: false)
                state?.sidebarVisible = false
            },
            removeBookmark: { [weak commands] bookmark in commands?.removeBookmark(cfi: bookmark.cfi) },
            search: { [weak commands] query in commands?.search(query) },
            goToHit: { [weak commands] hit in commands?.goToHit(hit) },
            close: { [weak state] in state?.sidebarVisible = false })
    }
}
