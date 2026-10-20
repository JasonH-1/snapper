#if DEBUG
import ObjectiveC
import UIKit

/// Draws a circle wherever a finger is, so the guide's demo clips show what
/// was tapped and dragged. Debug builds only, and only when launched with
/// `-SnapperShowTouches YES` (scripts/record-guide-demo.sh does this).
enum TouchIndicators {
    @MainActor static func installIfRequested() {
        guard UserDefaults.standard.bool(forKey: "SnapperShowTouches"),
              let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
              let replacement = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.snapper_sendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }
}

extension UIWindow {
    /// Swapped with `sendEvent(_:)`, so calling it here calls the original.
    @objc fileprivate func snapper_sendEvent(_ event: UIEvent) {
        snapper_sendEvent(event)
        guard event.type == .touches, let touches = event.allTouches else { return }
        TouchDots.shared.update(touches, in: self)
    }
}

@MainActor
private final class TouchDots {
    static let shared = TouchDots()
    private var dots: [ObjectIdentifier: UIView] = [:]

    func update(_ touches: Set<UITouch>, in window: UIWindow) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            switch touch.phase {
            case .began:
                let dot = Self.makeDot()
                dot.center = touch.location(in: window)
                window.addSubview(dot)
                dots[key] = dot
                UIView.animate(withDuration: 0.12) { dot.transform = .identity; dot.alpha = 1 }
            case .moved, .stationary:
                guard let dot = dots[key] else { continue }
                dot.center = touch.location(in: window)
                window.bringSubviewToFront(dot)
            case .ended, .cancelled:
                guard let dot = dots.removeValue(forKey: key) else { continue }
                UIView.animate(withDuration: 0.25, animations: {
                    dot.alpha = 0
                    dot.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
                }, completion: { _ in dot.removeFromSuperview() })
            default:
                break
            }
        }
    }

    private static func makeDot() -> UIView {
        let size: CGFloat = 46
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        dot.isUserInteractionEnabled = false
        dot.layer.cornerRadius = size / 2
        dot.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        dot.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        dot.layer.borderWidth = 2
        dot.alpha = 0
        dot.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        return dot
    }
}
#endif
