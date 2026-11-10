import AppKit
import Combine
import PlatenCore
import SwiftUI
import WebKit
import os

// Menu commands (found through the responder chain) and their validation.
extension ReaderViewController {
    // MARK: - Menu actions (found through the responder chain)

    @objc func previousPageLeft(_ sender: Any?) { turn(.left) }
    @objc func nextPageRight(_ sender: Any?) { turn(.right) }
    @objc func previousChapter(_ sender: Any?) { js("platen.prevSection()") }
    @objc func nextChapter(_ sender: Any?) { js("platen.nextSection()") }
    @objc func goBackInHistory(_ sender: Any?) { js("platen.goBack()") }
    @objc func toggleContents(_ sender: Any?) {
        setSidebar(visible: !(state.sidebarVisible && state.sidebarTab != .search),
                   tab: state.sidebarTab == .search ? .contents : nil)
    }
    @objc func showContentsFromMenu(_ sender: Any?) { setSidebar(visible: true, tab: .contents) }
    @objc func toggleBookmark(_ sender: Any?) { js("platen.toggleBookmark()") }
    @objc func findInBook(_ sender: Any?) {
        setSidebar(visible: true, tab: .search)
        state.searchFocusRequest += 1
    }
    @objc func findNext(_ sender: Any?) { stepThroughHits(by: 1) }
    @objc func findPrevious(_ sender: Any?) { stepThroughHits(by: -1) }
    @objc func searchForSelection(_ sender: Any?) {
        guard let text = state.selection?.text else { return }
        setSidebar(visible: true, tab: .search)
        startSearch(String(text.prefix(200)))
    }
    @objc func copyWithCitation(_ sender: Any?) { copyWithCitation() }
    @objc func shareSelection(_ sender: Any?) {
        guard let text = state.selection?.text else { return }
        let picker = NSSharingServicePicker(items: [text])
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
    @objc func showReadingControls(_ sender: Any?) { showExplainer(flash: false) }
    @objc func setLayoutFromMenu(_ sender: NSMenuItem) {
        if let layout = (sender.representedObject as? String).flatMap(ReadingLayout.init) { setLayout(layout) }
    }
    @objc func makeTextBigger(_ sender: Any?) { settings.biggerText() }
    @objc func makeTextSmaller(_ sender: Any?) { settings.smallerText() }
    @objc func makeTextDefaultSize(_ sender: Any?) { settings.defaultTextSize() }
    @objc func toggleReaderControls(_ sender: Any?) { setOverlay(visible: !overlayVisible) }


    @objc func setThemeFromMenu(_ sender: NSMenuItem) {
        if let choice = (sender.representedObject as? String).flatMap(AppearanceChoice.init) {
            settings.appearance = choice
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let ready = book != nil && failureHost == nil
        switch item.action {
        case #selector(setLayoutFromMenu(_:)):
            let layout = (item.representedObject as? String).flatMap(ReadingLayout.init)
            item.state = layout == ReadingLayout(flow: state.flow, pages: settings.pageLayout) ? .on : .off
            if layout == .scroll {
                item.toolTip = state.isFixedLayout ? String(localized: "Fixed-layout books are always paginated.") : nil
                return ready && !state.isFixedLayout
            }
            return ready
        case #selector(setThemeFromMenu(_:)):
            item.state = (item.representedObject as? String) == settings.appearance.rawValue ? .on : .off
            return true
        case #selector(makeTextBigger(_:)):
            return !state.isFixedLayout && settings.fontSizeIndex < ReaderSettings.fontSizes.count - 1
        case #selector(makeTextSmaller(_:)):
            return !state.isFixedLayout && settings.fontSizeIndex > 0
        case #selector(makeTextDefaultSize(_:)):
            return !state.isFixedLayout
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
        case #selector(copyWithCitation(_:)), #selector(shareSelection(_:)), #selector(searchForSelection(_:)):
            return ready && state.selection != nil
        case #selector(toggleReaderControls(_:)):
            item.title = overlayVisible ? String(localized: "Hide Controls") : String(localized: "Show Controls")
            item.toolTip = String(localized: "Or press C.")
            return ready
        default:
            return ready
        }
    }
}
