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

    /// Where problem reports and feedback go (Report This Book, Send
    /// Feedback).
    static let supportEmail = "support@platenreader.org"
}
