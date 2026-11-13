import AppKit
import Combine
import PlatenCore
import SwiftUI
import WebKit
import os

// Contents, jumps, bookmarks, find in book, and getting text out (Copy with
// Citation, the context menu).
extension ReaderViewController {
    // MARK: - Contents, jumps and bookmarks

    /// A jump through the contents, a bookmark or the slider: reader.js
    /// remembers where the reader was, for the Back button.
    func jump(to target: String, keepOrigin: Bool = false) {
        guard bookSentToShell else { return }
        callPlaten("jumpTo", target, keepOrigin)
        view.window?.makeFirstResponder(webView)
    }

    /// Opens or closes the contents popover. It hangs from the Contents
    /// button in the overlay, so the overlay is shown first.
    func setSidebar(visible: Bool, tab: ReaderState.SidebarTab? = nil) {
        if let tab { state.sidebarTab = tab }
        guard visible != state.sidebarVisible else { return }
        if visible {
            let wasHidden = !overlayVisible
            setOverlay(visible: true)
            // The popover needs its button on screen to hang from.
            DispatchQueue.main.asyncAfter(deadline: .now() + (wasHidden ? 0.05 : 0)) { [weak self] in
                self?.state.sidebarVisible = true
            }
        } else {
            state.sidebarVisible = false
        }
    }

    /// The popover was closed (by us, Esc or a click outside it).
    func sidebarDidClose() {
        view.window?.makeFirstResponder(webView)
        // Search highlights are temporary: they go when the panel closes.
        if state.sidebarTab == .search || !state.searchGroups.isEmpty { js("platen.clearSearch()") }
        restartHideTimer()
    }

    func sendBookmarksToPage() {
        let list = state.bookmarks.map { ["cfi": $0.cfi] }
        guard bookSentToShell else { return }
        callPlaten("setBookmarks", list)
    }

    func addBookmark(from body: [String: Any]) {
        guard var record, record.addBookmark(from: body) else { return }
        saveBookmarks(record)
        NSAccessibility.post(element: webView as Any, notification: .announcementRequested,
                             userInfo: [.announcement: String(localized: "Bookmark added"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
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

    // MARK: - Find in book

    func startSearch(_ query: String) {
        state.beginSearch(query)
        guard bookSentToShell else { return }
        callPlaten("search", state.activeSearchQuery)
    }

    func goToHit(_ hit: ReaderState.SearchHit) {
        let keep = state.currentHitID != nil // Back returns to before the first result
        state.currentHitID = hit.id
        jump(to: hit.cfi, keepOrigin: keep)
    }

    func stepThroughHits(by step: Int) {
        let hits = state.allHits
        guard !hits.isEmpty else { return findInBook(nil) }
        let current = hits.firstIndex { $0.id == state.currentHitID }
        let next = current.map { ($0 + step + hits.count) % hits.count } ?? (step > 0 ? 0 : hits.count - 1)
        goToHit(hits[next])
    }

    // MARK: - Getting text out

    /// The selected text followed by a citation line: author, title,
    /// chapter, and printed page where available. Plain and rich text.
    func copyWithCitation() {
        guard let selection = state.selection else { return }
        var parts: [String] = []
        if !state.author.isEmpty { parts.append(state.author) }
        let titleIndex = parts.count
        if !state.title.isEmpty { parts.append(state.title) }
        if !selection.chapter.isEmpty { parts.append(selection.chapter) }
        if let page = selection.page { parts.append(String(localized: "p. \(page)")) }

        let quote = "“\(selection.text)”"
        let plain = parts.isEmpty ? quote : "\(quote)\n— \(parts.joined(separator: ", "))"

        let rich = NSMutableAttributedString(string: quote)
        if !parts.isEmpty {
            let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            rich.append(NSAttributedString(string: "\n— "))
            for (i, part) in parts.enumerated() {
                if i > 0 { rich.append(NSAttributedString(string: ", ")) }
                let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                rich.append(NSAttributedString(string: part, attributes: i == titleIndex && !state.title.isEmpty ? [.font: italic] : [.font: base]))
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pasteboard.declareTypes([.string] + (rtf == nil ? [] : [.rtf]), owner: nil)
        pasteboard.setString(plain, forType: .string)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
    }

    /// Adds Platen's items to WebKit's context menu (which already has Look
    /// Up, Translate, Copy and Share) and removes browser-only items.
    func customiseContextMenu(_ menu: NSMenu) {
        let browserOnly: Set<String> = [
            "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
            "WKMenuItemIdentifierOpenFrameInNewWindow", "WKMenuItemIdentifierOpenLinkInNewWindow",
            "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierOpenImageInNewWindow",
            "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierOpenMediaInNewWindow",
            "WKMenuItemIdentifierDownloadMedia",
        ]
        for item in menu.items where browserOnly.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }

        var items: [NSMenuItem] = []
        if let selection = state.selection {
            let copyIndex = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
            let cite = NSMenuItem(title: String(localized: "Copy with Citation"), action: #selector(copyWithCitation(_:)), keyEquivalent: "")
            cite.target = self
            if let copyIndex { menu.insertItem(cite, at: copyIndex + 1) } else { items.append(cite) }
            let short = selection.text.count > 24 ? String(selection.text.prefix(24)) + "…" : selection.text
            let find = NSMenuItem(title: String(localized: "Search Book for “\(short)”"), action: #selector(searchForSelection(_:)), keyEquivalent: "")
            find.target = self
            items.append(find)
        } else {
            let mark = NSMenuItem(title: state.isPageBookmarked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark This Page"),
                                  action: #selector(toggleBookmark(_:)), keyEquivalent: "")
            mark.target = self
            let contents = NSMenuItem(title: String(localized: "Show Contents"), action: #selector(showContentsFromMenu(_:)), keyEquivalent: "")
            contents.target = self
            items += [mark, contents]
        }
        if !items.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }
    }
}
