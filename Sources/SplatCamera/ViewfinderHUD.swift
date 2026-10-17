import AppKit

/// What the finder shows around the image, the way a late-70s SLR did:
/// a shutter-speed card on the left edge with a meter needle swinging in from
/// outside the frame (and a green tab at the speed you set: match them), and
/// red seven-segment LEDs on the black surround below for aperture, speed,
/// focus distance and the frame counter. AppKit, over the Metal view.
final class ViewfinderHUD: NSView {
    /// Setting the scale: points as fractions of the image (0...1), what to say.
    struct Measure {
        var crosshair = true
        var a: CGPoint?
        var b: CGPoint?
        var label = ""
        var prompt = ""
        var entry: String?
    }
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
        var measure: Measure?
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

    /// `projected`: light in the finder (as framelines are), soft and glowing, not ink.
    private func text(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor,
                      align: NSTextAlignment = .left, width: CGFloat = 400, weight: NSFont.Weight = .medium,
                      projected: Bool = true) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        let shadow = NSShadow()
        if projected {
            shadow.shadowBlurRadius = size * 0.45
            shadow.shadowColor = color.withAlphaComponent(0.55)
            shadow.shadowOffset = .zero
        } else {
            shadow.shadowBlurRadius = 3
            shadow.shadowColor = .black
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: projected ? (NSFont(name: "Futura-Medium", size: size) ?? NSFont.systemFont(ofSize: size))
                : NSFont.monospacedSystemFont(ofSize: size, weight: weight),
            .foregroundColor: projected ? color.withAlphaComponent(0.85) : color,
            .paragraphStyle: style,
            .shadow: shadow,
        ]
        let x = align == .right ? p.x - width : (align == .center ? p.x - width / 2 : p.x)
        (s as NSString).draw(in: NSRect(x: x, y: p.y, width: width, height: size * 1.6), withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Mirror up: nothing reaches the finder, not even the readouts.
        if info.mirrorUp { meterShape = nil; return }
        let img = imageRect
        let u = img.height / 50

        if let beam = info.beam {
            meterShape = nil
            drawBeam(beam, in: img, u: u)
        } else {
            drawMeter(img, u: u)
        }
        // The lighting plot, over the top of the image.
        for (k, line) in info.lines.enumerated() {
            // Projected in the finder too: the lights warm, the help a paler cream.
            text(line, at: NSPoint(x: img.minX + 3.5 * u, y: img.minY + 1.2 * u + CGFloat(k) * 1.4 * u), size: 0.95 * u,
                 color: k < info.lines.count - 3 ? NSColor(calibratedRed: 1, green: 0.82, blue: 0.55, alpha: 1)
                    : NSColor(calibratedRed: 1, green: 0.93, blue: 0.84, alpha: 0.85), width: img.width * 0.92,
                 projected: true)
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
        if let m = info.measure { drawMeasure(m, in: img, u: u) }
    }

    // MARK: setting the scale

    private func drawMeasure(_ m: Measure, in img: NSRect, u: CGFloat) {
        let yellow = NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: 1)
        func at(_ p: CGPoint) -> NSPoint { NSPoint(x: img.minX + p.x * img.width, y: img.minY + p.y * img.height) }
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.setShadow(offset: .zero, blur: 3, color: NSColor.black.cgColor)
        yellow.setStroke()
        yellow.setFill()
        if m.crosshair {
            let c = NSPoint(x: img.midX, y: img.midY)
            let x = NSBezierPath()
            x.lineWidth = 1.5
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] as [(CGFloat, CGFloat)] {
                x.move(to: NSPoint(x: c.x + dx * 0.6 * u, y: c.y + dy * 0.6 * u))
                x.line(to: NSPoint(x: c.x + dx * 2.2 * u, y: c.y + dy * 2.2 * u))
            }
            x.stroke()
        }
        if let a = m.a {
            let pa = at(a)
            NSBezierPath(ovalIn: NSRect(x: pa.x - 0.45 * u, y: pa.y - 0.45 * u, width: 0.9 * u, height: 0.9 * u)).fill()
            if let b = m.b {
                let pb = at(b)
                let line = NSBezierPath()
                line.lineWidth = 2
                line.move(to: pa)
                line.line(to: pb)
                line.stroke()
                NSBezierPath(ovalIn: NSRect(x: pb.x - 0.45 * u, y: pb.y - 0.45 * u, width: 0.9 * u, height: 0.9 * u)).fill()
                text(m.label, at: NSPoint(x: (pa.x + pb.x) / 2 + u, y: (pa.y + pb.y) / 2 - 2 * u), size: 1.2 * u,
                     color: yellow, width: 20 * u)
            }
        }
        ctx?.restoreGState()
        if let entry = m.entry {
            let w = 34 * u, h = 7 * u
            let r = NSRect(x: img.midX - w / 2, y: img.maxY - h - 3 * u, width: w, height: h)
            NSColor(white: 0.06, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: r, xRadius: 0.8 * u, yRadius: 0.8 * u).fill()
            text("really:", at: NSPoint(x: r.minX + 1.5 * u, y: r.minY + 2.2 * u), size: 1.2 * u, color: NSColor(white: 0.7, alpha: 1))
            text(entry + "▏", at: NSPoint(x: r.minX + 9 * u, y: r.minY + 1.6 * u), size: 2.2 * u, color: yellow, width: w)
        }
        text(m.prompt, at: NSPoint(x: img.midX, y: img.maxY - 2.2 * u), size: 0.95 * u, color: yellow,
             align: .center, width: img.width)
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

    /// Where the meter is, for the finder's shader to show it through the
    /// eyepiece: its scale as soft projected light, the needle a dark wire in
    /// front with a faint shadow. In this view's points.
    struct MeterShape: Equatable {
        var card: NSRect            // the printed plate
        var pivot: NSPoint          // the needle's pivot (off the plate, outside the frame)
        var tip: NSPoint
        var u: CGFloat
        var shutterIndex: Int
        var bounds: NSSize
        /// The plate's texture covers the card and the set-speed tab beside it.
        var plateRect: NSRect { NSRect(x: card.minX, y: card.minY, width: card.width + 2 * u, height: card.height) }
    }
    private(set) var meterShape: MeterShape?

    private static func meterLayout(_ img: NSRect, u: CGFloat) -> NSRect {
        let cardW = 3.6 * u, cardH = img.height * 0.66
        // Inside the frame, just in from its left edge (the needle swings in from outside).
        return NSRect(x: img.minX + 1.0 * u, y: img.midY - cardH / 2, width: cardW, height: cardH)
    }

    /// Fastest at the top: the height of a (fractional) speed index on the card.
    private static func speedY(_ index: CGFloat, card: NSRect, u: CGFloat) -> CGFloat {
        let n = shutterSpeeds.count
        let cap = 2.0 * u
        let step = (card.height - 2 * cap) / CGFloat(n)
        return card.minY + cap + (CGFloat(n - 1) - index + 0.5) * step
    }

    /// The needle swings (it has mass) to the speed the meter wants at this
    /// aperture; the finder's shader draws it and the plate.
    private func drawMeter(_ img: NSRect, u: CGFloat) {
        let n = shutterSpeeds.count
        let card = Self.meterLayout(img, u: u)
        let set = CGFloat(info.shutterIndex)
        let want = max(-1.5, min(CGFloat(n) + 0.5, set + CGFloat(info.meterStops)))
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, now - lastDraw))
        lastDraw = now
        let k: CGFloat = 60, damp: CGFloat = 11
        needleSpeed += (k * (want - needle) - damp * needleSpeed) * dt
        needle += needleSpeed * dt
        // The needle aims through the reading's tick (ticks point at the pivot).
        let pivot = NSPoint(x: card.minX - 9 * u, y: card.midY)
        let aim = NSPoint(x: card.minX + 0.1 * u, y: Self.speedY(needle, card: card, u: u))
        // The tip ends just past the ticks, short of the numbers.
        let reach = (card.minX + 1.15 * u - pivot.x) / (aim.x - pivot.x)
        meterShape = MeterShape(card: card, pivot: pivot,
                                tip: NSPoint(x: pivot.x + (aim.x - pivot.x) * reach, y: pivot.y + (aim.y - pivot.y) * reach),
                                u: u, shutterIndex: info.shutterIndex, bounds: bounds.size)
        // Keep animating while it is still swinging.
        if abs(needleSpeed) > 0.01 || abs(want - needle) > 0.01 {
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        }
    }

    /// The scale as projected light (as framelines are in a finder): rgb the
    /// light's colour, alpha how much. A faint bar, speeds and ticks in warm
    /// cream, slow speeds and the ends in red, the set speed's tab in green.
    /// Drawn in this view's points into the current (flipped) context.
    static func drawPlate(_ m: MeterShape) {
        let card = m.card, u = m.u
        let cap = 2.0 * u
        let cream = NSColor(calibratedRed: 1.0, green: 0.90, blue: 0.78, alpha: 1)
        let red = NSColor(calibratedRed: 1.0, green: 0.40, blue: 0.28, alpha: 1)
        let bar = NSBezierPath(roundedRect: card, xRadius: 0.5 * u, yRadius: 0.5 * u)
        cream.withAlphaComponent(0.16).setFill()
        bar.fill()
        red.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: NSRect(x: card.minX, y: card.minY, width: card.width, height: cap * 0.8),
                     xRadius: 0.4 * u, yRadius: 0.4 * u).fill()
        NSBezierPath(roundedRect: NSRect(x: card.minX, y: card.maxY - cap * 0.8, width: card.width, height: cap * 0.8),
                     xRadius: 0.4 * u, yRadius: 0.4 * u).fill()
        let mAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 1.0 * u, weight: .semibold),
                                                     .foregroundColor: NSColor(white: 0.0, alpha: 0.55)]
        let mark = NSAttributedString(string: "M", attributes: mAttrs)
        mark.draw(at: NSPoint(x: card.midX - mark.size().width / 2, y: card.maxY - cap * 0.8 + (cap * 0.8 - mark.size().height) / 2))
        let step = (card.height - 2 * cap) / CGFloat(shutterSpeeds.count)
        for (i, sp) in shutterSpeeds.enumerated() {
            let slow = sp.seconds >= 1.0 / 30
            let y = speedY(CGFloat(i), card: card, u: u)
            let size = min(step * 0.58, card.width * 0.25)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Futura-Medium", size: size) ?? NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: slow ? red : cream,
            ]
            let str = NSAttributedString(string: sp.label, attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: card.maxX - sz.width - 0.35 * u, y: y - sz.height / 2))
            // A tick at each speed, along the needle's line when it points there.
            let p0 = NSPoint(x: card.minX + 0.1 * u, y: y)
            let dx = p0.x - m.pivot.x, dy = p0.y - m.pivot.y
            let len = (dx * dx + dy * dy).squareRoot()
            let tick = NSBezierPath()
            tick.move(to: p0)
            tick.line(to: NSPoint(x: p0.x + dx / len * 0.9 * u, y: p0.y + dy / len * 0.9 * u))
            tick.lineWidth = 0.13 * u
            (slow ? red : cream).withAlphaComponent(0.85).setStroke()
            tick.stroke()
        }
        // The green tab: the speed you set.
        NSColor(calibratedRed: 0.45, green: 0.95, blue: 0.70, alpha: 0.9).setFill()
        let tab = NSBezierPath()
        let ty = speedY(CGFloat(m.shutterIndex), card: card, u: u)
        tab.move(to: NSPoint(x: card.maxX - 0.2 * u, y: ty - 0.45 * step))
        tab.line(to: NSPoint(x: card.maxX + 1.4 * u, y: ty - 0.25 * step))
        tab.line(to: NSPoint(x: card.maxX + 1.4 * u, y: ty + 0.25 * step))
        tab.line(to: NSPoint(x: card.maxX - 0.2 * u, y: ty + 0.45 * step))
        tab.close()
        tab.fill()
    }

    // MARK: flying a light

    private func drawBeam(_ beam: (hot: CGFloat, edge: CGFloat, falloff: CGFloat), in img: NSRect, u: CGFloat) {
        // Projected light, as the wireframes are: warm cream, soft, glowing.
        let cream = NSColor(calibratedRed: 1.0, green: 0.90, blue: 0.76, alpha: 1)
        let c = NSPoint(x: img.midX, y: img.midY)
        let glow = NSShadow()
        glow.shadowColor = cream.withAlphaComponent(0.6)
        glow.shadowBlurRadius = 0.5 * u
        glow.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        glow.set()
        for (r, alpha, dash) in [(beam.hot, 0.45, false), (beam.edge, 0.75, false), (beam.falloff, 0.5, true)] {
            let rad = r * img.width
            let path = NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad))
            path.lineWidth = 0.22 * u
            path.lineCapStyle = .round
            if dash { path.setLineDash([1.2 * u, 0.9 * u], count: 2, phase: 0) }
            cream.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: c.x - 0.6 * u, y: c.y)); cross.line(to: NSPoint(x: c.x + 0.6 * u, y: c.y))
        cross.move(to: NSPoint(x: c.x, y: c.y - 0.6 * u)); cross.line(to: NSPoint(x: c.x, y: c.y + 0.6 * u))
        cross.lineWidth = 0.18 * u
        cream.withAlphaComponent(0.7).setStroke()
        cross.stroke()
        NSGraphicsContext.restoreGraphicsState()
        text(info.title, at: NSPoint(x: img.midX, y: img.maxY - 4 * u), size: 1.5 * u, color: cream,
             align: .center, width: img.width, projected: true)
    }
}
