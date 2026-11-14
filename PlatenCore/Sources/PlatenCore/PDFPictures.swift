import CoreGraphics
import Foundation

/// Where the pictures are on a PDF page, so a long press on one can offer to
/// save or share it. PDFKit has no way to ask this, so the page's drawing
/// instructions are read with Core Graphics' scanner: each picture (an image
/// XObject, or an inline image) is drawn into a unit square transformed by
/// the current transformation matrix, so following `q`, `Q` and `cm` gives
/// its place. Pictures inside form XObjects (grouped drawings) are found too.
///
/// Rectangles are in the page's default user space (PDF points, origin at the
/// bottom left, before the page's /Rotate), as `PDFPage.bounds(for:)` and
/// `CGPDFPage.getBoxRect` use. Platform-neutral, so it is unit-tested.
public enum PDFPictures {
    /// The pictures on a page, in the order they are drawn (later ones on
    /// top). Tiny ones (under 8 points either way: rules, dots, masks) are
    /// left out.
    public static func rects(on page: CGPDFPage) -> [CGRect] {
        let scan = Scan()
        let content = CGPDFContentStreamCreateWithPage(page)
        scan.run(content)
        CGPDFContentStreamRelease(content)
        return scan.found.filter { $0.width >= 8 && $0.height >= 8 }
    }

    /// The picture under a point (page space), if any: the smallest one that
    /// contains it, so a small picture inside a full-page background (a
    /// scanned page) is the one chosen.
    public static func picture(at point: CGPoint, on page: CGPDFPage) -> CGRect? {
        rects(on: page)
            .filter { $0.contains(point) }
            .min { $0.width * $0.height < $1.width * $1.height }
    }

    /// The scanner's state while it walks the page. Core Graphics calls back
    /// through C functions, which reach it through the `info` pointer.
    private final class Scan {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var found: [CGRect] = []
        var depth = 0
        /// The table of operators listened for, made once per scan.
        private var table: CGPDFOperatorTableRef!

        init() { table = makeTable() }

        func run(_ content: CGPDFContentStreamRef) {
            let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
        }

        /// A picture drawn now fills the unit square under the current matrix.
        func addUnitSquare() {
            guard found.count < 500 else { return }
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm).standardized
            if rect.width.isFinite, rect.height.isFinite { found.append(rect) }
        }

        private func makeTable() -> CGPDFOperatorTableRef {
            let table = CGPDFOperatorTableCreate()!
            CGPDFOperatorTableSetCallback(table, "q") { _, info in
                guard let scan = Scan.from(info) else { return }
                scan.stack.append(scan.ctm)
            }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in
                guard let scan = Scan.from(info), let saved = scan.stack.popLast() else { return }
                scan.ctm = saved
            }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
                guard let scan = Scan.from(info) else { return }
                // The six numbers come off the stack last first.
                var n = [CGPDFReal](repeating: 0, count: 6)
                for i in (0..<6).reversed() {
                    guard CGPDFScannerPopNumber(scanner, &n[i]) else { return }
                }
                let m = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                scan.ctm = m.concatenating(scan.ctm)
            }
            // An inline image (BI … ID … EI) also fills the unit square.
            CGPDFOperatorTableSetCallback(table, "EI") { _, info in
                Scan.from(info)?.addUnitSquare()
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                guard let scan = Scan.from(info) else { return }
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner, &name), let name else { return }
                let content = CGPDFScannerGetContentStream(scanner)
                guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
                switch String(cString: subtype) {
                case "Image":
                    scan.addUnitSquare()
                case "Form" where scan.depth < 8:
                    // A grouped drawing: its own matrix, then its contents.
                    let saved = scan.ctm
                    scan.ctm = Scan.matrix(of: dictionary).concatenating(scan.ctm)
                    var resources: CGPDFDictionaryRef?
                    CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                    // Without resources of its own, it uses the page's
                    // (through the parent stream).
                    let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
                    let savedStack = scan.stack
                    scan.depth += 1
                    scan.run(inner)
                    scan.depth -= 1
                    CGPDFContentStreamRelease(inner)
                    scan.stack = savedStack
                    scan.ctm = saved
                default:
                    break
                }
            }
            return table
        }

        /// A form's /Matrix (identity if it has none).
        static func matrix(of dictionary: CGPDFDictionaryRef) -> CGAffineTransform {
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 else {
                return .identity
            }
            var n = [CGPDFReal](repeating: 0, count: 6)
            for i in 0..<6 where !CGPDFArrayGetNumber(array, i, &n[i]) { return .identity }
            return CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
        }

        static func from(_ info: UnsafeMutableRawPointer?) -> Scan? {
            info.map { Unmanaged<Scan>.fromOpaque($0).takeUnretainedValue() }
        }

        deinit { CGPDFOperatorTableRelease(table) }
    }
}
