import XCTest

/// The natural voice's download (`KokoroVoiceDownloader`): a file is used
/// only if it is exactly the pinned one.
final class KokoroVoiceDownloadTests: XCTestCase {
    func testTheChecksumIsSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try KokoroVoiceDownloader.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testAFileThatIsNotThePinnedOneIsRefused() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString).zip")
        try Data(repeating: 7, count: 1000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try KokoroVoiceDownloader.install(from: file)) { error in
            guard case KokoroVoiceDownloadError.damaged = error else { return XCTFail("\(error)") }
        }
    }

    /// The pin is the release's: an https address on GitHub, and a SHA-256.
    func testThePinIsAGitHubReleaseWithAHash() {
        XCTAssertEqual(KokoroVoiceRelease.url.scheme, "https")
        XCTAssertEqual(KokoroVoiceRelease.url.host, "github.com")
        XCTAssertEqual(KokoroVoiceRelease.sha256.count, 64)
    }
}
