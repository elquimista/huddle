// Draws the Huddle app icon into an .iconset folder.
//   swift Scripts/make-icon.swift <out.iconset> [--dev]
import AppKit

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args[1])
let isDev = args.contains("--dev")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func draw(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // Standard macOS icon plate: 824pt rounded square centred on a 1024pt canvas.
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let top = isDev ? NSColor(srgbRed: 1.00, green: 0.66, blue: 0.20, alpha: 1)
                    : NSColor(srgbRed: 0.40, green: 0.90, blue: 0.42, alpha: 1)
    let bottom = isDev ? NSColor(srgbRed: 0.93, green: 0.36, blue: 0.13, alpha: 1)
                       : NSColor(srgbRed: 0.08, green: 0.70, blue: 0.24, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)

    // Two round speech bubbles with curved tails: a faded one behind, a solid one in front.
    func bubble(_ rect: NSRect, tailLeft: Bool) -> NSBezierPath {
        // The tail is defined for a 600x500 oval and scaled to `rect`.
        let path = NSBezierPath(ovalIn: rect)
        let sx = rect.width / 600, sy = rect.height / 500
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + (tailLeft ? x : 600 - x) * sx, y: rect.minY + y * sy)
        }
        let tail = NSBezierPath()
        tail.move(to: p(88, 120))
        tail.curve(to: p(24, -38), controlPoint1: p(94, 50), controlPoint2: p(68, -4))
        tail.curve(to: p(240, 18), controlPoint1: p(108, -42), controlPoint2: p(186, -20))
        tail.close()
        path.append(tail)
        return path
    }
    let backRect = NSRect(x: 452, y: 470, width: 400, height: 320)
    let frontRect = NSRect(x: 180, y: 300, width: 480, height: 390)
    let front = bubble(frontRect, tailLeft: true)
    let gradient = NSGradient(starting: top, ending: bottom)!
    let context = NSGraphicsContext.current!.cgContext

    // Back bubble: oval and tail filled as one shape, then faded together.
    context.saveGState()
    context.setAlpha(0.6)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: backRect).fill()
    bubble(backRect, tailLeft: false).fill()
    context.endTransparencyLayer()
    context.restoreGState()

    // A plate-coloured halo around the front bubble keeps the two apart.
    context.saveGState()
    context.addPath(CGPath(__byStroking: front.cgPath, transform: nil, lineWidth: 36,
                           lineCap: .round, lineJoin: .round, miterLimit: 10)!)
    context.clip()
    gradient.draw(in: plate, angle: -90)
    context.restoreGState()

    NSColor.white.setFill()
    front.fill()

    if isDev {
        // "DEV" fills the front bubble, in the plate's colour.
        let label = NSAttributedString(string: "DEV", attributes: [
            .font: NSFont.systemFont(ofSize: 176, weight: .black),
            .foregroundColor: bottom,
            .kern: 2,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: frontRect.midX - size.width / 2 + 1, y: frontRect.midY - size.height / 2))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let data = draw(pixels: points * scale).representation(using: .png, properties: [:])!
    try data.write(to: outDir.appendingPathComponent(name))
}
