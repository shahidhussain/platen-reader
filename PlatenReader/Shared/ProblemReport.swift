import Foundation
import PlatenCore

/// Problem reports by email (spec, "Failure handling"): "Report This Book"
/// on the screen shown when a book cannot be opened, and Send Feedback. The
/// reader's own mail app sends them, so the reader sees everything before
/// it goes, and Platen itself sends nothing (spec: no network).
///
/// Each app writes the email in its own way (`MailComposer`); this is what
/// goes in it: the address, the subject with its tag, the opening of the
/// body, and the diagnostics file.
enum ProblemReport {
    /// The subject's tag, for sorting reports as they arrive:
    /// "[Platen 1.0.2 · macOS · E-1030]" (no code for feedback).
    static func tag(code: String?) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(macOS)
        let system = "macOS"
        #else
        let system = "iOS"
        #endif
        return "[" + ["Platen \(version)", system, code].compactMap { $0 }.joined(separator: " · ") + "]"
    }

    /// The subject of a report about a book that would not open.
    static func bookSubject(code: String) -> String {
        tag(code: code) + " " + String(localized: "A book that would not open")
    }

    /// The subject of feedback (Help › Send Feedback…, Settings).
    static var feedbackSubject: String {
        tag(code: nil) + " " + String(localized: "Feedback")
    }

    /// The opening of a book report's body, for the reader to add to.
    static var bookBody: String {
        String(localized: """
        What happened, and where the book came from (if you know):



        The attached file says which version of Platen this is, the system, the kind of device, the error and how the book was made. It holds no book titles or file names.
        """)
    }

    /// A mailto: link to support, for when no mail account is set up to
    /// attach files with: the address, subject and body only.
    static func mailtoURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = AppLinks.supportEmail
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return components.url
    }

    // MARK: - The diagnostics file

    /// Writes the diagnostics for a book that would not open to a file to
    /// attach: the app, the system and the device; the error and its code;
    /// the facts of the book (`BookFacts`: its kind, EPUB version and the
    /// program that made it); and the app's recent log, which leaves out
    /// book titles and file names.
    static func writeBookDiagnostics(error: Error, bookURL: URL?, now: Date = Date()) throws -> URL {
        let facts = bookURL.map(BookFacts.read(url:))
        let text = bookDiagnostics(error: error, facts: facts, log: recentLog(), now: now)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Report", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(DiagnosticLog.fileName(at: now)
            .replacingOccurrences(of: "Diagnostics", with: "Report"))
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The diagnostics' text (the tests check it).
    static func bookDiagnostics(error: Error, facts: BookFacts?, log: String, now: Date) -> String {
        var lines = [
            "Platen Reader problem report, made \(ISO8601DateFormatter().string(from: now))",
            DiagnosticLog.aboutThisDevice,
            "",
            "Error code: \(ErrorCode.code(for: error))",
            "Error: \(describe(error))",
        ]
        if let facts {
            lines.append("")
            lines += facts.lines
        }
        if !log.isEmpty {
            lines += ["", "Recent log (book titles, file names and searches are left out):", log]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The error: for Platen's own, its message and the detail under it;
    /// for the system's (a file that could not be read), only where it came
    /// from (domain and code, and those of the error under it), as their
    /// messages name the file.
    static func describe(_ error: Error) -> String {
        if error is BookOpenError || error is PDFOpenError, let local = error as? LocalizedError {
            return [local.errorDescription, local.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError { text += ", under it \(under.domain) \(under.code)" }
        return text
    }

    /// The last part of the diagnostic log (the latest 200 lines).
    private static func recentLog() -> String {
        guard let url = try? DiagnosticLog.shared.export(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).joined(separator: "\n")
    }
}

/// Short codes for why a book would not open, in the subject's tag and the
/// diagnostics ("E-1030"), so reports can be sorted at a glance. Codes are
/// never reused for something else.
enum ErrorCode {
    static func code(for error: Error) -> String {
        "E-\(number(for: error))"
    }

    static func number(for error: Error) -> Int {
        switch error {
        case let error as BookOpenError:
            switch error {
            case .drm(let scheme):
                switch scheme {
                case .adobeADEPT: return 1001
                case .appleFairPlay: return 1002
                case .readiumLCP: return 1003
                case .kindle: return 1004
                case .unknown: return 1009
                }
            case .kfx: return 1010
            case .unsupportedFormat: return 1020
            case .unreadable: return 1030
            }
        case let error as PDFOpenError:
            switch error {
            case .unreadable: return 1040
            case .locked: return 1041
            }
        default:
            let ns = error as NSError
            // The file could not be read at all (gone, no permission, not
            // downloaded from iCloud).
            if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain { return 1050 }
            return 1099
        }
    }

    /// Whether the error is the book's DRM, which a report cannot help
    /// with: the failure screen links to the guide instead.
    static func isDRM(_ error: Error) -> Bool {
        if case .drm = error as? BookOpenError { return true }
        return false
    }
}
