// Draws the bookmark ribbon (docs/platen-press.md, "The bookmark ribbon"):
// a slim ribbon of orange grosgrain with a swallowtail notch, fine woven ribs
// running across it, and a line of stitching in a darker thread along both
// long edges and round the notch. In light and dark (deeper, so it does not
// glow on a dark page), at 2x (Mac) and 3x (iPhone, iPad).
//
// The shadow on the page is not drawn here: the page adds it (reader.css,
// BookmarkRibbonView), so it falls on whatever colour the page is.
//
//   swift design/ribbon/make-ribbon.swift
//
// writes PlatenReader/Web/ribbon/ribbon-{light,dark}@{2,3}x.png, which the
// web shell (bookmarks.js) and the iOS PDF reader (BookmarkRibbonView) use.
// The texture comes from a fixed seed, so the files only change when this
// script does.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The ribbon's size in points, and the notch's depth.
let width = 20.0, height = 30.0, notch = 6.5

struct Palette {
    var cloth: (Double, Double, Double)
    var thread: (Double, Double, Double)
}

let palettes: [String: Palette] = [
    // The app's accent (Colours.xcassets: #F0861A), as cloth.
    "light": Palette(cloth: (0.92, 0.50, 0.11), thread: (0.62, 0.28, 0.04)),
    // Deeper on a dark page, so it does not glow.
    "dark": Palette(cloth: (0.78, 0.40, 0.08), thread: (0.48, 0.21, 0.03)),
]

/// A small, fixed random source, so the weave is the same every run.
struct Seeded {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 33) / Double(1 << 31)
    }
}

func ribbonPath(inset: Double = 0) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: inset, y: 0))
    path.addLine(to: CGPoint(x: width - inset, y: 0))
    path.addLine(to: CGPoint(x: width - inset, y: height - inset * 0.6))
    path.addLine(to: CGPoint(x: width / 2, y: height - notch - inset * 0.9))
    path.addLine(to: CGPoint(x: inset, y: height - inset * 0.6))
    path.closeSubpath()
    return path
}

func draw(_ palette: Palette, scale: Double) -> CGImage {
    let w = Int(width * scale), h = Int(height * scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Points, with y down (as the ribbon hangs).
    context.translateBy(x: 0, y: CGFloat(h))
    context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))

    // The cloth, row by row of pixels: ribs across it (a rib every 0.55
    // points, lighter on its crown), a little unevenness thread to thread,
    // and darker towards the edges, as if the ribbon were slightly rounded.
    context.saveGState()
    context.addPath(ribbonPath())
    context.clip()
    var random = Seeded(state: 0x5EED)
    let pixel = 1 / scale
    let rowShade = (0..<h).map { _ in random.next() }
    for py in 0..<h {
        let y = Double(py) * pixel
        let rib = 0.5 + 0.5 * cos(2 * .pi * y / 0.55)
        for px in 0..<w {
            let x = Double(px) * pixel
            let across = abs(x - width / 2) / (width / 2)
            let rounded = 1 - 0.16 * pow(across, 2.2)
            let warp = 0.985 + 0.03 * random.next()
            let shade = rounded * warp * (0.93 + 0.09 * rib) * (0.985 + 0.03 * rowShade[py])
            context.setFillColor(red: palette.cloth.0 * shade, green: palette.cloth.1 * shade,
                                 blue: palette.cloth.2 * shade, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: pixel, height: pixel))
        }
    }
    context.restoreGState()

    // The stitching: short stitches of darker thread, 1.6 points in from
    // the long edges and round the notch, each a small rounded dash with a
    // highlight along it and a needle hole darkening each end, so it reads
    // as thread sewn through rather than a dashed line.
    let inset = 1.7
    let line: [CGPoint] = [
        CGPoint(x: inset, y: 0),
        CGPoint(x: inset, y: height - 2.2),
        CGPoint(x: width / 2, y: height - notch - 1.55),
        CGPoint(x: width - inset, y: height - 2.2),
        CGPoint(x: width - inset, y: 0),
    ]
    let stitch = 1.05, gap = 0.62
    var carried = 0.4 // where along the line the next stitch starts
    for (a, b) in zip(line, line.dropFirst()) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        let ux = dx / length, uy = dy / length
        var t = carried
        while t + stitch <= length {
            let start = CGPoint(x: a.x + ux * t, y: a.y + uy * t)
            let end = CGPoint(x: a.x + ux * (t + stitch), y: a.y + uy * (t + stitch))
            // The thread.
            context.setLineCap(.round)
            context.setLineWidth(0.5)
            context.setStrokeColor(red: palette.thread.0, green: palette.thread.1, blue: palette.thread.2, alpha: 0.95)
            context.strokeLineSegments(between: [start, end])
            // Its sheen, along one side.
            context.setLineWidth(0.16)
            context.setStrokeColor(red: 1, green: 0.86, blue: 0.62, alpha: 0.28)
            let nx = -uy * 0.1, ny = ux * 0.1
            context.strokeLineSegments(between: [CGPoint(x: start.x + ux * 0.2 + nx, y: start.y + uy * 0.2 + ny),
                                                 CGPoint(x: end.x - ux * 0.2 + nx, y: end.y - uy * 0.2 + ny)])
            // The needle holes.
            context.setFillColor(red: 0.2, green: 0.08, blue: 0.0, alpha: 0.35)
            for p in [start, end] {
                context.fillEllipse(in: CGRect(x: p.x - 0.22, y: p.y - 0.22, width: 0.44, height: 0.44))
            }
            t += stitch + gap
        }
        carried = max(0, t - length)
    }

    // The cut ends of the notch: a touch soft, never ragged (a faint
    // lighter line along the cut, inside the edge).
    context.setLineWidth(0.35)
    context.setStrokeColor(red: palette.cloth.0, green: palette.cloth.1, blue: palette.cloth.2, alpha: 0.5)
    context.strokeLineSegments(between: [CGPoint(x: 0.3, y: height - 0.4), CGPoint(x: width / 2, y: height - notch - 0.3),
                                         CGPoint(x: width / 2, y: height - notch - 0.3), CGPoint(x: width - 0.3, y: height - 0.4)])
    return context.makeImage()!
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let output = here.appendingPathComponent("../../PlatenReader/Web/ribbon").standardizedFileURL
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (name, palette) in palettes.sorted(by: { $0.key < $1.key }) {
    for scale in [2, 3] {
        let url = output.appendingPathComponent("ribbon-\(name)@\(scale)x.png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, draw(palette, scale: Double(scale)), nil)
        CGImageDestinationFinalize(destination)
        print("wrote", url.path)
    }
}
