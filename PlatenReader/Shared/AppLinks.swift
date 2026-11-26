import Foundation

/// Addresses the app links out to. Following one opens the reader's own
/// browser or mail app; the app itself never loads anything (spec: no
/// network).
///
/// PLACEHOLDERS until the site and the mailbox exist (asked for 22 and 24
/// Nov 2026): change them here before release. Shipped copies keep whatever
/// is here for good, so each should be on a domain Platen owns, with the
/// paths below redirected on the server and the address forwarded to
/// wherever support is read: then where they lead can change without an
/// update.
enum AppLinks {
    /// The Platen Reader website (Settings on iOS, the About window).
    static let website = URL(string: "https://platenreader.org")!

    /// The guide to DRM-protected books: why Platen cannot open them, and
    /// what to do instead. The failure screen for a DRM book links to it.
    static let drmGuide = URL(string: "https://platenreader.org/drm")!

    /// The privacy policy (About, and Settings on iOS; also given to App
    /// Store Connect), on the author's site.
    static let privacyPolicy = URL(string: "https://shahidhussain.com/projects/platen-reader/privacy/")!
    /// The author's website (About: "Made by Shahid Hussain").
    static let author = URL(string: "https://shahidhussain.com")!

    /// The source code: the GitHub repository (from the git remote).
    static let repository = URL(string: "https://github.com/shahidhussain/platen-reader")!
    /// The app's licence, the MPL 2.0, as it is in the repository.
    static let licence = repository.appendingPathComponent("blob/main/LICENSE")
    /// A new issue on GitHub (About: "Report an Issue").
    static let newIssue = repository.appendingPathComponent("issues/new")

    /// Where problem reports and feedback go (Report This Book, Send
    /// Feedback).
    static let supportEmail = "support@platenreader.org"
}
