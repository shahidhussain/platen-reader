import UIKit

/// The ambient glow behind a reader's pages (books and PDFs): a soft light
/// of the page's own colours. It stays where it is while pages slide over
/// it, and changes from one page's glow to the next by fading, in step with
/// the slide: halfway across, halfway faded; a slide that is put back,
/// faded back. (Moving with the pages instead left a hard line in the glow
/// where the old page's met the new one's.)
///
/// It holds two pictures: the glow on show, and, during a slide, the next
/// page's over it, whose opacity is the slide's progress
/// (`PageTurnAnimator.slideProgress`).
final class AmbientGlowView: UIView {
    private let current = UIImageView()
    private let incoming = UIImageView()
    /// True between a slide's start and its end: a new glow made meanwhile
    /// belongs to the page sliding in, so it goes in `incoming`.
    private(set) var isSliding = false
    private var progress: CGFloat = 0

    /// Told the glow on show each time it changes (nil: none, or hidden),
    /// so the bands behind the controls can take its colours (GlowBand).
    var glowChanged: ((UIImage?) -> Void)?

    override var isHidden: Bool {
        didSet { if isHidden != oldValue { glowChanged?(isHidden ? nil : current.image) } }
    }

    /// The glow on show is now `image`.
    private func setCurrent(_ image: UIImage?) {
        current.image = image
        if !isHidden { glowChanged?(image) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        for view in [current, incoming] {
            view.contentMode = .scaleToFill
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        incoming.alpha = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The glow on show (during a slide, the old page's).
    var image: UIImage? { current.image }

    /// Shows a glow: at once, or fading from the last one over `fade`
    /// seconds. During a slide it is the page sliding in, and fades with
    /// the slide instead.
    func show(_ image: UIImage?, fade: TimeInterval = 0, curve: UIView.AnimationOptions = []) {
        if isSliding {
            incoming.image = image
            incoming.alpha = progress
            return
        }
        guard fade > 0, current.image != nil else { setCurrent(image); return }
        UIView.transition(with: current, duration: fade,
                          options: [.transitionCrossDissolve, .allowUserInteraction, curve]) {
            self.setCurrent(image)
        }
    }

    /// A slide has moved `progress` of the way (0: the old page, 1: the
    /// new). Called inside the slide's own animation when it animates, so
    /// the fade keeps its timing.
    func slide(to progress: CGFloat) {
        if !isSliding {
            isSliding = true
            incoming.layer.removeAllAnimations()
            incoming.image = nil
        }
        self.progress = min(max(progress, 0), 1)
        incoming.alpha = self.progress
    }

    /// The slide is over: the new page stayed (`turned`), so its glow is
    /// now the one on show, or it was put back.
    func endSlide(turned: Bool) {
        guard isSliding else { return }
        isSliding = false
        if turned, let image = incoming.image { setCurrent(image) }
        incoming.image = nil
        incoming.alpha = 0
        progress = 0
    }
}
