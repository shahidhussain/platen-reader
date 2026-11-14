import CryptoKit
import Foundation

/// Covers already made, kept in the Caches folder so the folder view can
/// show them at once next time. The system may empty Caches whenever it
/// likes; the covers are then simply made again.
///
/// A book's entry is keyed on its path, size and modification date, so a
/// book that is replaced or edited gets a new cover, and none of the book's
/// own bytes need reading to find its entry. (A moved book is looked at
/// again, which is cheap.) Each entry is two files: `<key>.json` (the
/// title, the authors and whether there is a picture) and `<key>.jpg`.
public final class CoverCache: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public var info: BookCoverInfo
        /// The cover picture, if the book has one.
        public var imageURL: URL?
    }

    /// What is written to `<key>.json`.
    private struct Record: Codable {
        var version: Int
        var info: BookCoverInfo
        var hasImage: Bool
    }

    public let directory: URL
    /// The longest side of the pictures made, in pixels.
    public let maxPixelSize: Int

    public init(directory: URL, maxPixelSize: Int = 720) {
        self.directory = directory
        self.maxPixelSize = maxPixelSize
    }

    /// The cache in the app's own Caches folder.
    public static func standard(maxPixelSize: Int = 720) -> CoverCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return CoverCache(directory: caches.appendingPathComponent("Covers", isDirectory: true), maxPixelSize: maxPixelSize)
    }

    /// The key for a book file, from what the file system says about it.
    public static func key(path: String, size: Int64, modified: Date) -> String {
        let input = "\(path)|\(size)|\(modified.timeIntervalSinceReferenceDate)"
        return SHA256.hash(data: Data(input.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The key for a book file, or nil if it cannot be looked at.
    public static func key(for url: URL) -> String? {
        // URLs keep what they were told about the file; ask afresh.
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return key(path: url.standardizedFileURL.path, size: Int64(size), modified: modified)
    }

    /// The cached cover, if there is one made by the current `BookCover`.
    public func cached(key: String) -> Entry? {
        guard let data = try? Data(contentsOf: jsonURL(key)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == BookCover.version else { return nil }
        let image = imageURL(key)
        if record.hasImage, !FileManager.default.fileExists(atPath: image.path) { return nil }
        return Entry(info: record.info, imageURL: record.hasImage ? image : nil)
    }

    /// Saves a cover made by `BookCover`.
    @discardableResult
    public func store(_ result: BookCover.Result, key: String) -> Entry {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var hasImage = false
        if let jpeg = result.jpeg {
            hasImage = (try? jpeg.write(to: imageURL(key), options: .atomic)) != nil
        }
        let record = Record(version: BookCover.version, info: result.info, hasImage: hasImage)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: jsonURL(key), options: .atomic)
        }
        return Entry(info: result.info, imageURL: hasImage ? imageURL(key) : nil)
    }

    /// The book's cover: from the cache, or made now and cached. Slow the
    /// first time (it reads the book), so call it off the main thread.
    public func cover(for url: URL) -> Entry {
        let key = Self.key(for: url)
        if let key, let entry = cached(key: key) { return entry }
        let result = BookCover.extract(from: url, maxPixelSize: maxPixelSize)
        guard let key else { return Entry(info: result.info, imageURL: nil) }
        return store(result, key: key)
    }

    private func jsonURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }
    private func imageURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".jpg") }
}
