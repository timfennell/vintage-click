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
    static let border: CGFloat = 0.035            // white paper round it
    static let gap: CGFloat = 0.16                // between prints
    private var columns: Int { max(1, min(8, Int(ceil(sqrt(Double(prints.count) * 1.6))))) }

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

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        // The wall: warm white, a little darker away from the lights.
        ctx.setFillColor(NSColor(calibratedRed: 0.66, green: 0.65, blue: 0.63, alpha: 1).cgColor)
        ctx.fill(b)
        let cs = CGColorSpaceCreateDeviceRGB()
        // Track lights: a pool of light on each column of prints, brightest a little above centre.
        if !prints.isEmpty {
            let pool = CGGradient(colorsSpace: cs, colors: [NSColor(calibratedRed: 1, green: 0.97, blue: 0.9, alpha: 0.75).cgColor,
                                                            NSColor(calibratedRed: 1, green: 0.97, blue: 0.9, alpha: 0.35).cgColor,
                                                            NSColor(calibratedWhite: 1, alpha: 0.0).cgColor] as CFArray,
                                  locations: [0, 0.45, 1])!
            let rows = (prints.count + columns - 1) / columns
            for c in 0..<columns {
                let f0 = frame(of: c)
                let top = toView(CGPoint(x: f0.midX, y: f0.minY - 0.15))
                let reach = (CGFloat(rows) * (f0.height + Self.gap * 1.3) + 0.4) * zoom
                ctx.saveGState()
                ctx.translateBy(x: top.x, y: top.y + reach * 0.35)
                ctx.scaleBy(x: 0.55, y: 1)
                ctx.drawRadialGradient(pool, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: reach * 0.75, options: [])
                ctx.restoreGState()
            }
        }
        // The prints.
        for i in prints.indices {
            let fr = viewRect(frame(of: i))
            guard fr.intersects(b.insetBy(dx: -50, dy: -50)) else { continue }
            let p = prints[i]
            // Paper, lifted a little off the wall.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: max(1, 0.006 * zoom)), blur: max(2, 0.012 * zoom),
                          color: NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)
            ctx.setFillColor(NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.93, alpha: 1).cgColor)
            ctx.fill(fr)
            ctx.restoreGState()
            // The image.
            let inset = Self.border * zoom
            let imgRect = fr.insetBy(dx: inset, dy: inset)
            if let im = image(p, pixels: imgRect.width * (window?.backingScaleFactor ?? 2)) {
                ctx.saveGState()
                ctx.interpolationQuality = .high
                // Fit the print's own shape inside the paper's window.
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
            // Pins at the top corners.
            let pin = max(2, 0.008 * zoom)
            for x in [fr.minX + inset * 0.5, fr.maxX - inset * 0.5] {
                let c = CGPoint(x: x, y: fr.minY + inset * 0.5)
                ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.25).cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - pin + pin * 0.3, y: c.y - pin + pin * 0.4, width: 2 * pin, height: 2 * pin))
                ctx.setFillColor(NSColor(calibratedRed: 0.72, green: 0.70, blue: 0.66, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - pin, y: c.y - pin, width: 2 * pin, height: 2 * pin))
                ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.7).cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - pin * 0.45, y: c.y - pin * 0.55, width: pin * 0.6, height: pin * 0.6))
            }
            // A pencilled caption under each, once near enough to read.
            if zoom > 900 {
                let size = 0.011 * zoom
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .regular),
                                                            .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 0.8)]
                (p.caption as NSString).draw(at: CGPoint(x: fr.minX, y: fr.maxY + 0.012 * zoom), withAttributes: attrs)
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
}
