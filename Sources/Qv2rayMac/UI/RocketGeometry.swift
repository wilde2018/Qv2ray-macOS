import CoreGraphics

/// The Qv2ray rocket, shared by the menu bar icon, the app icon and in-app artwork.
/// Designed upright in a y-up space (nose at +y), then tilted 45° so it reads as
/// "taking off", and fitted into the target rect.
enum RocketGeometry {
    enum Part { case body, fins, nozzle, window, flame }

    /// A part fitted into `rect`. `flipped` = y-down target (SwiftUI, flipped images).
    /// `includeFlame` reserves room for the exhaust so every part lines up whether or not it's drawn.
    static func path(_ part: Part, in rect: CGRect, flipped: Bool = false, includeFlame: Bool = false) -> CGPath {
        var t = transform(in: rect, flipped: flipped, includeFlame: includeFlame)
        return local(part).copy(using: &t) ?? CGMutablePath()
    }

    /// Design units → points, for line widths that scale with the artwork.
    static func scale(in rect: CGRect, includeFlame: Bool = false) -> CGFloat {
        let bb = rotatedBounds(includeFlame: includeFlame)
        return min(rect.width / bb.width, rect.height / bb.height)
    }

    private static let rotation = CGAffineTransform(rotationAngle: -.pi / 4)

    private static func rotatedBounds(includeFlame: Bool) -> CGRect {
        let all = CGMutablePath()
        for part in [Part.body, .fins, .nozzle] + (includeFlame ? [.flame] : []) { all.addPath(local(part)) }
        var r = rotation
        return (all.copy(using: &r) ?? all).boundingBoxOfPath
    }

    private static func transform(in rect: CGRect, flipped: Bool, includeFlame: Bool) -> CGAffineTransform {
        let bb = rotatedBounds(includeFlame: includeFlame)
        let s = min(rect.width / bb.width, rect.height / bb.height)
        return rotation
            .concatenating(CGAffineTransform(translationX: -bb.midX, y: -bb.midY))
            .concatenating(CGAffineTransform(scaleX: s, y: flipped ? -s : s))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
    }

    /// Upright design, roughly 12 × 17 units (21 with the flame).
    private static func local(_ part: Part) -> CGPath {
        let p = CGMutablePath()
        switch part {
        case .body:
            // Ogive nose, straight flanks, tapered tail.
            p.move(to: CGPoint(x: 0, y: 10))
            p.addCurve(to: CGPoint(x: 3.2, y: 1.8), control1: CGPoint(x: 2.2, y: 8.6), control2: CGPoint(x: 3.2, y: 5.2))
            p.addLine(to: CGPoint(x: 3.2, y: -4.2))
            p.addQuadCurve(to: CGPoint(x: 2.3, y: -5.6), control: CGPoint(x: 3.2, y: -5.2))
            p.addLine(to: CGPoint(x: -2.3, y: -5.6))
            p.addQuadCurve(to: CGPoint(x: -3.2, y: -4.2), control: CGPoint(x: -3.2, y: -5.2))
            p.addLine(to: CGPoint(x: -3.2, y: 1.8))
            p.addCurve(to: CGPoint(x: 0, y: 10), control1: CGPoint(x: -3.2, y: 5.2), control2: CGPoint(x: -2.2, y: 8.6))
            p.closeSubpath()
        case .fins:
            // Swept fins; their inner edge sits exactly on the body's flank.
            for side: CGFloat in [-1, 1] {
                p.move(to: CGPoint(x: 3.2 * side, y: -0.2))
                p.addQuadCurve(to: CGPoint(x: 6.0 * side, y: -3.9), control: CGPoint(x: 5.7 * side, y: -1.3))
                p.addLine(to: CGPoint(x: 6.0 * side, y: -6.5))
                p.addLine(to: CGPoint(x: 3.2 * side, y: -4.2))
                p.closeSubpath()
            }
        case .nozzle:
            p.move(to: CGPoint(x: -1.6, y: -5.6))
            p.addLine(to: CGPoint(x: -1.2, y: -7.0))
            p.addLine(to: CGPoint(x: 1.2, y: -7.0))
            p.addLine(to: CGPoint(x: 1.6, y: -5.6))
            p.closeSubpath()
        case .window:
            p.addEllipse(in: CGRect(x: -1.75, y: 1.65, width: 3.5, height: 3.5))
        case .flame:
            p.move(to: CGPoint(x: -1.0, y: -7.4))
            p.addQuadCurve(to: CGPoint(x: 0, y: -11.2), control: CGPoint(x: -1.2, y: -9.6))
            p.addQuadCurve(to: CGPoint(x: 1.0, y: -7.4), control: CGPoint(x: 1.2, y: -9.6))
            p.closeSubpath()
        }
        return p
    }
}
