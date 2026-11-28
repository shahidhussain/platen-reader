import CoreGraphics
import CoreImage
import Foundation

/// The ambient light around a PDF's pages, for both apps: the background
/// coloured by the pages themselves, as an Ambilight television lights the
/// wall behind it with the colours on screen. The page then sits in a soft
/// glow of its own colours rather than against a hard edge, and whatever room
/// the window or screen has around the page is filled with it.
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
///
/// iOS wraps it as `PDFAmbientBackground` (UIImage, and the glow of a book's
/// page); the Mac's PDF reader uses it directly.
enum AmbientGlow {
    /// One queue, so pictures are made one at a time, in order.
    static let queue = DispatchQueue(label: "Platen Reader PDF ambient background", qos: .userInitiated)
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The pixels each page is drawn at.
    static let pageSize = (width: 12, height: 16)

    /// The glow of pages (or parts of pages, each region in its page's own
    /// coordinates), side by side. Call off the main thread (`queue`).
    /// `themeBrightness` is the reader's background's brightness, 0 to 1.
    static func picture(of pages: [(CGPDFPage, CGRect)], themeBrightness: CGFloat) -> CGImage? {
        guard !pages.isEmpty else { return nil }
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        return picture(width: pageSize.width * pages.count, height: pageSize.height, paper: white,
                       themeBrightness: themeBrightness) { bitmap, _ in
            for (index, (page, region)) in pages.enumerated() {
                let target = CGRect(x: index * pageSize.width, y: 0, width: pageSize.width, height: pageSize.height)
                bitmap.saveGState()
                // Fit the region (the crop box, or the part on screen) into
                // its cell, stretched (the picture is only colours, so
                // proportions do not matter), clipped to the cell.
                bitmap.clip(to: target)
                let box = region
                bitmap.translateBy(x: target.minX, y: target.minY)
                bitmap.scaleBy(x: target.width / max(box.width, 1), y: target.height / max(box.height, 1))
                bitmap.translateBy(x: -box.minX, y: -box.minY)
                bitmap.drawPDFPage(page)
                bitmap.restoreGState()
            }
        }
    }

    /// Draws something tiny (`draw`, on `paper`), then makes the glow of it.
    static func picture(width: Int, height: Int, paper: CGColor, themeBrightness: CGFloat,
                        draw: (CGContext, CGSize) -> Void) -> CGImage? {
        // 1. The pages, tiny, side by side, in RGBA bytes we can read.
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            bitmap.setFillColor(paper) // under any transparency
            bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
            bitmap.interpolationQuality = .low
            draw(bitmap, CGSize(width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // 2. Keep each colour, but bring its brightness towards the theme:
        // a little for greys and white, more for strong colours.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (h, s, b) = hsb(red: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                                blue: CGFloat(pixels[i + 2]) / 255)
            let weight = 0.1 + 0.5 * s // how much of the page's own brightness shows
            let brightness = themeBrightness + (b - themeBrightness) * weight
            let (r, g, bl) = rgb(hue: h, saturation: min(1, s * 1.1), brightness: brightness)
            pixels[i] = UInt8(max(0, min(255, r * 255)))
            pixels[i + 1] = UInt8(max(0, min(255, g * 255)))
            pixels[i + 2] = UInt8(max(0, min(255, bl * 255)))
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
        return context.createCGImage(blurred, from: extent)
    }

    // MARK: - Colour

    /// A colour's hue, saturation and brightness (HSB, each 0 to 1), as
    /// UIColor and NSColor give them.
    static func hsb(red r: CGFloat, green g: CGFloat, blue b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let high = max(r, g, b), low = min(r, g, b), range = high - low
        let saturation = high == 0 ? 0 : range / high
        guard range > 0 else { return (0, saturation, high) }
        var hue: CGFloat
        if high == r { hue = (g - b) / range } else if high == g { hue = 2 + (b - r) / range } else { hue = 4 + (r - g) / range }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, saturation, high)
    }

    /// The red, green and blue (0 to 1) of a hue, saturation and brightness.
    static func rgb(hue: CGFloat, saturation s: CGFloat, brightness v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        guard s > 0 else { return (v, v, v) }
        let h = (hue - floor(hue)) * 6
        let sector = Int(h) % 6
        let f = h - floor(h)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch sector {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    /// The brightness of a theme colour (its hex, "#rrggbb").
    static func brightness(ofHex hex: String) -> CGFloat {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return 1 }
        let r = CGFloat((value >> 16) & 0xff) / 255, g = CGFloat((value >> 8) & 0xff) / 255, b = CGFloat(value & 0xff) / 255
        return hsb(red: r, green: g, blue: b).2
    }
}
