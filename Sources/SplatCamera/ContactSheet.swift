import AppKit
import ImageIO
import CoreImage

/// The only place pictures are seen: a session's rolls laid out on a light
/// table, each cut into its own strips of six (rebate, sprocket holes, edge
/// print), looked at through a loupe you slide over it. The loupe magnifies from the full-size frames.
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
    /// The session on the table: all its rolls, each cut into strips of its own.
    var sessionIndex = 0
    /// The chosen frame: an index into the table's frames (session order).
    var selected = 0
    /// Frames shot on the current roll that are still in the darkroom.
    var pending: (roll: URL?, frames: [Int]) = (nil, [])

    // The loupe: where it sits (view points) and how much it magnifies.
    private(set) var loupeCentre: CGPoint?
    private(set) var loupePower: CGFloat = 4

    private var thumbs: [URL: NSImage] = [:]
    private var detail: [URL: NSImage] = [:]
    private var loading: Set<URL> = []
    /// Keepers, per roll (frame indices from 0).
    private var marks: [URL: Set<Int>] = [:]

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

    /// The sessions, oldest first: each its rolls' indices (loose old rolls are one session each).
    private var sessions: [[Int]] {
        var out: [[Int]] = []
        for (i, r) in rolls.enumerated() {
            if let last = out.last?.last, !r.session.isEmpty, rolls[last].session == r.session {
                out[out.count - 1].append(i)
            } else {
                out.append([i])
            }
        }
        return out
    }

    private var sessionRolls: [Int] { sessions.indices.contains(sessionIndex) ? sessions[sessionIndex] : [] }

    func reload(showRoll dir: URL?) {
        let keepSession = sessionRolls.first.map { rolls[$0].session }
        rolls = Self.scanRolls()
        let all = sessions
        if let d = dir?.standardizedFileURL, let r = rolls.firstIndex(where: { $0.dir.standardizedFileURL == d }),
           let si = all.firstIndex(where: { $0.contains(r) }) {
            sessionIndex = si
        } else if let k = keepSession, let si = all.firstIndex(where: { rolls[$0[0]].session == k }) {
            sessionIndex = si
        } else {
            sessionIndex = max(0, all.count - 1)
        }
        loadMarks()
        // Open on the newest frame of that roll, with the loupe over it.
        if let d = dir?.standardizedFileURL {
            let cells = tableLayout().cells
            if let i = cells.lastIndex(where: { rolls[$0.roll].dir.standardizedFileURL == d && $0.frame < rolls[$0.roll].frames.count }) {
                selected = i
            } else {
                selected = max(0, cells.count - 1)
            }
            centreLoupeOnSelection()
        }
        needsDisplay = true
    }

    private func centreLoupeOnSelection() {
        let cells = tableLayout().cells
        if cells.indices.contains(selected) { loupeCentre = CGPoint(x: cells[selected].rect.midX, y: cells[selected].rect.midY) }
    }

    /// Left and right along the strips; up and down to the frame nearest above or below.
    func move(dx: Int, dy: Int) {
        let cells = tableLayout().cells
        guard !cells.isEmpty else { return }
        selected = max(0, min(cells.count - 1, selected + dx))
        if dy != 0 {
            let here = cells[selected]
            let rows = Set(cells.map { $0.rect.midY }).sorted()
            if let r = rows.firstIndex(of: here.rect.midY), rows.indices.contains(r + dy) {
                let y = rows[r + dy]
                if let best = cells.indices.filter({ cells[$0].rect.midY == y })
                    .min(by: { abs(cells[$0].rect.midX - here.rect.midX) < abs(cells[$1].rect.midX - here.rect.midX) }) {
                    selected = best
                }
            }
        }
        centreLoupeOnSelection()
        needsDisplay = true
    }

    /// The next or previous session's rolls onto the table.
    func changeRoll(_ d: Int) {
        let n = sessions.count
        guard n > 0 else { return }
        sessionIndex = max(0, min(n - 1, sessionIndex + d))
        selected = 0
        detail.removeAll()
        loadMarks()
        centreLoupeOnSelection()
        needsDisplay = true
    }

    /// The loupe under the mouse; the frame under it becomes the chosen one.
    func putLoupe(at p: CGPoint) {
        loupeCentre = p
        if let i = tableLayout().cells.firstIndex(where: { $0.rect.contains(p) }) { selected = i }
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
        let cells = tableLayout().cells
        guard cells.indices.contains(selected) else { return }
        let c = cells[selected]
        let roll = rolls[c.roll]
        guard c.frame < roll.frames.count else { return }
        var m = marks[roll.dir] ?? []
        if m.contains(c.frame) { m.remove(c.frame) } else { m.insert(c.frame) }
        marks[roll.dir] = m
        if let d = try? JSONEncoder().encode(m.map { $0 + 1 }.sorted()) {
            try? d.write(to: roll.dir.appendingPathComponent("marks.json"))
        }
        needsDisplay = true
    }

    private func loadMarks() {
        marks = [:]
        for i in sessionRolls {
            let u = rolls[i].dir.appendingPathComponent("marks.json")
            if let d = try? Data(contentsOf: u), let a = try? JSONDecoder().decode([Int].self, from: d) {
                marks[rolls[i].dir] = Set(a.map { $0 - 1 })
            }
        }
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
        struct Strip {
            var rect: NSRect
            var roll: Int           // index into rolls
            var first: Int          // its first frame on the roll (0-based)
            var frames: [NSRect]
        }
        var strips: [Strip] = []
        var cells: [(rect: NSRect, roll: Int, frame: Int)] = []
        var mm: CGFloat = 1
    }

    /// How many frames a roll has to show: those developed, and any still in the darkroom.
    private func shown(_ r: Int) -> Int {
        let roll = rolls[r]
        let pend = pending.roll?.standardizedFileURL == roll.dir.standardizedFileURL ? (pending.frames.max() ?? 0) : 0
        return max(roll.frames.count, pend)
    }

    /// The session's rolls, each cut into strips of six as a lab would (the
    /// last cut short after the last frame shot), laid in rows, in columns if
    /// there are many, as large as the table allows.
    private func tableLayout() -> Layout {
        let b = bounds
        var cuts: [(roll: Int, first: Int, count: Int)] = []
        for r in sessionRolls {
            let n = shown(r)
            var f = 0
            while f < n {
                cuts.append((r, f, min(6, n - f)))
                f += 6
            }
        }
        var L = Layout()
        guard !cuts.isEmpty else { return L }
        let areaW = b.width * 0.92, areaH = b.height * 0.88
        // Film in millimetres: a strip 35 high, 38 per frame plus 6 of leader.
        func fit(_ cols: Int) -> CGFloat {
            let rows = Int((Double(cuts.count) / Double(cols)).rounded(.up))
            let byW = (areaW / CGFloat(cols) * 0.96) / (6 * 38 + 6)
            let byH = areaH / (CGFloat(rows) * 35 + CGFloat(rows - 1) * 6)
            return min(byW, byH)
        }
        let cols = (1...4).max { fit($0) < fit($1) } ?? 1
        let mm = fit(cols)
        let rows = Int((Double(cuts.count) / Double(cols)).rounded(.up))
        let colW = (6 * 38 + 6) * mm, gapX = (areaW - CGFloat(cols) * colW) / CGFloat(max(1, cols))
        let blockH = CGFloat(rows) * 35 * mm + CGFloat(rows - 1) * 6 * mm
        let x0 = b.midX - (CGFloat(cols) * colW + CGFloat(cols - 1) * gapX) / 2
        let y0 = max(b.height * 0.03, (b.height * 0.95 - blockH) / 2)
        L.mm = mm
        for (k, cut) in cuts.enumerated() {
            let col = k / rows, row = k % rows
            let x = x0 + CGFloat(col) * (colW + gapX), y = y0 + CGFloat(row) * 41 * mm
            let rect = NSRect(x: x, y: y, width: (CGFloat(cut.count) * 38 + 6) * mm, height: 35 * mm)
            var frames: [NSRect] = []
            for j in 0..<cut.count {
                let fr = NSRect(x: x + (4 + CGFloat(j) * 38) * mm, y: y + 5.5 * mm, width: 36 * mm, height: 24 * mm)
                frames.append(fr)
                L.cells.append((fr, cut.roll, cut.first + j))
            }
            L.strips.append(.init(rect: rect, roll: cut.roll, first: cut.first, frames: frames))
        }
        return L
    }

    /// The strips on the glass. `fine`: under the loupe, from the full-size frames.
    private func drawStrips(_ L: Layout, fine: Bool, near: CGPoint?) {
        // Real 35 mm in film millimetres: perforations 1.98 x 2.79 at 4.75 pitch,
        // 2 mm in from the edge; the frame from 5.5 to 29.5 across.
        let mm = L.mm
        var cell = 0
        for (s, cut) in L.strips.enumerated() {
            let roll = rolls[cut.roll]
            let strip = cut.rect
            let stockName = roll.stock.uppercased()
            let bw = filmStocks.first { roll.stock.hasPrefix($0.name) }?.blackAndWhite ?? false
            // Edge print is exposed into the film at the factory and developed with
            // it: on the print it glows out of the black rebate, warm through a
            // colour film's mask, grey on black-and-white.
            let edge = bw ? NSColor(white: 0.80, alpha: 0.85)
                : NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.30, alpha: 0.85)
            let pend = pending.roll?.standardizedFileURL == roll.dir.standardizedFileURL ? pending.frames : []
            // Laid down by hand: never quite square, never quite in line.
            var rng = Grit(seed: UInt64(roll.number * 131 + cut.first * 17 + s + 5))
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
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: strip).addClip()
            // Outer margins (2 mm): the stock name along the top, frame numbers,
            // half-frame marks and a DX-style bar code along the bottom.
            let top = strip.minY + 0.35 * mm, bottom = strip.maxY - 1.75 * mm
            var nx = strip.minX + 3 * mm
            repeat {
                filmPrint("\(stockName)  SAFETY FILM", at: NSPoint(x: nx, y: top), mm: mm, color: edge)
                nx += 115 * mm
            } while nx < strip.maxX - 50 * mm
            for (j, fr) in cut.frames.enumerated() {
                let n = cut.first + j + 1
                filmPrint("\(n)", at: NSPoint(x: fr.minX + 2 * mm, y: bottom), mm: mm, color: edge)
                filmPrint("▸ \(n)A", at: NSPoint(x: fr.midX + 1 * mm, y: bottom), mm: mm, color: edge)
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
            NSGraphicsContext.restoreGraphicsState()
            for (j, fr) in cut.frames.enumerated() {
                let i = cut.first + j
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
            for _ in 0..<(2 + rng.int(3) + cut.frames.count * 2) {
                let p = NSPoint(x: strip.minX + rng.unit() * strip.width, y: strip.minY + rng.unit() * strip.height)
                let r = (0.08 + 0.25 * rng.unit() * rng.unit()) * mm
                NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r * (0.6 + 0.4 * rng.unit()), width: 2 * r, height: 1.6 * r)).fill()
            }
            if rng.unit() < 0.4 {
                hair(from: NSPoint(x: strip.minX + rng.unit() * strip.width, y: strip.minY + rng.unit() * strip.height),
                     length: (3 + 6 * rng.unit()) * mm, width: 0.07 * mm, color: NSColor(white: 0.9, alpha: 0.55), rng: &rng)
            }
            let keep = marks[roll.dir] ?? []
            for (j, fr) in cut.frames.enumerated() {
                if keep.contains(cut.first + j) { greasePencil(around: fr, seed: UInt64(roll.number * 100 + cut.first + j), mm: mm) }
                if cell + j == selected {
                    let sel = NSBezierPath(rect: fr.insetBy(dx: -2, dy: -2))
                    sel.lineWidth = 1.5
                    sel.setLineDash([6, 4], count: 2, phase: 0)
                    NSColor(white: 0.1, alpha: 0.8).setStroke()
                    sel.stroke()
                }
            }
            cell += cut.frames.count
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
        let L = tableLayout()
        guard !L.strips.isEmpty else {
            label("No rolls developed yet.", at: NSPoint(x: b.midX - 110, y: b.midY), size: 18,
                  color: NSColor(white: 0.2, alpha: 1))
            return
        }
        drawStrips(L, fine: false, near: nil)

        // The loupe: the table under it, magnified, from the full-size frames.
        let c = loupeCentre ?? CGPoint(x: b.midX, y: b.midY)
        let R = b.height * 0.2
        loupeShadow(c, R)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)).addClip()
        if let seen = loupeView(L, centre: c, radius: R) {
            NSImage(cgImage: seen, size: NSSize(width: 2 * R, height: 2 * R))
                .draw(in: NSRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        }
        loupeReticle(c, R)
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
        loupeBody(c, R)

        // The session, how many films, and the chosen frame (the edge print names each film).
        let rollsHere = sessionRolls.map { rolls[$0] }
        let when = rollsHere.first?.session ?? ""
        var chosen = ""
        if L.cells.indices.contains(selected) {
            let c = L.cells[selected]
            chosen = " · roll \(rolls[c.roll].number) frame \(c.frame + 1)"
        }
        let hint = String(format: "%@%d %@ (session %d of %d)%@ · loupe %.0f×     sticks: loupe  L2/R2: power  d-pad: frame  A: mark  L1/R1: session  B: back",
                          when.isEmpty ? "" : when + " · ", rollsHere.count, rollsHere.count == 1 ? "roll" : "rolls",
                          sessionIndex + 1, sessions.count, chosen, loupePower)
        let hintW = NSAttributedString(string: hint, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)]).size().width
        label(hint, at: NSPoint(x: max(8, b.midX - hintW / 2), y: b.height - 20), size: 11.5, color: NSColor(white: 0.15, alpha: 1))
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

    private static let brass = NSColor(calibratedRed: 0.74, green: 0.56, blue: 0.26, alpha: 1)

    private func ringPath(_ c: CGPoint, _ r0: CGFloat, _ r1: CGFloat) -> NSBezierPath {
        let p = NSBezierPath(ovalIn: NSRect(x: c.x - r1, y: c.y - r1, width: 2 * r1, height: 2 * r1))
        p.append(NSBezierPath(ovalIn: NSRect(x: c.x - r0, y: c.y - r0, width: 2 * r0, height: 2 * r0)))
        p.windingRule = .evenOdd
        return p
    }

    /// The power, read inside the optic: a scale printed on the glass along the
    /// bottom, and a fine needle swinging up to it from below the field.
    private func loupeReticle(_ c: CGPoint, _ R: CGFloat) {
        let pivot = NSPoint(x: c.x, y: c.y + R * 1.02)
        let rr = R * 0.5
        func angle(_ p: CGFloat) -> CGFloat {
            let t = (log(p) - log(2)) / (log(10) - log(2))
            return -.pi / 2 - 0.62 + 1.24 * max(0, min(1, t))     // up, from left to right
        }
        let ink = NSColor(white: 0.06, alpha: 0.8)
        let halo = NSShadow()
        halo.shadowColor = NSColor(white: 1, alpha: 0.35)
        halo.shadowBlurRadius = 1.5
        halo.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        halo.set()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: pivot, radius: rr, startAngle: angle(2) * 180 / .pi, endAngle: angle(10) * 180 / .pi)
        arc.lineWidth = 1
        ink.setStroke()
        arc.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Futura-Medium", size: R * 0.045) ?? NSFont.systemFont(ofSize: R * 0.045),
            .foregroundColor: ink,
        ]
        for p in stride(from: 2.0, through: 10.0, by: 0.5) {
            let a = angle(CGFloat(p))
            let major = [2.0, 3, 4, 6, 8, 10].contains(p)
            let t = NSBezierPath()
            t.move(to: NSPoint(x: pivot.x + cos(a) * rr, y: pivot.y + sin(a) * rr))
            t.line(to: NSPoint(x: pivot.x + cos(a) * (rr + R * (major ? 0.04 : 0.022)), y: pivot.y + sin(a) * (rr + R * (major ? 0.04 : 0.022))))
            t.lineWidth = major ? 1.1 : 0.7
            t.stroke()
            if major {
                let str = NSAttributedString(string: p == 10 ? "10×" : "\(Int(p))", attributes: attrs)
                let sz = str.size()
                let q = NSPoint(x: pivot.x + cos(a) * (rr + R * 0.075), y: pivot.y + sin(a) * (rr + R * 0.075))
                str.draw(at: NSPoint(x: q.x - sz.width / 2, y: q.y - sz.height / 2))
            }
        }
        // The needle: fine, dark, from below the field to just past the scale.
        let a = angle(loupePower)
        let needle = NSBezierPath()
        needle.move(to: NSPoint(x: pivot.x + cos(a) * R * 0.2, y: pivot.y + sin(a) * R * 0.2))
        needle.line(to: NSPoint(x: pivot.x + cos(a) * (rr + R * 0.035), y: pivot.y + sin(a) * (rr + R * 0.035)))
        needle.lineWidth = 1.3
        NSColor(white: 0.02, alpha: 0.9).setStroke()
        needle.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The knob's place round the barrel for a power (radians, y down), the
    /// same sweep as the needle's.
    private static let tabRange: (CGFloat, CGFloat) = (.pi / 2 + 0.62, .pi / 2 - 0.62)
    private static func tabAngle(_ power: CGFloat) -> CGFloat {
        let t = (log(power) - log(2)) / (log(10) - log(2))
        return tabRange.0 + (tabRange.1 - tabRange.0) * max(0, min(1, t))
    }
    /// The zoom knob rides round the bottom of the barrel with the needle
    /// inside (geared to it): lower left at 2x, lower right at 10x.
    private var knobAngle: CGFloat { Self.tabAngle(loupePower) }

    /// The loupe stands on the table: its shadow, soft, down and to the right.
    private func loupeShadow(_ c: CGPoint, _ R: CGFloat) {
        let band = R * 0.16
        let sh = NSShadow()
        sh.shadowColor = NSColor(white: 0, alpha: 0.45)
        sh.shadowBlurRadius = R * 0.12
        sh.shadowOffset = NSSize(width: R * 0.05, height: R * 0.07)
        NSGraphicsContext.saveGraphicsState()
        sh.set()
        NSColor(white: 0.1, alpha: 1).setFill()
        ringPath(c, R, R + band).fill()
        let k = NSPoint(x: c.x + cos(knobAngle) * (R + band + R * 0.06), y: c.y + sin(knobAngle) * (R + band + R * 0.06))
        NSBezierPath(ovalIn: NSRect(x: k.x - R * 0.09, y: k.y - R * 0.09, width: R * 0.18, height: R * 0.18)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The loupe's barrel: black enamel over brass, rounded and lit from the
    /// upper left, worn through to the brass where hands hold it, chipped and
    /// scratched, knurled, engraved; and the zoom knob, which turns with the power.
    private func loupeBody(_ c: CGPoint, _ R: CGFloat) {
        let band = R * 0.16
        let ring = ringPath(c, R, R + band)
        var rng = Grit(seed: 1959)
        NSGraphicsContext.saveGraphicsState()
        ring.addClip()
        // Enamel: a rounded profile (dark at both edges, a sheen along the crown).
        NSGradient(colors: [NSColor(white: 0.03, alpha: 1), NSColor(white: 0.17, alpha: 1), NSColor(white: 0.06, alpha: 1),
                            NSColor(white: 0.02, alpha: 1)],
                   atLocations: [0, 0.45, 0.75, 1], colorSpace: .deviceRGB)?
            .draw(fromCenter: c, radius: R, toCenter: c, radius: R + band, options: [])
        // Light from the upper left.
        NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0), NSColor(white: 0, alpha: 0.25)])?
            .draw(in: NSRect(x: c.x - R - band, y: c.y - R - band, width: 2 * (R + band), height: 2 * (R + band)), angle: -50)
        // Knurling on the outer grip.
        for k in 0..<240 {
            let a = CGFloat(k) / 240 * 2 * .pi
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x + cos(a) * (R + band * 0.72), y: c.y + sin(a) * (R + band * 0.72)))
            p.line(to: NSPoint(x: c.x + cos(a) * (R + band), y: c.y + sin(a) * (R + band)))
            p.lineWidth = 0.8
            NSColor(white: k % 2 == 0 ? 0.0 : 0.3, alpha: 0.35).setStroke()
            p.stroke()
        }
        // Worn through to the brass: along the outer edge, most where it is handled.
        for _ in 0..<26 {
            let a = (rng.unit() < 0.6 ? -0.9 + rng.signed() * 0.9 : rng.unit() * 2 * .pi)
            let span = 0.03 + 0.16 * rng.unit()
            let r = R + band * (0.9 + 0.12 * rng.unit())
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r, startAngle: a * 180 / .pi, endAngle: (a + span) * 180 / .pi)
            p.lineWidth = band * (0.06 + 0.16 * rng.unit())
            p.lineCapStyle = .round
            Self.brass.withAlphaComponent(0.4 + 0.5 * rng.unit()).setStroke()
            p.stroke()
        }
        // Chips, and scratches across the crown.
        for _ in 0..<18 {
            let a = rng.unit() * 2 * .pi, d = R + band * rng.unit(), r = band * (0.03 + 0.07 * rng.unit())
            Self.brass.withAlphaComponent(0.4 + 0.4 * rng.unit()).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x + cos(a) * d - r, y: c.y + sin(a) * d - r * 0.7, width: 2 * r, height: 1.4 * r)).fill()
        }
        for _ in 0..<30 {
            let a = rng.unit() * 2 * .pi, d = R + band * (0.15 + 0.7 * rng.unit()), l = band * (0.3 + 1.2 * rng.unit())
            let t = a + .pi / 2 + rng.signed() * 0.6
            let p = NSBezierPath()
            let o = NSPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
            p.move(to: o)
            p.line(to: NSPoint(x: o.x + cos(t) * l, y: o.y + sin(t) * l))
            p.lineWidth = 0.5
            NSColor(white: rng.unit() < 0.7 ? 0.55 : 0.0, alpha: 0.35).setStroke()
            p.stroke()
        }
        // Engraved, the paint mostly worn out of the letters.
        let words = "OHI  LOUPE  4 – 10×  JAPAN"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Futura-Medium", size: band * 0.24) ?? NSFont.systemFont(ofSize: band * 0.24),
            .foregroundColor: NSColor(white: 0.85, alpha: 0.55),
        ]
        var a: CGFloat = -.pi / 2 - 0.42
        for ch in words {
            let str = NSAttributedString(string: String(ch), attributes: attrs)
            let w = str.size().width
            let r = R + band * 0.38
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: c.x + cos(a) * r, yBy: c.y + sin(a) * r)
            t.rotate(byRadians: a + .pi / 2)
            t.concat()
            str.draw(at: NSPoint(x: -w / 2, y: -str.size().height / 2))
            NSGraphicsContext.restoreGraphicsState()
            a += (w + band * 0.03) / r
        }
        // Gloss: the enamel mirrors the room. A soft window of light along the
        // crown at the upper left with a sharp core, a dimmer one opposite.
        func gleam(from a0: CGFloat, to a1: CGFloat, at r: CGFloat, width: CGFloat, alpha: CGFloat, blur: CGFloat) {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: r, startAngle: a0, endAngle: a1)
            arc.lineWidth = width
            arc.lineCapStyle = .round
            let glow = NSShadow()
            glow.shadowColor = NSColor(white: 1, alpha: alpha)
            glow.shadowBlurRadius = blur
            glow.shadowOffset = .zero
            NSGraphicsContext.saveGraphicsState()
            glow.set()
            NSColor(white: 1, alpha: alpha).setStroke()
            arc.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        gleam(from: 196, to: 252, at: R + band * 0.45, width: band * 0.16, alpha: 0.30, blur: band * 0.35)
        gleam(from: 205, to: 238, at: R + band * 0.42, width: band * 0.04, alpha: 0.85, blur: band * 0.06)
        gleam(from: 15, to: 60, at: R + band * 0.5, width: band * 0.1, alpha: 0.12, blur: band * 0.3)
        // Worn brass shines where it faces the light.
        var shine = Grit(seed: 1959)
        for _ in 0..<26 {
            let a = (shine.unit() < 0.6 ? -0.9 + shine.signed() * 0.9 : shine.unit() * 2 * .pi)
            let span = 0.03 + 0.16 * shine.unit()
            let r = R + band * (0.9 + 0.12 * shine.unit())
            _ = shine.unit(); _ = shine.unit()
            let facing = max(0, cos(a + span / 2 - (-2.3)))        // light from the upper left
            guard facing > 0.2 else { continue }
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r, startAngle: (a + span * 0.3) * 180 / .pi, endAngle: (a + span * 0.7) * 180 / .pi)
            p.lineWidth = band * 0.03
            NSColor(calibratedRed: 1, green: 0.93, blue: 0.7, alpha: 0.75 * facing).setStroke()
            p.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        // Bevels: the inner lip and the outer edge catch the light table's glow
        // from below (bright all round), the lip brightest toward the light.
        let lip = NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        lip.lineWidth = 2.2
        NSColor(white: 0.8, alpha: 0.45).setStroke()
        lip.stroke()
        let lipGleam = NSBezierPath()
        lipGleam.appendArc(withCenter: c, radius: R + 1, startAngle: 190, endAngle: 270)
        lipGleam.lineWidth = 1.6
        NSColor(white: 1, alpha: 0.8).setStroke()
        lipGleam.stroke()
        let outer = NSBezierPath(ovalIn: NSRect(x: c.x - R - band, y: c.y - R - band, width: 2 * (R + band), height: 2 * (R + band)))
        outer.lineWidth = 2
        NSColor(calibratedRed: 0.85, green: 0.88, blue: 0.95, alpha: 0.35).setStroke()
        outer.stroke()
        let outerDark = NSBezierPath(ovalIn: NSRect(x: c.x - R - band + 1.5, y: c.y - R - band + 1.5,
                                                    width: 2 * (R + band) - 3, height: 2 * (R + band) - 3))
        outerDark.lineWidth = 1
        NSColor(white: 0, alpha: 0.7).setStroke()
        outerDark.stroke()

        // The zoom knob: a knurled button on a short neck off the barrel.
        let dir = NSPoint(x: cos(knobAngle), y: sin(knobAngle))
        let k = NSPoint(x: c.x + dir.x * (R + band + R * 0.06), y: c.y + dir.y * (R + band + R * 0.06))
        let neck = NSBezierPath()
        neck.move(to: NSPoint(x: c.x + cos(knobAngle - 0.035) * (R + band * 0.9), y: c.y + sin(knobAngle - 0.035) * (R + band * 0.9)))
        neck.line(to: NSPoint(x: k.x - dir.y * R * 0.03, y: k.y + dir.x * R * 0.03))
        neck.line(to: NSPoint(x: k.x + dir.y * R * 0.03, y: k.y - dir.x * R * 0.03))
        neck.line(to: NSPoint(x: c.x + cos(knobAngle + 0.035) * (R + band * 0.9), y: c.y + sin(knobAngle + 0.035) * (R + band * 0.9)))
        neck.close()
        NSColor(white: 0.1, alpha: 1).setFill()
        neck.fill()
        // The button, seen from above: knurled rim, domed top, worn to brass at the edge.
        let kr = R * 0.085
        let rim = NSBezierPath(ovalIn: NSRect(x: k.x - kr, y: k.y - kr, width: 2 * kr, height: 2 * kr))
        NSGraphicsContext.saveGraphicsState()
        rim.addClip()
        NSGradient(colors: [NSColor(white: 0.26, alpha: 1), NSColor(white: 0.04, alpha: 1)])?
            .draw(fromCenter: NSPoint(x: k.x - kr * 0.3, y: k.y - kr * 0.3), radius: 0, toCenter: k, radius: kr, options: [])
        NSGraphicsContext.restoreGraphicsState()
        let phase = log(loupePower) * 3
        for j in 0..<36 {
            let a = CGFloat(j) / 36 * 2 * .pi + phase
            let p = NSBezierPath()
            p.move(to: NSPoint(x: k.x + cos(a) * kr * 0.78, y: k.y + sin(a) * kr * 0.78))
            p.line(to: NSPoint(x: k.x + cos(a) * kr, y: k.y + sin(a) * kr))
            p.lineWidth = 1.1
            NSColor(white: j % 2 == 0 ? 0 : 0.45, alpha: 0.75).setStroke()
            p.stroke()
        }
        rim.lineWidth = 1.2
        Self.brass.withAlphaComponent(0.6).setStroke()
        rim.stroke()
        let capR = kr * 0.55
        let cap = NSBezierPath(ovalIn: NSRect(x: k.x - capR, y: k.y - capR, width: 2 * capR, height: 2 * capR))
        NSGraphicsContext.saveGraphicsState()
        cap.addClip()
        NSGradient(colors: [NSColor(white: 0.35, alpha: 1), NSColor(white: 0.08, alpha: 1)])?
            .draw(fromCenter: NSPoint(x: k.x - capR * 0.35, y: k.y - capR * 0.35), radius: 0, toCenter: k, radius: capR, options: [])
        NSGraphicsContext.restoreGraphicsState()
        // The lock button in the middle, brass where the thumb wore it.
        let lb = capR * 0.45
        Self.brass.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: k.x - lb, y: k.y - lb, width: 2 * lb, height: 2 * lb)).fill()
        NSColor(white: 1, alpha: 0.6).setFill()
        NSBezierPath(ovalIn: NSRect(x: k.x - lb * 0.6, y: k.y - lb * 0.7, width: lb * 0.7, height: lb * 0.6)).fill()
        // A glint on the cap and along the arm, toward the light.
        let glint = NSBezierPath()
        glint.appendArc(withCenter: k, radius: capR * 0.8, startAngle: 200, endAngle: 250)
        glint.lineWidth = capR * 0.18
        glint.lineCapStyle = .round
        NSColor(white: 1, alpha: 0.55).setStroke()
        glint.stroke()
    }

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
    private func loupeView(_ L: Layout, centre c: CGPoint, radius R: CGFloat) -> CGImage? {
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
        drawStrips(L, fine: true, near: c)
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
        // The light falling off: smoothly from the middle (cos^4 of the angle
        // off axis), then faster in the last stretch where the barrel cuts in.
        let dim = soft.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: falloffMask(side)),
        ])
        return ci.createCGImage(dim, from: img.extent)
    }

    private var falloffCache: (side: Int, image: CGImage)?

    private func falloffMask(_ side: Int) -> CGImage {
        if let f = falloffCache, f.side == side { return f.image }
        var px = [UInt8](repeating: 255, count: side * side * 4)
        let h = Float(side) / 2
        for y in 0..<side {
            for x in 0..<side {
                let r = (((Float(x) + 0.5 - h) * (Float(x) + 0.5 - h) + (Float(y) + 0.5 - h) * (Float(y) + 0.5 - h)).squareRoot()) / h
                let t = 0.62 * r                              // tan of the angle off axis at that radius
                let c2 = 1 / (1 + t * t)
                var v = c2 * c2                               // cos^4
                let e = max(0, min(1, (r - 0.86) / 0.14))
                v *= 1 - 0.55 * e * e * (3 - 2 * e)            // the barrel's own shading at the rim
                let i = (y * side + x) * 4
                // A touch warm as it darkens, as old glass is.
                px[i] = UInt8(max(0, min(255, v * 255 + (1 - v) * 10)))
                px[i + 1] = UInt8(max(0, min(255, v * 255)))
                px[i + 2] = UInt8(max(0, min(255, v * 255 - (1 - v) * 14)))
            }
        }
        let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let img = ctx.makeImage()!
        falloffCache = (side, img)
        return img
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
