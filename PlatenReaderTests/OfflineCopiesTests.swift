import XCTest

/// Tests of `OfflineCopies` (Shared/OfflineCopies.swift): favourites kept
/// away from the device are copied to it, a copy goes when its book leaves
/// Favourites or the setting is turned off, and a changed original is
/// copied again. Books here are files in a temporary folder, standing in
/// for ones on a share or in iCloud (`needsCopy` says every book needs one).
@MainActor
final class OfflineCopiesTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private let suite = "org.platenreader.tests.offline"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineCopiesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("share"), withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    private func make() -> (RecentList, OfflineCopies) {
        let list = RecentList(kind: .favorites, directory: root.appendingPathComponent("recents"), limit: 1000)
        let copies = OfflineCopies(list: list, directory: root.appendingPathComponent("offline"), defaults: defaults,
                                   needsCopy: { _ in true })
        return (list, copies)
    }

    private func book(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent("share").appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Waits (up to 5 s) for a condition the copies' background work makes
    /// true.
    private func waitFor(_ what: String, _ condition: @escaping () -> Bool) async {
        let start = Date()
        while !condition(), Date().timeIntervalSince(start) < 5 { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), what)
    }

    func testAFavouriteIsCopiedAndItsCopyGoesWhenItIsNoLongerOne() async throws {
        let (list, copies) = make()
        let original = try book("Middlemarch.epub", "the book")
        let item = try XCTUnwrap(list.opened(original))
        XCTAssertTrue(copies.isEnabled, "on unless turned off")
        copies.sync()
        await waitFor("copied") { copies.copyURL(for: item) != nil }
        let copy = try XCTUnwrap(copies.copyURL(for: item))
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "the book")
        XCTAssertEqual(copy.lastPathComponent, "Middlemarch.epub")
        XCTAssertTrue(OfflineCopies.isCopy(copy, in: copies.directory))
        XCTAssertFalse(OfflineCopies.isCopy(original, in: copies.directory))
        XCTAssertEqual(copies.copyURL(forBookAt: item.path), copy, "found from Recent Books by its path")
        XCTAssertGreaterThan(copies.bytes, 0)

        // Taken off Favourites: the copy is deleted.
        list.remove(item)
        copies.sync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertNil(copies.copyURL(for: item))
        XCTAssertEqual(copies.bytes, 0)
    }

    func testTurningTheSettingOffDeletesEveryCopyAndOnCopiesAgain() async throws {
        let (list, copies) = make()
        let item = try XCTUnwrap(list.opened(try book("a.epub", "a")))
        copies.sync()
        await waitFor("copied") { copies.copyURL(for: item) != nil }
        copies.isEnabled = false
        XCTAssertNil(copies.copyURL(for: item))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: copies.directory.path))?.count ?? 0, 0)
        copies.isEnabled = true
        await waitFor("copied again") { copies.copyURL(for: item) != nil }
    }

    func testAChangedOriginalIsCopiedAgain() async throws {
        let (list, copies) = make()
        let original = try book("b.epub", "first")
        let item = try XCTUnwrap(list.opened(original))
        copies.sync()
        await waitFor("copied") { copies.copyURL(for: item) != nil }
        try Data("second, longer".utf8).write(to: original)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: original.path)
        copies.sync()
        await waitFor("copied again") {
            copies.copyURL(for: item).flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "second, longer"
        }
    }

    /// A book on the device itself needs no copy.
    func testBooksOnTheDeviceAreNotCopied() throws {
        let local = RecentItem(bookmark: Data(), name: "x.epub",
                               path: "/var/mobile/Containers/Data/Application/ID/Documents/x.epub", lastOpened: Date())
        XCTAssertFalse(OfflineCopies.isKeptElsewhere(local))
        let share = RecentItem(bookmark: Data(), name: "x.epub",
                               path: "/private/var/mobile/Library/LiveFiles/com.apple.filesystems.smbclientd/abc/books/x.epub",
                               lastOpened: Date())
        XCTAssertTrue(OfflineCopies.isKeptElsewhere(share))
        let cloud = RecentItem(bookmark: Data(), name: "x.epub",
                               path: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Books/x.epub",
                               lastOpened: Date())
        XCTAssertTrue(OfflineCopies.isKeptElsewhere(cloud))
    }
}
