import UIKit

/// Going back by swiping, in the home screen's navigation (folders inside
/// Recent Folders), even though the folder view hides its Back button to
/// give the grid the space. UIKit turns the back swipe off when the Back
/// button is hidden; this turns it on again, for a swipe from the edge and
/// (iOS 26) a swipe anywhere across the page, whenever there is somewhere
/// to go back to.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        if #available(iOS 26.0, *) {
            interactiveContentPopGestureRecognizer?.delegate = self
        }
    }

    public func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
