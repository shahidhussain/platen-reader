import Foundation

/// Everything Platen remembers about one book: where the reader stopped and
/// their bookmarks. This is the only per-book data (see "Minimal state").
///
/// Stored as human-readable JSON, one file per book, at
/// `~/Library/Application Support/Platen Reader/books/<key>.json`.
/// The format is documented in docs/per-book-data.md.
public struct BookRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Bookmark: Codable, Equatable, Sendable {
        /// EPUB CFI of the first word on the bookmarked page. For a PDF,
        /// `page:<index>` (the page's index, counting from 0).
        public var cfi: String
        public var created: Date
        /// The first line of text, for the bookmarks list.
        public var snippet: String
        /// Chapter title at the bookmark, for the list. Optional: added after
        /// schema version 1 was first written, so older files lack it.
        public var chapter: String?
        /// Printed page number, when the book has a page list.
        public var page: String?
        /// Approximate position in the book (0–1), used only to sort the list.
        public var fraction: Double?

        public init(cfi: String, created: Date = Date(), snippet: String,
                    chapter: String? = nil, page: String? = nil, fraction: Double? = nil) {
            self.cfi = cfi
            self.created = created
            self.snippet = snippet
            self.chapter = chapter
            self.page = page
            self.fraction = fraction
        }
    }

    public var schemaVersion: Int = BookRecord.currentSchemaVersion
    public var key: String
    public var uniqueIdentifier: String?
    public var fingerprint: String
    /// Informational only; books are found by key, never by path.
    public var lastKnownPath: String?
    public var lastCFI: String?
    /// "paginated" or "scrolled".
    public var readingMode: String?
    public var bookmarks: [Bookmark] = []
    public var lastOpened: Date?
    /// PDFs only: the page shown when last read (index from 0), and the zoom
    /// if the reader zoomed in or out (nil when the page was fitted to the
    /// window). Optional, so files written before PDFs existed still load.
    public var lastPage: Int?
    public var lastZoom: Double?

    public init(key: String, uniqueIdentifier: String?, fingerprint: String) {
        self.key = key
        self.uniqueIdentifier = uniqueIdentifier
        self.fingerprint = fingerprint
    }
}

/// Reads and writes `BookRecord`s. Writes are atomic (write to a temporary
/// file, then rename) so a crash can never leave half a file, and debounced
/// so turning pages quickly does not mean writing on every turn.
public final class PositionStore: @unchecked Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "Platen.PositionStore")
    private var pending: [String: DispatchWorkItem] = [:]
    private let debounce: TimeInterval

    /// The default location in Application Support.
    public static var defaultDirectory: URL {
        #if DEBUG
        // Automated UI tests keep their positions and bookmarks in a
        // throwaway folder, away from the reader's own (see AppDefaults).
        if let home = ProcessInfo.processInfo.environment["PLATEN_TEST_HOME"] {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("books", isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Platen Reader", isDirectory: true)
            .appendingPathComponent("books", isDirectory: true)
    }

    public static let shared = PositionStore()

    public init(directory: URL = PositionStore.defaultDirectory, debounce: TimeInterval = 0.75) {
        self.directory = directory
        self.debounce = debounce
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Loads the record for a book, or nil if none exists or it is unreadable.
    public func load(key: String) -> BookRecord? {
        queue.sync {
            guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
            return try? Self.decoder.decode(BookRecord.self, from: data)
        }
    }

    /// Saves after a short delay; a newer save for the same book replaces a
    /// pending one.
    public func scheduleSave(_ record: BookRecord) {
        queue.async { [self] in
            pending[record.key]?.cancel()
            let work = DispatchWorkItem { [self] in
                pending[record.key] = nil
                write(record)
            }
            pending[record.key] = work
            queue.asyncAfter(deadline: .now() + debounce, execute: work)
        }
    }

    /// Saves immediately (e.g. when the window closes), replacing any pending
    /// save for the same book.
    public func saveNow(_ record: BookRecord) {
        queue.sync {
            pending[record.key]?.cancel()
            pending[record.key] = nil
            write(record)
        }
    }

    /// Deletes every record (Settings > Advanced).
    public func removeAll() throws {
        try queue.sync {
            pending.values.forEach { $0.cancel() }
            pending.removeAll()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    // Must be called on `queue`.
    private func write(_ record: BookRecord) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(record)
            try data.write(to: url(for: record.key), options: [.atomic])
        } catch {
            // Losing a position is unfortunate but never worth interrupting
            // reading for; log and carry on.
            NSLog("Platen: could not save reading position: \(error)")
        }
    }
}
