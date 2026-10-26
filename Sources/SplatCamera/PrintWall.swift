import AppKit
import ImageIO

/// The print wall: the enlarged prints of a session pinned to a white
/// gallery wall under track lights, to walk along and look at closely. A view
/// over the game (like the light table); the viewer passes it the pad and keys.
final class PrintWallView: NSView {
    struct Print { let url: URL; let caption: String; var aspect: CGFloat }

    private(set) var sessions: [(name: String, prints: [Print])] = []
    private(set) var sessionIndex = 0
    private var prints: [Print] { sessions.indices.contains(sessionIndex) ? sessions[sessionIndex].prints : [] }
    var selected = 0

    // The view onto the wall: its centre in wall metres, and pixels per metre (eased toward targets).
    private var centre = CGPoint.zero, zoom: CGFloat = 400
    private var targetCentre = CGPoint.zero, targetZoom: CGFloat = 400
    private var closeUp = false

    // Prints at several sizes, loaded as the zoom asks for them.
    private var images: [String: CGImage] = [:]
    private var loading: Set<String> = []
    private let queue = DispatchQueue(label: "print-wall", qos: .userInitiated, attributes: .concurrent)

    override var isFlipped: Bool { true }

    // MARK: layout (wall metres)

    static let printWidth: CGFloat = 0.40          // the image
    static let border: CGFloat = 0.075            // the mat round it
    static let gap: CGFloat = 0.16                // between prints
    private var columns: Int { max(1, min(8, prints.count, Int(ceil(sqrt(Double(prints.count) * 1.6))))) }

    private func frame(of i: Int) -> CGRect {
        let c = i % columns, r = i / columns
        let w = Self.printWidth + 2 * Self.border
        let h = Self.printWidth / 1.5 + 2 * Self.border
        return CGRect(x: CGFloat(c) * (w + Self.gap), y: CGFloat(r) * (h + Self.gap * 1.3), width: w, height: h)
    }
    private var wallBounds: CGRect {
        prints.indices.reduce(CGRect.null) { $0.union(frame(of: $1)) }.insetBy(dx: -0.3, dy: -0.35)
    }

    // MARK: loading

    /// Every session's enlarged prints (proofs stay on the light table); opens on `name`'s.
    func reload(session name: String?) {
        var out: [(String, [Print])] = []
        for r in ContactSheetView.scanRolls() {
            for f in r.frames {
                guard Self.isPrint(f) else { continue }
                let caption = Self.caption(f, roll: r)
                if let last = out.last, last.0 == r.session { out[out.count - 1].1.append(Print(url: f, caption: caption, aspect: 1.5)) }
                else { out.append((r.session, [Print(url: f, caption: caption, aspect: 1.5)])) }
            }
        }
        sessions = out.map { (name: $0.0, prints: $0.1) }
        if let name, let i = sessions.firstIndex(where: { $0.name == name }) { sessionIndex = i }
        else { sessionIndex = max(0, sessions.count - 1) }
        selected = 0
        frameWall(animated: false)
        needsDisplay = true
    }

    /// Only frames the enlarger has printed: a shot record beside them and no longer a proof.
    static func isPrint(_ f: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: ShotRecord.url(for: f).path) else { return false }
        let j = f.deletingPathExtension().appendingPathExtension("json")
        guard let d = try? Data(contentsOf: j), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (o["proof"] as? Bool) == false
    }

    private static func caption(_ f: URL, roll: ContactSheetView.Roll) -> String {
        let j = f.deletingPathExtension().appendingPathExtension("json")
        let n = f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "frame-", with: "")
        var s = "Roll \(roll.number) · \(n)"
        if let d = try? Data(contentsOf: j), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let lens = o["lens"] as? String { s += " · " + lens }
            if let a = o["aperture"] as? Double, let t = o["shutter"] as? String { s += String(format: " · f/%.1f %@", a, t) }
            if let film = o["film"] as? String { s += " · " + film }
        }
        return s
    }

    /// The print at a size fit for this many pixels across (512, 2048 or full), loaded in the background.
    private func image(_ p: Print, pixels: CGFloat) -> CGImage? {
        let levels: [Int] = [512, 2048, 0]
        let want = levels.first { $0 == 0 || CGFloat($0) >= pixels * 1.2 } ?? 0
        let key = "\(p.url.path)#\(want)"
        if let im = images[key] { return im }
        if !loading.contains(key) {
            loading.insert(key)
            queue.async { [weak self] in
                guard let src = CGImageSourceCreateWithURL(p.url as CFURL, nil) else { return }
                let im: CGImage?
                if want == 0 { im = CGImageSourceCreateImageAtIndex(src, 0, nil) }
                else {
                    im = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: want] as CFDictionary)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loading.remove(key)
                    if let im { self.images[key] = im; self.needsDisplay = true }
                }
            }
        }
        // Meanwhile any smaller one already here.
        for l in levels.reversed() where l != want {
            if let im = images["\(p.url.path)#\(l)"], l != 0 && (want == 0 || l < want) { return im }
        }
        return nil
    }

    // MARK: moving about

    /// The whole wall in view.
    func frameWall(animated: Bool) {
        let b = wallBounds
        targetCentre = CGPoint(x: b.midX, y: b.midY)
        targetZoom = min(bounds.width / max(b.width, 0.1), bounds.height * 0.9 / max(b.height, 0.1))
        closeUp = false
        if !animated { centre = targetCentre; zoom = targetZoom }
    }

    /// Up to one print, filling most of the view.
    private func frameSelected() {
        guard prints.indices.contains(selected) else { return }
        let f = frame(of: selected)
        targetCentre = CGPoint(x: f.midX, y: f.midY)
        targetZoom = min(bounds.width / (f.width * 1.15), bounds.height / (f.height * 1.25))
        closeUp = true
    }

    func update(move: CGVector, zoomBy z: CGFloat, dt: CGFloat) {
        // The sticks walk along the wall (faster when stood back), the triggers step in and out.
        let speed = 0.9 * bounds.width / max(targetZoom, 1)
        targetCentre.x += move.dx * speed * dt
        targetCentre.y += move.dy * speed * dt
        if z != 0 { targetZoom = max(60, min(40000, targetZoom * exp(z * dt * 1.6))) }
        let b = wallBounds
        targetCentre.x = max(b.minX, min(b.maxX, targetCentre.x))
        targetCentre.y = max(b.minY, min(b.maxY, targetCentre.y))
        let ease = 1 - exp(-dt / 0.12)
        let before = (centre, zoom)
        centre.x += (targetCentre.x - centre.x) * ease
        centre.y += (targetCentre.y - centre.y) * ease
        zoom *= pow(targetZoom / zoom, ease)
        if abs(before.0.x - centre.x) + abs(before.0.y - centre.y) > 1e-5 || abs(before.1 - zoom) > 1e-3 { needsDisplay = true }
    }

    func wheel(_ d: CGFloat, at p: CGPoint?) {
        let old = targetZoom
        targetZoom = max(60, min(40000, targetZoom * exp(d * 0.12)))
        // Toward the pointer, as a magnifier would.
        if let p {
            let w = toWall(p)
            targetCentre.x = w.x + (targetCentre.x - w.x) * old / targetZoom
            targetCentre.y = w.y + (targetCentre.y - w.y) * old / targetZoom
        }
    }

    func step(dx: Int, dy: Int) {
        guard !prints.isEmpty else { return }
        selected = max(0, min(prints.count - 1, selected + dx + dy * columns))
        frameSelected()
        needsDisplay = true
    }

    /// A: look closely at the chosen print; again to stand back.
    func toggleCloseUp() {
        if closeUp { frameWall(animated: true) } else { frameSelected() }
    }

    func changeSession(_ d: Int) {
        guard !sessions.isEmpty else { return }
        sessionIndex = max(0, min(sessions.count - 1, sessionIndex + d))
        selected = 0
        images.removeAll()
        frameWall(animated: false)
        needsDisplay = true
    }

    private func toView(_ w: CGPoint) -> CGPoint {
        CGPoint(x: (w.x - centre.x) * zoom + bounds.midX, y: (w.y - centre.y) * zoom + bounds.midY)
    }
    private func toWall(_ v: CGPoint) -> CGPoint {
        CGPoint(x: (v.x - bounds.midX) / zoom + centre.x, y: (v.y - bounds.midY) / zoom + centre.y)
    }
    private func viewRect(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * zoom, height: r.height * zoom)
    }

    // MARK: drawing

    // MARK: surfaces

    /// A small repeatable random stream (each print's own flaws stay put).
    struct Rand {
        var s: UInt64
        init(seed: UInt64) { s = seed | 1 }
        mutating func next() -> CGFloat {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return CGFloat(s % 1_000_000) / 1_000_000
        }
    }
    static func seed(_ u: URL) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for c in u.path.utf8 { h = (h ^ UInt64(c)) &* 1099511628211 }
        return h
    }

    /// Tiles of texture, made once: the wall's paint (fine roller stipple lit
    /// from above, as relief), its larger unevenness, and the mat board's fibre.
    private static func noiseTile(size n: Int, octaves: [(cell: Int, amp: Float)], seed: UInt32,
                                  emboss: Bool = false, streak: Bool = false) -> CGImage? {
        func hash(_ x: Int, _ y: Int, _ s: UInt32) -> Float {
            var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263) &+ s &* 2246822519
            h = (h ^ (h >> 13)) &* 1274126177
            return Float(h & 0xFFFF) / 65535
        }
        var height = [Float](repeating: 0, count: n * n)
        for (cell, amp) in octaves {
            let cells = max(1, n / cell)
            for y in 0..<n {
                for x in 0..<n {
                    // Tileable value noise: cells wrap round the tile.
                    let fx = Float(x) / Float(cell), fy = Float(y) / Float(streak ? cell * 6 : cell)
                    let x0 = Int(fx), y0 = Int(fy)
                    let tx = fx - Float(x0), ty = fy - Float(y0)
                    let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
                    let cy = streak ? max(1, n / (cell * 6)) : cells
                    func v(_ i: Int, _ j: Int) -> Float { hash(i % cells, j % cy, seed &+ UInt32(cell)) }
                    let a = v(x0, y0) + (v(x0 + 1, y0) - v(x0, y0)) * sx
                    let b = v(x0, y0 + 1) + (v(x0 + 1, y0 + 1) - v(x0, y0 + 1)) * sx
                    height[y * n + x] += (a + (b - a) * sy - 0.5) * amp
                }
            }
        }
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                var g: Float
                if emboss {
                    // Relief lit from above: slopes facing up are lighter (rows run down).
                    let up = height[((y + n - 1) % n) * n + x], down = height[((y + 1) % n) * n + x]
                    g = 0.5 + (up - down) * 4
                } else {
                    g = 0.5 + height[y * n + x]
                }
                let v = UInt8(max(0, min(255, g * 255)))
                px[(y * n + x) * 4] = v; px[(y * n + x) * 4 + 1] = v; px[(y * n + x) * 4 + 2] = v; px[(y * n + x) * 4 + 3] = 255
            }
        }
        guard let prov = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    private lazy var stipple = Self.noiseTile(size: 512, octaves: [(3, 0.5), (6, 0.35), (12, 0.2)], seed: 7, emboss: true)
    private lazy var mottle = Self.noiseTile(size: 256, octaves: [(32, 0.5), (64, 0.5), (128, 0.4)], seed: 11)
    private lazy var fibre = Self.noiseTile(size: 512, octaves: [(2, 0.35), (5, 0.3)], seed: 23, streak: true)

    /// A texture tiled over `area` (view space), `tile` metres across, blended over what is there.
    private func texture(_ ctx: CGContext, _ img: CGImage?, tile: CGFloat, area: CGRect, mode: CGBlendMode, alpha: CGFloat) {
        guard let img, tile * zoom >= 1.5 else { return }
        ctx.saveGState()
        ctx.clip(to: area)
        ctx.setBlendMode(mode)
        ctx.setAlpha(alpha)
        let o = toView(.zero)
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: tile, height: tile), byTiling: true)
        ctx.restoreGState()
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        // The wall, as its paint is (the light comes after): eggshell white,
        // gently uneven, with the stipple of a roller.
        ctx.setFillColor(NSColor(calibratedRed: 0.95, green: 0.93, blue: 0.87, alpha: 1).cgColor)
        ctx.fill(b)
        texture(ctx, mottle, tile: 2.4, area: b, mode: .softLight, alpha: 0.35)
        texture(ctx, stipple, tile: 0.09, area: b, mode: .overlay, alpha: min(0.55, 0.0006 * zoom))
        // Old pin holes in the wall from earlier hangings.
        if zoom > 600 {
            for i in prints.indices {
                var r = Rand(seed: Self.seed(prints[i].url) ^ 0x51)
                let f = frame(of: i).insetBy(dx: -0.08, dy: -0.08)
                for _ in 0..<3 {
                    let p = toView(CGPoint(x: f.minX + r.next() * f.width, y: f.minY + r.next() * f.height))
                    let rad = max(0.6, 0.6 * zoom / 1000)
                    ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.5).cgColor)
                    ctx.fillEllipse(in: CGRect(x: p.x - rad, y: p.y - rad * 0.4, width: rad * 2, height: rad * 2))
                    ctx.setFillColor(NSColor(calibratedWhite: 0.3, alpha: 0.7).cgColor)
                    ctx.fillEllipse(in: CGRect(x: p.x - rad * 0.7, y: p.y - rad * 0.9, width: rad * 1.4, height: rad * 1.4))
                }
            }
        }
        // The prints on their mats.
        for i in prints.indices {
            let fr = viewRect(frame(of: i))
            guard fr.intersects(b.insetBy(dx: -80, dy: -80)) else { continue }
            drawMounted(ctx, prints[i], fr)
        }
        // The light over everything: the house light, and a track spot over each
        // column of prints, brightest a little above their middle.
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(NSColor(calibratedRed: 0.70, green: 0.69, blue: 0.67, alpha: 1).cgColor)
        ctx.fill(b)
        if !prints.isEmpty {
            let cs = CGColorSpaceCreateDeviceRGB()
            let pool = CGGradient(colorsSpace: cs, colors: [NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.93, alpha: 1).cgColor,
                                                            NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.93, alpha: 0.55).cgColor,
                                                            NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.93, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 0.5, 1])!
            let rows = (prints.count + columns - 1) / columns
            for c in 0..<columns {
                let f0 = frame(of: c)
                let top = toView(CGPoint(x: f0.midX, y: f0.minY - 0.15))
                let reach = (CGFloat(rows) * (f0.height + Self.gap * 1.3) + 0.4) * zoom
                ctx.saveGState()
                ctx.setBlendMode(.lighten)
                ctx.translateBy(x: top.x, y: top.y + reach * 0.35)
                ctx.scaleBy(x: 0.6, y: 1)
                ctx.drawRadialGradient(pool, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: reach * 0.8, options: [])
                ctx.restoreGState()
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // Captions, pencilled under each print once close enough to read.
        if zoom > 900 {
            for i in prints.indices {
                let fr = viewRect(frame(of: i))
                guard fr.intersects(b.insetBy(dx: -80, dy: -80)) else { continue }
                let size = 0.011 * zoom
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .regular),
                                                            .foregroundColor: NSColor(calibratedWhite: 0.3, alpha: 0.75)]
                (prints[i].caption as NSString).draw(at: CGPoint(x: fr.minX, y: fr.maxY + 0.016 * zoom), withAttributes: attrs)
            }
        }
        // The rail of hints, as on the light table.
        let name = sessions.indices.contains(sessionIndex) ? sessions[sessionIndex].name : ""
        let hint = prints.isEmpty
            ? "No enlarged prints in this session yet: mark frames on the light table and press Y / P to enlarge them     B: back"
            : "\(name) · \(prints.count) print\(prints.count == 1 ? "" : "s") (session \(sessionIndex + 1) of \(sessions.count))     sticks / WASD: walk  triggers / wheel: closer  d-pad: next print  A: look closely  L1/R1: session  B: back"
        let bar = CGRect(x: 0, y: b.maxY - 34, width: b.width, height: 34)
        ctx.setFillColor(NSColor(calibratedWhite: 0.06, alpha: 0.92).cgColor)
        ctx.fill(bar)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Futura-Medium", size: 13) ?? NSFont.systemFont(ofSize: 13),
                                                    .foregroundColor: NSColor(calibratedRed: 1, green: 0.92, blue: 0.8, alpha: 0.9)]
        let str = hint as NSString
        let w = str.size(withAttributes: attrs).width
        str.draw(at: CGPoint(x: max(12, b.midX - w / 2), y: bar.minY + 9), withAttributes: attrs)
    }

    /// One print in its mat on the wall: the board's shadows (a tight contact
    /// shadow and a soft one, both below), its thickness, paper fibre, the
    /// bevelled window, the print, and its L-pins.
    private func drawMounted(_ ctx: CGContext, _ p: Print, _ fr: CGRect) {
        let mm = zoom / 1000
        // Shadows on the wall.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -max(1, 2.5 * mm)), blur: max(1.5, 3 * mm),
                      color: NSColor(calibratedWhite: 0, alpha: 0.38).cgColor)
        ctx.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor)
        ctx.fill(fr)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -max(3, 16 * mm)), blur: max(5, 32 * mm),
                      color: NSColor(calibratedWhite: 0, alpha: 0.28).cgColor)
        ctx.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor)
        ctx.fill(fr)
        ctx.restoreGState()
        // The board's face: white, with fine fibre.
        ctx.setFillColor(NSColor(calibratedRed: 0.985, green: 0.983, blue: 0.975, alpha: 1).cgColor)
        ctx.fill(fr)
        texture(ctx, fibre, tile: 0.03, area: fr, mode: .multiply, alpha: min(0.22, 0.00012 * zoom))
        // Its thickness (about 2 mm): the top edge catches the light, the bottom one is in shade.
        let t = max(0.8, 2 * mm)
        ctx.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.9).cgColor)
        ctx.fill(CGRect(x: fr.minX, y: fr.minY, width: fr.width, height: t * 0.6))
        ctx.setFillColor(NSColor(calibratedRed: 0.80, green: 0.79, blue: 0.76, alpha: 1).cgColor)
        ctx.fill(CGRect(x: fr.minX, y: fr.maxY - t, width: fr.width, height: t))
        ctx.setFillColor(NSColor(calibratedRed: 0.90, green: 0.895, blue: 0.88, alpha: 1).cgColor)
        ctx.fill(CGRect(x: fr.minX, y: fr.minY, width: t * 0.6, height: fr.height))
        ctx.fill(CGRect(x: fr.maxX - t * 0.6, y: fr.minY, width: t * 0.6, height: fr.height))
        // The print in the window.
        let inset = Self.border * zoom
        let imgRect = fr.insetBy(dx: inset, dy: inset)
        if let im = image(p, pixels: imgRect.width * (window?.backingScaleFactor ?? 2)) {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            let a = CGFloat(im.width) / CGFloat(im.height)
            var r = imgRect
            if a > r.width / r.height { let h = r.width / a; r.origin.y += (r.height - h) / 2; r.size.height = h }
            else { let w = r.height * a; r.origin.x += (r.width - w) / 2; r.size.width = w }
            ctx.translateBy(x: 0, y: r.maxY + r.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(im, in: r)
            ctx.restoreGState()
        } else {
            ctx.setFillColor(NSColor(calibratedWhite: 0.85, alpha: 1).cgColor)
            ctx.fill(imgRect)
        }
        // The bevel: the board cut at 45 degrees, its white core lit from above
        // (bottom bevel faces up into the light, the top one away), each a soft gradient.
        let bev = max(1, 3.5 * mm)
        let outer = imgRect.insetBy(dx: -bev, dy: -bev)
        let cs = CGColorSpaceCreateDeviceRGB()
        func bevel(_ pts: [CGPoint], _ from: CGPoint, _ to: CGPoint, _ a: CGFloat, _ b2: CGFloat) {
            ctx.saveGState()
            ctx.beginPath(); ctx.addLines(between: pts); ctx.closePath(); ctx.clip()
            let g = CGGradient(colorsSpace: cs, colors: [NSColor(calibratedRed: a, green: a * 0.996, blue: a * 0.985, alpha: 1).cgColor,
                                                         NSColor(calibratedRed: b2, green: b2 * 0.996, blue: b2 * 0.985, alpha: 1).cgColor] as CFArray,
                               locations: [0, 1])!
            ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        bevel([outer.origin, CGPoint(x: outer.maxX, y: outer.minY), CGPoint(x: imgRect.maxX, y: imgRect.minY), imgRect.origin],
              CGPoint(x: 0, y: outer.minY), CGPoint(x: 0, y: imgRect.minY), 0.84, 0.76)
        bevel([CGPoint(x: outer.minX, y: outer.maxY), CGPoint(x: outer.maxX, y: outer.maxY),
               CGPoint(x: imgRect.maxX, y: imgRect.maxY), CGPoint(x: imgRect.minX, y: imgRect.maxY)],
              CGPoint(x: 0, y: imgRect.maxY), CGPoint(x: 0, y: outer.maxY), 1.0, 0.97)
        bevel([outer.origin, CGPoint(x: outer.minX, y: outer.maxY), CGPoint(x: imgRect.minX, y: imgRect.maxY), imgRect.origin],
              CGPoint(x: outer.minX, y: 0), CGPoint(x: imgRect.minX, y: 0), 0.95, 0.90)
        bevel([CGPoint(x: outer.maxX, y: outer.minY), CGPoint(x: outer.maxX, y: outer.maxY),
               CGPoint(x: imgRect.maxX, y: imgRect.maxY), CGPoint(x: imgRect.maxX, y: imgRect.minY)],
              CGPoint(x: outer.maxX, y: 0), CGPoint(x: imgRect.maxX, y: 0), 0.94, 0.88)
        // The crisp cut where the bevel meets the face.
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.55, alpha: 0.35).cgColor)
        ctx.setLineWidth(max(0.4, 0.25 * mm))
        ctx.stroke(outer)
        // Real things are not perfect: dust, a stray fibre or hair, a little wear
        // at the corners, now and then a faint handling smudge. Fixed per print.
        var r = Rand(seed: Self.seed(p.url))
        if r.next() < 0.45 {
            let sx = fr.minX + fr.width * (0.2 + 0.6 * r.next()), sy = fr.maxY - inset * (0.25 + 0.4 * r.next())
            let w = 26 * mm * (0.7 + r.next()), h = 9 * mm * (0.7 + r.next())
            let g = CGGradient(colorsSpace: cs, colors: [NSColor(calibratedRed: 0.55, green: 0.5, blue: 0.45, alpha: 0.07).cgColor,
                                                         NSColor(calibratedRed: 0.55, green: 0.5, blue: 0.45, alpha: 0).cgColor] as CFArray,
                               locations: [0, 1])!
            ctx.saveGState()
            ctx.translateBy(x: sx, y: sy); ctx.scaleBy(x: 1, y: h / max(w, 0.01))
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: w, options: [])
            ctx.restoreGState()
        }
        for (cx, cy) in [(fr.minX, fr.minY), (fr.maxX, fr.minY), (fr.minX, fr.maxY), (fr.maxX, fr.maxY)] where r.next() < 0.5 {
            // A softened, slightly grey corner where the board was handled.
            let rad = (2 + 3 * r.next()) * mm
            ctx.setFillColor(NSColor(calibratedWhite: 0.8, alpha: 0.35).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2))
        }
        if mm > 0.25 {
            let dust = 14 + Int(r.next() * 24)
            for k in 0..<dust {
                // Most on the mat, some on the print; a few larger, most tiny.
                let onPrint = k % 4 == 0
                let area = onPrint ? imgRect : fr
                let x = area.minX + r.next() * area.width, y = area.minY + r.next() * area.height
                if !onPrint && imgRect.insetBy(dx: -bev, dy: -bev).contains(CGPoint(x: x, y: y)) { continue }
                let rad = max(0.35, (0.08 + 0.35 * pow(r.next(), 3)) * mm)
                let dark = onPrint ? 0.2 + 0.5 * r.next() : 0.35 + 0.3 * r.next()
                ctx.setFillColor(NSColor(calibratedWhite: dark, alpha: 0.55).cgColor)
                ctx.fillEllipse(in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2 * (0.7 + 0.6 * r.next())))
            }
            for _ in 0..<(1 + Int(r.next() * 2)) {
                // A fibre or hair: a short wandering curve.
                let x = fr.minX + r.next() * fr.width, y = fr.minY + r.next() * fr.height
                if imgRect.contains(CGPoint(x: x, y: y)) && r.next() < 0.7 { continue }
                let len = (2 + 6 * r.next()) * mm, ang = r.next() * 2 * .pi
                ctx.setStrokeColor(NSColor(calibratedWhite: 0.45 + 0.3 * r.next(), alpha: 0.5).cgColor)
                ctx.setLineWidth(max(0.3, 0.05 * mm))
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addCurve(to: CGPoint(x: x + cos(ang) * len, y: y + sin(ang) * len),
                             control1: CGPoint(x: x + cos(ang + 0.8) * len * 0.4, y: y + sin(ang + 0.8) * len * 0.4),
                             control2: CGPoint(x: x + cos(ang - 0.6) * len * 0.7, y: y + sin(ang - 0.6) * len * 0.7))
                ctx.strokePath()
            }
        }
        // L-pins: two along the top edge, two along the bottom.
        for (x, top) in [(fr.minX + fr.width * 0.14, true), (fr.maxX - fr.width * 0.14, true),
                         (fr.minX + fr.width * 0.14, false), (fr.maxX - fr.width * 0.14, false)] {
            drawPin(ctx, x: x, edgeY: top ? fr.minY : fr.maxY, onto: top ? 1 : -1, mm: mm)
        }
    }

    /// An L-pin seen from the front: the short leg of round steel wire lying
    /// across the mat's edge, the long leg going into the wall beside it.
    private func drawPin(_ ctx: CGContext, x: CGFloat, edgeY: CGFloat, onto: CGFloat, mm: CGFloat) {
        let wire = max(0.8, 1.0 * mm), leg = max(4, 11 * mm)
        let hole = CGPoint(x: x, y: edgeY - onto * wire * 1.4)
        let end = CGPoint(x: x, y: edgeY + onto * leg)
        let cs = CGColorSpaceCreateDeviceRGB()
        // Where it goes into the wall: a small dark hole.
        ctx.setFillColor(NSColor(calibratedWhite: 0.25, alpha: 0.6).cgColor)
        ctx.fillEllipse(in: CGRect(x: hole.x - wire * 0.9, y: hole.y - wire * 0.9, width: wire * 1.8, height: wire * 1.8))
        // Its soft shadow below and a little aside.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: wire * 0.6, height: -wire * 1.8), blur: wire * 2.2,
                      color: NSColor(calibratedWhite: 0, alpha: 0.45).cgColor)
        let body = CGRect(x: x - wire / 2, y: min(hole.y, end.y), width: wire, height: abs(end.y - hole.y))
        let path = CGPath(roundedRect: body, cornerWidth: wire / 2, cornerHeight: wire / 2, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(calibratedWhite: 0.6, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // Round steel: dark at the sides, a bright line along it.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let g = CGGradient(colorsSpace: cs, colors: [NSColor(calibratedWhite: 0.38, alpha: 1).cgColor,
                                                     NSColor(calibratedWhite: 0.95, alpha: 1).cgColor,
                                                     NSColor(calibratedWhite: 0.70, alpha: 1).cgColor,
                                                     NSColor(calibratedWhite: 0.32, alpha: 1).cgColor] as CFArray,
                           locations: [0, 0.35, 0.6, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: body.minX, y: 0), end: CGPoint(x: body.maxX, y: 0), options: [])
        ctx.restoreGState()
    }
}
