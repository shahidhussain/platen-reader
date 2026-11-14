import CoreImage
import PDFKit
import UIKit

/// The background around a PDF's pages, coloured by the pages themselves,
/// as an Ambilight television lights the wall behind it with the colours on
/// screen. The page then sits in a soft glow of its own colours rather than
/// against a hard edge.
///
/// It is cheap, so it never slows reading down:
/// 1. the pages on screen are drawn at a tiny size (12 by 16 pixels a page),
///    off the main thread;
/// 2. each of those few pixels keeps its colour, but its brightness is
///    pulled towards the theme's background: white paper stays close to the
///    theme (dark stays dark), while coloured areas (covers, photographs,
///    maps) glow in their own colours;
/// 3. the result is blurred and stretched across the screen behind the
///    pages, where its stretching smooths it further.
enum PDFAmbientBackground {
    /// One queue, so pictures are made one at a time, in order.
    private static let queue = DispatchQueue(label: "Platen Reader PDF ambient background", qos: .userInitiated)
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The pixels each page is drawn at.
    private static let pageSize = (width: 12, height: 16)

    /// Makes the background picture for these pages (one, or a spread side
    /// by side) and hands it back on the main thread. `theme` is the
    /// reader's background colour.
    static func make(for pages: [PDFPage], theme: UIColor, done: @escaping (UIImage?) -> Void) {
        let refs = pages.compactMap(\.pageRef)
        guard !refs.isEmpty else { return done(nil) }
        var themeHue: CGFloat = 0, themeSaturation: CGFloat = 0, themeBrightness: CGFloat = 0, alpha: CGFloat = 0
        theme.getHue(&themeHue, saturation: &themeSaturation, brightness: &themeBrightness, alpha: &alpha)
        queue.async {
            let image = picture(of: refs, themeBrightness: themeBrightness)
            DispatchQueue.main.async { done(image) }
        }
    }

    private static func picture(of pages: [CGPDFPage], themeBrightness: CGFloat) -> UIImage? {
        let width = pageSize.width * pages.count, height = pageSize.height
        // 1. The pages, tiny, side by side, in RGBA bytes we can read.
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            bitmap.setFillColor(UIColor.white.cgColor) // paper, under any transparency
            bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
            bitmap.interpolationQuality = .low
            for (index, page) in pages.enumerated() {
                let target = CGRect(x: index * pageSize.width, y: 0, width: pageSize.width, height: pageSize.height)
                bitmap.saveGState()
                // Fit the page's crop box into its cell, stretched (the
                // picture is only colours, so proportions do not matter).
                let box = page.getBoxRect(.cropBox)
                bitmap.translateBy(x: target.minX, y: target.minY)
                bitmap.scaleBy(x: target.width / max(box.width, 1), y: target.height / max(box.height, 1))
                bitmap.translateBy(x: -box.minX, y: -box.minY)
                bitmap.drawPDFPage(page)
                bitmap.restoreGState()
            }
            return true
        }
        guard drawn else { return nil }

        // 2. Keep each colour, but bring its brightness towards the theme:
        // a little for greys and white, more for strong colours.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let colour = UIColor(red: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                                 blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colour.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let weight = 0.1 + 0.5 * s // how much of the page's own brightness shows
            let brightness = themeBrightness + (b - themeBrightness) * weight
            let adjusted = UIColor(hue: h, saturation: min(1, s * 1.1), brightness: brightness, alpha: 1)
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
            adjusted.getRed(&r, green: &g, blue: &bl, alpha: &a)
            pixels[i] = UInt8(r * 255)
            pixels[i + 1] = UInt8(g * 255)
            pixels[i + 2] = UInt8(bl * 255)
            pixels[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let tiny = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        // 3. Enlarge a little and blur, so no pixel edges show once it is
        // stretched across the screen.
        let enlarged = CIImage(cgImage: tiny)
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        let extent = enlarged.extent
        let blurred = enlarged.clampedToExtent().applyingGaussianBlur(sigma: 5).cropped(to: extent)
        guard let result = context.createCGImage(blurred, from: extent) else { return nil }
        return UIImage(cgImage: result)
    }
}
