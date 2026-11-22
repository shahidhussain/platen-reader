import UIKit

/// Going back by swiping, in the home screen's navigation (folders inside
/// the Home tab): a swipe from the edge and (iOS 26) a swipe anywhere
/// across the page, whenever there is somewhere to go back to. (The folder
/// view once hid its Back button, which turns UIKit's back swipe off; this
/// turned it on again, and keeps it on for any view that hides it.)
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        // The swipe anywhere is new in iOS 26; its API exists only in that
        // SDK (Xcode 26 and later), so older toolchains, such as CI's, leave
        // it out.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            interactiveContentPopGestureRecognizer?.delegate = self
        }
        #endif
    }

    public func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
