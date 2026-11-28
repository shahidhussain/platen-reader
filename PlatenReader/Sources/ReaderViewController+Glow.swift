import AppKit
import WebKit

/// An image view that never takes the mouse: clicks go through to the page
/// beneath (click zones, links, selection).
final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Ambient light and picture-only pages (as on iOS)

extension ReaderViewController {
    /// Ambient light (Aa › Ambient Light) in every theme but Black, whose
    /// point is a black screen: the page is see-through, and a glow of what
    /// is on it lies behind it, as for PDFs. On a page of text it shows only
    /// towards the window's edges, as light spilling from behind a
    /// television, so the text sits on the theme's own colour.
    var usesAmbientLight: Bool { settings.ambientLight && currentTheme != .black }

    /// What differs in the page's settings on the Mac: see-through for the
    /// glow, and picture-only pages sent here to be shown full size.
    func adjust(_ web: inout WebSettings) {
        web.transparent = usesAmbientLight
        web.lonePictures = true
    }

    // MARK: Picture-only pages

    /// The page on screen is just one picture: shown full size over the page
    /// (whose own, smaller copy the page hides), or taken away. Round it is
    /// the glow, or the page's own colour without ambient light.
    func sessionShowLonePicture(_ data: Data?) {
        let image = data.flatMap(NSImage.init(data:))
        lonePictureView.layer?.backgroundColor = usesAmbientLight ? .clear : currentTheme.nsBackground.cgColor
        lonePictureView.image = image
        lonePictureView.isHidden = image == nil
        if let waiting = lonePictureWaiter {
            lonePictureWaiter = nil
            waiting()
        } else {
            updateAmbient()
        }
    }

    /// Before a page turn's second picture is taken (the curl): if the new
    /// page is a picture-only page, its picture is on show first (waited for
    /// briefly when it is a new one); if not, the last one is taken away.
    func settleLonePicture(_ done: @escaping () -> Void) {
        session.lonePictureState { [weak self] state in
            guard let self else { return done() }
            switch state {
            case "same":
                done()
            case "new":
                var finished = false
                let finish = { if !finished { finished = true; done() } }
                self.lonePictureWaiter = finish
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.lonePictureWaiter = nil
                    finish()
                }
            default:
                self.lonePictureView.image = nil
                self.lonePictureView.isHidden = true
                done()
            }
        }
    }

    /// Before a turn the page animates itself (Slide or None): the picture
    /// goes back to the page, so it moves with it.
    func releaseLonePictureForTurn() {
        guard !lonePictureView.isHidden else { return }
        lonePictureView.isHidden = true
        lonePictureView.image = nil
        session.releaseLonePicture()
    }

    /// A picture of the page as the reader sees it, for the curl: the glow
    /// (or the theme's colour), the page, and a picture-only page's picture.
    func pageSnapshot(_ done: @escaping (CGImage?) -> Void) {
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self, let page = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return done(nil) }
            let size = self.webView.bounds.size
            let scale = CGFloat(page.width) / max(size.width, 1)
            guard let context = CGContext(data: nil, width: page.width, height: page.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return done(page) }
            let bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
            context.setFillColor(self.currentTheme.nsBackground.cgColor)
            context.fill(bounds)
            if !self.ambient.isHidden, let glow = self.ambient.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(glow, in: bounds)
            }
            context.draw(page, in: bounds)
            if !self.lonePictureView.isHidden,
               let picture = self.lonePictureView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // Where the picture view shows it (aspect fit in its frame),
                // in the snapshot's pixels (Core Graphics counts from the
                // bottom, as AppKit does).
                let frame = self.lonePictureView.frame
                let fit = min(frame.width / CGFloat(picture.width), frame.height / CGFloat(picture.height))
                let drawn = CGSize(width: CGFloat(picture.width) * fit, height: CGFloat(picture.height) * fit)
                let origin = CGPoint(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2)
                context.draw(picture, in: CGRect(x: origin.x * scale, y: origin.y * scale,
                                                 width: drawn.width * scale, height: drawn.height * scale))
            }
            done(context.makeImage() ?? page)
        }
    }

    // MARK: The glow

    /// Whether the glow fills the window rather than only its edges: round
    /// a page with no text to keep clear (a picture-only page, or a
    /// fixed-layout book's page, set apart in the middle).
    private var glowFillsWindow: Bool {
        (!lonePictureView.isHidden && lonePictureView.image != nil) || state.isFixedLayout
    }

    /// Makes the glow from a small picture of the page as it is now, after a
    /// moment (turns come in runs), and fades it in. `layoutOnly`: the
    /// window changed size, so only the edges are worked out again.
    func updateAmbient(layoutOnly: Bool = false) {
        guard ambient.superview != nil else { return }
        ambient.isHidden = !usesAmbientLight
        lonePictureView.layer?.backgroundColor = usesAmbientLight ? .clear : currentTheme.nsBackground.cgColor
        guard usesAmbientLight, session.hasRendered else { return }
        if layoutOnly, ambientMask?.size == view.bounds.size { return }
        ambientWork?.cancel()
        // A new theme: the glow made in the old one goes at once, and the
        // new one is made once the page has been redrawn in its colours.
        let theme = currentTheme.background
        let newTheme = glowTheme != nil && glowTheme != theme
        glowTheme = theme
        if newTheme { ambient.image = nil }
        let work = DispatchWorkItem { [weak self] in
            self?.glowSource { [weak self] source in
                guard let self, let source else { return }
                let paper = self.currentTheme.nsBackground.cgColor
                let brightness = AmbientGlow.brightness(ofHex: self.currentTheme.background)
                AmbientGlow.queue.async { [weak self] in
                    let glow = AmbientGlow.picture(width: AmbientGlow.pageSize.width, height: AmbientGlow.pageSize.height,
                                                   paper: paper, themeBrightness: brightness) { bitmap, size in
                        bitmap.draw(source, in: CGRect(origin: .zero, size: size))
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let glow, self.usesAmbientLight, let shown = self.maskedGlow(glow) else { return }
                        // The first glow is there from the start; later ones
                        // (a turn, a new setting) fade from the old.
                        if self.ambient.image != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                            let fade = CATransition()
                            fade.type = .fade
                            fade.duration = 0.35
                            self.ambient.wantsLayer = true
                            self.ambient.layer?.add(fade, forKey: "fade")
                        }
                        self.ambient.image = NSImage(cgImage: shown, size: self.view.bounds.size)
                    }
                }
            }
        }
        ambientWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (newTheme ? 0.7 : 0.25), execute: work)
    }

    /// What the glow is made from: a small picture of the page; on a
    /// picture-only page, the picture alone (so its colours fill the glow all
    /// round); in a fixed-layout book, its page or spread alone, not the
    /// room round it.
    private func glowSource(_ done: @escaping (CGImage?) -> Void) {
        if !lonePictureView.isHidden, let picture = lonePictureView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return done(picture)
        }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 48
        let take = { [weak self] in
            self?.webView.takeSnapshot(with: config) { image, _ in
                done(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
        guard state.isFixedLayout else { take(); return }
        session.fixedLayoutPageRects { [weak self] rects in
            guard let self else { return done(nil) }
            let area = rects.reduce(CGRect.null) { $0.union($1) }.intersection(self.webView.bounds)
            if !area.isNull, area.width > 4, area.height > 4 { config.rect = area }
            take()
        }
    }

    /// The glow stretched to the window, and (round a page of text) faded
    /// towards the middle, strongest at the edges.
    private func maskedGlow(_ glow: CGImage) -> CGImage? {
        let size = view.bounds.size
        let width = max(Int(size.width), 1), height = max(Int(size.height), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .medium
        context.draw(glow, in: bounds)
        if !glowFillsWindow, let mask = edgeMask(size) {
            context.setBlendMode(.destinationIn)
            context.draw(mask, in: bounds)
        }
        return context.makeImage()
    }

    /// White at the window's edges, fading to nothing some way in (made once
    /// per window size).
    private func edgeMask(_ size: CGSize) -> CGImage? {
        if let ambientMask, ambientMask.size == size { return ambientMask.image }
        let width = max(Int(size.width), 1), height = max(Int(size.height), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray,
                                        locations: [0, 1]) else { return nil }
        // A little wider than iOS's 70 points: a Mac window is larger.
        let edge: CGFloat = 90
        let w = CGFloat(width), h = CGFloat(height)
        for (start, end) in [(CGPoint(x: 0, y: 0), CGPoint(x: edge, y: 0)),
                             (CGPoint(x: w, y: 0), CGPoint(x: w - edge, y: 0)),
                             (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: edge)),
                             (CGPoint(x: 0, y: h), CGPoint(x: 0, y: h - edge))] {
            context.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
        guard let image = context.makeImage() else { return nil }
        ambientMask = (size, image)
        return image
    }
}
