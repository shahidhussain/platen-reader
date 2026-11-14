import AppKit
import PlatenCore
import SwiftUI

// Menu commands only books have (validated in ReaderViewController.swift). The commands every
// book window shares (page turns, contents, bookmarks, find, layout, theme)
// are in ReaderBaseViewController.
extension ReaderViewController {
    // MARK: - Menu actions (found through the responder chain)

    @objc func searchForSelection(_ sender: Any?) {
        guard let text = state.selection?.text else { return }
        chrome.setSidebar(visible: true, tab: .search)
        session.search(String(text.prefix(200)))
    }
    @objc func copyWithCitation(_ sender: Any?) { copyWithCitation() }
    @objc func shareSelection(_ sender: Any?) {
        guard let text = state.selection?.text else { return }
        let picker = NSSharingServicePicker(items: [text])
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
    @objc func showReadingControls(_ sender: Any?) { showExplainer(flash: false) }
    @objc func makeTextBigger(_ sender: Any?) { settings.biggerText() }
    @objc func makeTextSmaller(_ sender: Any?) { settings.smallerText() }
    @objc func makeTextDefaultSize(_ sender: Any?) { settings.defaultTextSize() }
}
