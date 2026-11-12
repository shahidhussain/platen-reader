import Foundation
import PlatenCore

// Messages from reader.js that only update what the overlay and contents
// panel show, decoded once for both apps. Each app's view controller passes
// every message here first, then does its own platform work (window titles,
// VoiceOver announcements, saving the position and so on).

extension ReaderState {
    /// Updates the published state from one message posted by reader.js
    /// (`post(type, body)` in bridge.js).
    func apply(message type: String, body: [String: Any]) {
        switch type {
        case "opened":
            if let title = body["title"] as? String, !title.isEmpty { self.title = title }
            author = body["author"] as? String ?? ""
            isFixedLayout = body["fixedLayout"] as? Bool ?? false
            isRightToLeft = (body["dir"] as? String) == "rtl"
            sectionFractions = (body["sectionFractions"] as? [NSNumber])?.map(\.doubleValue) ?? []

        case "contents":
            // Arrives after the first page is on screen (built in the background).
            toc = ((body["toc"] as? [[String: Any]]) ?? []).enumerated().map { index, item in
                TOCItem(id: index, label: item["label"] as? String ?? "",
                        href: item["href"] as? String ?? "", depth: item["depth"] as? Int ?? 0)
            }
            sectionLabels = body["sectionLabels"] as? [String] ?? []

        case "back":
            backLabel = body["label"] as? String

        case "pageBookmarked":
            isPageBookmarked = body["bookmarked"] as? Bool ?? false

        case "selection":
            let text = body["text"] as? String ?? ""
            selection = text.isEmpty ? nil
                : Selection(text: text, chapter: body["chapter"] as? String ?? "", page: body["page"] as? String)

        case "searchResults":
            // Results of an older search are dropped.
            guard (body["query"] as? String) == activeSearchQuery else { break }
            let items = body["items"] as? [[String: Any]] ?? []
            var nextID = allHits.count
            let hits = items.map { item -> SearchHit in
                defer { nextID += 1 }
                return SearchHit(id: nextID, cfi: item["cfi"] as? String ?? "",
                                 pre: item["pre"] as? String ?? "", match: item["match"] as? String ?? "",
                                 post: item["post"] as? String ?? "")
            }
            searchGroups.append(.init(id: searchGroups.count, label: body["label"] as? String ?? "", hits: hits))

        case "searchProgress":
            if (body["query"] as? String) == activeSearchQuery {
                searchProgress = (body["progress"] as? NSNumber)?.doubleValue ?? 0
            }

        case "searchDone":
            if (body["query"] as? String) == activeSearchQuery {
                searchRunning = false
                searchDoneQuery = activeSearchQuery
            }

        case "relocate":
            // Before a chapter has loaded, foliate can report no fraction.
            if let f = (body["fraction"] as? NSNumber)?.doubleValue, f.isFinite { fraction = f }
            chapter = body["chapter"] as? String ?? ""
            chapterHref = body["chapterHref"] as? String
            pagesLeftInChapter = (body["pagesLeft"] as? NSNumber)?.intValue
            columnsOnScreen = (body["columns"] as? NSNumber)?.intValue ?? 1

        default:
            break
        }
    }

    /// Starts a new search: clears the old results. The app then calls
    /// `platen.search(query)`; results arrive as messages.
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

extension BookRecord {
    /// Adds the bookmark described by an `addBookmark` message (the page's
    /// first word, its text and where it is), keeping the list in reading
    /// order. Returns false if there was nothing to add.
    mutating func addBookmark(from body: [String: Any]) -> Bool {
        guard let cfi = body["cfi"] as? String, !bookmarks.contains(where: { $0.cfi == cfi }) else { return false }
        bookmarks.append(Bookmark(
            cfi: cfi,
            snippet: body["snippet"] as? String ?? "",
            chapter: (body["chapter"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            page: body["page"] as? String,
            fraction: (body["fraction"] as? NSNumber)?.doubleValue))
        bookmarks.sort { ($0.fraction ?? 0) < ($1.fraction ?? 0) }
        return true
    }
}
