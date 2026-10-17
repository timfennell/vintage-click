import AppKit

/// What the finder shows around the image, the way a late-70s SLR did:
/// a shutter-speed card on the left edge with a meter needle swinging in from
/// outside the frame (and a green tab at the speed you set: match them), and
/// red seven-segment LEDs on the black surround below for aperture, speed,
/// focus distance and the frame counter. AppKit, over the Metal view.
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
        var shutterIndex = 7           // the speed set, index into shutterSpeeds
        var mode = ""                  // DOF preview, lighting, developing...
        var stats = ""
        var mirrorUp = false
        var lines: [String] = []        // lighting plot, shown while placing lights
        /// Seen from a light: its beam's hot centre, edge and falloff, as radii
        /// in fractions of the image's width.
        var beam: (hot: CGFloat, edge: CGFloat, falloff: CGFloat)?
        var title = ""                  // big label: which light you are flying
    }
    var info = Info() { didSet { needsDisplay = true } }

    private var message: (text: String, until: Double)?
    /// The needle has mass: it swings toward the reading and settles.
    private var needle: CGFloat = 7
    private var needleSpeed: CGFloat = 0
    private var lastDraw = CACurrentMediaTime()

    /// A short message in the finder (end of roll, buffer full).
    func flash(_ text: String) {
        message = (text, CACurrentMediaTime() + 2)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private let ledRed = NSColor(calibratedRed: 1.0, green: 0.12, blue: 0.10, alpha: 1)
    private let dim = NSColor(white: 0.55, alpha: 1)

    /// The image's rectangle in this view (same fractions as the shader's inset).
    var imageRect: NSRect {
        let f = Viewer.finderImage
        return NSRect(x: bounds.width * f.x, y: bounds.height * f.y,
                      width: bounds.width * f.scale, height: bounds.height * f.scale)
    }

    private func text(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor,
                      align: NSTextAlignment = .left, width: CGFloat = 400, weight: NSFont.Weight = .medium) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
            .shadow: { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowColor = .black; return s }(),
        ]
        let x = align == .right ? p.x - width : (align == .center ? p.x - width / 2 : p.x)
        (s as NSString).draw(in: NSRect(x: x, y: p.y, width: width, height: size * 1.6), withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Mirror up: nothing reaches the finder, not even the readouts.
        if info.mirrorUp { return }
        let img = imageRect
        let u = img.height / 50

        if let beam = info.beam {
            drawBeam(beam, in: img, u: u)
        } else {
            drawMeter(img, u: u)
        }
        // The lighting plot, over the top of the image.
        for (k, line) in info.lines.enumerated() {
            text(line, at: NSPoint(x: img.minX + 3.5 * u, y: img.minY + 1.2 * u + CGFloat(k) * 1.4 * u), size: 0.95 * u,
                 color: k < info.lines.count - 3 ? NSColor(calibratedRed: 1, green: 0.72, blue: 0.25, alpha: 1)
                    : NSColor.white.withAlphaComponent(0.8), width: img.width * 0.92)
        }
        // On the black surround: what is mounted and loaded (dim), and speed stats.
        let top = img.minY - 1.6 * u
        text("\(info.lens)  ·  \(info.stock)", at: NSPoint(x: img.minX, y: max(2, top)), size: 0.8 * u, color: dim,
             width: img.width * 0.6)
        if !info.stats.isEmpty {
            text(info.stats, at: NSPoint(x: img.maxX, y: max(2, top)), size: 0.7 * u, color: dim.withAlphaComponent(0.6),
                 align: .right, width: img.width * 0.5)
        }
        drawLEDs(img, u: u)
    }

    // MARK: LEDs

    /// Seven-segment digits (and the few letters they can make), slanted, red, glowing.
    @discardableResult
    private func led(_ s: String, at origin: NSPoint, height h: CGFloat) -> CGFloat {
        let segs: [Character: String] = [
            "0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg", "5": "acdfg", "6": "acdefg",
            "7": "abc", "8": "abcdefg", "9": "abcdfg", "-": "g", "F": "aefg", "E": "adefg", "n": "ceg",
            "d": "bcdeg", "P": "abefg", "L": "def", "r": "eg", "o": "cdeg", "b": "cdefg", "S": "acdfg",
            "u": "cde", "H": "bcefg", "A": "abcefg", "t": "defg", "c": "deg",
        ]
        let w = h * 0.52, t = h * 0.11, slant = h * 0.12
        var x = origin.x
        let ctx = NSGraphicsContext.current?.cgContext
        for ch in s {
            if ch == "." {
                let d = NSRect(x: x - w * 0.12, y: origin.y + h - t * 1.1, width: t * 1.1, height: t * 1.1)
                ledFill(NSBezierPath(ovalIn: d), ctx)
                x += w * 0.25
                continue
            }
            if ch == " " { x += w * 0.7; continue }
            let on = segs[ch] ?? ""
            // Corners of the digit, slanted to the right going up.
            func pt(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint {
                NSPoint(x: x + fx * w + (1 - fy) * slant, y: origin.y + fy * h)
            }
            func seg(_ a: NSPoint, _ b: NSPoint) {
                let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 1e-3)
                let nx = -dy / len * t / 2, ny = dx / len * t / 2
                let ux = dx / len * t * 0.55, uy = dy / len * t * 0.55
                let p = NSBezierPath()
                p.move(to: NSPoint(x: a.x + ux, y: a.y + uy))
                p.line(to: NSPoint(x: a.x + ux * 1.6 + nx, y: a.y + uy * 1.6 + ny))
                p.line(to: NSPoint(x: b.x - ux * 1.6 + nx, y: b.y - uy * 1.6 + ny))
                p.line(to: NSPoint(x: b.x - ux, y: b.y - uy))
                p.line(to: NSPoint(x: b.x - ux * 1.6 - nx, y: b.y - uy * 1.6 - ny))
                p.line(to: NSPoint(x: a.x + ux * 1.6 - nx, y: a.y + uy * 1.6 - ny))
                p.close()
                ledFill(p, ctx)
            }
            for c in on {
                switch c {
                case "a": seg(pt(0, 0), pt(1, 0))
                case "b": seg(pt(1, 0), pt(1, 0.5))
                case "c": seg(pt(1, 0.5), pt(1, 1))
                case "d": seg(pt(0, 1), pt(1, 1))
                case "e": seg(pt(0, 0.5), pt(0, 1))
                case "f": seg(pt(0, 0), pt(0, 0.5))
                case "g": seg(pt(0, 0.5), pt(1, 0.5))
                default: break
                }
            }
            x += w * 1.45
        }
        return x
    }

    private func ledFill(_ p: NSBezierPath, _ ctx: CGContext?) {
        ctx?.saveGState()
        ctx?.setShadow(offset: .zero, blur: 6, color: ledRed.withAlphaComponent(0.8).cgColor)
        ledRed.setFill()
        p.fill()
        ctx?.restoreGState()
    }

    private func drawLEDs(_ img: NSRect, u: CGFloat) {
        let h = 2.0 * u
        let y = img.maxY + (bounds.maxY - img.maxY - h) * 0.4
        // Aperture, speed, distance across the middle; the counter to the right.
        let ax = led("F" + info.aperture, at: NSPoint(x: img.minX + img.width * 0.16, y: y), height: h)
        // Whole seconds carry a small "s" (2 s is not 1/2).
        let seconds = info.shutter.hasSuffix("\"")
        let sx = led(seconds ? String(info.shutter.dropLast()) : info.shutter,
                     at: NSPoint(x: max(ax + 3 * u, img.minX + img.width * 0.34), y: y), height: h)
        if seconds { text("s", at: NSPoint(x: sx + 0.1 * u, y: y + h * 0.1), size: h * 0.75, color: ledRed) }
        let fx = img.minX + img.width * 0.54
        if info.focus == "∞" {
            text("∞", at: NSPoint(x: fx, y: y - 0.45 * h), size: h * 1.3, color: ledRed)
        } else {
            let end = led(info.focus, at: NSPoint(x: fx, y: y), height: h)
            text("m", at: NSPoint(x: end + 0.2 * u, y: y + h * 0.1), size: h * 0.75, color: ledRed)
        }
        led(info.counter, at: NSPoint(x: img.minX + img.width * 0.80, y: y), height: h)
        // Small red notes under them: modes, messages, the film's speed.
        var notes: [String] = []
        if let m = message, CACurrentMediaTime() < m.until { notes.append(m.text) }
        if !info.mode.isEmpty { notes.append(info.mode) }
        notes.append(info.stock.contains(" at EI ") ? "EI \(info.iso) · " + (info.stock.contains("push") ? "PUSH" : "PULL") : "ISO \(info.iso)")
        text(notes.joined(separator: "   ·   "), at: NSPoint(x: img.midX, y: y + h * 1.3), size: 0.75 * u,
             color: ledRed.withAlphaComponent(0.85), align: .center, width: img.width)
    }

    // MARK: the meter

    /// The shutter-speed card on the left edge, the needle swinging in to the
    /// speed the meter wants, the green tab at the speed set.
    private func drawMeter(_ img: NSRect, u: CGFloat) {
        let speeds = shutterSpeeds
        let n = speeds.count
        let cardW = 3.6 * u, cardH = img.height * 0.66
        let card = NSRect(x: img.minX - cardW * 0.62, y: img.midY - cardH / 2, width: cardW, height: cardH)
        let cap = 2.0 * u
        let scaleTop = card.minY + cap, step = (cardH - 2 * cap) / CGFloat(n)
        // Fastest at the top. Position for a (fractional) speed index.
        func y(_ index: CGFloat) -> CGFloat { scaleTop + (CGFloat(n - 1) - index + 0.5) * step }

        // The card: cream, red caps, printed speeds (slow ones in red: hold steady).
        NSColor(calibratedRed: 0.93, green: 0.90, blue: 0.82, alpha: 1).setFill()
        NSBezierPath(roundedRect: card, xRadius: 0.5 * u, yRadius: 0.5 * u).fill()
        let red = NSColor(calibratedRed: 0.86, green: 0.27, blue: 0.18, alpha: 1)
        red.setFill()
        NSBezierPath(roundedRect: NSRect(x: card.minX, y: card.minY, width: cardW, height: cap), xRadius: 0.5 * u, yRadius: 0.5 * u).fill()
        NSBezierPath(roundedRect: NSRect(x: card.minX, y: card.maxY - cap, width: cardW, height: cap), xRadius: 0.5 * u, yRadius: 0.5 * u).fill()
        let capAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 1.1 * u, weight: .bold),
                                                       .foregroundColor: NSColor.white]
        let m = NSAttributedString(string: "M", attributes: capAttrs)
        m.draw(at: NSPoint(x: card.midX - m.size().width / 2, y: card.maxY - cap + (cap - m.size().height) / 2))
        for (i, s) in speeds.enumerated() {
            let slow = s.seconds >= 1.0 / 30
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: min(step * 0.6, cardW * 0.3), weight: .medium),
                .foregroundColor: slow ? red : NSColor(white: 0.12, alpha: 1),
            ]
            let str = NSAttributedString(string: s.label, attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: card.maxX - sz.width - 0.35 * u, y: y(CGFloat(i)) - sz.height / 2))
        }
        // The green tab: the speed you set.
        let set = CGFloat(info.shutterIndex)
        NSColor(calibratedRed: 0.15, green: 0.62, blue: 0.48, alpha: 0.95).setFill()
        let tab = NSBezierPath()
        let ty = y(set)
        tab.move(to: NSPoint(x: card.maxX - 0.2 * u, y: ty - 0.45 * step))
        tab.line(to: NSPoint(x: card.maxX + 1.4 * u, y: ty - 0.25 * step))
        tab.line(to: NSPoint(x: card.maxX + 1.4 * u, y: ty + 0.25 * step))
        tab.line(to: NSPoint(x: card.maxX - 0.2 * u, y: ty + 0.45 * step))
        tab.close()
        tab.fill()

        // The needle: the speed the meter wants at this aperture (+ over = faster).
        // It has mass, and swings past the ends of the card when far off.
        let want = max(-1.5, min(CGFloat(n) + 0.5, set + CGFloat(info.meterStops)))
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, now - lastDraw))
        lastDraw = now
        let k: CGFloat = 60, damp: CGFloat = 11
        needleSpeed += (k * (want - needle) - damp * needleSpeed) * dt
        needle += needleSpeed * dt
        let pivot = NSPoint(x: card.minX - 9 * u, y: card.midY)
        let tip = NSPoint(x: card.maxX + 2.2 * u, y: y(needle))
        let path = NSBezierPath()
        path.move(to: pivot)
        path.line(to: tip)
        path.lineWidth = max(1.6, 0.26 * u)
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        NSColor(white: 0.04, alpha: 0.95).setStroke()
        path.stroke()
        ctx?.restoreGState()
        // Keep animating while it is still swinging.
        if abs(needleSpeed) > 0.01 || abs(want - needle) > 0.01 {
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        }
    }

    // MARK: flying a light

    private func drawBeam(_ beam: (hot: CGFloat, edge: CGFloat, falloff: CGFloat), in img: NSRect, u: CGFloat) {
        let amber = NSColor(calibratedRed: 1, green: 0.72, blue: 0.25, alpha: 1)
        let c = NSPoint(x: img.midX, y: img.midY)
        for (r, alpha, dash) in [(beam.hot, 0.5, false), (beam.edge, 0.9, false), (beam.falloff, 0.6, true)] {
            let rad = r * img.width
            let path = NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad))
            path.lineWidth = 1.5
            if dash { path.setLineDash([8, 6], count: 2, phase: 0) }
            amber.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: c.x - 10, y: c.y)); cross.line(to: NSPoint(x: c.x + 10, y: c.y))
        cross.move(to: NSPoint(x: c.x, y: c.y - 10)); cross.line(to: NSPoint(x: c.x, y: c.y + 10))
        cross.stroke()
        text(info.title, at: NSPoint(x: img.midX, y: img.maxY - 4 * u), size: 1.5 * u, color: amber,
             align: .center, width: img.width)
    }
}
