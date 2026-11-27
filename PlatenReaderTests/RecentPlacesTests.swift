import XCTest

/// A saved folder is never taken to have moved onto, or off, a network
/// share or a drive: an iCloud Drive folder whose bookmark resolved to a
/// share's folder of the same name vanished from Home, merged into the
/// share's (reported 27 Nov 2026).
final class RecentPlacesTests: XCTestCase {
    private let iCloud = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Books"
    private let share = "/private/var/mobile/Library/LiveFiles/com.apple.filesystems.smbclientd/AbCd12/media/Books"
    private let otherMount = "/private/var/mobile/Library/LiveFiles/com.apple.filesystems.smbclientd/Zz9900/media/Books"
    private let onDevice = "/private/var/mobile/Containers/Shared/AppGroup/1234/File Provider Storage/Books"

    func testMovesWithinOneKindOfStorageAreFollowed() {
        XCTAssertTrue(RecentList.isPlausibleMove(from: share, to: otherMount), "a share mounted again elsewhere")
        XCTAssertTrue(RecentList.isPlausibleMove(from: iCloud, to: iCloud + " Old"))
        XCTAssertTrue(RecentList.isPlausibleMove(from: iCloud, to: onDevice), "moved in Files, iCloud to this device")
    }

    func testMovesOntoOrOffAShareOrADriveAreNot() {
        XCTAssertFalse(RecentList.isPlausibleMove(from: iCloud, to: share))
        XCTAssertFalse(RecentList.isPlausibleMove(from: share, to: iCloud))
        XCTAssertFalse(RecentList.isPlausibleMove(from: onDevice, to: "/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/USB/Books"))
    }

    @MainActor
    func testAnICloudFolderFoundOnAShareKeepsItsPlaceAndIsNotMerged() throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("RecentPlaces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let list = RecentList(kind: .folders, directory: store)
        let fake = Data("bookmark".utf8)
        let cloud = try XCTUnwrap(list.opened(URL(fileURLWithPath: iCloud, isDirectory: true), now: Date(timeIntervalSince1970: 1), bookmark: fake))
        list.opened(URL(fileURLWithPath: share, isDirectory: true), now: Date(timeIntervalSince1970: 2), bookmark: fake)
        XCTAssertEqual(list.items.count, 2)

        // The iCloud folder's bookmark led to the share's "Books".
        list.found(cloud.id, at: URL(fileURLWithPath: share, isDirectory: true))
        XCTAssertEqual(list.items.count, 2, "both folders stay on Home")
        // (Paths are kept in one form: "/var/…" for "/private/var/…".)
        XCTAssertEqual(list.items.first { $0.id == cloud.id }?.path,
                       FolderScanner.canonicalPath(URL(fileURLWithPath: iCloud)), "the iCloud folder keeps its own place")
    }
}
