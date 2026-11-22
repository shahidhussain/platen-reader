import Foundation
import PlatenCore

// How messages from reader.js change what the overlay and contents panel
// show. `BookSession` passes every message here first, then does the rest
// (saving the position, telling the app's reader view).

extension ReaderState {
    /// Updates the published state from one message (see ReaderBridge.swift).
    func apply(_ message: ReaderMessage) {
        switch message {
        case .opened(let book):
            if !book.title.isEmpty { title = book.title }
            author = book.author
            isFixedLayout = book.isFixedLayout
            isRightToLeft = book.isRightToLeft
            sectionFractions = book.sectionFractions
            language = book.language

        case .contents(let contents):
            // Arrives after the first page is on screen (built in the background).
            toc = contents.toc
            sectionLabels = contents.sectionLabels

        case .back(let label):
            backLabel = label

        case .note(let open):
            noteOpen = open

        case .pageBookmarked(let bookmarked):
            isPageBookmarked = bookmarked

        case .selection(let selection):
            self.selection = selection

        case .searchResults(let results):
            // Results of an older search are dropped.
            guard results.query == activeSearchQuery else { break }
            let firstID = allHits.count
            let hits = results.hits.enumerated().map { offset, hit in
                SearchHit(id: firstID + offset, cfi: hit.cfi, pre: hit.pre, match: hit.match, post: hit.post)
            }
            searchGroups.append(.init(id: searchGroups.count, label: results.label, hits: hits))

        case .searchProgress(let query, let progress):
            if query == activeSearchQuery { searchProgress = progress }

        case .searchDone(let query):
            if query == activeSearchQuery {
                searchRunning = false
                searchDoneQuery = activeSearchQuery
            }

        case .relocate(let place):
            // Before a chapter has loaded, foliate can report no fraction.
            if let fraction = place.fraction { self.fraction = fraction }
            chapter = place.chapter
            chapterHref = place.chapterHref
            pagesLeftInChapter = place.pagesLeft
            columnsOnScreen = place.columns

        case .ready, .firstRender, .addBookmark, .removeBookmark, .click, .image, .lonePicture, .externalLink,
             .failed, .pageText, .log, .readAloudBlock, .readAloudEnd:
            break // nothing the overlay shows
        }
    }

    /// Starts a new search: clears the old results. The reader then runs
    /// the search; results arrive as messages (books) or from PDFKit (PDFs).
    func beginSearch(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchQuery = query
        searchQuery = query
        searchGroups = []
        currentHitID = nil
        searchDoneQuery = nil
        searchProgress = 0
        searchRunning = !query.isEmpty
    }
}
