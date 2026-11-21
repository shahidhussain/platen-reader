import CoreGraphics
import Foundation
import ImageIO

/// What a cover picture looks like, judged from a small copy of it.
///
/// A PDF has no cover of its own: Platen shows its first page. For a comic,
/// a magazine or a designed book that is a real cover; for a report or a
/// paper it is a page of text, which in the Home tab's folder fans reads as
/// a blank card. `isTextLike` tells the two apart well enough for that: a
/// page of text is almost all plain paper (white, or the cream of a scan)
/// with a little dark ink, where a cover has colour, or large dark or
/// coloured areas. A minimal cover that is nearly all white may be taken for
/// text; that only means it is left out of a fan.
enum CoverLook {
    /// How much of the picture may be plain paper before it counts as text.
    static let paperShare = 0.8

    /// Whether the picture in this file looks like a page of text.
    static func isTextLike(file: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 48,
              ] as CFDictionary) else { return false }
        return isTextLike(image)
    }

    /// Whether the picture looks like a page of text: at least `paperShare`
    /// of it light and nearly colourless (paper, with its text blurred into
    /// it at this size).
    static func isTextLike(_ image: CGImage) -> Bool {
        let width = 24, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var paper = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let high = max(r, g, b), low = min(r, g, b)
            let lightness = (high + low) / 2
            let saturation = high == 0 ? 0 : (high - low) / high
            // White, or the cream or grey of a scanned page. At this size
            // lines of text blur into the paper as a light grey, so that
            // counts as paper too.
            if lightness > 0.6 && saturation < 0.2 { paper += 1 }
        }
        return Double(paper) / Double(width * height) >= paperShare
    }
}
