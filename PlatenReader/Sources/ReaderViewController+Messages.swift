import AppKit
import Combine
import PlatenCore
import SwiftUI
import WebKit
import os

// Messages from reader.js, and which pages the web view may load.
extension ReaderViewController {
    // MARK: - Messages from JavaScript

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Every message is { type, body } (see post() in reader.js).
        guard let envelope = message.body as? [String: Any], let type = envelope["type"] as? String else { return }
        let body = envelope["body"] as? [String: Any] ?? [:]
        switch type {
        case "ready":
            shellReady = true
            sendBookIfReady()

        case "firstRender":
            hasRendered = true
            spinner.stopAnimation(nil)
            let elapsed = (CFAbsoluteTimeGetCurrent() - openStarted) * 1000
            log.info("First page visible after \(elapsed, format: .fixed(precision: 0)) ms")
            #if DEBUG
            DebugHooks.afterFirstRender(webView: webView, bookName: document.fileURL?.deletingPathExtension().lastPathComponent ?? "book",
                                        root: view) { [weak self] step in self?.runDebugStep(step) }
            #endif

        case "opened":
            if let title = body["title"] as? String, !title.isEmpty { state.title = title }
            state.author = body["author"] as? String ?? ""
            state.isFixedLayout = body["fixedLayout"] as? Bool ?? false
            state.isRightToLeft = (body["dir"] as? String) == "rtl"
            state.sectionFractions = (body["sectionFractions"] as? [NSNumber])?.map(\.doubleValue) ?? []
            view.window?.windowController?.synchronizeWindowTitleWithDocumentName()
            sendBookmarksToPage()
            showFirstRunExplainerIfNeeded()
            // VoiceOver: name the page after the book, and let the page know
            // whether VoiceOver is on (it then follows page turns).
            bookPage.name = state.title
            callPlaten("setVoiceOver", NSWorkspace.shared.isVoiceOverEnabled)

        case "contents":
            // Arrives after the first page is on screen (built in the background).
            state.toc = ((body["toc"] as? [[String: Any]]) ?? []).enumerated().map { index, item in
                ReaderState.TOCItem(id: index, label: item["label"] as? String ?? "",
                                    href: item["href"] as? String ?? "", depth: item["depth"] as? Int ?? 0)
            }
            state.sectionLabels = body["sectionLabels"] as? [String] ?? []
            log.debug("contents: \(self.state.toc.count) entries\((body["synthesised"] as? Bool) == true ? " (built from headings)" : "", privacy: .public)")

        case "back":
            state.backLabel = body["label"] as? String
            log.debug("back label: \(self.state.backLabel ?? "none", privacy: .public)")

        case "pageBookmarked":
            state.isPageBookmarked = body["bookmarked"] as? Bool ?? false
            log.debug("page bookmarked: \(self.state.isPageBookmarked)")

        case "addBookmark":
            addBookmark(from: body)

        case "removeBookmark":
            if let cfi = body["cfi"] as? String { removeBookmark(cfi: cfi) }

        case "selection":
            let text = body["text"] as? String ?? ""
            state.selection = text.isEmpty ? nil
                : ReaderState.Selection(text: text, chapter: body["chapter"] as? String ?? "", page: body["page"] as? String)
            log.debug("selection: \(text.count) characters")

        case "searchResults":
            guard (body["query"] as? String) == activeSearchQuery else { break }
            let items = body["items"] as? [[String: Any]] ?? []
            var nextID = state.allHits.count
            let hits = items.map { item -> ReaderState.SearchHit in
                defer { nextID += 1 }
                return ReaderState.SearchHit(id: nextID, cfi: item["cfi"] as? String ?? "",
                                             pre: item["pre"] as? String ?? "", match: item["match"] as? String ?? "",
                                             post: item["post"] as? String ?? "")
            }
            state.searchGroups.append(.init(id: state.searchGroups.count, label: body["label"] as? String ?? "", hits: hits))

        case "searchProgress":
            if (body["query"] as? String) == activeSearchQuery {
                state.searchProgress = (body["progress"] as? NSNumber)?.doubleValue ?? 0
            }

        case "searchDone":
            if (body["query"] as? String) == activeSearchQuery {
                state.searchRunning = false
                state.searchDoneQuery = activeSearchQuery
            }

        case "relocate":
            state.fraction = (body["fraction"] as? NSNumber)?.doubleValue ?? state.fraction
            state.chapter = body["chapter"] as? String ?? ""
            state.chapterHref = body["chapterHref"] as? String
            state.pagesLeftInChapter = (body["pagesLeft"] as? NSNumber)?.intValue
            state.columnsOnScreen = (body["columns"] as? NSNumber)?.intValue ?? 1
            reportLayoutToSettings()
            view.window?.subtitle = state.chapter
            if let cfi = body["cfi"] as? String, var record {
                record.lastCFI = cfi
                record.readingMode = state.flow.rawValue
                self.record = record
                PositionStore.shared.scheduleSave(record) // debounced
            }

        case "click":
            handleClick(zone: body["zone"] as? String ?? "centre")

        case "image":
            showImage(from: body)

        case "externalLink":
            // Links to the web open in the user's browser, never in the reader.
            if let href = body["href"] as? String, let url = URL(string: href),
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }

        case "error":
            log.error("reader error: \(body["message"] as? String ?? "", privacy: .public)\n\(body["stack"] as? String ?? "", privacy: .public)")
            showFailure(BookOpenError.unreadable(body["message"] as? String ?? ""))

        case "pageText":
            // The text on screen, for VoiceOver (see accessibility.js). It
            // becomes the page VoiceOver reads, and is read out at once when
            // the page has just turned (or R was pressed).
            let text = body["text"] as? String ?? ""
            bookPage.text = text
            if body["speak"] as? Bool == true, !text.isEmpty, NSWorkspace.shared.isVoiceOverEnabled {
                NSAccessibility.post(element: view.window as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: text,
                                                .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }

        case "log":
            log.notice("js: \(body["message"] as? String ?? "", privacy: .public)")

        default:
            break
        }
    }

    // MARK: - Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the shell and its blob: iframes may load. Anything else (a book
        // trying to navigate the window) is refused.
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        if ["platen", "blob", "about", "data"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // If WebKit's content process crashes, reload and reopen at the last
        // saved position rather than leaving a blank window.
        log.error("Web content process terminated; reloading")
        shellReady = false
        bookSentToShell = false
        webView.load(URLRequest(url: ReaderSchemeHandler.shellURL))
    }
}
