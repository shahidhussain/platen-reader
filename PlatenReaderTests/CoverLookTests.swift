import CoreGraphics
import XCTest

/// Tests of `CoverLook` (Shared/CoverLook.swift): telling a PDF's first page
/// of text from a real cover, for the Home tab's folder fans.
final class CoverLookTests: XCTestCase {
    /// A 240 × 360 picture: a background, then rectangles over it.
    private func picture(_ background: (Double, Double, Double),
                         _ shapes: [(CGRect, (Double, Double, Double))] = []) -> CGImage {
        let context = CGContext(data: nil, width: 240, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 360))
        for (rect, colour) in shapes {
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fill(rect)
        }
        return context.makeImage()!
    }

    /// Lines of grey "text" down a page, with margins.
    private var textLines: [(CGRect, (Double, Double, Double))] {
        stride(from: 30, to: 330, by: 14).map { (CGRect(x: 24, y: $0, width: 192, height: 4), (0.2, 0.2, 0.2)) }
    }

    func testAPageOfTextIsTextLike() {
        XCTAssertTrue(CoverLook.isTextLike(picture((1, 1, 1), textLines)))
        // The cream paper of a scanned book, too.
        XCTAssertTrue(CoverLook.isTextLike(picture((0.96, 0.93, 0.84), textLines)))
    }

    func testCoversAreNot() {
        // A coloured cover with a white title panel.
        XCTAssertFalse(CoverLook.isTextLike(picture((0.7, 0.25, 0.2), [(CGRect(x: 30, y: 200, width: 180, height: 80), (1, 1, 1))])))
        // A dark cover with light lettering.
        XCTAssertFalse(CoverLook.isTextLike(picture((0.1, 0.1, 0.12), textLines.map { ($0.0, (0.95, 0.95, 0.95)) })))
        // A white cover with a large picture on it.
        XCTAssertFalse(CoverLook.isTextLike(picture((1, 1, 1), [(CGRect(x: 20, y: 60, width: 200, height: 200), (0.2, 0.4, 0.7))])))
    }
}
