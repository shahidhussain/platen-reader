import PDFKit
import PlatenCore
import UIKit

/// Saving and sharing a picture in a PDF: a long press on it shows Save to
/// Photos, Save to Files and Share. PlatenCore's `PDFPictures` finds where the
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
        highlight(onScreen)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let pageNumber = (pdfView.document?.index(for: page) ?? 0) + 1
        let name = String(localized: "\(url.deletingPathExtension().lastPathComponent), page \(pageNumber)")
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: String(localized: "Save to Photos"), style: .default) { [weak self] _ in
            self?.saveToPhotos(image)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Save to Files…"), style: .default) { [weak self] _ in
            self?.saveToFiles(image, name: name)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Share…"), style: .default) { [weak self] _ in
            self?.share(image, name: name, from: onScreen)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = pdfView
        sheet.popoverPresentationController?.sourceRect = onScreen
        present(sheet, animated: true)
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

    /// A brief tint over the picture, so it is clear which one was chosen.
    private func highlight(_ rect: CGRect) {
        let tint = UIView(frame: rect)
        tint.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.25)
        tint.isUserInteractionEnabled = false
        pdfView.addSubview(tint)
        UIView.animate(withDuration: 0.6, delay: 0.4) { tint.alpha = 0 } completion: { _ in tint.removeFromSuperview() }
    }

    // MARK: - Save and share

    /// Saves to the photo library. iOS asks once for permission to add
    /// photos (and only to add: Platen never sees the library).
    private func saveToPhotos(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(savedToPhotos(_:error:context:)), nil)
    }

    @objc private func savedToPhotos(_ image: UIImage, error: Error?, context: UnsafeMutableRawPointer?) {
        if let error {
            log.error("Could not save the picture to Photos: \(error.localizedDescription, privacy: .public)")
            chrome.showNotice(String(localized: "The picture could not be saved to Photos."))
        } else {
            chrome.showNotice(String(localized: "Saved to Photos"))
        }
    }

    /// Writes a PNG to a temporary folder and lets the reader choose where
    /// in Files it goes (the system's export picker copies it there).
    private func saveToFiles(_ image: UIImage, name: String) {
        guard let file = temporaryPNG(image, name: name) else { return }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        present(picker, animated: true)
    }

    /// Shared as a PNG file with a name, so the share sheet shows a preview
    /// and the picture keeps its name wherever it goes (Save Image is still
    /// offered).
    private func share(_ image: UIImage, name: String, from rect: CGRect) {
        let item: Any = temporaryPNG(image, name: name) ?? image
        let share = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = pdfView
        share.popoverPresentationController?.sourceRect = rect
        present(share, animated: true)
    }

    private func temporaryPNG(_ image: UIImage, name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pictures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A file name must not contain a slash (or a colon, shown as one).
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent(safe).appendingPathExtension("png")
        guard let data = image.pngData(), (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }
}
