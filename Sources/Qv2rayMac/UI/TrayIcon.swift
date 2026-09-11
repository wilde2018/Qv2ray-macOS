import AppKit

/// Menu bar icon: the tilted rocket as a template outline (macOS tints it for light / dark
/// menu bars automatically).
///
/// Idle:    rocket outline + hollow cabin window (ring)
/// Running: rocket outline + solid cabin window (filled circle)
enum TrayIcon {

    static func image(connected: Bool) -> NSImage {
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            draw(in: rect, connected: connected)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Qv2ray"
        return img
    }

    private static func draw(in rect: CGRect, connected: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let art = rect.insetBy(dx: 1.2, dy: 1.2) // room for the stroke
        let black = NSColor.black.cgColor
        ctx.setStrokeColor(black)
        ctx.setFillColor(black)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        ctx.setLineWidth(1.25)
        for part in [RocketGeometry.Part.fins, .nozzle, .body] {
            ctx.addPath(RocketGeometry.path(part, in: art))
        }
        ctx.strokePath()

        let window = RocketGeometry.path(.window, in: art).boundingBoxOfPath
        if connected {
            ctx.fillEllipse(in: window.insetBy(dx: -0.4, dy: -0.4))
        } else {
            ctx.setLineWidth(1.1)
            ctx.strokeEllipse(in: window)
        }
    }
}
