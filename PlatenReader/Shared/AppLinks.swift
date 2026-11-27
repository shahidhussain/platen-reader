import Foundation

/// Addresses the app links out to. Following one opens the reader's own
/// browser or mail app; the app itself never loads anything (spec: no
/// network).
///
/// All real (27 Nov 2026): the website, the DRM guide and the privacy
/// policy are pages of Platen Reader's section of the author's site, which
/// keeps those addresses (and the guide's #drm anchor) for good, and every
/// email goes to the one support address. Shipped copies keep
/// whatever is here for good, so change one only for an address that will
/// stay.
enum AppLinks {
    /// The Platen Reader website (Settings on iOS, the About window): its
    /// page on the author's site.
    static let website = URL(string: "https://shahidhussain.com/projects/platen-reader/")!

    /// The guide to DRM-protected books ("Books that won't open because of
    /// DRM" on the support page): what DRM is, why Platen cannot open such
    /// books, and what to do instead, for readers who have never heard of
    /// it. The failure screen for a DRM book links to it.
    static let drmGuide = URL(string: "https://shahidhussain.com/projects/platen-reader/support/#drm")!

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
    /// Feedback): the one address all of Platen's email goes to.
    static let supportEmail = "platen@shahidhussain.com"
}
