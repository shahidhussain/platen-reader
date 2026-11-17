import PDFKit
import PlatenCore
import UIKit

/// Saving and sharing a picture in a PDF: a long press on it shows Save to
/// Photos, Save to Files and Share (`offerPicture`, shared with the book
/// reader). PlatenCore's `PDFPictures` finds where the
/// pictures are on the page; the picture is then drawn from the page at up to
/// about 300 dots per inch, so it comes out as sharp as the PDF holds it,
/// whatever its format inside (JPEG, JBIG2, a vector drawing over a photo).
extension PDFReaderViewController {
    @objc func pressed(_ recogniser: UILongPressGestureRecognizer) {
        guard recogniser.state == .began else { return }
        let point = recogniser.location(in: pdfView)
        guard let page = pdfView.page(for: point, nearest: false), let pageRef = page.pageRef else { return }
        let pagePoint = pdfView.convert(point, to: page)
        guard let rect = PDFPictures.picture(at: pagePoint, on: pageRef),
              let image = Self.render(rect, of: pageRef) else { return }
        // A picture, not text: drop the selection PDFKit's own long press
        // starts on the nearest word (now, and once it has made it).
        pdfView.clearSelection()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.pdfView.clearSelection() }
        let onScreen = pdfView.convert(rect, from: page).intersection(pdfView.bounds)
        let pageNumber = (pdfView.document?.index(for: page) ?? 0) + 1
        let name = String(localized: "\(url.deletingPathExtension().lastPathComponent), page \(pageNumber)")
        offerPicture(image, file: nil, name: name, from: onScreen, in: pdfView)
    }

    /// The picture's area of the page, drawn upright (the page's /Rotate
    /// applied) at up to about 300 dots per inch and 4096 pixels.
    static func render(_ rect: CGRect, of page: CGPDFPage) -> UIImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let scale = min(300 / 72, 4096 / max(rect.width, rect.height))
        let size = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            // PDF space has its origin at the bottom left; flip, then move
            // the picture's corner to the canvas's.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -rect.minX, y: -rect.minY)
            cg.clip(to: rect)
            cg.interpolationQuality = .high
            cg.drawPDFPage(page)
        }
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        guard rotation != 0, let cgImage = drawn.cgImage else { return drawn }
        // A turned page: turn the picture the same way, for good (a PNG
        // keeps no orientation).
        let orientation: UIImage.Orientation = rotation == 90 ? .right : rotation == 180 ? .down : .left
        let turned = UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
        return UIGraphicsImageRenderer(size: turned.size, format: format).image { _ in
            turned.draw(at: .zero)
        }
    }
}
