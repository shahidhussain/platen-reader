import QuartzCore
import UIKit
import WebKit

/// The page turns that taps, the overlay's ‹ › buttons and the keyboard ask
/// for. "left" and "right" are sides of the screen (they turn the right way
/// in right-to-left books); "next" and "prev" are reading order.
enum PageTurnRequest: String {
    case left, right, next, prev
}

// Page Curl on iOS (Settings > Page Turn). iOS has a real paper curl built
// in: UIPageViewController's page-curl transition. The turn works like the
// Mac's (ReaderViewController+PageTurn there):
// 1. snapshot the page on screen and cover the web view with it;
// 2. turn the page underneath instantly (platen.turnInstantly);
// 3. snapshot the new page, and let the system curl the old one away.
//
// Swipes are not curled yet: they slide, following the finger. A curl that
// follows the finger needs the next page drawn before the finger moves.
extension ReaderViewController {
    func turn(_ request: PageTurnRequest) {
        let script: String
        switch request {
        case .left: script = "platen.goLeft()"
        case .right: script = "platen.goRight()"
        case .next: script = "platen.next()"
        case .prev: script = "platen.prev()"
        }
        let curl = settings.pageTurnStyle == .curl && !UIAccessibility.isReduceMotionEnabled
            && state.flow == .paginated
        // Taps faster than a curl (or holding an arrow key) turn instantly.
        guard curl, curlInProgress == nil else {
            finishCurl()
            return js(script)
        }
        curlTurn(request)
    }

    private func curlTurn(_ request: PageTurnRequest) {
        // Which way the leaf travels: towards the left is a forward curl
        // (lifted from the right edge).
        let leafMovesLeft: Bool
        switch request {
        case .right: leafMovesLeft = true
        case .left: leafMovesLeft = false
        case .next: leafMovesLeft = !state.isRightToLeft
        case .prev: leafMovesLeft = state.isRightToLeft
        }

        let pager = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                         options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
        pager.isDoubleSided = false
        pager.view.isUserInteractionEnabled = false
        pager.view.backgroundColor = .clear
        pager.view.frame = webView.frame
        curlInProgress = pager

        webView.takeSnapshot(with: nil) { [weak self] before, _ in
            guard let self, self.curlInProgress === pager, let before else { return self?.cancelCurl(pager, request) ?? () }
            // Cover the web view with the page as it is now.
            pager.setViewControllers([Self.page(before, background: self.view.backgroundColor)],
                                     direction: .forward, animated: false)
            self.addChild(pager)
            self.view.insertSubview(pager.view, aboveSubview: self.webView)
            pager.didMove(toParent: self)

            // Turn underneath, then curl the old page away to show the new.
            self.webView.callAsyncJavaScript("return await platen.turnInstantly(direction)",
                                             arguments: ["direction": request.rawValue], in: nil, in: .page) { result in
                guard self.curlInProgress === pager else { return }
                let moved = ((try? result.get()) as? [String: Any])?["moved"] as? Bool ?? false
                guard moved else { return self.finishCurl() } // at the start or end
                self.webView.takeSnapshot(with: nil) { after, _ in
                    guard self.curlInProgress === pager, let after else { return self.finishCurl() }
                    let started = CACurrentMediaTime()
                    pager.setViewControllers([Self.page(after, background: self.view.backgroundColor)],
                                             direction: leafMovesLeft ? .forward : .reverse, animated: true) { _ in
                        log.info("page curl took \(Int((CACurrentMediaTime() - started) * 1000)) ms")
                        if self.curlInProgress === pager { self.finishCurl() }
                    }
                }
            }
        }
    }

    /// The snapshot could not be taken: turn without the curl.
    private func cancelCurl(_ pager: UIPageViewController, _ request: PageTurnRequest) {
        guard curlInProgress === pager else { return }
        curlInProgress = nil
        turn(request)
    }

    /// Removes the curl's cover (the page underneath is already turned).
    func finishCurl() {
        guard let pager = curlInProgress else { return }
        curlInProgress = nil
        pager.willMove(toParent: nil)
        pager.view.removeFromSuperview()
        pager.removeFromParent()
    }

    private static func page(_ image: UIImage, background: UIColor?) -> UIViewController {
        let page = UIViewController()
        page.view.backgroundColor = background
        let imageView = UIImageView(image: image)
        imageView.frame = page.view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleToFill
        page.view.addSubview(imageView)
        return page
    }
}
