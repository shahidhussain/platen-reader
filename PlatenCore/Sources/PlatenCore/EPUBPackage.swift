import Foundation

/// What Swift needs to know about an EPUB's package document (the OPF).
///
/// foliate-js parses the package again in the web view to render the book;
/// Swift parses it for the things that must happen before or outside
/// rendering: identifying the book (to find its saved position), the window
/// title, citations, DRM detection and font de-obfuscation keys.
public struct EPUBPackage: Sendable, Equatable {
    public struct Identifier: Sendable, Equatable {
        public let id: String?
        public let value: String
        public let scheme: String?
    }

    public struct ManifestItem: Sendable, Equatable {
        public let id: String
        /// Path inside the zip, resolved against the OPF's folder.
        public let path: String
        public let mediaType: String
        public let properties: [String]
    }

    /// Path of the OPF inside the zip, e.g. "OEBPS/content.opf".
    public var opfPath: String = ""
    /// The EPUB version attribute, e.g. "2.0" or "3.0".
    public var version: String?
    /// The identifier the package marks as unique (`unique-identifier`).
    public var uniqueIdentifier: String?
    public var identifiers: [Identifier] = []
    public var titles: [String] = []
    public var creators: [String] = []
    public var languages: [String] = []
    public var manifest: [ManifestItem] = []
    /// Spine item paths in reading order.
    public var spine: [String] = []
    /// "pre-paginated" for fixed-layout books, otherwise "reflowable".
    public var layout: String = "reflowable"
    /// "ltr", "rtl" or "default".
    public var pageProgressionDirection: String = "default"
    /// Problems that did not stop parsing.
    public var warnings: [String] = []

    public var title: String? { titles.first }
    public var isFixedLayout: Bool { layout == "pre-paginated" }

    /// The UUID-form identifier Adobe's font obfuscation is keyed on, if any.
    public var uuidIdentifier: String? {
        let candidates = [uniqueIdentifier].compactMap { $0 } + identifiers.map(\.value)
        return candidates.first { Self.uuidBytes(from: $0) != nil }
    }

    /// Parses "urn:uuid:xxxxxxxx-xxxx-..." (or a bare UUID) into 16 bytes.
    static func uuidBytes(from identifier: String) -> [UInt8]? {
        var s = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("urn:uuid:") { s.removeFirst("urn:uuid:".count) }
        let hex = s.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

public enum EPUBParseError: Error, LocalizedError, Equatable {
    case missingContainer
    case noPackageInContainer
    case missingPackage(String)

    public var errorDescription: String? {
        switch self {
        case .missingContainer:
            return "The book has no META-INF/container.xml, so its contents cannot be found."
        case .noPackageInContainer:
            return "The book’s container file does not say where its contents are."
        case let .missingPackage(path):
            return "The book’s package file “\(path)” is missing."
        }
    }
}

enum EPUBPackageParser {
    static let opfMediaType = "application/oebps-package+xml"

    /// Reads container.xml and returns the path of the first package document.
    static func packagePath(fromContainer data: Data) throws -> String {
        var rootfiles: [(path: String, mediaType: String?)] = []
        _ = XMLScanner.scan(data, start: { element in
            if element.name == "rootfile", let path = element.attributes["full-path"] {
                rootfiles.append((path, element.attributes["media-type"]))
            }
        })
        // Prefer an OPF rootfile; some containers also list PDFs or others.
        if let opf = rootfiles.first(where: { $0.mediaType == opfMediaType }) ?? rootfiles.first {
            return opf.path
        }
        throw EPUBParseError.noPackageInContainer
    }

    static func parsePackage(_ data: Data, path opfPath: String) -> EPUBPackage {
        var package = EPUBPackage()
        package.opfPath = opfPath
        let baseFolder = (opfPath as NSString).deletingLastPathComponent

        var uniqueIdentifierID: String?
        var manifestByID: [String: EPUBPackage.ManifestItem] = [:]
        var spineIDs: [String] = []

        let error = XMLScanner.scan(data, start: { element in
            let a = element.attributes
            switch element.name {
            case "package":
                uniqueIdentifierID = a["unique-identifier"]
                package.version = a["version"]
            case "item":
                guard let id = a["id"], let href = a["href"] else { return }
                let item = EPUBPackage.ManifestItem(
                    id: id,
                    path: PathResolver.join(base: baseFolder, href: href),
                    mediaType: a["media-type"] ?? "",
                    properties: (a["properties"] ?? "").split(separator: " ").map(String.init)
                )
                manifestByID[id] = item
                package.manifest.append(item)
            case "itemref":
                if let idref = a["idref"] { spineIDs.append(idref) }
            case "spine":
                if let direction = a["page-progression-direction"] {
                    package.pageProgressionDirection = direction
                }
            default:
                break
            }
        }, end: { element, text in
            let a = element.attributes
            switch element.name {
            case "identifier":
                guard !text.isEmpty else { return }
                package.identifiers.append(.init(id: a["id"], value: text, scheme: a["scheme"]))
            case "title":
                if !text.isEmpty, element.namespace?.contains("purl.org/dc") ?? true {
                    package.titles.append(text)
                }
            case "creator":
                if !text.isEmpty { package.creators.append(text) }
            case "language":
                if !text.isEmpty { package.languages.append(text) }
            case "meta":
                // EPUB 3: <meta property="rendition:layout">pre-paginated</meta>
                if a["property"] == "rendition:layout", !text.isEmpty {
                    package.layout = text
                }
                // Some EPUB 2 fixed-layout books use name/content instead.
                if a["name"] == "fixed-layout", a["content"] == "true" {
                    package.layout = "pre-paginated"
                }
            default:
                break
            }
        })
        if let error {
            package.warnings.append("Package file is not well-formed: \(error.localizedDescription)")
        }

        package.uniqueIdentifier = package.identifiers.first { $0.id != nil && $0.id == uniqueIdentifierID }?.value
            ?? package.identifiers.first?.value
        package.spine = spineIDs.compactMap { id in
            guard let item = manifestByID[id] else {
                package.warnings.append("Spine refers to missing manifest item “\(id)”.")
                return nil
            }
            return item.path
        }
        return package
    }
}
