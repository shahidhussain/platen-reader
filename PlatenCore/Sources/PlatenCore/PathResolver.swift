import Foundation

/// Finds zip entries for the paths books ask for, forgiving the mistakes real
/// EPUBs make.
///
/// Lookup order, cheapest first:
/// 1. the exact path;
/// 2. the path with `.`/`..` segments resolved and a leading slash removed;
/// 3. percent-decoded (`My%20Chapter.xhtml` → `My Chapter.xhtml`);
/// 4. Unicode-normalised (macOS tools often write decomposed NFD names, while
///    hrefs are usually composed NFC);
/// 5. case-insensitive (`Chapter1.xhtml` vs `chapter1.xhtml`), because books
///    made on case-insensitive file systems often get this wrong.
public struct PathResolver: Sendable {
    private let exact: Set<String>
    /// Normalised (NFC, lowercased) path → actual stored path.
    private let folded: [String: String]

    public init(paths: [String]) {
        exact = Set(paths)
        var folded: [String: String] = [:]
        for path in paths {
            let key = Self.fold(path)
            // Keep the first match; duplicates differing only by case are rare
            // and either choice is a guess.
            if folded[key] == nil { folded[key] = path }
        }
        self.folded = folded
    }

    /// Returns the stored path for a requested path, or nil if nothing
    /// plausible exists.
    public func resolve(_ requested: String) -> String? {
        if exact.contains(requested) { return requested }

        let normalised = Self.normalise(requested)
        if exact.contains(normalised) { return normalised }

        var candidates = [normalised]
        if let decoded = normalised.removingPercentEncoding, decoded != normalised {
            candidates.append(decoded)
        }
        for candidate in candidates {
            for form in [candidate.precomposedStringWithCanonicalMapping,
                         candidate.decomposedStringWithCanonicalMapping]
            where exact.contains(form) {
                return form
            }
        }
        for candidate in candidates {
            if let match = folded[Self.fold(candidate)] { return match }
        }
        return nil
    }

    /// Joins an href to the folder of the document that contains it, the way
    /// a browser resolves a relative URL. Fragments and queries are dropped.
    public static func join(base: String, href: String) -> String {
        var href = href
        if let hash = href.firstIndex(of: "#") { href = String(href[..<hash]) }
        if let query = href.firstIndex(of: "?") { href = String(href[..<query]) }
        if href.hasPrefix("/") { return normalise(href) }
        return normalise(base.isEmpty ? href : base + "/" + href)
    }

    /// Removes a leading slash and resolves "." and ".." segments.
    static func normalise(_ path: String) -> String {
        var output: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".": continue
            case "..": if !output.isEmpty { output.removeLast() }
            default: output.append(segment)
            }
        }
        return output.joined(separator: "/")
    }

    private static func fold(_ path: String) -> String {
        normalise(path).precomposedStringWithCanonicalMapping.lowercased()
    }
}
