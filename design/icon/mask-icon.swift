// Cuts a rendered icon (1024 × 1024, from Quick Look, which fills the
// background with white) to the macOS icon shape, so everything outside the
// rounded square is transparent. The shape matches the SVG: a square from 100
// to 924 with 185-pixel corners.
//
// Usage: swift design/icon/mask-icon.swift <in.png> <out.png>
import AppKit

let args = CommandLine.arguments
let source = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1])))!
let size = 1024
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current?.imageInterpolation = .high
// Half a pixel inside the edge, so no white fringe survives.
NSBezierPath(roundedRect: NSRect(x: 100.5, y: 100.5, width: 823, height: 823), xRadius: 184.5, yRadius: 184.5).addClip()
source.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
