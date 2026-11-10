import AppKit
import UniformTypeIdentifiers

/// A picture from the book shown full size over the page. It grows from
/// where the picture sits on the page and shrinks back when closed.
///
/// Click anywhere or press Esc to close. Right-click (or Control-click) for
/// Copy Image, Save Image… and Share…, so the picture can be used elsewhere.
final class ImageZoomView: NSView {
    var onClose: (() -> Void)?

    private let image: NSImage
    private let data: Data
    private let type: String
    private let name: String
    private let imageView = NSImageView()
    private let background: NSColor
    private var backdropAlpha: CGFloat = 0 { didSet { needsDisplay = true } }
    private var sourceRect = NSRect.zero
    /// While animating, layout must not snap the picture into place.
    private var animating = false

    init(image: NSImage, data: Data, type: String, name: String, background: NSColor) {
        self.image = image
        self.data = data
        self.type = type
        self.name = name
        self.background = background
        super.init(frame: .zero)
        wantsLayer = true
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.isEditable = false
        imageView.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()
        addSubview(imageView)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(name.isEmpty ? String(localized: "Picture") : name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    // The picture view must not take clicks or menus itself: this view
    // handles both.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// The backdrop: the page colour, nearly opaque, fading in and out.
    override func draw(_ dirtyRect: NSRect) {
        background.withAlphaComponent(0.97 * backdropAlpha).setFill()
        bounds.fill()
    }

    /// Where the picture sits when fully shown: as large as the window
    /// allows (keeping its proportions), with a small margin.
    private var fittedRect: NSRect {
        let margin: CGFloat = 24
        let area = bounds.insetBy(dx: margin, dy: margin)
        let size = image.size
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return area }
        let scale = min(area.width / size.width, area.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h).integral
    }

    func present(from source: NSRect, animated: Bool) {
        sourceRect = source.width > 0 ? source : fittedRect
        animate(animated, from: sourceRect, to: fittedRect, alpha: (0, 1), completion: nil)
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        animate(animated, from: imageView.frame, to: sourceRect, alpha: (backdropAlpha, 0), completion: completion)
    }

    // The zoom is driven frame by frame from the display link rather than
    // with AppKit's implicit animations: animating a layer-backed view's
    // frame can start from the wrong place (offset by half its size), which
    // made the picture jump before it grew.
    private var displayLink: CADisplayLink?
    private var animation: (start: CFTimeInterval, duration: CFTimeInterval, from: NSRect, to: NSRect,
                            alpha: (CGFloat, CGFloat), completion: (() -> Void)?)?

    private func animate(_ animated: Bool, from: NSRect, to: NSRect, alpha: (CGFloat, CGFloat),
                         completion: (() -> Void)?) {
        displayLink?.invalidate()
        guard animated else {
            imageView.frame = to
            backdropAlpha = alpha.1
            animating = false
            completion?()
            return
        }
        animating = true
        imageView.frame = from
        backdropAlpha = alpha.0
        animation = (CACurrentMediaTime(), 0.24, from, to, alpha, completion)
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let a = animation else { link.invalidate(); return }
        let t = min(1, (CACurrentMediaTime() - a.start) / a.duration)
        // Ease in and out.
        let e = CGFloat(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * e }
        imageView.frame = NSRect(x: mix(a.from.minX, a.to.minX), y: mix(a.from.minY, a.to.minY),
                                 width: mix(a.from.width, a.to.width), height: mix(a.from.height, a.to.height))
        backdropAlpha = mix(a.alpha.0, a.alpha.1)
        if t >= 1 {
            link.invalidate()
            displayLink = nil
            animation = nil
            animating = false
            a.completion?()
        }
    }

    override func layout() {
        super.layout()
        if !animating { imageView.frame = fittedRect }
    }

    // MARK: Input

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return }
        onClose?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 49 { onClose?() } // Esc, space
        else { super.keyDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {} // keep the page still underneath

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy Image"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Save Image…"), action: #selector(saveImage(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Share…"), action: #selector(shareImage(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc func copy(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // The original bytes where the type is one other apps read, plus a
        // TIFF/PNG rendering from NSImage for everything else.
        pasteboard.writeObjects([image])
        if let utType, utType.conforms(to: .png) || utType.conforms(to: .jpeg) {
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(utType.identifier))
        }
    }

    @objc func saveImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        let ext = utType?.preferredFilenameExtension ?? "png"
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = (base.isEmpty ? String(localized: "Picture") : String(base.prefix(60)))
            .replacingOccurrences(of: "/", with: "-") + "." + ext
        if let utType { panel.allowedContentTypes = [utType] }
        panel.beginSheetModal(for: window) { [data] response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch { NSApp.presentError(error) }
        }
    }

    @objc func shareImage(_ sender: Any?) {
        let picker = NSSharingServicePicker(items: [image])
        picker.show(relativeTo: NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1), of: self, preferredEdge: .minY)
    }

    private var utType: UTType? {
        UTType(mimeType: type) ?? (type.isEmpty ? nil : UTType(filenameExtension: type))
    }
}
