import Foundation

/// Random access to the bytes of a book file.
///
/// Platen reads books in one of two ways (see the spec, "Opening"):
/// - books up to 50 MB are read into memory in one sequential read, so a
///   sleeping NAS or dropped network connection can never interrupt reading;
/// - larger books are read lazily through a seekable file handle, one zip
///   entry at a time, so a 300 MB illustrated book does not fill memory.
///
/// Everything above this layer (the zip reader, the package parser) only sees
/// this protocol and does not care which of the two it is talking to.
public protocol ByteSource: AnyObject, Sendable {
    /// Total length of the file in bytes.
    var size: UInt64 { get }
    /// Reads up to `length` bytes starting at `offset`. Returns fewer bytes
    /// only when the read runs past the end of the file.
    func read(offset: UInt64, length: Int) throws -> Data
}

public enum ByteSourceError: Error, LocalizedError {
    case outOfBounds(offset: UInt64, length: Int, size: UInt64)

    public var errorDescription: String? {
        switch self {
        case let .outOfBounds(offset, length, size):
            return "Tried to read \(length) bytes at \(offset) in a file of \(size) bytes."
        }
    }
}

/// A book held entirely in memory.
public final class MemoryByteSource: ByteSource, @unchecked Sendable {
    // `Data` is immutable here, so sharing across threads is safe.
    public let data: Data

    public init(data: Data) {
        // Re-base the data so indices start at zero, whatever slice we got.
        self.data = data.startIndex == 0 ? data : Data(data)
    }

    public var size: UInt64 { UInt64(data.count) }

    public func read(offset: UInt64, length: Int) throws -> Data {
        guard offset <= size, length >= 0 else {
            throw ByteSourceError.outOfBounds(offset: offset, length: length, size: size)
        }
        let start = Int(offset)
        let end = min(data.count, start + length)
        // `subdata` copies, which keeps callers from holding slices of a
        // potentially large buffer with surprising indices.
        return data.subdata(in: start..<end)
    }
}

/// A book read lazily from disk (or a network share) through a file handle.
public final class FileByteSource: ByteSource, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock() // seek + read must happen together
    public let size: UInt64

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    public func read(offset: UInt64, length: Int) throws -> Data {
        guard offset <= size, length >= 0 else {
            throw ByteSourceError.outOfBounds(offset: offset, length: length, size: size)
        }
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }
}

// MARK: - Little-endian helpers

extension Data {
    /// Reads a little-endian unsigned integer at `offset` (relative to
    /// `startIndex`). Returns nil if the data is too short, so parsers can
    /// treat truncation as "corrupt" rather than crashing.
    @inlinable
    func le<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return nil }
        var value: T = 0
        let base = startIndex + offset
        for i in 0..<size {
            value |= T(self[base + i]) << (8 * i)
        }
        return value
    }

    /// Big-endian variant, used by the MOBI (Palm database) header.
    @inlinable
    func be<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return nil }
        var value: T = 0
        let base = startIndex + offset
        for i in 0..<size {
            value = (value << 8) | T(self[base + i])
        }
        return value
    }
}
