import AppKit

/// Problem reports and feedback on the Mac (ProblemReport says what goes in
/// them): a new email in the reader's mail app, addressed to support, with
/// the files attached, for them to read, add to and send. Platen sends
/// nothing itself.
@MainActor
enum ProblemMail {
    /// "Report This Book…": writes the diagnostics (in the background: the
    /// book is read again for its facts), then the email.
    static func reportBook(error: Error, bookURL: URL?, attachBook: Bool, window: NSWindow?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let diagnostics = try? ProblemReport.writeBookDiagnostics(error: error, bookURL: bookURL)
            DispatchQueue.main.async {
                var files = [diagnostics].compactMap { $0 }
                if attachBook, let bookURL { files.append(bookURL) }
                compose(subject: ProblemReport.bookSubject(code: ErrorCode.code(for: error)),
                        body: ProblemReport.bookBody, attachments: files, window: window)
            }
        }
    }

    /// Help › Send Feedback…: an empty email with the version and system in
    /// the subject.
    static func sendFeedback(window: NSWindow?) {
        compose(subject: ProblemReport.feedbackSubject, body: "", attachments: [], window: window)
    }

    /// The email, through the system's "compose email" service (Mail, or
    /// the reader's chosen mail app). With no mail account set up to take
    /// attachments, it falls back to a mailto: link, and shows the files in
    /// Finder to be attached by hand.
    private static func compose(subject: String, body: String, attachments: [URL], window: NSWindow?) {
        let items: [Any] = (body.isEmpty ? [] : [body as NSString]) + attachments.map { $0 as NSURL }
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) {
            service.recipients = [AppLinks.supportEmail]
            service.subject = subject
            service.perform(withItems: items)
            log.info("problem report: email written (\(attachments.count) attachment(s))")
            return
        }
        log.info("problem report: no mail service; using a mailto: link")
        guard let url = ProblemReport.mailtoURL(subject: subject, body: body) else { return }
        NSWorkspace.shared.open(url)
        guard !attachments.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(attachments)
        let alert = NSAlert()
        alert.messageText = String(localized: "Attach the Report to the Email")
        alert.informativeText = String(localized: "Your mail app could not be given the files, so they are shown in Finder. Drag them into the email before sending it.")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
