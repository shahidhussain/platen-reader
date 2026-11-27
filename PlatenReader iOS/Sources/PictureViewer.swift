import UIKit

/// A picture from a book or a PDF on its own, filling the screen ("View
/// Image" in the long-press menu, `offerPicture`). It grows out of where the
/// picture is on the page, on black, and any tap puts it back: the reader is
/// where they were. Two fingers zoom in, for a map or a detailed plate.
final class PictureViewer: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let name: String
    /// Where the picture is on the page, in window coordinates: it grows
    /// from there and goes back there.
    private let origin: CGRect
    private let scroll = UIScrollView()
    private let imageView = UIImageView()

    init(image: UIImage, name: String, origin: CGRect) {
        self.image = image
        self.name = name
        self.origin = origin
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        view.addSubview(scroll)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = name
        imageView.accessibilityHint = String(localized: "Tap to go back to the page.")
        scroll.addSubview(imageView)

        // Any tap goes back (VoiceOver's two-finger scrub too).
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Laid out at the fit until the reader zooms (a turn re-fits it):
        // the picture is the scroll view's content, kept in the middle by
        // insets (`scrollViewDidZoom`).
        if scroll.zoomScale == 1 {
            let fit = fittedSize(in: view.bounds.size)
            imageView.frame = CGRect(origin: .zero, size: fit)
            scroll.contentSize = fit
            scrollViewDidZoom(scroll)
        }
    }

    /// The picture's size as large as it fits.
    private func fittedSize(in bounds: CGSize) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.layoutIfNeeded()
        let fit = imageView.frame
        if UIAccessibility.isReduceMotionEnabled || origin.isEmpty {
            view.alpha = 0
            view.backgroundColor = .black
            UIView.animate(withDuration: 0.2) { self.view.alpha = 1 }
        } else {
            // From the picture's place on the page to the fit, as the black
            // comes up behind it.
            imageView.frame = scroll.convert(origin, from: nil)
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
                self.imageView.frame = fit
                self.view.backgroundColor = .black
            }
        }
    }

    @objc private func close() {
        let shrink = !UIAccessibility.isReduceMotionEnabled && !origin.isEmpty
        UIView.animate(withDuration: shrink ? 0.25 : 0.2, delay: 0, options: .curveEaseIn) {
            if shrink {
                // (Unzoomed first, so the way back is worked out at the fit.)
                self.scroll.zoomScale = 1
                self.imageView.frame = self.scroll.convert(self.origin, from: nil)
                self.view.backgroundColor = .clear
            } else {
                self.view.alpha = 0
            }
        } completion: { _ in
            self.dismiss(animated: false)
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }

    // MARK: - Zooming

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    /// Keeps the zoomed picture in the middle while it is smaller than the
    /// screen in either direction.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        scrollView.contentInset = UIEdgeInsets(top: max(0, (bounds.height - content.height) / 2),
                                               left: max(0, (bounds.width - content.width) / 2),
                                               bottom: 0, right: 0)
    }
}
