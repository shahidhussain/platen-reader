import Foundation

/// The kinds of DRM Platen can recognise. Platen never removes or plays DRM;
/// it only names it so the user gets a clear message instead of a blank page.
public enum DRMScheme: String, Sendable, Equatable, Codable {
    case adobeADEPT
    case appleFairPlay
    case readiumLCP
    case kindle
    case unknown

    /// A plain-English name for messages.
    public var displayName: String {
        switch self {
        case .adobeADEPT: return String(localized: "Adobe Digital Editions DRM", bundle: .module)
        case .appleFairPlay: return String(localized: "Apple Books (FairPlay) DRM", bundle: .module)
        case .readiumLCP: return String(localized: "Readium LCP DRM", bundle: .module)
        case .kindle: return String(localized: "Kindle DRM", bundle: .module)
        case .unknown: return String(localized: "an unrecognised form of DRM", bundle: .module)
        }
    }
}

/// One entry from META-INF/encryption.xml: which file, and which algorithm.
public struct EncryptedResource: Sendable, Equatable {
    public let path: String
    public let algorithm: String

    /// IDPF font obfuscation (EPUB 3 spec). Not DRM.
    public static let idpfFontAlgorithm = "http://www.idpf.org/2008/embedding"
    /// Adobe font obfuscation. Not DRM.
    public static let adobeFontAlgorithm = "http://ns.adobe.com/pdf/enc#RC"

    public var isFontObfuscation: Bool {
        algorithm == Self.idpfFontAlgorithm || algorithm == Self.adobeFontAlgorithm
    }
}

enum DRMDetector {
    /// Parses META-INF/encryption.xml into (path, algorithm) pairs.
    static func encryptedResources(in data: Data) -> [EncryptedResource] {
        var results: [EncryptedResource] = []
        // Within each <EncryptedData>, an <EncryptionMethod Algorithm=…> and a
        // <CipherReference URI=…> appear in either order.
        var algorithm: String?
        var uri: String?
        _ = XMLScanner.scan(data, start: { element in
            switch element.name {
            case "EncryptedData": algorithm = nil; uri = nil
            case "EncryptionMethod": algorithm = element.attributes["Algorithm"]
            case "CipherReference": uri = element.attributes["URI"]
            default: break
            }
        }, end: { element, _ in
            if element.name == "EncryptedData", let algorithm, let uri {
                // URIs are relative to the root of the container.
                let path = PathResolver.normalise(uri.removingPercentEncoding ?? uri)
                results.append(EncryptedResource(path: path, algorithm: algorithm))
            }
        })
        return results
    }

    /// Decides whether an EPUB is DRM-protected, and by whom.
    /// - Parameters:
    ///   - entryPaths: all paths in the zip;
    ///   - encryption: parsed encryption.xml entries, if the file exists.
    static func detectEPUB(entryPaths: Set<String>, encryption: [EncryptedResource]) -> DRMScheme? {
        // Marker files are the most reliable way to name the scheme.
        if entryPaths.contains("META-INF/license.lcpl") { return .readiumLCP }
        if entryPaths.contains("META-INF/sinf.xml") { return .appleFairPlay }

        let realEncryption = encryption.filter { !$0.isFontObfuscation }
        guard !realEncryption.isEmpty else { return nil }

        if entryPaths.contains("META-INF/rights.xml") { return .adobeADEPT }
        // ADEPT books without rights.xml still use XML-Enc AES with Adobe keys.
        if realEncryption.contains(where: { $0.algorithm.contains("adobe") }) { return .adobeADEPT }
        return .unknown
    }

    /// Checks a MOBI/AZW/AZW3 file's first record for an encryption type.
    /// - Parameter header: the first few KB of the file.
    static func detectMOBI(header: Data) -> DRMScheme? {
        // Palm database: record list starts at 78; first record's offset is a
        // big-endian UInt32 there. Record 0 begins with the PalmDOC header,
        // whose encryption field is at +12 (0 = none, 1 = old Mobipocket,
        // 2 = Mobipocket/Kindle).
        guard let record0 = header.be(UInt32.self, at: 78).map(Int.init),
              let encryption = header.be(UInt16.self, at: record0 + 12)
        else { return nil }
        return encryption == 0 ? nil : .kindle
    }
}
