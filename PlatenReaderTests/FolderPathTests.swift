import XCTest

/// Tests of `FolderScanner.standardPath` and `canonicalPath`
/// (Shared/BookFolder.swift): paths worked out from the text alone, never
/// the disk, the same as `standardizedFileURL` gives.
final class FolderPathTests: XCTestCase {
    func testStandardPathMatchesFoundationWithoutTheDisk() {
        let paths = [
            "/var/mobile/Containers/Shared/AppGroup/X/File Provider Storage/Books/Moby Dick.epub",
            "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Comics/Kafka",
            "/Users/me/Books/./novel.epub",
            "/Users/me/Books/Old/../novel.epub",
            "/Users/me/Books/Ünïcödé & spaces #1.pdf",
            "/Users/me/.hidden/book.epub",
        ]
        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: false)
            XCTAssertEqual(FolderScanner.standardPath(url), url.standardizedFileURL.path, path)
        }
    }

    func testAFolderURLHasNoTrailingSlash() {
        let url = URL(fileURLWithPath: "/Users/me/Books/Comics", isDirectory: true)
        XCTAssertEqual(FolderScanner.standardPath(url), "/Users/me/Books/Comics")
    }

    func testCanonicalPathDropsPrivate() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Books/a.epub", isDirectory: false)
        XCTAssertEqual(FolderScanner.canonicalPath(url), "/var/mobile/Books/a.epub")
    }
}
