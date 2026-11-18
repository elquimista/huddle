import AppKit

extension NSWindow {
    /// Shakes side to side, as macOS password prompts do when the password is wrong. Not with
    /// Reduce Motion on.
    func shake() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let origin = frame.origin
        let path = CGMutablePath()
        path.move(to: origin)
        for distance in [8.0, 6.0, 4.0] {
            path.addLine(to: CGPoint(x: origin.x - distance, y: origin.y))
            path.addLine(to: CGPoint(x: origin.x + distance, y: origin.y))
        }
        path.addLine(to: origin)
        let animation = CAKeyframeAnimation()
        animation.path = path
        animation.duration = 0.35
        animations = ["frameOrigin": animation]
        animator().setFrameOrigin(origin)
    }
}
