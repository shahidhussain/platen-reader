import Foundation

/// Serves a book's files to the renderer, from memory, with fix-ups applied.
///
/// The app's `WKURLSchemeHandler` turns `platen://reader/book/<path>`
/// requests into calls to `resource(at:)`. Nothing is ever written to disk.
public struct BookResource: Sendable {
    public let data: Data
    public let mimeType: String
}

public enum BookResourceError: Error, LocalizedError {
    case notFound(String)
    case unreadable(String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(path): return "Not found in book: \(path)"
        case let .unreadable(path, underlying): return "Could not read \(path): \(underlying)"
        }
    }
}

extension Book {
    /// Special path that returns the whole file. foliate-js reads MOBI/AZW3
    /// files itself, from a single blob.
    public static let wholeFilePath = "__file__"

    /// Returns the bytes and MIME type for a path the renderer asked for.
    /// - Parameter path: the path inside the book, already percent-decoded
    ///   once by the scheme handler.
    public func resource(at path: String) throws -> BookResource {
        if path == Self.wholeFilePath {
            guard source.size <= UInt64(Int.max) else { throw BookResourceError.notFound(path) }
            let data = try source.read(offset: 0, length: Int(source.size))
            return BookResource(data: data, mimeType: "application/octet-stream")
        }
        if let data = syntheticFiles[path] {
            return BookResource(data: data, mimeType: MIMEType.forPath(path))
        }
        guard let archive, let resolver, let actual = resolver.resolve(path),
              let entry = archive.entry(at: actual)
        else { throw BookResourceError.notFound(path) }

        // Font obfuscation is undone here, in Swift, so encryption.xml is
        // hidden from foliate-js (otherwise it would try to undo it again).
        if actual == "META-INF/encryption.xml" && !obfuscatedFonts.isEmpty {
            throw BookResourceError.notFound(path)
        }

        var data: Data
        do {
            // allowPartial: a damaged chapter shows what survives rather than
            // nothing at all.
            data = try archive.data(for: entry, allowPartial: true)
        } catch {
            throw BookResourceError.unreadable(path, underlying: error.localizedDescription)
        }
        if let algorithm = obfuscatedFonts[actual], let package {
            data = FontDeobfuscator.deobfuscate(data, algorithm: algorithm, package: package)
        }
        let declared = package?.manifest.first { $0.path == actual }?.mediaType
        return BookResource(data: data, mimeType: MIMEType.forPath(actual, declared: declared))
    }
}

/// MIME types by file extension, preferring the manifest's declaration.
public enum MIMEType {
    static let byExtension: [String: String] = [
        "xhtml": "application/xhtml+xml", "xht": "application/xhtml+xml",
        "html": "text/html", "htm": "text/html",
        "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
        "xml": "application/xml", "opf": "application/oebps-package+xml",
        "ncx": "application/x-dtbncx+xml", "smil": "application/smil+xml",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "avif": "image/avif",
        "ttf": "font/ttf", "otf": "font/otf", "woff": "font/woff", "woff2": "font/woff2",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "ogg": "audio/ogg",
        "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm",
        "json": "application/json", "txt": "text/plain", "wasm": "application/wasm",
    ]

    public static func forPath(_ path: String, declared: String? = nil) -> String {
        if let declared, !declared.isEmpty { return declared }
        let ext = (path as NSString).pathExtension.lowercased()
        return byExtension[ext] ?? "application/octet-stream"
    }
}
