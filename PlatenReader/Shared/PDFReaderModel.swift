import Foundation
import PDFKit
import PlatenCore

/// Why a PDF could not be opened.
enum PDFOpenError: Error, LocalizedError {
    case unreadable
    case locked

    var errorDescription: String? {
        switch self {
        case .unreadable: return String(localized: "This PDF could not be opened.")
        case .locked: return String(localized: "This PDF is protected by a password.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unreadable: return String(localized: "The file may be damaged, or not a PDF.")
        case .locked: return String(localized: "Platen does not open password-protected PDFs. Open it in another app.")
        }
    }
}

/// The book-keeping for one PDF, shared by the Mac and iOS readers (spec,
/// "PDF"). PDFKit draws the pages; this connects the document to the same
/// `ReaderState` the overlay shows for books, so the location line, slider,
/// Contents (the PDF's outline), bookmarks, search and the Back button all
/// work as they do for EPUBs, anchored to page indexes instead of CFIs.
///
/// Each app's PDF reader owns a `PDFView`, tells this model when the page
/// changes (`pageChanged`), and asks it where to go (`pageIndex(for:)`).
final class PDFReaderModel: NSObject, PDFDocumentDelegate {
    let state: ReaderState
    let document: PDFDocument
    private(set) var record: BookRecord

    /// The outline flattened in reading order: where each entry starts.
    private var outlineStarts: [(page: Int, label: String, href: String)] = []
    /// Search: the selection behind each result, to highlight it on the page.
    private(set) var hitSelections: [Int: PDFSelection] = [:]
    /// Back: the page before the latest jump, until the reader turns a page.
    private var jumpOrigin: Int?
    private var jumpTarget: Int?

    var pageCount: Int { document.pageCount }

    // MARK: - Opening

    /// What `load` produces: the document and its identity.
    struct Loaded {
        let document: PDFDocument
        let fingerprint: String
        let key: String
        let documentID: String?
    }

    /// Reads a PDF off the main thread. Files up to 50 MB are read into
    /// memory in one sequential read, so a network share or iCloud file can
    /// go away afterwards (as for books); larger ones are read by PDFKit
    /// from the file as pages are needed.
    static func load(url: URL) throws -> Loaded {
        var result: Result<Loaded, Error> = .failure(PDFOpenError.unreadable)
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges],
                                                         error: &coordinationError) { readURL in
            result = Result {
                let size = (try FileManager.default.attributesOfItem(atPath: readURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
                let source: ByteSource
                let document: PDFDocument?
                if size <= Book.inMemoryLimit {
                    let data = try Data(contentsOf: readURL)
                    source = MemoryByteSource(data: data)
                    document = PDFDocument(data: data)
                } else {
                    source = try FileByteSource(url: readURL)
                    document = PDFDocument(url: readURL)
                }
                guard let document else { throw PDFOpenError.unreadable }
                if document.isLocked { throw PDFOpenError.locked }
                let identity = try PDFIdentity.identify(source: source)
                return Loaded(document: document, fingerprint: identity.fingerprint,
                              key: identity.key, documentID: identity.documentID)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    init(loaded: Loaded, url: URL, state: ReaderState) {
        self.state = state
        self.document = loaded.document
        var record = PositionStore.shared.load(key: loaded.key)
            ?? BookRecord(key: loaded.key, uniqueIdentifier: loaded.documentID.map { "pdf:" + $0 },
                          fingerprint: loaded.fingerprint)
        record.lastKnownPath = url.path
        record.lastOpened = Date()
        self.record = record
        super.init()
        document.delegate = self

        let attributes = document.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        state.title = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
        state.author = (attributes[PDFDocumentAttribute.authorAttribute] as? String) ?? ""
        state.isPDF = true
        state.isFixedLayout = true
        state.flow = .paginated
        state.bookmarks = record.bookmarks
        readOutline()
    }

    /// Where to open: the saved page, or the first.
    var startPage: Int { min(max(record.lastPage ?? 0, 0), max(pageCount - 1, 0)) }
    var savedZoom: Double? { record.lastZoom }

    // MARK: - Contents (the outline)

    private func readOutline() {
        var items: [ReaderState.TOCItem] = []
        var starts: [(Int, String, String)] = []
        func walk(_ item: PDFOutline, depth: Int) {
            for i in 0..<item.numberOfChildren {
                guard let child = item.child(at: i) else { continue }
                let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let page = child.destination?.page {
                    let index = document.index(for: page)
                    let href = Self.href(page: index)
                    items.append(.init(id: items.count, label: label, href: href, depth: depth))
                    starts.append((index, label, href))
                }
                walk(child, depth: depth + 1)
            }
        }
        if let root = document.outlineRoot { walk(root, depth: 0) }
        state.toc = items
        // Reading order, so "the chapter containing page N" is the last
        // entry starting at or before N.
        outlineStarts = starts.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
            .map { (page: $0.element.0, label: $0.element.1, href: $0.element.2) }
        // Slider ticks at the top-level entries.
        let top = items.filter { $0.depth == 0 }.compactMap { item -> (Double, String)? in
            guard let page = pageIndex(for: item.href) else { return nil }
            return (fraction(ofPage: page), item.label)
        }
        state.sectionFractions = top.map(\.0) + (top.isEmpty ? [] : [1])
        state.sectionLabels = top.map(\.1)
    }

    static func href(page: Int) -> String { "page:\(page)" }

    /// The page an outline entry, bookmark or search result points at.
    func pageIndex(for href: String) -> Int? {
        guard href.hasPrefix("page:"), let index = Int(href.dropFirst(5)) else { return nil }
        return min(max(index, 0), max(pageCount - 1, 0))
    }

    func fraction(ofPage index: Int) -> Double {
        pageCount > 1 ? Double(index) / Double(pageCount - 1) : 0
    }

    func page(atFraction f: Double) -> Int {
        Int((min(max(f, 0), 1) * Double(max(pageCount - 1, 0))).rounded())
    }

    /// The printed page label where the PDF has one ("iv", "214"), else the
    /// page's number counting from 1.
    func pageLabel(_ index: Int) -> String {
        if let label = document.page(at: index)?.label, !label.isEmpty { return label }
        return String(index + 1)
    }

    // MARK: - Where the reader is

    /// Called by the view whenever the page on screen changes. `visible` is
    /// every page on screen (two in a spread), the first being `index`.
    func pageChanged(to index: Int, visible: [Int], zoom: Double?) {
        guard pageCount > 0 else { return }
        state.fraction = fraction(ofPage: index)
        state.locationDetail = String(localized: "p. \(pageLabel(index)) of \(pageCount)")
        let current = outlineStarts.last { $0.page <= index }
        state.chapter = current?.label ?? ""
        state.chapterHref = current?.href
        if let next = outlineStarts.first(where: { $0.page > index }) {
            state.pagesLeftInChapter = max(0, next.page - index - 1)
        } else {
            state.pagesLeftInChapter = max(0, pageCount - index - 1)
        }
        state.columnsOnScreen = max(visible.count, 1)
        state.isPageBookmarked = visible.contains { page in record.bookmarks.contains { $0.cfi == Self.href(page: page) } }

        // Back: kept after a jump until the reader moves away from where
        // the jump landed.
        if let target = jumpTarget, !visible.contains(target), index != target {
            jumpOrigin = nil
            jumpTarget = nil
            state.backLabel = nil
        }

        record.lastPage = index
        record.lastZoom = zoom
        record.readingMode = state.flow.rawValue // Scroll is remembered per PDF, as per book
        PositionStore.shared.scheduleSave(record)
    }

    func saveNow() {
        PositionStore.shared.saveNow(record)
    }

    /// A jump through the contents, a bookmark, a search result or the
    /// slider: remember where the reader was, for the Back button.
    func noteJump(from origin: Int, to target: Int, keepOrigin: Bool = false) {
        guard origin != target else { return }
        if !(keepOrigin && jumpOrigin != nil) { jumpOrigin = origin }
        jumpTarget = target
        if let jumpOrigin { state.backLabel = String(localized: "p. \(pageLabel(jumpOrigin))") }
    }

    /// Where Back goes (and forgets the jump).
    func takeBackTarget() -> Int? {
        defer { jumpOrigin = nil; jumpTarget = nil; state.backLabel = nil }
        return jumpOrigin
    }

    // MARK: - Bookmarks

    /// Adds a bookmark for the first page on screen, or removes the
    /// bookmarks of every page on screen if there are any.
    func toggleBookmark(visible: [Int]) {
        let marked = record.bookmarks.filter { b in visible.contains { Self.href(page: $0) == b.cfi } }
        if !marked.isEmpty {
            record.bookmarks.removeAll { b in marked.contains(b) }
        } else if let index = visible.first {
            let text = document.page(at: index)?.string ?? ""
            let snippet = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            record.bookmarks.append(BookRecord.Bookmark(
                cfi: Self.href(page: index),
                snippet: String(snippet.prefix(120)),
                chapter: outlineStarts.last { $0.page <= index }?.label,
                page: pageLabel(index),
                fraction: fraction(ofPage: index)))
            record.bookmarks.sort { ($0.fraction ?? 0) < ($1.fraction ?? 0) }
        }
        bookmarksChanged(visible: visible)
    }

    func removeBookmark(cfi: String, visible: [Int]) {
        record.bookmarks.removeAll { $0.cfi == cfi }
        bookmarksChanged(visible: visible)
    }

    private func bookmarksChanged(visible: [Int]) {
        state.bookmarks = record.bookmarks
        state.isPageBookmarked = visible.contains { page in record.bookmarks.contains { $0.cfi == Self.href(page: page) } }
        PositionStore.shared.saveNow(record) // bookmarks are saved at once
    }

    // MARK: - Search

    /// Searches the whole document in the background; results arrive
    /// through the delegate methods below, grouped by outline entry.
    func search(_ query: String) {
        if document.isFinding { document.cancelFindString() }
        state.beginSearch(query)
        hitSelections = [:]
        guard !state.activeSearchQuery.isEmpty else { return }
        document.beginFindString(state.activeSearchQuery, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    func cancelSearch() {
        if document.isFinding { document.cancelFindString() }
        hitSelections = [:]
    }

    /// Results beyond this are not listed (the panel would be unusable).
    private static let maxHits = 1000

    func didMatchString(_ instance: PDFSelection) {
        guard hitSelections.count < Self.maxHits, let page = instance.pages.first else { return }
        let index = document.index(for: page)
        let match = instance.string ?? state.activeSearchQuery
        // The line around the match, split into before / match / after.
        var pre = "", post = ""
        if let line = instance.copy() as? PDFSelection {
            line.extendForLineBoundaries()
            let text = (line.string ?? "").replacingOccurrences(of: "\n", with: " ")
            if let range = text.range(of: match, options: [.caseInsensitive, .diacriticInsensitive]) {
                pre = String(text[..<range.lowerBound].suffix(60))
                post = String(text[range.upperBound...].prefix(80))
            }
        }
        let id = state.allHits.count
        let hit = ReaderState.SearchHit(id: id, cfi: Self.href(page: index), pre: pre, match: match, post: post)
        hitSelections[id] = instance
        let label = outlineStarts.last { $0.page <= index }?.label ?? String(localized: "p. \(pageLabel(index))")
        if let last = state.searchGroups.indices.last, state.searchGroups[last].label == label {
            state.searchGroups[last].hits.append(hit)
        } else {
            state.searchGroups.append(.init(id: state.searchGroups.count, label: label, hits: [hit]))
        }
    }

    func documentDidEndPageFind(_ notification: Notification) {
        guard let index = notification.userInfo?["PDFDocumentPageIndex"] as? Int, pageCount > 0 else { return }
        state.searchProgress = Double(index + 1) / Double(pageCount)
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        state.searchRunning = false
        state.searchDoneQuery = state.activeSearchQuery
    }
}
