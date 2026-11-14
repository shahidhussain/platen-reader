import AppKit
import Combine
import PlatenCore
import SwiftUI
import WebKit
import os

// MARK: - Pictures

extension ReaderViewController {
    /// A click on a picture in the book: show it full size, zooming from
    /// where it sits on the page.
    func showImage(_ picture: ReaderMessage.Picture) {
        guard imageZoom == nil, let image = NSImage(data: picture.data) else { return }
        log.debug("Showing picture (\(picture.data.count) bytes)")
        // Web coordinates have their origin at the top left; AppKit's at the
        // bottom left.
        let rect = picture.rect
        let source = NSRect(x: rect.minX, y: view.bounds.height - rect.minY - rect.height,
                            width: rect.width, height: rect.height)
        let zoom = ImageZoomView(image: image, data: picture.data, type: picture.mimeType,
                                 name: picture.alt, background: currentTheme.nsBackground)
        zoom.onClose = { [weak self] in self?.closeImage() }
        zoom.frame = view.bounds
        zoom.autoresizingMask = [.width, .height]
        view.addSubview(zoom, positioned: .below, relativeTo: chrome.titleBackingView)
        imageZoom = zoom
        if chrome.isVisible { chrome.setVisible(false) }
        zoom.present(from: source, animated: !reducedMotion)
        view.window?.makeFirstResponder(zoom)
    }

    func closeImage() {
        guard let zoom = imageZoom else { return }
        imageZoom = nil
        zoom.dismiss(animated: !reducedMotion) { zoom.removeFromSuperview() }
        view.window?.makeFirstResponder(webView)
    }
}
