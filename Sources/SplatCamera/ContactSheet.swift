import AppKit
import ImageIO
import CoreImage

/// The only place pictures are seen: each roll laid out on a light table in
/// strips of six (rebate, sprocket holes, edge print), looked at through a
/// loupe you slide over it. The loupe magnifies from the full-size frames.
/// Keepers get a red grease-pencil box (saved with the roll).
final class ContactSheetView: NSView {
    struct Roll {
        let number: Int
        let stock: String
        let dir: URL
        var frames: [URL]
        /// Which day and sitting it is from ("2026-10-17 · 09.14 Skate park"), if filed so.
        var session: String
    }

    var rolls: [Roll] = []
    var rollIndex = 0
    var selected = 0
    /// Frames shot on the current roll that are still in the darkroom.
    var pending: (roll: URL?, frames: [Int]) = (nil, [])

    // The loupe: where it sits (view points) and how much it magnifies.
    private(set) var loupeCentre: CGPoint?
    private(set) var loupePower: CGFloat = 4

    private var thumbs: [URL: NSImage] = [:]
    private var detail: [URL: NSImage] = [:]
    private var loading: Set<URL> = []
    private var marks: Set<Int> = []

    override var isFlipped: Bool { true }

    /// Where rolls are kept: chosen in File > Choose Where Rolls Are Kept
    /// (remembered), else ~/Pictures/Splat Camera. SPLAT_CAMERA_ROLLS overrides, for tests.
    static var root: URL {
        if let env = ProcessInfo.processInfo.environment["SPLAT_CAMERA_ROLLS"] { return URL(fileURLWithPath: env) }
        if let chosen = UserDefaults.standard.string(forKey: "rollsFolder") { return URL(fileURLWithPath: chosen) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Splat Camera")
    }

    /// Rolls on disk, oldest first: filed as date / session / roll
    /// ("2026-10-17/09.14 Skate park/Roll 01 - Portrait 400/frame-07.png"),
    /// plus older rolls kept straight in the folder.
    static func scanRolls() -> [Roll] {
        let fm = FileManager.default
        func children(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func roll(_ d: URL, session: String) -> Roll? {
            let name = d.lastPathComponent
            guard name.hasPrefix("Roll "), let n = Int(name.dropFirst(5).prefix(2)) else { return nil }
            let stock = name.components(separatedBy: " - ").dropFirst().joined(separator: " - ")
            let frames = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "png" && $0.lastPathComponent.hasPrefix("frame-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return Roll(number: n, stock: stock, dir: d, frames: frames, session: session)
        }
        var rolls: [Roll] = []
        for top in children(root) {
            if let r = roll(top, session: "") { rolls.append(r); continue }
            // A day, then its sittings, then their rolls.
            for sitting in children(top) {
                for d in children(sitting) {
                    if let r = roll(d, session: "\(top.lastPathComponent) · \(sitting.lastPathComponent)") { rolls.append(r) }
                }
            }
        }
        // Older loose rolls first, then by day and sitting (folder names sort in time).
        return rolls.sorted { ($0.session, $0.number) < ($1.session, $1.number) }
    }

    func reload(showRoll dir: URL?) {
        let keep = roll?.dir
        rolls = Self.scanRolls()
        if let d = (dir ?? keep)?.standardizedFileURL, let i = rolls.firstIndex(where: { $0.dir.standardizedFileURL == d }) {
            rollIndex = i
        } else {
            rollIndex = max(0, rolls.count - 1)
        }
        loadMarks()
        // Open on the newest frame, with the loupe over it.
        if dir != nil {
            selected = max(0, frameCount - 1)
            centreLoupeOnSelection()
        }
        needsDisplay = true
    }

    private func centreLoupeOnSelection() {
        let L = tableLayout()
        if selected < L.frames.count { loupeCentre = CGPoint(x: L.frames[selected].midX, y: L.frames[selected].midY) }
    }

    private var roll: Roll? { rolls.indices.contains(rollIndex) ? rolls[rollIndex] : nil }
    private var frameCount: Int { roll?.frames.count ?? 0 }

    func move(dx: Int, dy: Int) {
        selected = max(0, min(35, selected + dx + dy * 6))
        centreLoupeOnSelection()
        needsDisplay = true
    }

    func changeRoll(_ d: Int) {
        guard !rolls.isEmpty else { return }
        rollIndex = max(0, min(rolls.count - 1, rollIndex + d))
        selected = 0
        centreLoupeOnSelection()
        detail.removeAll()
        loadMarks()
        needsDisplay = true
    }

    /// The loupe under the mouse; the frame under it becomes the chosen one.
    func putLoupe(at p: CGPoint) {
        loupeCentre = p
        let L = tableLayout()
        if let i = L.frames.firstIndex(where: { $0.contains(p) }) { selected = i }
        needsDisplay = true
    }

    func turnLoupe(_ wheel: CGFloat) {
        loupePower = max(2, min(10, loupePower * exp(wheel * 0.05)))
        needsDisplay = true
    }

    /// Slides the loupe (velocity in view points per second) and turns its power.
    func handleLoupe(move v: CGVector, power: CGFloat, dt: CGFloat) {
        var c = loupeCentre ?? CGPoint(x: bounds.midX, y: bounds.midY)
        c.x = max(bounds.minX, min(bounds.maxX, c.x + v.dx * dt))
        c.y = max(bounds.minY, min(bounds.maxY, c.y + v.dy * dt))
        loupeCentre = c
        loupePower = max(2, min(10, loupePower * exp(power * dt)))
        needsDisplay = true
    }

    /// Red grease pencil round the chosen frame: a keeper (or not any more).
    func toggleMark() {
        guard roll != nil, selected < frameCount else { return }
        if marks.contains(selected) { marks.remove(selected) } else { marks.insert(selected) }
        saveMarks()
        needsDisplay = true
    }

    private var marksURL: URL? { roll?.dir.appendingPathComponent("marks.json") }

    private func loadMarks() {
        marks = []
        if let u = marksURL, let d = try? Data(contentsOf: u),
           let a = try? JSONDecoder().decode([Int].self, from: d) { marks = Set(a.map { $0 - 1 }) }
    }

    private func saveMarks() {
        guard let u = marksURL, let d = try? JSONEncoder().encode(marks.map { $0 + 1 }.sorted()) else { return }
        try? d.write(to: u)
    }

    // MARK: images

    private func image(_ url: URL, size: Int, cache: ReferenceWritableKeyPath<ContactSheetView, [URL: NSImage]>) -> NSImage? {
        if let t = self[keyPath: cache][url] { return t }
        let key = URL(fileURLWithPath: url.path + "#\(size)")
        if !loading.contains(key) {
            loading.insert(key)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: size,
                      ] as CFDictionary) else { return }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self[keyPath: cache].count > 6 && cache == \ContactSheetView.detail {
                        self.detail.removeAll()
                    }
                    self[keyPath: cache][url] = img
                    self.loading.remove(key)
                    self.needsDisplay = true
                }
            }
        }
        return nil
    }

    // MARK: drawing

    private struct Layout {
        var strips: [NSRect] = []
        var frames: [NSRect] = []
    }

    private func tableLayout() -> Layout {
        let b = bounds
        let areaH = b.height * 0.9, areaW = min(b.width * 0.9, areaH * 0.95)
        let x0 = b.midX - areaW / 2, y0 = b.height * 0.04
        let frameW = areaW / 6.25, frameH = frameW / 1.5
        let stripH = frameH * 35 / 24          // 35 mm film, 24 mm frames
        let gap = (areaH - stripH * 6) / 5
        var L = Layout()
        for strip in 0..<6 {
            let y = y0 + CGFloat(strip) * (stripH + gap)
            L.strips.append(NSRect(x: x0, y: y, width: areaW, height: stripH))
            for k in 0..<6 {
                let fx = x0 + frameW * 0.125 + CGFloat(k) * frameW * 1.02
                L.frames.append(NSRect(x: fx, y: y + (stripH - frameH) / 2, width: frameW * 0.98, height: frameH))
            }
        }
        return L
    }

    /// The strips on the glass. `fine`: under the loupe, from the full-size frames.
    private func drawStrips(_ L: Layout, roll: Roll, fine: Bool, near: CGPoint?) {
        let stockName = roll.stock.uppercased()
        let bw = filmStocks.first { roll.stock.hasPrefix($0.name) }?.blackAndWhite ?? false
        // Edge print is exposed into the film at the factory and developed with
        // it: on the print it glows out of the black rebate, warm through a
        // colour film's mask, grey on black-and-white.
        let edge = bw ? NSColor(white: 0.80, alpha: 0.85)
            : NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.30, alpha: 0.85)
        let pend = pending.roll?.standardizedFileURL == roll.dir.standardizedFileURL ? pending.frames : []
        // Real 35 mm in film millimetres: perforations 1.98 x 2.79 at 4.75 pitch,
        // 2 mm in from the edge; the frame from 5.5 to 29.5 across.
        let mm = L.frames[0].height / 24
        for (s, strip) in L.strips.enumerated() {
            // Laid down by hand: never quite square, never quite in line.
            var rng = Grit(seed: UInt64(roll.number * 131 + s * 17 + 5))
            NSGraphicsContext.saveGraphicsState()
            let lay = NSAffineTransform()
            lay.translateX(by: strip.midX + rng.signed() * 1.5, yBy: strip.midY + rng.signed() * 1.2)
            lay.rotate(byDegrees: rng.signed() * 0.35)
            lay.translateX(by: -strip.midX, yBy: -strip.midY)
            lay.concat()
            // The base, punched: the light table shows through the sprocket holes.
            let film = NSBezierPath(rect: strip)
            film.windingRule = .evenOdd
            var hx = strip.minX + 1.2 * mm
            while hx < strip.maxX - 2 * mm {
                for hy in [strip.minY + 2.0 * mm, strip.maxY - 4.8 * mm] {
                    film.append(NSBezierPath(roundedRect: NSRect(x: hx, y: hy, width: 1.98 * mm, height: 2.79 * mm),
                                             xRadius: 0.5 * mm, yRadius: 0.5 * mm))
                }
                hx += 4.75 * mm
            }
            NSColor(white: 0.05, alpha: 1).setFill()
            film.fill()
            // Outer margins (2 mm): the stock name along the top, frame numbers,
            // half-frame marks and a DX-style bar code along the bottom.
            let top = strip.minY + 0.35 * mm, bottom = strip.maxY - 1.75 * mm
            var nx = strip.minX + 3 * mm
            while nx < strip.maxX - 60 * mm {
                filmPrint("\(stockName)  SAFETY FILM", at: NSPoint(x: nx, y: top), mm: mm, color: edge)
                nx += 115 * mm
            }
            for k in 0..<6 {
                let i = s * 6 + k
                let fr = L.frames[i]
                filmPrint("\(i + 1)", at: NSPoint(x: fr.minX + 2 * mm, y: bottom), mm: mm, color: edge)
                filmPrint("▸ \(i + 1)A", at: NSPoint(x: fr.midX + 1 * mm, y: bottom), mm: mm, color: edge)
                if !bw {
                    // The bar code: thin and thick dashes, the same for the whole roll.
                    edge.withAlphaComponent(0.6).setFill()
                    var bx = fr.minX + 8 * mm
                    for b in 0..<12 {
                        let w = (stockName.unicodeScalars.reduce(b) { $0 &+ Int($1.value) } % 3 == 0 ? 0.7 : 0.35) * mm
                        NSRect(x: bx, y: bottom + 0.25 * mm, width: w, height: 1.1 * mm).fill()
                        bx += 0.9 * mm
                    }
                }
            }
            for k in 0..<6 {
                let i = s * 6 + k
                let fr = L.frames[i]
                guard i < roll.frames.count else {
                    if pend.contains(i + 1) {
                        label("in the darkroom", at: NSPoint(x: fr.minX + 4, y: fr.midY - 5), size: 1.6 * mm,
                              color: NSColor(white: 0.45, alpha: 1))
                    }
                    continue
                }
                let url = roll.frames[i]
                var img = image(url, size: 480, cache: \.thumbs)
                if fine, let c = near, fr.insetBy(dx: -fr.width, dy: -fr.height).contains(c) {
                    img = image(url, size: 2400, cache: \.detail) ?? img
                }
                img?.draw(in: fr, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            // Dust printed in with the pictures: white specks, now and then a hair.
            NSColor(white: 0.92, alpha: 0.7).setFill()
            for _ in 0..<(10 + rng.int(14)) {
                let p = NSPoint(x: strip.minX + rng.unit() * strip.width, y: strip.minY + rng.unit() * strip.height)
                let r = (0.08 + 0.25 * rng.unit() * rng.unit()) * mm
                NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r * (0.6 + 0.4 * rng.unit()), width: 2 * r, height: 1.6 * r)).fill()
            }
            if rng.unit() < 0.4 {
                hair(from: NSPoint(x: strip.minX + rng.unit() * strip.width, y: strip.minY + rng.unit() * strip.height),
                     length: (3 + 6 * rng.unit()) * mm, width: 0.07 * mm, color: NSColor(white: 0.9, alpha: 0.55), rng: &rng)
            }
            for k in 0..<6 where marks.contains(s * 6 + k) {
                greasePencil(around: L.frames[s * 6 + k], seed: UInt64(s * 6 + k), mm: mm)
            }
            if selected / 6 == s, selected < L.frames.count {
                let sel = NSBezierPath(rect: L.frames[selected].insetBy(dx: -2, dy: -2))
                sel.lineWidth = 1.5
                sel.setLineDash([6, 4], count: 2, phase: 0)
                NSColor(white: 0.1, alpha: 0.8).setStroke()
                sel.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A keeper, ringed in red china marker: wobbly, waxy, gone over twice.
    private func greasePencil(around fr: NSRect, seed: UInt64, mm: CGFloat) {
        var rng = Grit(seed: seed &* 7919 &+ 3)
        let box = fr.insetBy(dx: -1.6 * mm, dy: -1.6 * mm)
        for pass in 0..<2 {
            let path = NSBezierPath()
            let corners = [NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.minY),
                           NSPoint(x: box.maxX, y: box.maxY), NSPoint(x: box.minX, y: box.maxY)]
            func jitter(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x + rng.signed() * 1.2 * mm, y: p.y + rng.signed() * 1.2 * mm) }
            let start = jitter(corners[0])
            path.move(to: start)
            for k in 1...4 {
                let a = corners[(k - 1) % 4], b = corners[k % 4]
                let mid = NSPoint(x: (a.x + b.x) / 2 + rng.signed() * 0.8 * mm, y: (a.y + b.y) / 2 + rng.signed() * 0.8 * mm)
                path.curve(to: k == 4 ? NSPoint(x: start.x + 2 * mm, y: start.y + rng.signed() * mm) : jitter(b),
                           controlPoint1: mid, controlPoint2: mid)
            }
            path.lineWidth = (pass == 0 ? 0.9 : 0.6) * mm
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor(calibratedRed: 0.80, green: 0.08, blue: 0.07, alpha: pass == 0 ? 0.72 : 0.5).setStroke()
            path.stroke()
        }
    }

    private func hair(from p: NSPoint, length: CGFloat, width: CGFloat, color: NSColor, rng: inout Grit) {
        let path = NSBezierPath()
        path.move(to: p)
        let a = rng.unit() * 2 * .pi
        let end = NSPoint(x: p.x + cos(a) * length, y: p.y + sin(a) * length)
        path.curve(to: end, controlPoint1: NSPoint(x: p.x + rng.signed() * length, y: p.y + rng.signed() * length),
                   controlPoint2: NSPoint(x: end.x + rng.signed() * length * 0.6, y: end.y + rng.signed() * length * 0.6))
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        // The light table: tubes behind a worn diffuser, dust and lint on the glass.
        if let table = tableImage() { NSImage(cgImage: table, size: b.size).draw(in: b) }
        guard let roll else {
            label("No rolls developed yet.", at: NSPoint(x: b.midX - 110, y: b.midY), size: 18,
                  color: NSColor(white: 0.2, alpha: 1))
            return
        }
        let L = tableLayout()
        drawStrips(L, roll: roll, fine: false, near: nil)

        // The loupe: the table under it, magnified, from the full-size frames.
        let c = loupeCentre ?? CGPoint(x: b.midX, y: b.midY)
        let R = b.height * 0.2
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)).addClip()
        if let seen = loupeView(L, roll: roll, centre: c, radius: R) {
            NSImage(cgImage: seen, size: NSSize(width: 2 * R, height: 2 * R))
                .draw(in: NSRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        }
        // Specks on the loupe's own glass, and its flare off the rim.
        var lr = Grit(seed: 77)
        for _ in 0..<7 {
            let a = lr.unit() * 2 * .pi, d = R * (0.2 + 0.75 * lr.unit()), r = R * (0.006 + 0.012 * lr.unit())
            NSColor(white: 0.2, alpha: 0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x + cos(a) * d - r, y: c.y + sin(a) * d - r, width: 2 * r, height: 2 * r)).fill()
        }
        NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])?
            .draw(fromCenter: NSPoint(x: c.x - R * 0.45, y: c.y - R * 0.5), radius: 0,
                  toCenter: NSPoint(x: c.x - R * 0.45, y: c.y - R * 0.5), radius: R * 0.5, options: [])
        NSGraphicsContext.restoreGraphicsState()
        // Lens edge falloff and the black barrel.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)).addClip()
        NSGradient(colors: [NSColor(white: 0, alpha: 0), NSColor(white: 0, alpha: 0), NSColor(white: 0, alpha: 0.45)],
                   atLocations: [0, 0.8, 1], colorSpace: .deviceRGB)?
            .draw(fromCenter: c, radius: 0, toCenter: c, radius: R, options: [])
        NSGraphicsContext.restoreGraphicsState()
        let barrel = NSBezierPath(ovalIn: NSRect(x: c.x - R - 7, y: c.y - R - 7, width: 2 * R + 14, height: 2 * R + 14))
        barrel.lineWidth = 14
        NSColor(white: 0.08, alpha: 0.95).setStroke()
        barrel.stroke()
        let rim = NSBezierPath(ovalIn: NSRect(x: c.x - R - 14, y: c.y - R - 14, width: 2 * R + 28, height: 2 * R + 28))
        rim.lineWidth = 1.5
        NSColor(white: 0.55, alpha: 0.9).setStroke()
        rim.stroke()

        let where_ = roll.session.isEmpty ? "" : roll.session + " · "
        let hint = String(format: "%@Roll %d (%d of %d) · %@ · loupe %.0f×      sticks: loupe   L2/R2: power   d-pad: frame   A: mark   L1/R1: roll   B: back",
                          where_, roll.number, rollIndex + 1, rolls.count, roll.stock, loupePower)
        label(hint, at: NSPoint(x: b.midX - 330, y: b.height - 20), size: 11.5, color: NSColor(white: 0.15, alpha: 1))
    }

    /// Edge print: small, a little soft (a latent image, not ink), in the margin.
    private func filmPrint(_ s: String, at p: NSPoint, mm: CGFloat, color: NSColor) {
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.6)
        glow.shadowBlurRadius = 0.35 * mm
        glow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo-Bold", size: 1.45 * mm) ?? NSFont.monospacedSystemFont(ofSize: 1.45 * mm, weight: .bold),
            .foregroundColor: color,
            .shadow: glow,
            .kern: 0.12 * mm,
        ]
        NSAttributedString(string: s, attributes: attrs).draw(at: p)
    }

    // MARK: the table and the loupe, as things

    private var tableCache: (size: NSSize, image: CGImage)?

    /// The light table's glow: fluorescent tubes behind a diffuser (bands),
    /// warmer and cooler patches, darker corners, then dust, lint and fine
    /// scratches on the glass. Made once per size.
    private func tableImage() -> CGImage? {
        let size = bounds.size
        if let t = tableCache, t.size == size { return t.image }
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var rng = Grit(seed: 2024)
        // Low-frequency mottle from a coarse random grid, smoothly interpolated.
        let gw = 9, gh = 7
        let grid: [Float] = (0..<(gw * gh)).map { _ in Float(rng.signed()) }
        func mottle(_ x: Float, _ y: Float) -> Float {
            let fx = x * Float(gw - 1), fy = y * Float(gh - 1)
            let ix = min(gw - 2, Int(fx)), iy = min(gh - 2, Int(fy))
            let tx = fx - Float(ix), ty = fy - Float(iy)
            let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
            let a: Float = grid[iy * gw + ix], b: Float = grid[iy * gw + ix + 1]
            let c: Float = grid[(iy + 1) * gw + ix], d: Float = grid[(iy + 1) * gw + ix + 1]
            let top: Float = a + (b - a) * sx
            let low: Float = c + (d - c) * sx
            return top + (low - top) * sy
        }
        for y in 0..<h {
            let v = Float(y) / Float(h)
            for x in 0..<w {
                let u = Float(x) / Float(w)
                let dx = u - 0.5, dy = v - 0.5
                var lum: Float = 0.93
                lum += 0.035 * cos(u * 2 * .pi * 3.5 + 0.7)          // the tubes
                lum += 0.03 * mottle(u, v)
                lum *= 1 - 0.32 * (dx * dx + dy * dy) * 2
                lum += Float(Int(rng.next() % 1000)) / 1000 * 0.012 - 0.006
                let warm = 0.012 * mottle(1 - v, u)
                let i = (y * w + x) * 4
                px[i] = UInt8(max(0, min(255, (lum + warm) * 255)))
                px[i + 1] = UInt8(max(0, min(255, (lum + 0.004) * 255)))
                px[i + 2] = UInt8(max(0, min(255, (lum - warm + 0.03) * 255)))
            }
        }
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for _ in 0..<260 {
            let r = 0.4 + 1.6 * rng.unit() * rng.unit()
            NSColor(white: 0.25, alpha: 0.12 + 0.35 * rng.unit()).setFill()
            NSBezierPath(ovalIn: NSRect(x: rng.unit() * CGFloat(w), y: rng.unit() * CGFloat(h), width: 2 * r,
                                        height: 2 * r * (0.6 + 0.4 * rng.unit()))).fill()
        }
        for _ in 0..<7 {
            hair(from: NSPoint(x: rng.unit() * CGFloat(w), y: rng.unit() * CGFloat(h)), length: 10 + 30 * rng.unit(),
                 width: 0.6, color: NSColor(white: 0.3, alpha: 0.3), rng: &rng)
        }
        for _ in 0..<10 {
            let p = NSPoint(x: rng.unit() * CGFloat(w), y: rng.unit() * CGFloat(h))
            let a = rng.unit() * .pi, len = 40 + 200 * rng.unit()
            let path = NSBezierPath()
            path.move(to: p)
            path.line(to: NSPoint(x: p.x + cos(a) * len, y: p.y + sin(a) * len))
            path.lineWidth = 0.5
            NSColor(white: rng.unit() < 0.5 ? 1 : 0.4, alpha: 0.12).setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        tableCache = (size, img)
        return img
    }

    private lazy var ci = CIContext(options: [.cacheIntermediates: false])

    /// What the loupe sees: the table under it magnified, through a simple
    /// lens. Pincushion toward the rim, colour fringes growing outward, the
    /// edge going soft, the light falling off.
    private func loupeView(_ L: Layout, roll: Roll, centre c: CGPoint, radius R: CGFloat) -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let side = Int(2 * R * scale)
        guard side > 8, let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -(c.x - R), y: -(c.y - R))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let t = NSAffineTransform()
        t.translateX(by: c.x, yBy: c.y)
        t.scale(by: loupePower)
        t.translateX(by: -c.x, yBy: -c.y)
        t.concat()
        if let table = tableImage() { NSImage(cgImage: table, size: bounds.size).draw(in: bounds) }
        drawStrips(L, roll: roll, fine: true, near: c)
        NSGraphicsContext.restoreGraphicsState()
        guard let raw = ctx.makeImage() else { return nil }
        let img = CIImage(cgImage: raw)
        let mid = CIVector(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        let half = CGFloat(side) / 2
        // Pincushion: the rim magnified more than the middle.
        let bent = img.applyingFilter("CIBumpDistortion", parameters: [
            kCIInputCenterKey: mid, kCIInputRadiusKey: half * 1.15, kCIInputScaleKey: -0.14,
        ]).cropped(to: img.extent)
        // Lateral colour: red a touch bigger than green, blue a touch smaller.
        func channel(_ m: (CGFloat, CGFloat, CGFloat), _ k: CGFloat) -> CIImage {
            let only = bent.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m.0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: m.1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: m.2, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            let move = CGAffineTransform(translationX: half, y: half).scaledBy(x: k, y: k).translatedBy(x: -half, y: -half)
            return only.transformed(by: move).cropped(to: img.extent)
        }
        let fringed = channel((1, 0, 0), 1.010)
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: channel((0, 1, 0), 1)])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: channel((0, 0, 1), 0.990)])
        // Soft toward the rim (field curvature): sharp in the middle, smeared at the edge.
        let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": mid, "inputRadius0": half * 0.45, "inputRadius1": half,
            "inputColor0": CIColor.black, "inputColor1": CIColor.white,
        ])!.outputImage!.cropped(to: img.extent)
        let soft = fringed.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
            "inputMask": mask, kCIInputRadiusKey: 4.5 * scale,
        ]).cropped(to: img.extent)
        // The light falling off toward the edge.
        let dim = soft.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: mid, kCIInputRadiusKey: half * 1.05, kCIInputIntensityKey: 0.6, "inputFalloff": 0.4,
        ])
        return ci.createCGImage(dim, from: img.extent)
    }

    private func label(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(size, 7), weight: .semibold),
            .foregroundColor: color,
        ]
        NSAttributedString(string: s, attributes: attrs).draw(at: p)
    }
}

/// A small seeded random source, so the same roll lies the same way each time.
struct Grit {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func unit() -> CGFloat { CGFloat(next() % 1_000_000) / 1_000_000 }
    mutating func signed() -> CGFloat { unit() * 2 - 1 }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}
