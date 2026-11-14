import AppKit
import Combine
import PlatenCore
import SwiftUI
import WebKit
import os

// Getting text out: Copy with Citation and the context menu. (Contents,
// jumps, bookmarks and find in book are the session's and the base
// class's.)
extension ReaderViewController {
    // MARK: - Getting text out

    /// The selected text followed by a citation line: author, title,
    /// chapter, and printed page where available. Plain and rich text.
    func copyWithCitation() {
        guard let selection = state.selection else { return }
        let citation = Citation(selection: selection, author: state.author, title: state.title)
        let plain = citation.plainText

        // Rich text: the same, with the book's title in italics.
        let rich = NSMutableAttributedString(string: citation.quote)
        if !citation.parts.isEmpty {
            let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            rich.append(NSAttributedString(string: "\n— "))
            for (i, part) in citation.parts.enumerated() {
                if i > 0 { rich.append(NSAttributedString(string: ", ")) }
                rich.append(NSAttributedString(string: part, attributes: [.font: i == citation.titleIndex ? italic : base]))
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
