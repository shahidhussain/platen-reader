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
        imageView.wantsLayer = true
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

    /// Where the picture sits when fully shown: as large as fits with a
    /// margin, but never enlarged beyond twice its natural size (small
    /// pictures blown up to fill a big screen just look blurred).
    private var fittedRect: NSRect {
        let margin: CGFloat = 40
        let bounds = self.bounds.insetBy(dx: margin, dy: margin)
        let size = pointSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height, 2)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: self.bounds.midX - w / 2, y: self.bounds.midY - h / 2, width: w, height: h).integral
    }

    /// The picture's natural size in points on this screen.
    private var pointSize: NSSize {
        let rep = image.representations.first
        let pixels = NSSize(width: rep?.pixelsWide ?? 0, height: rep?.pixelsHigh ?? 0)
        let scale = window?.backingScaleFactor ?? 2
        if pixels.width > 0 { return NSSize(width: pixels.width / scale, height: pixels.height / scale) }
        return image.size
    }

    func present(from source: NSRect, animated: Bool) {
        sourceRect = source.width > 0 ? source : fittedRect
        imageView.frame = sourceRect
        animate(animated, alpha: 1, frame: fittedRect, completion: nil)
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        animate(animated, alpha: 0, frame: sourceRect, completion: completion)
    }

    private func animate(_ animated: Bool, alpha: CGFloat, frame: NSRect, completion: (() -> Void)?) {
        animating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? 0.25 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            imageView.animator().frame = frame
            animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.animating = false
            completion?()
        })
        // The backdrop fades with the picture's movement.
        if animated {
            let steps = 12
            for i in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(i) / Double(steps)) { [weak self] in
                    guard let self else { return }
                    let t = CGFloat(i) / CGFloat(steps)
                    self.backdropAlpha = alpha == 1 ? t : 1 - t
                }
            }
        } else {
            backdropAlpha = alpha
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
