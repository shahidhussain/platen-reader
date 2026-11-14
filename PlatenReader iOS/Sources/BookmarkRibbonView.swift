import UIKit

/// The bookmark ribbon on a bookmarked PDF page, drawn like the books' one
/// (PlatenReader/Web/modules/bookmarks.js): a ribbon of red cloth with a
/// notched end, shaded across its width (darker at the edges, as if rounded),
/// a fine darker edge down its sides and along the notch, and a soft shadow
/// on the page beneath. It is placed over the page's top edge, as a real
/// ribbon lies on the page (see `PDFReaderViewController.placeRibbon`).
final class BookmarkRibbonView: UIView {
    /// The size it is drawn at (points); the shape is 22 by 30 units.
    static let size = CGSize(width: 26, height: 36)

    private let cloth = CAGradientLayer()
    private let clothMask = CAShapeLayer()
    private let edge = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        cloth.colors = [
            UIColor(red: 0.66, green: 0.13, blue: 0.10, alpha: 1).cgColor,
            UIColor(red: 0.87, green: 0.29, blue: 0.24, alpha: 1).cgColor,
            UIColor(red: 0.72, green: 0.16, blue: 0.12, alpha: 1).cgColor,
        ]
        cloth.locations = [0, 0.45, 1]
        cloth.startPoint = CGPoint(x: 0, y: 0.5)
        cloth.endPoint = CGPoint(x: 1, y: 0.5)
        cloth.mask = clothMask
        layer.addSublayer(cloth)

        edge.fillColor = nil
        edge.strokeColor = UIColor(red: 0.31, green: 0.03, blue: 0.02, alpha: 0.5).cgColor
        edge.lineWidth = 1
        edge.lineJoin = .round
        layer.addSublayer(edge)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { Self.size }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        // The notch rises 6.5 of the 30 units from the bottom corners.
        let notch = h * 6.5 / 30
        let shape = UIBezierPath()
        shape.move(to: .zero)
        shape.addLine(to: CGPoint(x: w, y: 0))
        shape.addLine(to: CGPoint(x: w, y: h))
        shape.addLine(to: CGPoint(x: w / 2, y: h - notch))
        shape.addLine(to: CGPoint(x: 0, y: h))
        shape.close()

        // The edge: down one side, along the notch and up the other, half a
        // point inside, so it is not cut off. The top is left open.
        let inset: CGFloat = 0.5
        let outline = UIBezierPath()
        outline.move(to: CGPoint(x: inset, y: 0))
        outline.addLine(to: CGPoint(x: inset, y: h - 1))
        outline.addLine(to: CGPoint(x: w / 2, y: h - notch - 0.6))
        outline.addLine(to: CGPoint(x: w - inset, y: h - 1))
        outline.addLine(to: CGPoint(x: w - inset, y: 0))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cloth.frame = bounds
        clothMask.path = shape.cgPath
        edge.path = outline.cgPath
        layer.shadowPath = shape.cgPath
        CATransaction.commit()
    }
}
