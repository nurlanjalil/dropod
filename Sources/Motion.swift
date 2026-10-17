import AppKit
import QuartzCore

/// Shared animation helpers. Every effect falls back to a short fade when
/// "Reduce motion" is on in Accessibility settings.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A gentle ease-out used for resizing and moving things.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)

    static func spring(_ keyPath: String, from: Any?, to: Any?,
                       damping: CGFloat = 16, stiffness: CGFloat = 280) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.damping = damping
        animation.stiffness = stiffness
        animation.duration = animation.settlingDuration
        return animation
    }

    /// Sets a layer's transform, springing to it from wherever it currently is.
    static func setTransform(_ layer: CALayer, _ transform: CATransform3D, animated: Bool) {
        let from = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
        guard animated, !reduced else { return }
        layer.add(spring("transform", from: from, to: transform), forKey: "transform")
    }

    /// A scale around the centre of a view-backed layer (those are anchored bottom-left).
    static func scale(_ s: CGFloat, around layer: CALayer) -> CATransform3D {
        let mid = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        var t = CATransform3DMakeTranslation(mid.x, mid.y, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -mid.x, -mid.y, 0)
    }

    // MARK: Windows

    /// Fades a window in while its content springs up from slightly smaller.
    static func present(_ panel: ShelfPanel) {
        panel.visibilityToken += 1
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.12 : 0.18
            panel.animator().alphaValue = 1
        }
        guard !reduced, let layer = panel.contentView?.layer else { return }
        layer.removeAnimation(forKey: "dismiss")
        layer.add(spring("transform", from: scale(0.88, around: layer), to: CATransform3DIdentity,
                         damping: 18, stiffness: 320), forKey: "present")
    }

    /// Shrinks and fades a window away, then orders it out.
    static func dismiss(_ panel: ShelfPanel, completion: (() -> Void)? = nil) {
        let token = panel.visibilityToken
        let layer = panel.contentView?.layer
        if !reduced, let layer {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = CATransform3DIdentity
            shrink.toValue = scale(0.9, around: layer)
            shrink.duration = 0.16
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "dismiss")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? 0.1 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // Shown again while fading out: leave it alone.
            guard panel.visibilityToken == token else { return }
            panel.orderOut(nil)
            layer?.removeAnimation(forKey: "dismiss")
            completion?()
        })
    }
}
