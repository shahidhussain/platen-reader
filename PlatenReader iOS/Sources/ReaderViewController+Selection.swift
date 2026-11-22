import UIKit
import UniformTypeIdentifiers

/// The menu over a text selection in a book (iOS), beside the system's own
/// Copy, Look Up, Translate and Share: Copy with Citation and Search Book
/// for "…", as the Mac has them (plan, phase 5). The selection itself, its
/// chapter and page come from the shell (`ReaderState.selection`); the
/// citation's wording is shared with the Mac (`Citation`).
extension ReaderViewController {
    /// The two commands, added to the selection's menu by `buildMenu`
    /// (ReaderViewController.swift) while some text is selected.
    func selectionMenu() -> UIMenu? {
        guard let selection = state.selection, !selection.text.isEmpty else { return nil }
        let copy = UIAction(title: String(localized: "Copy with Citation"), image: UIImage(systemName: "quote.opening")) { [weak self] _ in
            self?.copyWithCitation()
        }
        // The menu names what will be searched for, shortened as the Mac's does.
        let words = selection.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let shown = words.count > 24 ? String(words.prefix(24)) + "…" : words
        let search = UIAction(title: String(localized: "Search Book for “\(shown)”"),
                              image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
            self?.searchForSelection()
        }
        // No Share of our own: iOS puts its Share… in this menu already, and
        // two would be confusing.
        return UIMenu(options: .displayInline, children: [copy, search])
    }

    /// The selection in quotation marks with where it is from, as plain
    /// text and as rich text with the book's title in italics, so a notes
    /// app or a mail keeps the italics and a plain field gets the plain form.
    func copyWithCitation() {
        guard let selection = state.selection else { return }
        let citation = Citation(selection: selection, author: state.author, title: state.title)
        var item: [String: Any] = [UTType.utf8PlainText.identifier: citation.plainText]
        if let rtf = Self.richText(citation) { item[UTType.rtf.identifier] = rtf }
        UIPasteboard.general.items = [item]
    }

    private static func richText(_ citation: Citation) -> Data? {
        let size = UIFont.systemFontSize
        let base = UIFont.systemFont(ofSize: size)
        let italic = UIFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(.traitItalic)
            .map { UIFont(descriptor: $0, size: size) } ?? base
        let rich = NSMutableAttributedString(string: citation.quote, attributes: [.font: base])
        if !citation.parts.isEmpty {
            rich.append(NSAttributedString(string: "\n— ", attributes: [.font: base]))
            for (index, part) in citation.parts.enumerated() {
                if index > 0 { rich.append(NSAttributedString(string: ", ", attributes: [.font: base])) }
                rich.append(NSAttributedString(string: part, attributes: [.font: index == citation.titleIndex ? italic : base]))
            }
        }
        return try? rich.data(from: NSRange(location: 0, length: rich.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// Opens the Search tab and searches the book for the selected words.
    func searchForSelection() {
        guard let text = state.selection?.text else { return }
        showSidebar(tab: .search)
        session.search(String(text.prefix(200)))
    }
}
