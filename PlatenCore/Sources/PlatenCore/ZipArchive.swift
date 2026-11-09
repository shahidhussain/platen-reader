import Foundation

/// One file inside a zip archive, as described by the central directory (or,
/// for damaged files, by its local header).
public struct ZipEntry: Sendable, Hashable {
    /// The path inside the archive, exactly as stored (decoded to a String).
    public let path: String
    /// 0 = stored, 8 = deflate. Anything else is unsupported.
    public let method: UInt16
    public let flags: UInt16
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    /// Where this entry's local file header starts in the file.
    public let localHeaderOffset: UInt64

    public var isDirectory: Bool { path.hasSuffix("/") }
    /// Bit 0 of the flags: traditional zip encryption. EPUBs never use it
    /// legitimately; treat as unreadable.
    public var isEncrypted: Bool { flags & 0x1 != 0 }
}

public enum ZipError: Error, LocalizedError, Equatable {
    case notAZip
    case emptyArchive
    case entryNotFound(String)
    case unsupportedCompression(path: String, method: UInt16)
    case encryptedEntry(String)
    case corruptEntry(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "The file is not a zip archive."
        case .emptyArchive: return "The zip archive contains no files."
        case let .entryNotFound(path): return "“\(path)” is missing from the book."
        case let .unsupportedCompression(path, method):
            return "“\(path)” uses zip compression method \(method), which is not supported."
        case let .encryptedEntry(path): return "“\(path)” is encrypted."
        case let .corruptEntry(path): return "“\(path)” is damaged and could not be read."
        }
    }
}

/// A small, read-only zip reader that tolerates the problems found in real
/// EPUB files.
///
/// Supported: stored and deflate entries, Zip64 (archives and entries over
/// 4 GB or 65,535 entries), UTF-8 and legacy file names, extra data before the
/// archive (offsets are corrected), and, when the central directory is missing
/// or damaged, recovery by scanning local file headers.
///
/// Nothing is ever extracted to disk: `data(for:)` returns one entry's bytes.
public final class ZipArchive: @unchecked Sendable {
    // Signatures (little-endian "PK.." markers).
    private static let localHeaderSig: UInt32 = 0x0403_4B50
    private static let centralHeaderSig: UInt32 = 0x0201_4B50
    private static let endOfCentralDirSig: UInt32 = 0x0605_4B50
    private static let zip64EndSig: UInt32 = 0x0606_4B50
    private static let zip64LocatorSig: UInt32 = 0x0706_4B50
    private static let dataDescriptorSig: UInt32 = 0x0807_4B50

    public let source: ByteSource
    /// Entries in archive order. Directories are included.
    public let entries: [ZipEntry]
    /// Non-fatal problems found while reading the directory. Shown to the user
    /// only if the book then fails to open.
    public private(set) var problems: [String] = []
    /// True when the central directory was unusable and entries were found by
    /// scanning the file instead.
    public let wasRecovered: Bool

    private let byPath: [String: ZipEntry]

    public init(source: ByteSource) throws {
        self.source = source
        var problems: [String] = []
        var recovered = false
        var found: [ZipEntry]
        do {
            found = try Self.readCentralDirectory(source, problems: &problems)
        } catch {
            problems.append("Central directory unreadable (\(error)); scanning the file instead.")
            found = []
        }
        if found.isEmpty {
            // Either no directory or an empty one: try to recover entries by
            // walking the local file headers from the start of the file.
            found = Self.scanLocalHeaders(source, problems: &problems)
            recovered = !found.isEmpty
        }
        guard !found.isEmpty else {
            // Distinguish "not a zip at all" from "a zip with nothing in it".
            let head = (try? source.read(offset: 0, length: 4)) ?? Data()
            throw head.le(UInt32.self, at: 0) == Self.localHeaderSig
                || head.le(UInt32.self, at: 0) == Self.endOfCentralDirSig
                ? ZipError.emptyArchive : ZipError.notAZip
        }
        entries = found
        wasRecovered = recovered
        self.problems = problems
        // Later duplicates win, matching what most unzip tools do.
        var map: [String: ZipEntry] = [:]
        for entry in found { map[entry.path] = entry }
        byPath = map
    }

    /// Looks up an entry by its exact stored path.
    public func entry(at path: String) -> ZipEntry? {
        byPath[path]
    }

    /// Reads and decompresses one entry.
    /// - Parameter allowPartial: return whatever could be decoded from a
    ///   damaged entry instead of throwing.
    public func data(for entry: ZipEntry, allowPartial: Bool = false) throws -> Data {
        if entry.isEncrypted { throw ZipError.encryptedEntry(entry.path) }
        // The local header repeats the name and has its own extra field,
        // whose length can differ from the central directory's copy, so we
        // must read it to find where the data really starts.
        let header = try source.read(offset: entry.localHeaderOffset, length: 30)
        guard header.le(UInt32.self, at: 0) == Self.localHeaderSig,
              let nameLength = header.le(UInt16.self, at: 26),
              let extraLength = header.le(UInt16.self, at: 28)
        else { throw ZipError.corruptEntry(entry.path) }

        let dataStart = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)
        let available = source.size > dataStart ? source.size - dataStart : 0
        let toRead = min(entry.compressedSize, available)
        if toRead < entry.compressedSize && !allowPartial {
            throw ZipError.corruptEntry(entry.path)
        }
        guard toRead <= UInt64(Int.max) else { throw ZipError.corruptEntry(entry.path) }
        let compressed = try source.read(offset: dataStart, length: Int(toRead))

        switch entry.method {
        case 0:
            return compressed
        case 8:
            do {
                return try Inflate.inflate(
                    compressed,
                    expectedSize: Int(clamping: entry.uncompressedSize),
                    allowPartial: allowPartial
                )
            } catch {
                throw ZipError.corruptEntry(entry.path)
            }
        default:
            throw ZipError.unsupportedCompression(path: entry.path, method: entry.method)
        }
    }

    /// Convenience: read an entry by exact path.
    public func data(at path: String) throws -> Data {
        guard let entry = byPath[path] else { throw ZipError.entryNotFound(path) }
        return try data(for: entry)
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ source: ByteSource, problems: inout [String]) throws -> [ZipEntry] {
        // The end-of-central-directory record is 22 bytes plus an optional
        // comment of up to 65,535 bytes, so search the last 65,557 bytes,
        // backwards, for its signature.
        let tailLength = UInt64(min(source.size, 22 + 65_535))
        guard tailLength >= 22 else { return [] }
        let tailStart = source.size - tailLength
        let tail = try source.read(offset: tailStart, length: Int(tailLength))

        var eocdIndex: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail.le(UInt32.self, at: i) == endOfCentralDirSig {
                eocdIndex = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdIndex else { return [] }
        let eocdOffset = tailStart + UInt64(eocd)

        var entryCount = UInt64(tail.le(UInt16.self, at: eocd + 10) ?? 0)
        var cdSize = UInt64(tail.le(UInt32.self, at: eocd + 12) ?? 0)
        var cdOffset = UInt64(tail.le(UInt32.self, at: eocd + 16) ?? 0)

        // Zip64: the 32-bit fields are saturated and the real values live in
        // a Zip64 end record, found via a locator just before the EOCD.
        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF, eocdOffset >= 20 {
            let locator = try source.read(offset: eocdOffset - 20, length: 20)
            if locator.le(UInt32.self, at: 0) == zip64LocatorSig,
               let zip64Offset = locator.le(UInt64.self, at: 8),
               zip64Offset < source.size {
                let record = try source.read(offset: zip64Offset, length: 56)
                if record.le(UInt32.self, at: 0) == zip64EndSig {
                    entryCount = record.le(UInt64.self, at: 32) ?? entryCount
                    cdSize = record.le(UInt64.self, at: 40) ?? cdSize
                    cdOffset = record.le(UInt64.self, at: 48) ?? cdOffset
                }
            }
        }

        // "Extra data" tolerance: if bytes were prepended to the archive (for
        // example a self-extractor stub), every stored offset is off by the
        // same amount. The directory always sits right before the EOCD, so we
        // can measure the shift and correct for it.
        var shift: Int64 = 0
        if cdSize <= eocdOffset {
            let actualCDOffset = eocdOffset - cdSize
            if actualCDOffset != cdOffset {
                // Only trust this if there is no Zip64 end record in between.
                let probe = try source.read(offset: actualCDOffset, length: 4)
                if probe.le(UInt32.self, at: 0) == centralHeaderSig {
                    shift = Int64(actualCDOffset) - Int64(cdOffset)
                    problems.append("Archive offsets shifted by \(shift) bytes; corrected.")
                    cdOffset = actualCDOffset
                }
            }
        }

        guard cdOffset < source.size, cdSize <= source.size - cdOffset, cdSize <= UInt64(Int.max) else {
            throw ZipError.corruptEntry("central directory")
        }
        let directory = try source.read(offset: cdOffset, length: Int(cdSize))

        var result: [ZipEntry] = []
        result.reserveCapacity(Int(min(entryCount, 100_000)))
        var p = 0
        while p + 46 <= directory.count, directory.le(UInt32.self, at: p) == centralHeaderSig {
            guard let flags = directory.le(UInt16.self, at: p + 8),
                  let method = directory.le(UInt16.self, at: p + 10),
                  let csize32 = directory.le(UInt32.self, at: p + 20),
                  let usize32 = directory.le(UInt32.self, at: p + 24),
                  let nameLength = directory.le(UInt16.self, at: p + 28).map(Int.init),
                  let extraLength = directory.le(UInt16.self, at: p + 30).map(Int.init),
                  let commentLength = directory.le(UInt16.self, at: p + 32).map(Int.init),
                  let offset32 = directory.le(UInt32.self, at: p + 42),
                  p + 46 + nameLength + extraLength <= directory.count
            else { break }

            let nameData = directory.subdata(in: (directory.startIndex + p + 46)..<(directory.startIndex + p + 46 + nameLength))
            let extra = directory.subdata(in: (directory.startIndex + p + 46 + nameLength)..<(directory.startIndex + p + 46 + nameLength + extraLength))

            var csize = UInt64(csize32)
            var usize = UInt64(usize32)
            var offset = UInt64(offset32)
            parseZip64Extra(extra, usize: &usize, csize: &csize, offset: &offset)

            let corrected = UInt64(max(0, Int64(offset) + shift))
            result.append(ZipEntry(
                path: decodeName(nameData, utf8Flag: flags & 0x800 != 0),
                method: method,
                flags: flags,
                compressedSize: csize,
                uncompressedSize: usize,
                localHeaderOffset: corrected
            ))
            p += 46 + nameLength + extraLength + commentLength
        }
        if UInt64(result.count) != entryCount {
            problems.append("Directory lists \(entryCount) entries but \(result.count) were readable.")
        }
        return result
    }

    /// Zip64 "extended information" extra field (header ID 0x0001). Each
    /// 64-bit value is present only if its 32-bit counterpart is saturated,
    /// and always in this order.
    private static func parseZip64Extra(_ extra: Data, usize: inout UInt64, csize: inout UInt64, offset: inout UInt64) {
        var p = 0
        while p + 4 <= extra.count {
            guard let id = extra.le(UInt16.self, at: p),
                  let length = extra.le(UInt16.self, at: p + 2).map(Int.init) else { return }
            if id == 0x0001 {
                var q = p + 4
                if usize == 0xFFFF_FFFF, let v = extra.le(UInt64.self, at: q) { usize = v; q += 8 }
                if csize == 0xFFFF_FFFF, let v = extra.le(UInt64.self, at: q) { csize = v; q += 8 }
                if offset == 0xFFFF_FFFF, let v = extra.le(UInt64.self, at: q) { offset = v; q += 8 }
                return
            }
            p += 4 + length
        }
    }

    /// File names are UTF-8 when flag bit 11 is set. Older tools wrote code
    /// page 437 or the system encoding; try UTF-8 anyway (most such names are
    /// ASCII or UTF-8 in practice), then fall back to Latin-1, which never
    /// fails.
    private static func decodeName(_ data: Data, utf8Flag: Bool) -> String {
        if let name = String(data: data, encoding: .utf8) { return name }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Recovery scan

    /// Walks the file looking for local file headers. Used when the central
    /// directory is missing (truncated download) or unreadable.
    private static func scanLocalHeaders(_ source: ByteSource, problems: inout [String]) -> [ZipEntry] {
        // Recovery is only attempted for books we can hold in memory; for very
        // large damaged files, scanning over a network would be too slow.
        guard source.size <= 512 * 1024 * 1024,
              let data = try? source.read(offset: 0, length: Int(source.size)) else { return [] }

        var results: [ZipEntry] = []
        var p = 0
        while p + 30 <= data.count {
            guard data.le(UInt32.self, at: p) == localHeaderSig,
                  let flags = data.le(UInt16.self, at: p + 6),
                  let method = data.le(UInt16.self, at: p + 8),
                  let csize32 = data.le(UInt32.self, at: p + 18),
                  let usize32 = data.le(UInt32.self, at: p + 22),
                  let nameLength = data.le(UInt16.self, at: p + 26).map(Int.init),
                  let extraLength = data.le(UInt16.self, at: p + 28).map(Int.init),
                  p + 30 + nameLength + extraLength <= data.count
            else {
                // Not at a header: search forward for the next one.
                guard let next = nextSignature(in: data, from: p + 1) else { break }
                p = next
                continue
            }
            let nameData = data.subdata(in: (p + 30)..<(p + 30 + nameLength))
            let extra = data.subdata(in: (p + 30 + nameLength)..<(p + 30 + nameLength + extraLength))
            var csize = UInt64(csize32)
            var usize = UInt64(usize32)
            var ignored: UInt64 = 0
            parseZip64Extra(extra, usize: &usize, csize: &csize, offset: &ignored)

            let dataStart = p + 30 + nameLength + extraLength
            // When bit 3 is set the sizes come after the data, in a data
            // descriptor, and the header holds zeros. Use the next header as
            // the end bound; inflate stops at the stream's own end marker.
            let usesDescriptor = flags & 0x8 != 0 && csize == 0
            if usesDescriptor || UInt64(dataStart) + csize > UInt64(data.count) {
                let end = nextSignature(in: data, from: dataStart) ?? data.count
                var length = end - dataStart
                // Trim a trailing data descriptor from stored entries.
                if method == 0, length >= 16,
                   data.le(UInt32.self, at: end - 16) == dataDescriptorSig {
                    length -= 16
                }
                csize = UInt64(max(0, length))
                if usize == 0 { usize = csize }
            }
            results.append(ZipEntry(
                path: decodeName(nameData, utf8Flag: flags & 0x800 != 0),
                method: method,
                flags: flags,
                compressedSize: csize,
                uncompressedSize: usize,
                localHeaderOffset: UInt64(p)
            ))
            p = dataStart + Int(min(csize, UInt64(data.count - dataStart)))
        }
        if !results.isEmpty {
            problems.append("Recovered \(results.count) entries by scanning a damaged archive.")
        }
        return results
    }

    /// Next local header or central directory signature at or after `from`.
    private static func nextSignature(in data: Data, from: Int) -> Int? {
        guard from < data.count - 3 else { return nil }
        var i = from
        while i <= data.count - 4 {
            // Cheap first-byte check before reading four bytes.
            if data[i] == 0x50, data[i + 1] == 0x4B {
                let sig = data.le(UInt32.self, at: i)
                if sig == localHeaderSig || sig == centralHeaderSig { return i }
            }
            i += 1
        }
        return nil
    }
}
