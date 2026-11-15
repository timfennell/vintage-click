import AppKit

/// The darkroom's monitor: the frame of a take developed last, small in the
/// corner of the finder or the light table while the rest are developing. Shown
/// as a piece of the developed film: the frame in its black rebate, sprocket
/// holes above and below, the edge print glowing out of the margin, the ends of
/// the frames either side; under it a caption in the menus' warm, glowing type.
final class DarkroomMonitor: NSView {
    private var image: CGImage?
    private var caption = ""
    private var edgeText = ""
    private var frameNumber = 0
    private var blackAndWhite = false
    /// The frame before (it slides off to the left as the new one comes in).
    private var previous: CGImage?
    private var previousNumber = 0
    /// The film's advance: 0 just after a new frame arrives, 1 when it has come to rest.
    private var advance: CGFloat = 1
    private var advanceStart: CFTimeInterval = 0
    private var ticker: Timer?
    private static let advanceTime: CFTimeInterval = 0.45

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// `stock`/`take` go into the edge print; `frame` (from 1) is printed by the frame.
    func show(_ image: CGImage, caption: String, stock: String = "", take: Int = 0, frame: Int = 0, blackAndWhite: Bool = false) {
        // A new frame: the film pulls through one frame's length.
        if let old = self.image, frame != self.frameNumber, !isHidden {
            previous = old
            previousNumber = self.frameNumber
            advance = 0
            advanceStart = CACurrentMediaTime()
            if ticker == nil {
                let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(t, forMode: .common)
                ticker = t
            }
        }
        self.image = image
        self.caption = caption
        self.edgeText = stock.isEmpty ? "SAFETY FILM" : "\(stock.uppercased())   TAKE \(take)"
        self.frameNumber = frame
        self.blackAndWhite = blackAndWhite
        isHidden = false
        needsDisplay = true
    }

    func clear() {
        image = nil
        previous = nil
        frameNumber = 0
        stopTicker()
        advance = 1
        isHidden = true
    }

    private func tick() {
        let u = min(1, (CACurrentMediaTime() - advanceStart) / Self.advanceTime)
        // eased: drawn through quickly, coming to rest in the gate
        advance = CGFloat(1 - pow(1 - u, 3))
        needsDisplay = true
        if u >= 1 { stopTicker() }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private static let captionH: CGFloat = 26

    /// Sits in the upper right of `host`, a third of its width, shaped like the frame
    /// on its piece of film.
    func place(in host: NSView) {
        if superview !== host {
            removeFromSuperview()
            host.addSubview(self)
        }
        let aspect = image.map { CGFloat($0.height) / CGFloat(max(1, $0.width)) } ?? 2.0 / 3
        let w = (host.bounds.width * 0.3).rounded()
        let L = layout(width: w, aspect: aspect)
        let h = (L.film.height + Self.captionH).rounded()
        frame = NSRect(x: host.bounds.width - w - 24, y: host.isFlipped ? 24 : host.bounds.height - h - 24, width: w, height: h)
        autoresizingMask = host.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
    }

    /// Real 35 mm, scaled: the frame fills most of the width; the film is the frame's
    /// height plus the margins (perforations 1.98 x 2.79 mm at 4.75 mm pitch).
    private func layout(width w: CGFloat, aspect: CGFloat) -> (film: NSRect, pic: NSRect, mm: CGFloat) {
        let picW = w * 0.84
        let picH = picW * aspect
        let mm = picH / 24                      // the picture is 24 mm tall on the film
        let filmH = picH + 11 * mm               // 35 mm: 5.5 mm margins either side
        let film = NSRect(x: 0, y: 0, width: w, height: filmH)
        let pic = NSRect(x: (w - picW) / 2, y: 5.5 * mm, width: picW, height: picH)
        return (film, pic, mm)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let aspect = CGFloat(image.height) / CGFloat(max(1, image.width))
        let (film, pic, mm) = layout(width: bounds.width, aspect: aspect)
        let edge = blackAndWhite ? NSColor(white: 0.80, alpha: 0.85)
            : NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.30, alpha: 0.85)

        // How far the film still has to travel: a whole frame (and its frame line) at
        // first, nothing at rest. Everything on the film moves together.
        // A frame advances a whole number of perforations, so the holes don't jump.
        let pitch = 4.75 * mm
        let framePitch = ((pic.width + 0.8 * mm) / pitch).rounded(.up) * pitch
        let shift = (1 - advance) * framePitch
        ctx.saveGState()
        NSBezierPath(rect: film).addClip()

        // The base, punched: the finder shows through the sprocket holes.
        let base = NSBezierPath(rect: film)
        base.windingRule = .evenOdd
        var hx = film.midX - pitch * (film.width / pitch / 2).rounded(.down) - 0.99 * mm
        hx += shift.truncatingRemainder(dividingBy: pitch) - pitch
        while hx < film.maxX {
            for hy in [film.minY + 2.0 * mm, film.maxY - 4.79 * mm] {
                base.append(NSBezierPath(roundedRect: NSRect(x: hx, y: hy, width: 1.98 * mm, height: 2.79 * mm),
                                         xRadius: 0.5 * mm, yRadius: 0.5 * mm))
            }
            hx += pitch
        }
        NSColor(white: 0.05, alpha: 0.96).setFill()
        base.fill()

        // The frames: this one, the one before to its left (dimmed, as the frames
        // either side are), and the one still to come, dark, to its right.
        func drawFrame(_ img: CGImage?, at x: CGFloat, number: Int, dim: CGFloat) {
            let r = NSRect(x: x, y: pic.minY, width: pic.width, height: pic.height)
            guard r.maxX > film.minX, r.minX < film.maxX else { return }
            if let img {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: pic.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(img, in: NSRect(x: r.minX, y: 0, width: r.width, height: r.height))
                ctx.restoreGState()
                if dim > 0 {
                    NSColor(white: 0, alpha: dim).setFill()
                    r.fill(using: .sourceOver)
                }
            } else {
                NSColor(white: 0.13, alpha: 1).setFill()
                r.fill()
            }
            if number > 0 {
                let bottom = film.maxY - 1.6 * mm
                filmPrint("\(number)", at: NSPoint(x: r.minX + 2 * mm, y: bottom), mm: mm, color: edge)
                filmPrint("▸ \(number)A", at: NSPoint(x: r.midX + 1 * mm, y: bottom), mm: mm, color: edge)
            }
        }
        let x0 = pic.minX + shift
        drawFrame(previous, at: x0 - framePitch, number: previous == nil ? 0 : previousNumber, dim: 0.55 * advance)
        drawFrame(image, at: x0, number: frameNumber, dim: 0)
        drawFrame(nil, at: x0 + framePitch, number: 0, dim: 0)
        if previous == nil { drawFrame(nil, at: x0 - framePitch, number: 0, dim: 0) }

        // Edge print along the top (the outer 2 mm, outside the sprocket holes, as on
        // the contact sheet), exposed into the film: it travels with it.
        filmPrint(edgeText, at: NSPoint(x: x0 + 2 * mm, y: film.minY + 0.35 * mm), mm: mm, color: edge)
        filmPrint(edgeText, at: NSPoint(x: x0 - framePitch + 2 * mm, y: film.minY + 0.35 * mm), mm: mm, color: edge)
        ctx.restoreGState()

        // The caption: the menus' light type, warm cream with a soft glow.
        let cream = NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.80, alpha: 0.92)
        let glow = NSShadow()
        glow.shadowColor = cream.withAlphaComponent(0.5)
        glow.shadowBlurRadius = 4
        glow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [
            .font: MenuOverlay.glowFont(14),
            .foregroundColor: cream,
            .shadow: glow,
        ]
        let cw = (caption as NSString).size(withAttributes: attrs).width
        NSColor(white: 0.03, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: film.maxY + 3, width: cw + 16, height: Self.captionH - 5), xRadius: 4, yRadius: 4).fill()
        (caption as NSString).draw(at: NSPoint(x: 8, y: film.maxY + 5), withAttributes: attrs)
    }

    /// Edge print: small bold capitals exposed into the film, glowing out of the black.
    private func filmPrint(_ s: String, at p: NSPoint, mm: CGFloat, color: NSColor) {
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.6)
        glow.shadowBlurRadius = max(1, 0.35 * mm)
        glow.shadowOffset = .zero
        let size = 1.1 * mm
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo-Bold", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
            .shadow: glow,
            .kern: 0.12 * mm,
        ]
        NSAttributedString(string: s, attributes: attrs).draw(at: p)
    }
}
