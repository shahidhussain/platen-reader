import Foundation

/// What the overlay shows, published so the SwiftUI overlay updates itself.
final class ReaderState: ObservableObject {
    struct TOCItem: Identifiable, Equatable {
        let id: Int
        let label: String
        let href: String
        let depth: Int
    }

    @Published var title = ""
    @Published var author = ""
    @Published var chapter = ""
    /// Printed page number from the book's page list, when it has one.
    @Published var printedPage: String?
    @Published var fraction: Double = 0
    /// Where each section starts, as a fraction of the book (slider ticks).
    @Published var sectionFractions: [Double] = []
    @Published var toc: [TOCItem] = []
    @Published var isFixedLayout = false
    @Published var flow: ReadingFlow = .paginated
    @Published var isRightToLeft = false

    /// "Chapter 4 · 37% · p. 214"
    var locationLine: String {
        var parts: [String] = []
        if !chapter.isEmpty { parts.append(chapter) }
        parts.append(fraction.formatted(.percent.precision(.fractionLength(0))))
        if let printedPage { parts.append(String(localized: "p. \(printedPage)")) }
        return parts.joined(separator: " · ")
    }
}
