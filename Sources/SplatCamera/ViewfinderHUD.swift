import AppKit

/// What the finder shows around the image: a match-needle meter on the right,
/// aperture / shutter / film along the bottom, and the counter. Drawn by
/// AppKit over the Metal view (text is not worth a Metal font atlas yet).
final class ViewfinderHUD: NSView {
    struct Info {
        var lens = ""
        var aperture = ""
        var shutter = ""
        var stock = ""
        var iso = 0
        var counter = ""
        var focus = ""
        var meterStops: Float = 0      // + over, - under
        var mode = ""                  // DOF preview, exposing, etc.
        var stats = ""
        var mirrorUp = false
        var lines: [String] = []        // lighting plot, shown while placing lights
    }
    var info = Info() { didSet { needsDisplay = true } }

    private var message: (text: String, until: Double)?

    /// A short message in the finder (end of roll, buffer full).
    func flash(_ text: String) {
        message = (text, CACurrentMediaTime() + 2)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private let led = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.25, alpha: 0.95)

    private func text(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor,
                      align: NSTextAlignment = .left, width: CGFloat = 400) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: style,
            .shadow: { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowColor = .black; return s }(),
        ]
        let x = align == .right ? p.x - width : (align == .center ? p.x - width / 2 : p.x)
        (s as NSString).draw(in: NSRect(x: x, y: p.y, width: width, height: size * 1.6),
                             withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let u = b.height / 60   // layout unit
        // Mirror up: nothing reaches the finder, not even the readouts.
        if info.mirrorUp { return }
        let now = CACurrentMediaTime()
        if let m = message, now < m.until {
            text(m.text, at: NSPoint(x: b.midX, y: b.midY + 9 * u), size: 1.4 * u, color: led,
                 align: .center, width: b.width)
        }
        // Bottom strip: like the LED / window readouts of a 70s SLR.
        let y = b.maxY - 3.2 * u
        text("f/\(info.aperture)", at: NSPoint(x: 2 * u, y: y), size: 1.6 * u, color: led)
        text(info.shutter, at: NSPoint(x: 12 * u, y: y), size: 1.6 * u, color: led)
        text("ISO \(info.iso)", at: NSPoint(x: 22 * u, y: y), size: 1.3 * u, color: led)
        text(info.focus, at: NSPoint(x: b.midX, y: y), size: 1.3 * u, color: led,
             align: .center, width: 20 * u)
        text(info.counter, at: NSPoint(x: b.maxX - 6 * u, y: y), size: 1.3 * u, color: led,
             align: .right, width: 40 * u)
        // Top: lens and stock, and anything the camera is busy doing.
        text("\(info.lens)  ·  \(info.stock)", at: NSPoint(x: 2 * u, y: 1.2 * u), size: 1.1 * u,
             color: NSColor.white.withAlphaComponent(0.75), width: b.width * 0.6)
        if !info.mode.isEmpty {
            text(info.mode, at: NSPoint(x: b.maxX - 2 * u, y: 1.2 * u), size: 1.1 * u,
                 color: led, align: .right, width: b.width * 0.4)
        }
        if !info.stats.isEmpty {
            text(info.stats, at: NSPoint(x: 2 * u, y: 3.0 * u), size: 0.85 * u,
                 color: NSColor.white.withAlphaComponent(0.5), width: b.width * 0.8)
        }
        for (k, line) in info.lines.enumerated() {
            text(line, at: NSPoint(x: 2 * u, y: 5 * u + CGFloat(k) * 1.5 * u), size: 1.0 * u,
                 color: k < info.lines.count - 3 ? led : NSColor.white.withAlphaComponent(0.8),
                 width: b.width * 0.9)
        }
        drawMeter(in: NSRect(x: b.maxX - 4.5 * u, y: b.midY - 14 * u, width: 2.5 * u, height: 28 * u), u: u)
    }

    /// Match-needle meter: + at the top, - at the bottom, centred is correct.
    private func drawMeter(in r: NSRect, u: CGFloat) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: -0.4 * u, dy: -1.6 * u), xRadius: 0.5 * u, yRadius: 0.5 * u).fill()
        let white = NSColor.white.withAlphaComponent(0.85)
        white.setStroke()
        let line = NSBezierPath()
        line.lineWidth = max(1, 0.12 * u)
        for s in -2...2 {
            let yy = r.midY - CGFloat(s) / 2.5 * r.height / 2
            line.move(to: NSPoint(x: r.minX + (s == 0 ? 0.2 * u : 0.8 * u), y: yy))
            line.line(to: NSPoint(x: r.maxX - 0.2 * u, y: yy))
        }
        line.stroke()
        text("+", at: NSPoint(x: r.midX, y: r.minY - 1.6 * u), size: 1.1 * u, color: white, align: .center, width: 3 * u)
        text("–", at: NSPoint(x: r.midX, y: r.maxY), size: 1.1 * u, color: white, align: .center, width: 3 * u)
        let s = CGFloat(max(-2.6, min(2.6, info.meterStops)))
        let yy = r.midY - s / 2.5 * r.height / 2
        let needle = NSBezierPath()
        needle.lineWidth = max(1.5, 0.22 * u)
        needle.move(to: NSPoint(x: r.minX - 0.3 * u, y: yy))
        needle.line(to: NSPoint(x: r.maxX + 0.1 * u, y: yy))
        (abs(info.meterStops) < 0.34 ? NSColor.systemGreen : led).setStroke()
        needle.stroke()
    }
}
