import Foundation

/// How Platen recognises a PDF again after it is renamed or moved: the same
/// fingerprint as a book (file size plus a hash of the first and last 64 KB),
/// with the PDF's document ID in place of an EPUB's OPF identifier (spec,
/// "PDF"). Rendering is PDFKit's job, in the apps; this only reads bytes, so
/// it stays platform-neutral and testable.
public enum PDFIdentity {
    /// True if the bytes start like a PDF ("%PDF-"). PDFs may have a little
    /// junk before the header, so the first kilobyte is searched.
    public static func looksLikePDF(_ head: Data) -> Bool {
        head.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    /// The fingerprint and the key for the per-book data file.
    public static func identify(source: ByteSource) throws -> (documentID: String?, fingerprint: String, key: String) {
        let fingerprint = try BookIdentity.fingerprint(of: source)
        let tailLength = Int(min(source.size, UInt64(BookIdentity.sampleLength)))
        let tail = try source.read(offset: source.size - UInt64(tailLength), length: tailLength)
        let documentID = documentID(inTail: tail)
        // Prefixed so a PDF's key can never collide with an EPUB whose OPF
        // identifier happens to be the same string.
        let key = BookIdentity.key(uniqueIdentifier: documentID.map { "pdf:" + $0 }, fingerprint: fingerprint)
        return (documentID, fingerprint, key)
    }

    /// The first part of the trailer's `/ID [<…> <…>]`, which stays the same
    /// when a PDF is edited (the second part changes). Found in the last
    /// trailer or cross-reference stream, so near the end of the file; the
    /// last occurrence wins, as it belongs to the latest revision.
    static func documentID(inTail tail: Data) -> String? {
        // Latin-1 maps every byte to one character, so binary data cannot
        // make the decoding fail.
        guard let text = String(data: tail, encoding: .isoLatin1) else { return nil }
        var found: String?
        var searchRange = text.startIndex..<text.endIndex
        while let idRange = text.range(of: "/ID", range: searchRange) {
            searchRange = idRange.upperBound..<text.endIndex
            // Skip whitespace, then expect "[" and a hex string "<…>".
            var i = idRange.upperBound
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex, text[i] == "[" else { continue }
            i = text.index(after: i)
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex, text[i] == "<",
                  let close = text[i...].firstIndex(of: ">") else { continue }
            let hex = text[text.index(after: i)..<close].filter { !$0.isWhitespace }
            if !hex.isEmpty, hex.allSatisfy(\.isHexDigit) { found = hex.lowercased() }
        }
        return found
    }
}
