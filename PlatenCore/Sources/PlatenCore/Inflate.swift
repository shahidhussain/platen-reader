import Compression
import Foundation

/// Decompresses raw DEFLATE data (zip compression method 8).
///
/// Apple's Compression framework calls this algorithm `COMPRESSION_ZLIB`,
/// but it actually expects a raw deflate stream with no zlib header, which is
/// exactly what zip files contain.
enum Inflate {
    enum Failure: Error {
        case cannotInitialise
        case corruptStream
        case truncatedStream
    }

    /// - Parameters:
    ///   - input: The compressed bytes. Extra bytes after the end of the
    ///     deflate stream (for example a data descriptor) are ignored.
    ///   - expectedSize: The uncompressed size from the zip directory. Used
    ///     only to size the output buffer; it is not trusted.
    ///   - allowPartial: When true, a corrupt or truncated stream returns
    ///     whatever was decoded before the damage instead of throwing. Used to
    ///     "open what can be read" from damaged books.
    /// - Returns: The decompressed bytes.
    static func inflate(_ input: Data, expectedSize: Int, allowPartial: Bool = false) throws -> Data {
        if input.isEmpty { return Data() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            != COMPRESSION_STATUS_ERROR else { throw Failure.cannotInitialise }
        defer { compression_stream_destroy(stream) }

        let chunkSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var output = Data()
        // Cap the reservation so a lying header cannot make us allocate GBs.
        output.reserveCapacity(min(max(expectedSize, 0), 256 * 1024 * 1024))

        var finished = false
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count

            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunkSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.pointee.dst_size
                if produced > 0 { output.append(buffer, count: produced) }

                switch status {
                case COMPRESSION_STATUS_END:
                    finished = true
                    return
                case COMPRESSION_STATUS_OK:
                    // No input left and nothing produced: the stream was cut
                    // off before its end marker.
                    if stream.pointee.src_size == 0 && produced == 0 { return }
                default:
                    if allowPartial { return }
                    throw Failure.corruptStream
                }
            }
        }
        if !finished && !allowPartial { throw Failure.truncatedStream }
        return output
    }
}
