import CryptoKit
import Foundation

/// Reverses the light "obfuscation" publishers apply to embedded fonts.
///
/// This is not DRM: it exists so a font file cannot simply be copied out of
/// an EPUB and installed. Both schemes XOR the start of the font file with a
/// key derived from the book's identifier:
///
/// - IDPF: first 1040 bytes, key = SHA-1 of the unique identifier with all
///   whitespace removed (20 bytes, repeated).
/// - Adobe: first 1024 bytes, key = the 16 bytes of the book's UUID
///   identifier, repeated.
///
/// XOR is its own inverse, so the same function obfuscates and de-obfuscates
/// (handy for building test fixtures).
public enum FontDeobfuscator {
    public static func idpfKey(uniqueIdentifier: String) -> [UInt8] {
        // The spec removes U+0020, U+0009, U+000D and U+000A.
        // Filter scalars, not Characters: in Swift "\r\n" is one Character,
        // so a Character-based filter would miss a lone "\n".
        var stripped = String.UnicodeScalarView()
        stripped.append(contentsOf: uniqueIdentifier.unicodeScalars.filter {
            !["\u{20}", "\u{09}", "\u{0D}", "\u{0A}"].contains($0)
        })
        return Array(Insecure.SHA1.hash(data: Data(String(stripped).utf8)))
    }

    public static func adobeKey(uuidIdentifier: String) -> [UInt8]? {
        EPUBPackage.uuidBytes(from: uuidIdentifier)
    }

    /// XORs the first `length` bytes of `data` with `key`, repeating the key.
    public static func apply(key: [UInt8], length: Int, to data: Data) -> Data {
        guard !key.isEmpty else { return data }
        var bytes = data
        let count = min(length, bytes.count)
        bytes.withUnsafeMutableBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            for i in 0..<count { buffer[i] ^= key[i % key.count] }
        }
        return bytes
    }

    /// De-obfuscates a resource according to its encryption algorithm, if
    /// it is one of the two font schemes. Other data is returned unchanged.
    static func deobfuscate(_ data: Data, algorithm: String, package: EPUBPackage) -> Data {
        switch algorithm {
        case EncryptedResource.idpfFontAlgorithm:
            guard let id = package.uniqueIdentifier else { return data }
            return apply(key: idpfKey(uniqueIdentifier: id), length: 1040, to: data)
        case EncryptedResource.adobeFontAlgorithm:
            guard let id = package.uuidIdentifier, let key = adobeKey(uuidIdentifier: id) else { return data }
            return apply(key: key, length: 1024, to: data)
        default:
            return data
        }
    }
}
