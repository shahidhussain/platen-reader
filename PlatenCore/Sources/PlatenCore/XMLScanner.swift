import Foundation

/// A tiny event-driven XML reader built on Foundation's `XMLParser`, which
/// exists on both macOS and iOS (unlike `XMLDocument`).
///
/// It is lenient by design: if the document is malformed, parsing stops at the
/// error but everything collected up to that point is kept. A package file
/// with a stray bad entity near the end still yields its metadata and spine.
final class XMLScanner: NSObject, XMLParserDelegate {
    struct Element {
        /// Local name without prefix, e.g. "item" for "opf:item".
        let name: String
        let namespace: String?
        /// Attributes keyed by local name. Prefixed attributes such as
        /// `opf:scheme` are stored under both "opf:scheme" and "scheme".
        let attributes: [String: String]
    }

    private var onStart: (Element) -> Void = { _ in }
    private var onEnd: (Element, String) -> Void = { _, _ in }
    private var stack: [(Element, String)] = []
    private(set) var error: Error?

    /// Walks the document. `start` fires for each opening tag; `end` fires for
    /// each closing tag with the element's direct and nested text content.
    static func scan(
        _ data: Data,
        start: @escaping (Element) -> Void = { _ in },
        end: @escaping (Element, String) -> Void = { _, _ in }
    ) -> Error? {
        let scanner = XMLScanner()
        scanner.onStart = start
        scanner.onEnd = end
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = scanner
        parser.parse()
        return scanner.error
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attributes = attributeDict
        for (key, value) in attributeDict {
            if let colon = key.firstIndex(of: ":") {
                let local = String(key[key.index(after: colon)...])
                if attributes[local] == nil { attributes[local] = value }
            }
        }
        let element = Element(name: elementName, namespace: namespaceURI, attributes: attributes)
        stack.append((element, ""))
        onStart(element)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Text belongs to every open element, so nested text (e.g. <a><span>x)
        // is visible to the outer element too.
        for i in stack.indices { stack[i].1 += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            for i in stack.indices { stack[i].1 += string }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let (element, text) = stack.popLast() else { return }
        onEnd(element, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }
}
