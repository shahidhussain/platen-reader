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
    func showImage(from body: [String: Any]) {
        guard imageZoom == nil,
              let base64 = body["data"] as? String, let data = Data(base64Encoded: base64),
              let image = NSImage(data: data) else { return }
        log.debug("Showing picture (\(data.count) bytes)")
        let rect = body["rect"] as? [String: Any] ?? [:]
        func number(_ key: String) -> CGFloat { CGFloat((rect[key] as? NSNumber)?.doubleValue ?? 0) }
        // Web coordinates have their origin at the top left; AppKit's at the
        // bottom left.
        let source = NSRect(x: number("x"), y: view.bounds.height - number("y") - number("height"),
                            width: number("width"), height: number("height"))
        let zoom = ImageZoomView(image: image, data: data, type: body["mimeType"] as? String ?? "",
                                 name: body["alt"] as? String ?? "", background: currentTheme.nsBackground)
        zoom.onClose = { [weak self] in self?.closeImage() }
        zoom.frame = view.bounds
        zoom.autoresizingMask = [.width, .height]
        view.addSubview(zoom, positioned: .below, relativeTo: titleBacking)
        imageZoom = zoom
        if overlayVisible { setOverlay(visible: false) }
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
