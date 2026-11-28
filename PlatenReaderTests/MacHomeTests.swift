import AppKit
import XCTest

/// The Mac's Home window runs on the iOS home screen's shared code
/// (HomeViews.swift, FolderView.swift); these are the parts that differ on
/// the Mac (these tests run on the Mac).
final class MacHomeTests: XCTestCase {
    func testPathsInTheHomeFolderAreShortenedWithATilde() {
        let home = "/Users/reader"
        XCTAssertEqual(StoragePlace.homeShortened("/Users/reader/Books/Sci-Fi", home: home), "~/Books/Sci-Fi")
        XCTAssertEqual(StoragePlace.homeShortened("/Users/reader", home: home), "~")
        XCTAssertEqual(StoragePlace.homeShortened("/Users/reader/Books", home: home + "/"), "~/Books",
                       "a home folder given with a trailing slash")
        XCTAssertEqual(StoragePlace.homeShortened("/Users/readers/Books", home: home), "/Users/readers/Books",
                       "another folder whose name starts the same is not the home folder")
        XCTAssertEqual(StoragePlace.homeShortened("/Volumes/Books", home: home), "/Volumes/Books")
    }

    func testAFolderInTheHomeFolderIsOnThisMac() {
        let place = StoragePlace(path: NSHomeDirectory() + "/Books")
        XCTAssertEqual(place.kind, .device)
        XCTAssertEqual(place.location, "~/Books")
        XCTAssertEqual(StorageKind.device.symbol, "internaldrive")
    }

    func testTheAppComingToTheFrontIsTheMacsOwnNotification() {
        XCTAssertEqual(Notification.Name.platenAppReturned, NSApplication.didBecomeActiveNotification)
    }

    @MainActor
    func testCoversGetSmallerAsMoreFitAcrossAndAStepStaysInRange() {
        let widths = (3...8).map(CoverColumns.macCoverWidth)
        XCTAssertEqual(widths, widths.sorted(by: >), "fewer across means bigger covers")
        let options = BookTypeFilter.shared
        let before = options.columns
        defer { options.columns = before }
        options.columns = 3
        CoverColumns.step(options, roomy: true, bigger: true)
        XCTAssertEqual(options.columns, 3, "already the biggest")
        CoverColumns.step(options, roomy: true, bigger: false)
        XCTAssertEqual(options.columns, 4)
        XCTAssertEqual(CoverColumns.items(options, roomy: true).count, 1, "one adaptive column: as many as fit")
    }

    /// A folder chosen on the Mac is kept with a security-scoped link (for the
    /// sandboxed App Store build to come), and found again from it.
    @MainActor
    func testAChosenFolderIsFoundAgainFromItsLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacHome-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Books", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let list = RecentList(kind: .folders, directory: root.appendingPathComponent("recents"))
        let item = try XCTUnwrap(list.opened(folder))
        let found = try XCTUnwrap(RecentList.resolve(item))
        XCTAssertEqual(FolderScanner.canonicalPath(found), FolderScanner.canonicalPath(folder))
    }
}
