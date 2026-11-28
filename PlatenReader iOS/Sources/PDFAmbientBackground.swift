import CoreImage
import PDFKit
import UIKit

/// The background around a PDF's pages, coloured by the pages themselves
/// (the shared `AmbientGlow`, which says how), with UIKit's colours and
/// pictures: the iOS PDF reader's, and the glow of a book's page.
enum PDFAmbientBackground {
    private static var queue: DispatchQueue { AmbientGlow.queue }
    private static var pageSize: (width: Int, height: Int) { AmbientGlow.pageSize }

    /// Makes the background picture for these pages (one, or a spread side
    /// by side) and hands it back on the main thread. `theme` is the
    /// reader's background colour.
    static func make(for pages: [PDFPage], theme: UIColor, done: @escaping (UIImage?) -> Void) {
        make(for: pages.compactMap { page in page.pageRef.map { ($0, $0.getBoxRect(.cropBox)) } }, theme: theme, done: done)
    }

    /// The glow of parts of pages (each page's region in its own
    /// coordinates), side by side: what is on screen when the reader has
    /// zoomed in, so the glow follows the part they are looking at.
    static func make(for parts: [(page: PDFPage, region: CGRect)], theme: UIColor, done: @escaping (UIImage?) -> Void) {
        make(for: parts.compactMap { part in part.page.pageRef.map { ($0, part.region) } }, theme: theme, done: done)
    }

    private static func make(for refs: [(CGPDFPage, CGRect)], theme: UIColor, done: @escaping (UIImage?) -> Void) {
        guard !refs.isEmpty else { return done(nil) }
        let brightness = brightness(of: theme)
        queue.async {
            let image = AmbientGlow.picture(of: refs, themeBrightness: brightness).map { UIImage(cgImage: $0) }
            DispatchQueue.main.async { done(image) }
        }
    }

    /// The same glow from a picture of what is on screen (a book's page,
    /// snapshotted small): see-through parts count as the theme's colour.
    static func make(from snapshot: UIImage, theme: UIColor, done: @escaping (UIImage?) -> Void) {
        guard let cg = snapshot.cgImage else { return done(nil) }
        let brightness = brightness(of: theme)
        let paper = theme.cgColor
        queue.async {
            let image = AmbientGlow.picture(width: pageSize.width, height: pageSize.height, paper: paper,
                                            themeBrightness: brightness) { bitmap, size in
                bitmap.draw(cg, in: CGRect(origin: .zero, size: size))
            }.map { UIImage(cgImage: $0) }
            DispatchQueue.main.async { done(image) }
        }
    }

    private static func brightness(of colour: UIColor) -> CGFloat {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return brightness
    }
}
