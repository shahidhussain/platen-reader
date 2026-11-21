import XCTest
import PlatenCore

/// Tests of the folder view's shared logic (Shared/BookFolder.swift): what
/// a folder lists, iCloud's stand-ins for books not yet downloaded, and the
/// chosen folder kept across launches.
final class BookFolderTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func touch(_ folder: URL, _ name: String) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
    }

    func testListsBooksAndFoldersInFinderOrder() throws {
        let folder = try temporaryFolder()
        for name in ["Book 10.epub", "Book 2.epub", "notes.docx", "Report.PDF", "Tale.kepub.epub", "readme.txt", ".DS_Store"] {
            touch(folder, name)
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Series"), withIntermediateDirectories: false)

        let entries = FolderScanner.entries(in: folder)
        XCTAssertEqual(entries.map(\.name), ["Series", "Book 2", "Book 10", "readme", "Report", "Tale"])
        XCTAssertEqual(entries.first?.kind, .folder)
        XCTAssertTrue(entries.dropFirst().allSatisfy { $0.kind == .book && $0.isDownloaded })
    }

    func testICloudStandInsShowAsBooksNotDownloaded() throws {
        let folder = try temporaryFolder()
        touch(folder, ".Far Away.epub.icloud")
        touch(folder, ".notes.docx.icloud") // not a book
        touch(folder, ".icloud")            // nothing to name

        let entries = FolderScanner.entries(in: folder)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Far Away")
        XCTAssertEqual(entries[0].url.lastPathComponent, "Far Away.epub")
        XCTAssertFalse(entries[0].isDownloaded)
    }

    func testMissingFolderListsNothing() {
        XCTAssertEqual(FolderScanner.entries(in: URL(fileURLWithPath: "/no/such/folder")), [])
    }

    func testInsideTreatsPrivateVarAsVar() {
        let folder = URL(fileURLWithPath: "/var/mobile/Books")
        XCTAssertTrue(FolderScanner.isInside(URL(fileURLWithPath: "/private/var/mobile/Books/a/b.epub"), folder: folder))
        XCTAssertTrue(FolderScanner.isInside(folder, folder: folder))
        XCTAssertFalse(FolderScanner.isInside(URL(fileURLWithPath: "/var/mobile/Books2/b.epub"), folder: folder))
    }
}

/// The opening stages behind the loading bar (Shared/OpeningProgress.swift).
final class OpeningStageTests: XCTestCase {
    func testStagesMoveTheBarForwardAndNeverFillIt() {
        let stages: [OpeningStage] = [.downloading, .reading, .preparing, .layingOut]
        XCTAssertEqual(stages, stages.sorted())
        let targets = stages.map(\.progress)
        XCTAssertEqual(targets, targets.sorted(), "each stage moves the bar on")
        XCTAssertLessThan(targets.last ?? 1, 1, "the bar fills only when the page is shown")
        XCTAssertTrue(stages.allSatisfy { !$0.label.isEmpty })
    }

    @MainActor
    func testANewReaderStartsOpening() {
        XCTAssertEqual(ReaderState().opening, .reading)
    }
}

/// Recent Books and Recent Folders (Shared/Recents.swift), and folder search.
final class RecentsTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func file(_ folder: URL, _ name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    @MainActor
    func testNewestFirstOncePerItemAndKeptAcrossLaunches() throws {
        let folder = try temporaryFolder()
        let store = folder.appendingPathComponent("recents")
        let list = RecentList(kind: .books, directory: store)
        let a = file(folder, "A.epub"), b = file(folder, "B.epub")
        list.opened(a, now: Date(timeIntervalSince1970: 1))
        list.opened(b, now: Date(timeIntervalSince1970: 2))
        list.opened(a, title: "Book A", author: "Ann", now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(list.items.map(\.name), ["A.epub", "B.epub"])
        XCTAssertEqual(list.items[0].displayName, "Book A")
        XCTAssertEqual(list.items[1].displayName, "B")

        let relaunched = RecentList(kind: .books, directory: store)
        XCTAssertEqual(relaunched.items, list.items)
        XCTAssertEqual(RecentList(kind: .folders, directory: store).items, [], "books and folders are kept apart")
    }

    @MainActor
    func testCoversAreKeptAndRemovedWithTheirItem() throws {
        let folder = try temporaryFolder()
        let list = RecentList(kind: .books, directory: folder.appendingPathComponent("recents"))
        let item = try XCTUnwrap(list.opened(file(folder, "A.epub")))
        XCTAssertNil(list.coverURL(for: item))
        list.update(item.id, title: "Title", author: nil, cover: Data("jpeg".utf8))
        let updated = list.items[0]
        let cover = try XCTUnwrap(list.coverURL(for: updated))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cover.path))
        list.remove(updated)
        XCTAssertEqual(list.items, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.path))
    }

    @MainActor
    func testTheListIsCapped() throws {
        let folder = try temporaryFolder()
        let list = RecentList(kind: .folders, directory: folder.appendingPathComponent("recents"), limit: 3)
        for i in 1...5 { list.opened(file(folder, "\(i)")) }
        XCTAssertEqual(list.items.map(\.name), ["5", "4", "3"])
    }

    /// Favourites are a list of their own, found by file, and kept apart
    /// from Recent Books.
    @MainActor
    func testFavouritesAreAListOfTheirOwn() throws {
        let folder = try temporaryFolder()
        let store = folder.appendingPathComponent("recents")
        let favourites = RecentList(kind: .favorites, directory: store)
        let books = RecentList(kind: .books, directory: store)
        let book = file(folder, "Middlemarch.epub")
        XCTAssertNil(favourites.item(at: book))
        favourites.opened(book)
        XCTAssertEqual(favourites.item(at: book)?.name, "Middlemarch.epub")
        XCTAssertTrue(books.items.isEmpty)
        XCTAssertEqual(RecentList(kind: .favorites, directory: store).items.map(\.name), ["Middlemarch.epub"])
        favourites.remove(try XCTUnwrap(favourites.item(at: book)))
        XCTAssertFalse(favourites.contains(book))
    }

    /// Recent Books → Favourites (a cover's long-press menu): the entry is
    /// copied, cover and all, without opening the book; marking it again
    /// changes nothing; removing it leaves Recent Books alone.
    @MainActor
    func testARecentBookCanBecomeAFavourite() throws {
        let folder = try temporaryFolder()
        let store = folder.appendingPathComponent("recents")
        let books = RecentList(kind: .books, directory: store)
        let favourites = RecentList(kind: .favorites, directory: store, limit: 1000)
        let book = file(folder, "Middlemarch.epub")
        let recent = try XCTUnwrap(books.opened(book, title: "Middlemarch", author: "George Eliot"))
        books.update(recent.id, title: nil, author: nil, cover: Data([1, 2, 3]))
        let withCover = try XCTUnwrap(books.item(at: book))

        let favourite = favourites.add(copyOf: withCover, from: books)
        XCTAssertNotEqual(favourite.id, withCover.id)
        XCTAssertEqual(favourite.title, "Middlemarch")
        XCTAssertEqual(favourite.author, "George Eliot")
        XCTAssertEqual(favourite.bookmark, withCover.bookmark)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(favourites.coverURL(for: favourite))), Data([1, 2, 3]))
        XCTAssertTrue(favourites.contains(book))

        XCTAssertEqual(favourites.add(copyOf: withCover, from: books).id, favourite.id)
        XCTAssertEqual(favourites.items.count, 1)

        favourites.remove(favourite)
        XCTAssertFalse(favourites.contains(book))
        XCTAssertTrue(books.contains(book))
        XCTAssertNotNil(books.coverURL(for: withCover).map { try? Data(contentsOf: $0) } ?? nil)
    }

    @MainActor
    func testAnOrderSetByHandIsKept() throws {
        let folder = try temporaryFolder()
        let store = folder.appendingPathComponent("recents")
        let list = RecentList(kind: .folders, directory: store, limit: 4)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for (i, name) in ["A", "B", "C"].enumerated() {
            list.opened(file(folder, name), now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(list.items.map(\.name), ["C", "B", "A"])
        XCTAssertFalse(list.isOrderedByHand)

        // Drag A to the top: the order is the reader's from now on.
        list.move(fromOffsets: [2], toOffset: 0)
        XCTAssertEqual(list.items.map(\.name), ["A", "C", "B"])
        XCTAssertTrue(list.isOrderedByHand)

        // Opening one again leaves it where it is; a new one goes on top.
        list.opened(file(folder, "B"), now: start.addingTimeInterval(10))
        XCTAssertEqual(list.items.map(\.name), ["A", "C", "B"])
        list.opened(file(folder, "D"), now: start.addingTimeInterval(11))
        XCTAssertEqual(list.items.map(\.name), ["D", "A", "C", "B"])

        // Full: the one opened longest ago (A, at 0) goes, wherever it is.
        list.opened(file(folder, "E"), now: start.addingTimeInterval(12))
        XCTAssertEqual(list.items.map(\.name), ["E", "D", "C", "B"])

        // Kept across launches.
        let relaunched = RecentList(kind: .folders, directory: store, limit: 4)
        XCTAssertTrue(relaunched.isOrderedByHand)
        XCTAssertEqual(relaunched.items.map(\.name), ["E", "D", "C", "B"])

        // Sort by Date: newest first again, and opening moves to the top.
        relaunched.sortByDate()
        XCTAssertFalse(relaunched.isOrderedByHand)
        XCTAssertEqual(relaunched.items.map(\.name), ["E", "D", "B", "C"])
        relaunched.opened(file(folder, "C"), now: start.addingTimeInterval(13))
        XCTAssertEqual(relaunched.items.first?.name, "C")
        XCTAssertFalse(RecentList(kind: .folders, directory: store).isOrderedByHand)
    }

    @MainActor
    func testAnItemThatHasGoneIsNotReachable() throws {
        let folder = try temporaryFolder()
        let list = RecentList(kind: .books, directory: folder.appendingPathComponent("recents"))
        let url = file(folder, "A.epub")
        let item = try XCTUnwrap(list.opened(url))
        XCTAssertNotNil(RecentList.check(item).url)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(RecentList.check(item).url)
    }

    /// The time limit answers even when the checks themselves cannot run
    /// (the file system not answering): it is kept on the main thread.
    @MainActor
    func testReachabilityAnswersWithinItsTimeLimit() async throws {
        let folder = try temporaryFolder()
        let list = RecentList(kind: .books, directory: folder.appendingPathComponent("recents"))
        let item = try XCTUnwrap(list.opened(file(folder, "A.epub")))
        let started = Date()
        if case .yes = await list.reachability(of: item, timeout: 5) {} else { XCTFail("should be found") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testSearchMatchesEveryWordInNameTitleOrAuthor() {
        XCTAssertTrue(FolderSearch.matches("", name: "anything"))
        XCTAssertTrue(FolderSearch.matches("eyre", name: "je.epub", title: "Jane Eyre"))
        XCTAssertTrue(FolderSearch.matches("bronte jane", name: "je.epub", title: "Jane Eyre", authors: ["Charlotte Brontë"]))
        XCTAssertTrue(FolderSearch.matches("KOBO", name: "kobo"))
        XCTAssertFalse(FolderSearch.matches("austen", name: "je.epub", title: "Jane Eyre", authors: ["Charlotte Brontë"]))
    }
}

/// Where recent folders are kept, worked out from their paths
/// (StoragePlace), and the folder view's filter by kind of book.
final class StorageAndFilterTests: XCTestCase {
    func testStorageKindsAndReadablePaths() {
        let iCloud = StoragePlace(path: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Books/Kids")
        XCTAssertEqual(iCloud, StoragePlace(kind: .iCloud, location: "iCloud Drive/Books/Kids"))

        let appCloud = StoragePlace(path: "/private/var/mobile/Library/Mobile Documents/iCloud~com~maker~Reader/Documents/Novels")
        XCTAssertEqual(appCloud, StoragePlace(kind: .iCloud, location: "iCloud Drive/Reader/Novels"))

        let share = StoragePlace(path: "/private/var/mobile/Library/LiveFiles/com.apple.filesystems.smbclientd/A1B2C3/both/books-kids/picturebooks")
        XCTAssertEqual(share, StoragePlace(kind: .network, location: "smb://both/books-kids/picturebooks"))

        let drive = StoragePlace(path: "/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/USB Stick/Books")
        XCTAssertEqual(drive.kind, .drive)
        XCTAssertTrue(drive.location.hasSuffix("USB Stick/Books"))

        let onPhone = StoragePlace(path: "/private/var/mobile/Containers/Shared/AppGroup/1234/File Provider Storage/Books")
        XCTAssertEqual(onPhone, StoragePlace(kind: .device, location: "On My iPhone/Books"))

        let ownFolder = StoragePlace(path: "/var/mobile/Containers/Data/Application/ABCD/Documents/Library Books")
        XCTAssertEqual(ownFolder, StoragePlace(kind: .device, location: "On My iPhone/Platen Reader/Library Books"))

        XCTAssertEqual(StoragePlace(path: "/Volumes/both/books").kind, .drive)
        XCTAssertEqual(StoragePlace(path: "/Users/me/Library/CloudStorage/Dropbox/Books").kind, .otherCloud)
    }

    func testOlderEntriesWorkOutTheirPlaceFromThePath() {
        let item = RecentItem(bookmark: Data(), name: "Kids",
                              path: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Books/Kids",
                              lastOpened: Date())
        XCTAssertEqual(item.storageKind, .iCloud)
        XCTAssertEqual(item.locationText, "iCloud Drive/Books/Kids")
    }

    func testBookFileTypesByExtension() {
        func type(_ name: String) -> BookFileType? { BookFileType(URL(fileURLWithPath: "/b/" + name)) }
        XCTAssertEqual(type("a.epub"), .epub)
        XCTAssertEqual(type("a.kepub.epub"), .kepub)
        XCTAssertEqual(type("a.KEPUB"), .kepub)
        XCTAssertEqual(type("a.mobi"), .mobi)
        XCTAssertEqual(type("a.prc"), .mobi)
        XCTAssertEqual(type("a.azw3"), .kindle)
        XCTAssertEqual(type("a.pdf"), .pdf)
        XCTAssertEqual(type("a.txt"), .text)
        XCTAssertNil(type("a.docx"))
    }

    @MainActor
    func testTheFilterAlwaysShowsAtLeastOneKindAndIsKept() throws {
        let suite = "org.platenreader.tests.filter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let filter = BookTypeFilter(defaults: defaults)
        XCTAssertTrue(filter.showsAll)
        for type in BookFileType.allCases { filter.toggle(type) }
        XCTAssertEqual(BookFileType.allCases.filter(filter.isShown), [.text], "the last kind stays shown")
        XCTAssertFalse(filter.shows(URL(fileURLWithPath: "/b/a.epub")))
        XCTAssertTrue(filter.shows(URL(fileURLWithPath: "/b/a.txt")))

        let relaunched = BookTypeFilter(defaults: defaults)
        XCTAssertEqual(BookFileType.allCases.filter(relaunched.isShown), [.text])
        relaunched.toggle(.epub)
        XCTAssertTrue(relaunched.isShown(.epub))
    }
}

extension RecentsTests {
    @MainActor
    func testOnePlaceUnderTwoSpellingsIsOneEntry() throws {
        let folder = try temporaryFolderForExtension()
        let store = folder.appendingPathComponent("recents")
        let list = RecentList(kind: .folders, directory: store)
        // The temporary folder is under /var/folders, which is a link to
        // /private/var/folders: one place, two spellings.
        let short = folder.standardizedFileURL.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        list.opened(URL(fileURLWithPath: short, isDirectory: true))
        list.opened(URL(fileURLWithPath: "/private" + short, isDirectory: true))
        XCTAssertEqual(list.items.count, 1)
        XCTAssertTrue(list.contains(URL(fileURLWithPath: "/private" + short)))
    }

    private func temporaryFolderForExtension() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// Keeping folder listings, and racing a check against its time limit.
final class FolderSpeedTests: XCTestCase {
    @MainActor
    func testAListingIsKeptForNextTime() {
        let folder = URL(fileURLWithPath: "/tmp/platen-test-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(FolderListingCache.listing(of: folder))
        let entries = [FolderEntry(url: folder.appendingPathComponent("a.epub"), name: "a", kind: .book)]
        FolderListingCache.keep(entries, of: folder)
        XCTAssertEqual(FolderListingCache.listing(of: folder), entries)
    }

    func testTheFirstAnswerWins() async {
        let answer: String = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            once.resume("time limit")
            once.resume("check") // too late: ignored
        }
        XCTAssertEqual(answer, "time limit")
    }
}

/// The folder view's sort orders (FolderSort).
final class FolderSortTests: XCTestCase {
    private func book(_ name: String, modified: Double, created: Double, size: Int64) -> FolderEntry {
        FolderEntry(url: URL(fileURLWithPath: "/b/\(name).epub"), name: name, kind: .book,
                    modified: Date(timeIntervalSince1970: modified), created: Date(timeIntervalSince1970: created), size: size)
    }

    func testEachOrderFoldersFirst() {
        let folder = FolderEntry(url: URL(fileURLWithPath: "/b/Z"), name: "Z", kind: .folder)
        let a = book("Book 10", modified: 1, created: 3, size: 50)
        let b = book("Book 2", modified: 3, created: 1, size: 10)
        let c = book("Alpha", modified: 2, created: 2, size: 99)
        let all = [a, b, folder, c]
        XCTAssertEqual(FolderSort.name.sorted(all).map(\.name), ["Z", "Alpha", "Book 2", "Book 10"])
        XCTAssertEqual(FolderSort.modified.sorted(all).map(\.name), ["Z", "Book 2", "Alpha", "Book 10"])
        XCTAssertEqual(FolderSort.created.sorted(all).map(\.name), ["Z", "Book 10", "Alpha", "Book 2"])
        XCTAssertEqual(FolderSort.size.sorted(all).map(\.name), ["Z", "Alpha", "Book 10", "Book 2"])
    }

    /// Title and author orders use what has been read of each book; a book
    /// with no title known goes by its file name, one with no author last.
    func testTitleAndAuthorOrders() {
        let a = book("a", modified: 0, created: 0, size: 0)
        let b = book("b", modified: 0, created: 0, size: 0)
        let c = book("Middle", modified: 0, created: 0, size: 0) // nothing read yet
        let info: [URL: BookCoverInfo] = [
            a.url: BookCoverInfo(title: "Zebra Days", authors: ["Anne Ames"]),
            b.url: BookCoverInfo(title: "Apples", authors: ["Zoe Zed"]),
        ]
        let all = [a, b, c]
        XCTAssertEqual(FolderSort.title.sorted(all, info: info).map(\.name), ["b", "Middle", "a"])
        XCTAssertEqual(FolderSort.author.sorted(all, info: info).map(\.name), ["a", "b", "Middle"])
    }
}
