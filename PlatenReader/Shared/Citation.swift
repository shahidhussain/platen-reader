import Foundation

/// The text of Copy with Citation: the selected words in quotation marks,
/// then a line naming the author, title, chapter and (where the book gives
/// one) the printed page. Putting it on the pasteboard, with the title in
/// italics, is each platform's own job.
struct Citation: Equatable {
    /// The selection, in quotation marks.
    let quote: String
    /// The citation line's parts, in order: author, title, chapter, page.
    let parts: [String]
    /// Which of `parts` is the book's title (set in italics), if it has one.
    let titleIndex: Int?

    init(selection: ReaderState.Selection, author: String, title: String) {
        var parts: [String] = []
        if !author.isEmpty { parts.append(author) }
        titleIndex = title.isEmpty ? nil : parts.count
        if !title.isEmpty { parts.append(title) }
        if !selection.chapter.isEmpty { parts.append(selection.chapter) }
        if let page = selection.page { parts.append(String(localized: "p. \(page)")) }
        self.parts = parts
        quote = "“\(selection.text)”"
    }

    /// As plain text: the quote, then "— author, title, chapter, p. N".
    var plainText: String {
        parts.isEmpty ? quote : "\(quote)\n— \(parts.joined(separator: ", "))"
    }
}
