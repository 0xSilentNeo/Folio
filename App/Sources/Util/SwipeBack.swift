import UIKit

/// Swipe back with the navigation bar hidden. UIKit turns the back swipe off
/// whenever a navigation controller's bar is hidden, and every page here
/// hides it (the title page draws its own Back button) — so the swipe never
/// worked on title pages. Re-enabled for any screen that has somewhere to go
/// back to.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { interactiveContentPopGestureRecognizer?.delegate = self }
        #endif
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1 && transitionCoordinator == nil
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}
