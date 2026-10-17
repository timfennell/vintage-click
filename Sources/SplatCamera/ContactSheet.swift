import AppKit
import ImageIO

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
    }

    var rolls: [Roll] = []
    var rollIndex = 0
    var selected = 0
    /// Frames shot on the current roll that are still in the darkroom.
    var pending: (roll: Int, frames: [Int]) = (0, [])

    // The loupe: where it sits (view points) and how much it magnifies.
    private(set) var loupeCentre: CGPoint?
    private(set) var loupePower: CGFloat = 4

    private var thumbs: [URL: NSImage] = [:]
    private var detail: [URL: NSImage] = [:]
    private var loading: Set<URL> = []
    private var marks: Set<Int> = []

    override var isFlipped: Bool { true }

    /// Where rolls are kept (SPLAT_CAMERA_ROLLS overrides, for tests).
    static let root = ProcessInfo.processInfo.environment["SPLAT_CAMERA_ROLLS"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Splat Camera")

    /// Rolls on disk, oldest first ("Roll 03 - Portrait 400/frame-07.png").
    static func scanRolls() -> [Roll] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var rolls: [Roll] = []
        for d in dirs {
            let name = d.lastPathComponent
            guard name.hasPrefix("Roll "), let n = Int(name.dropFirst(5).prefix(2)) else { continue }
            let stock = name.components(separatedBy: " - ").dropFirst().joined(separator: " - ")
            let frames = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "png" && $0.lastPathComponent.hasPrefix("frame-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            rolls.append(Roll(number: n, stock: stock, dir: d, frames: frames))
        }
        return rolls.sorted { $0.number < $1.number }
    }

    func reload(showRoll number: Int?) {
        let keep = roll?.number
        rolls = Self.scanRolls()
        if let n = number ?? keep, let i = rolls.firstIndex(where: { $0.number == n }) {
            rollIndex = i
        } else {
            rollIndex = max(0, rolls.count - 1)
        }
        loadMarks()
        // Open on the newest frame, with the loupe over it.
        if number != nil {
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
        var hole: CGFloat = 0
    }

    private func tableLayout() -> Layout {
        let b = bounds
        let areaH = b.height * 0.9, areaW = min(b.width * 0.9, areaH * 0.95)
        let x0 = b.midX - areaW / 2, y0 = b.height * 0.04
        let frameW = areaW / 6.25, frameH = frameW / 1.5
        let stripH = frameH * 1.55
        let gap = (areaH - stripH * 6) / 5
        var L = Layout()
        L.hole = stripH * 0.06
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
        let edge = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.2, alpha: 0.9)
        let stockName = roll.stock.uppercased()
        let pend = pending.roll == roll.number ? pending.frames : []
        for (s, strip) in L.strips.enumerated() {
            NSColor(white: 0.05, alpha: 1).setFill()
            strip.fill()
            // Sprocket holes: the light table shows through them.
            NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1).setFill()
            let hole = L.hole
            var hx = strip.minX + hole
            while hx < strip.maxX - hole {
                for hy in [strip.minY + hole * 0.6, strip.maxY - hole * 2] {
                    NSBezierPath(roundedRect: NSRect(x: hx, y: hy, width: hole * 1.1, height: hole * 1.4),
                                 xRadius: hole * 0.2, yRadius: hole * 0.2).fill()
                }
                hx += hole * 2.6
            }
            let frameTop = L.frames[s * 6].minY
            label("\(stockName)   SAFETY FILM", at: NSPoint(x: strip.minX + L.frames[0].width * 0.6, y: frameTop - hole * 2.1),
                  size: hole * 1.2, color: edge)
            for k in 0..<6 {
                let i = s * 6 + k
                let fr = L.frames[i]
                label("\(i + 1)", at: NSPoint(x: fr.minX + fr.width * 0.45, y: fr.maxY + hole * 0.15),
                      size: hole * 1.2, color: edge)
                guard i < roll.frames.count else {
                    if pend.contains(i + 1) {
                        label("in the darkroom", at: NSPoint(x: fr.minX + 4, y: fr.midY - 5), size: hole * 1.1,
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
        }
        for i in marks where i < L.frames.count {
            let box = NSBezierPath(roundedRect: L.frames[i].insetBy(dx: -4, dy: -4), xRadius: 6, yRadius: 6)
            box.lineWidth = 3.5
            NSColor(calibratedRed: 0.85, green: 0.08, blue: 0.06, alpha: 0.85).setStroke()
            box.stroke()
        }
        if selected < L.frames.count {
            let sel = NSBezierPath(rect: L.frames[selected].insetBy(dx: -2, dy: -2))
            sel.lineWidth = 1.5
            sel.setLineDash([6, 4], count: 2, phase: 0)
            NSColor(white: 0.1, alpha: 0.8).setStroke()
            sel.stroke()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        // The light table: an even cool glow, a little darker at the edges.
        NSGradient(colors: [NSColor(calibratedRed: 0.95, green: 0.97, blue: 1.0, alpha: 1),
                            NSColor(calibratedRed: 0.80, green: 0.83, blue: 0.88, alpha: 1)])?
            .draw(in: NSBezierPath(rect: b), relativeCenterPosition: .zero)
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
        NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.0, alpha: 1).setFill()
        b.fill()
        let t = NSAffineTransform()
        t.translateX(by: c.x, yBy: c.y)
        t.scale(by: loupePower)
        t.translateX(by: -c.x, yBy: -c.y)
        t.concat()
        drawStrips(L, roll: roll, fine: true, near: c)
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

        let hint = String(format: "Roll %d of %d · %@ · loupe %.0f×      sticks: loupe   L2/R2: power   d-pad: frame   A: mark   L1/R1: roll   B: back",
                          roll.number, rolls.count, roll.stock, loupePower)
        label(hint, at: NSPoint(x: b.midX - 330, y: b.height - 20), size: 11.5, color: NSColor(white: 0.15, alpha: 1))
    }

    private func label(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(size, 7), weight: .semibold),
            .foregroundColor: color,
        ]
        NSAttributedString(string: s, attributes: attrs).draw(at: p)
    }
}
