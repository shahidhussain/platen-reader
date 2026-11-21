import UIKit

/// Saving and sharing a picture from a book or a PDF: a long press on it
/// shows Save to Photos, Save to Files and Share. The book reader finds the
/// picture in the page (`platen.pictureAt` in input.js) and has its own
/// bytes; the PDF reader draws it from the page.
extension ReaderBaseViewController {
    /// Briefly tints the picture, then offers what can be done with it.
    /// - Parameters:
    ///   - file: the picture's own bytes and file extension, when known (a
    ///     book's JPEG or PNG), so Files and Share get it as it is; nil: a PNG
    ///     is made from `image`.
    ///   - rect: where the picture is, in `view`'s coordinates.
    func offerPicture(_ image: UIImage, file: (data: Data, ext: String)?, name: String, from rect: CGRect, in view: UIView) {
        highlight(rect, in: view)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: String(localized: "Save to Photos"), style: .default) { [weak self] _ in
            self?.saveToPhotos(image)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Save to Files…"), style: .default) { [weak self] _ in
            guard let self, let url = self.temporaryFile(image, file: file, name: name) else { return }
            self.present(UIDocumentPickerViewController(forExporting: [url], asCopy: true), animated: true)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Share…"), style: .default) { [weak self] _ in
            guard let self else { return }
            // As a named file, so the share sheet shows a preview and the
            // picture keeps its name (Save Image is still offered).
            let item: Any = self.temporaryFile(image, file: file, name: name) ?? image
            let share = UIActivityViewController(activityItems: [item], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = view
            share.popoverPresentationController?.sourceRect = rect
            self.present(share, animated: true)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = rect
        present(sheet, animated: true)
    }

    /// A brief tint over the picture, so it is clear which one was chosen.
    private func highlight(_ rect: CGRect, in view: UIView) {
        let tint = UIView(frame: rect)
        tint.backgroundColor = (UIColor(named: "Honey") ?? .systemOrange).withAlphaComponent(0.25)
        tint.isUserInteractionEnabled = false
        view.addSubview(tint)
        UIView.animate(withDuration: 0.6, delay: 0.4) { tint.alpha = 0 } completion: { _ in tint.removeFromSuperview() }
    }

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

    /// The picture as a file in a temporary folder: its own bytes if known,
    /// else a PNG.
    private func temporaryFile(_ image: UIImage, file: (data: Data, ext: String)?, name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pictures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A file name must not contain a slash (or a colon, shown as one).
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent(safe).appendingPathExtension(file?.ext ?? "png")
        guard let data = file?.data ?? image.pngData(), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
}
