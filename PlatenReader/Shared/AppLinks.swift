import Foundation

/// Addresses the app links out to. Following one opens the reader's own
/// browser; the app itself never loads anything (spec: no network).
enum AppLinks {
    /// The Platen Reader website, from Settings (iOS).
    ///
    /// A placeholder until the site exists (asked for 22 Nov 2026): the
    /// domain follows the bundle ID (org.platenreader) and is not known to be
    /// registered. Change it here before release.
    static let website = URL(string: "https://platenreader.org")!
}
