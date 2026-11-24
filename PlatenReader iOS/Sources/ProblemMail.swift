import MessageUI
import SwiftUI
import UIKit

/// Problem reports and feedback on iOS (ProblemReport says what goes in
/// them): the system's mail composer, addressed to support, with the files
/// attached, for the reader to read, add to and send. Without a mail account
/// set up, the share sheet offers the files instead (and a book report says
/// where to send them). Platen sends nothing itself.
@MainActor
enum ProblemMail {
    /// "Report This Book…": writes the diagnostics (in the background: the
    /// book is read again for its facts), then the email.
    static func reportBook(error: Error, bookURL: URL?, attachBook: Bool, from controller: UIViewController) {
        DispatchQueue.global(qos: .userInitiated).async {
            let diagnostics = try? ProblemReport.writeBookDiagnostics(error: error, bookURL: bookURL)
            DispatchQueue.main.async {
                var files = [diagnostics].compactMap { $0 }
                if attachBook, let bookURL { files.append(bookURL) }
                compose(subject: ProblemReport.bookSubject(code: ErrorCode.code(for: error)),
                        body: ProblemReport.bookBody, attachments: files, from: controller)
            }
        }
    }

    /// Settings › Send Feedback: an empty email with the version and system
    /// in the subject.
    static func sendFeedback(from controller: UIViewController) {
        compose(subject: ProblemReport.feedbackSubject, body: "", attachments: [], from: controller)
    }

    private static let delegate = Delegate()

    private static func compose(subject: String, body: String, attachments: [URL], from controller: UIViewController) {
        if MFMailComposeViewController.canSendMail() {
            let mail = MFMailComposeViewController()
            mail.mailComposeDelegate = delegate
            mail.setToRecipients([AppLinks.supportEmail])
            mail.setSubject(subject)
            mail.setMessageBody(body, isHTML: false)
            for file in attachments {
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                let type = file.pathExtension == "txt" ? "text/plain" : "application/octet-stream"
                mail.addAttachmentData(data, mimeType: type, fileName: file.lastPathComponent)
            }
            controller.present(mail, animated: true)
            return
        }
        // No mail account: a mailto: link for another mail app, or, with
        // files to send, the share sheet.
        if attachments.isEmpty {
            if let url = ProblemReport.mailtoURL(subject: subject, body: body) { UIApplication.shared.open(url) }
            return
        }
        let share = UIActivityViewController(activityItems: attachments, applicationActivities: nil)
        share.popoverPresentationController?.sourceView = controller.view
        share.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY,
                                                                 width: 1, height: 1)
        let alert = UIAlertController(
            title: String(localized: "No Mail Account"),
            message: String(localized: "Send the report to \(AppLinks.supportEmail), with “\(subject)” as the subject."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Share Report…"), style: .default) { _ in
            controller.present(share, animated: true)
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        controller.present(alert, animated: true)
    }

    private final class Delegate: NSObject, MFMailComposeViewControllerDelegate {
        nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult,
                                               error: Error?) {
            MainActor.assumeIsolated { controller.dismiss(animated: true) }
        }
    }
}
