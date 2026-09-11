import AppKit

/// The .app icon: a macOS-style rounded tile (standard margin + shadow) with a deep-space
/// gradient and a few stars, and the rocket in full colour with its exhaust flame.
enum AppIconGenerator {
    static func icon(size: Int) -> NSImage {
        let s = CGFloat(size)
        return NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let space = CGColorSpaceCreateDeviceRGB()
            func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
                CGColor(red: r, green: g, blue: b, alpha: a)
            }
            func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
                CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
            }

            // Tile
            let tileRect = rect.insetBy(dx: s * 0.1, dy: s * 0.1)
            let radius = tileRect.width * 0.225
            let tile = CGPath(roundedRect: tileRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0, 0, 0, 0.35))
            ctx.addPath(tile)
            ctx.setFillColor(rgb(0.1, 0.13, 0.25))
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(tile)
            ctx.clip()
            ctx.drawLinearGradient(gradient([rgb(0.23, 0.33, 0.62), rgb(0.08, 0.1, 0.24)], [0, 1]),
                                   start: CGPoint(x: tileRect.minX, y: tileRect.maxY),
                                   end: CGPoint(x: tileRect.maxX, y: tileRect.minY), options: [])
            let glow = CGPoint(x: tileRect.midX + tileRect.width * 0.05, y: tileRect.midY + tileRect.height * 0.05)
            ctx.drawRadialGradient(gradient([rgb(0.45, 0.62, 1, 0.45), rgb(0.45, 0.62, 1, 0)], [0, 1]),
                                   startCenter: glow, startRadius: 0, endCenter: glow,
                                   endRadius: tileRect.width * 0.5, options: [])
            let stars: [(CGFloat, CGFloat, CGFloat)] = [(0.22, 0.78, 0.012), (0.34, 0.9, 0.007), (0.82, 0.3, 0.009),
                                                        (0.72, 0.86, 0.006), (0.15, 0.45, 0.007), (0.9, 0.62, 0.006)]
            ctx.setFillColor(rgb(1, 1, 1, 0.75))
            for (x, y, r) in stars {
                let c = CGPoint(x: tileRect.minX + tileRect.width * x, y: tileRect.minY + tileRect.height * y)
                let rr = tileRect.width * r
                ctx.fillEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            }

            // Rocket
            let art = tileRect.insetBy(dx: tileRect.width * 0.16, dy: tileRect.height * 0.16)
            func part(_ p: RocketGeometry.Part) -> CGPath { RocketGeometry.path(p, in: art, includeFlame: true) }
            let unit = RocketGeometry.scale(in: art, includeFlame: true)

            let flame = part(.flame)
            let fb = flame.boundingBoxOfPath
            ctx.saveGState()
            ctx.addPath(flame)
            ctx.clip()
            ctx.drawLinearGradient(gradient([rgb(1, 0.95, 0.55), rgb(1, 0.6, 0.15), rgb(0.95, 0.25, 0.2, 0)], [0, 0.45, 1]),
                                   start: CGPoint(x: fb.maxX, y: fb.maxY), end: CGPoint(x: fb.minX, y: fb.minY), options: [])
            ctx.restoreGState()

            ctx.addPath(part(.fins))
            ctx.setFillColor(rgb(0.45, 0.64, 1))
            ctx.fillPath()
            ctx.addPath(part(.nozzle))
            ctx.setFillColor(rgb(0.62, 0.67, 0.8))
            ctx.fillPath()

            let body = part(.body)
            let bb = body.boundingBoxOfPath
            ctx.saveGState()
            ctx.addPath(body)
            ctx.clip()
            ctx.drawLinearGradient(gradient([rgb(1, 1, 1), rgb(0.84, 0.88, 0.96)], [0.35, 1]),
                                   start: CGPoint(x: bb.minX, y: bb.maxY), end: CGPoint(x: bb.maxX, y: bb.minY), options: [])
            ctx.restoreGState()

            let win = part(.window).boundingBoxOfPath
            ctx.setFillColor(rgb(0.13, 0.2, 0.42))
            ctx.fillEllipse(in: win)
            ctx.setStrokeColor(rgb(0.45, 0.64, 1))
            ctx.setLineWidth(unit * 0.45)
            ctx.strokeEllipse(in: win)
            let hl = win.width * 0.22
            ctx.setFillColor(rgb(1, 1, 1, 0.85))
            ctx.fillEllipse(in: CGRect(x: win.midX - win.width * 0.2 - hl / 2, y: win.midY + win.height * 0.12 - hl / 2,
                                       width: hl, height: hl))
            return true
        }
    }
}
