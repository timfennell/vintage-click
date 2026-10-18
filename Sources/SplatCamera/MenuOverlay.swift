import AppKit
import CoreImage

/// The game menu (Esc on the keyboard, + / Menu on a pad): switch between the
/// camera, lighting and the light table, see the controls, and the odd job
/// that belongs to the app (another scene, where rolls go, quit).
final class MenuOverlay: NSView {
    struct Item {
        let title: String
        let detail: String
        let action: () -> Void
    }
    var items: [Item] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    /// Showing the controls guide instead of the menu.
    var showingHelp = false { didSet { needsDisplay = true } }
    /// Showing the film page: which stock, rated how (push/pull stops).
    var showingFilm = false { didSet { needsDisplay = true } }
    var filmChoice = 0 { didSet { needsDisplay = true } }
    var filmPush = 0 { didSet { needsDisplay = true } }
    var onLoadFilm: ((Int, Int) -> Void)?
    /// Showing the lens page: a collection, a lens in it; mounting one.
    var showingLenses = false { didSet { needsDisplay = true } }
    var lensShelf = 0 { didSet { needsDisplay = true } }
    var lensChoice = 0 { didSet { needsDisplay = true } }
    var mountedLens = 0
    var onMountLens: ((Int) -> Void)?
    private var lensRects: [NSRect] = []
    private var shelfRects: [NSRect] = []

    /// The bag's last shelf holds the filters.
    var filterShelf: Int { lensCollections.count }
    var onFilterShelf: Bool { lensShelf == filterShelf }
    var mountedFilter = 0
    /// Whether the lens on the camera takes that filter (rear-filter lenses: colour and ND only).
    var filterFits: (Int) -> Bool = { _ in true }
    var onMountFilter: ((Int) -> Void)?
    private var lensRowFirst = 0

    func moveLens(_ d: Int) {
        let n = onFilterShelf ? lensFilters.count : lensCollections[lensShelf].lenses.count
        lensChoice = (lensChoice + d + n) % n
    }
    func moveShelf(_ d: Int) {
        lensShelf = (lensShelf + d + filterShelf + 1) % (filterShelf + 1)
        lensChoice = onFilterShelf ? mountedFilter : 0
    }
    func mountLens() {
        if onFilterShelf { onMountFilter?(lensChoice); return }
        let before = lensCollections.prefix(lensShelf).reduce(0) { $0 + $1.lenses.count }
        onMountLens?(before + lensChoice)
    }

    // A simple chooser page (the lights' gels): a title, a line about it, rows.
    var showingList = false { didSet { needsDisplay = true } }
    var listTitle = "", listAbout = ""
    var listRows: [(name: String, detail: String)] = []
    var listChoice = 0 { didSet { needsDisplay = true } }
    var listMarked = -1
    var onChooseList: ((Int) -> Void)?
    private var listRects: [NSRect] = []
    private var listRowFirst = 0
    func moveList(_ d: Int) {
        guard !listRows.isEmpty else { return }
        listChoice = (listChoice + d + listRows.count) % listRows.count
    }

    private func drawList(_ u: CGFloat) {
        let rowH = 3.0 * u
        let shown = min(listRows.count, 12)
        let first = max(0, min(listRows.count - shown, listChoice - shown / 2))
        listRowFirst = first
        let w = min(bounds.width * 0.7, 70 * u), h = CGFloat(shown) * rowH + 12 * u
        let panel = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        NSColor(white: 0.08, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: panel, xRadius: u, yRadius: u).fill()
        text(listTitle, NSPoint(x: panel.minX + 2 * u, y: panel.minY + 1.5 * u), size: 1.5 * u, color: amber, weight: .bold)
        text(listAbout, NSPoint(x: panel.minX + 2 * u, y: panel.minY + 4.0 * u), size: 0.9 * u, color: NSColor(white: 0.55, alpha: 1))
        listRects = []
        for k in 0..<shown {
            let i = first + k
            let row = listRows[i]
            let r = NSRect(x: panel.minX + u, y: panel.minY + 6.2 * u + CGFloat(k) * rowH, width: w - 2 * u, height: rowH - 0.4 * u)
            listRects.append(r)
            if i == listChoice {
                amber.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: r, xRadius: 0.5 * u, yRadius: 0.5 * u).fill()
            }
            text((i == listChoice ? "▶ " : "  ") + row.name + (i == listMarked ? "  ●" : ""),
                 NSPoint(x: r.minX + u, y: r.minY + 0.3 * u), size: 1.15 * u, color: i == listChoice ? amber : .white)
            text(row.detail, NSPoint(x: r.minX + 3 * u, y: r.minY + 1.7 * u), size: 0.8 * u, color: NSColor(white: 0.5, alpha: 1))
        }
        if first > 0 { text("▲ more", NSPoint(x: panel.maxX - 9 * u, y: panel.minY + 4.0 * u), size: 0.8 * u, color: NSColor(white: 0.5, alpha: 1)) }
        if first + shown < listRows.count {
            text("▼ more", NSPoint(x: panel.maxX - 9 * u, y: panel.maxY - 2.6 * u), size: 0.8 * u, color: NSColor(white: 0.5, alpha: 1))
        }
        text("▲▼ choose   A / Enter / click again: put it on   B / Esc back      ● on now",
             NSPoint(x: panel.minX + 2 * u, y: panel.maxY - 2.6 * u), size: 0.9 * u, color: NSColor(white: 0.6, alpha: 1))
    }
    private var filmRects: [NSRect] = []
    private var ratingRect = NSRect.zero

    func moveFilm(_ d: Int) { filmChoice = (filmChoice + d + filmStocks.count) % filmStocks.count }
    func changePush(_ d: Int) { filmPush = max(-1, min(3, filmPush + d)) }
    func loadFilm() { onLoadFilm?(filmChoice, filmPush) }
    var currentMode = ""

    override var isFlipped: Bool { true }

    private let amber = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.42, alpha: 1)
    private var itemRects: [NSRect] = []

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + d + items.count) % items.count
    }

    func choose() {
        guard items.indices.contains(selected) else { return }
        items[selected].action()
    }

    // Mouse: hover chooses, click selects.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !showingHelp && !showingFilm && !showingLenses && !showingList, let i = itemRects.firstIndex(where: { $0.contains(p) }), i != selected { selected = i }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if showingHelp { showingHelp = false; return }
        if showingLenses {
            if let i = shelfRects.firstIndex(where: { $0.contains(p) }) {
                lensShelf = i
                lensChoice = onFilterShelf ? mountedFilter : 0
                return
            }
            if let k = lensRects.firstIndex(where: { $0.contains(p) }) {
                let i = lensRowFirst + k
                if i == lensChoice { mountLens() } else { lensChoice = i }
            }
            return
        }
        if showingList {
            if let k = listRects.firstIndex(where: { $0.contains(p) }) {
                let i = listRowFirst + k
                if i == listChoice { onChooseList?(i) } else { listChoice = i }
            }
            return
        }
        if showingFilm {
            // The rating line: click its left half to pull, right half to push.
            if ratingRect.contains(p) {
                changePush(p.x < ratingRect.midX ? -1 : 1)
                return
            }
            // Click a stock to choose it, click it again to load it.
            if let i = filmRects.firstIndex(where: { $0.contains(p) }) {
                if i == filmChoice { loadFilm() } else { filmChoice = i }
            }
            return
        }
        if let i = itemRects.firstIndex(where: { $0.contains(p) }) {
            selected = i
            choose()
        }
    }

    /// The menus' type is light, as the finder's meter scale is: warm cream
    /// (greys become dimmer cream, amber stays warm), soft, with a glow.
    static func glowFont(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "Futura-Bold" : "Futura-Medium", size: size) ?? NSFont.systemFont(ofSize: size)
    }

    private func light(_ c: NSColor) -> NSColor {
        guard let rgb = c.usingColorSpace(.deviceRGB) else { return c }
        let mx = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        let mn = min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        if mx - mn < 0.05 {
            let w = min(1, mx * 1.15 + 0.08)
            return NSColor(calibratedRed: w, green: w * 0.92, blue: w * 0.80, alpha: rgb.alphaComponent)
        }
        return rgb
    }

    private func text(_ s: String, _ p: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .medium) {
        let c = light(color)
        let glow = NSShadow()
        glow.shadowColor = c.withAlphaComponent(0.3)
        glow.shadowBlurRadius = size * 0.14
        glow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.glowFont(size * 1.05, bold: weight == .bold),
                                                    .foregroundColor: c, .shadow: glow]
        NSAttributedString(string: s, attributes: attrs).draw(at: p)
    }

    private lazy var ci = CIContext(options: [.cacheIntermediates: false])

    /// Drawn whole, then softened a touch and bloomed, so the type glows as
    /// light does rather than sitting on the screen like print.
    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            drawContent(dirtyRect)
            return
        }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        drawContent(bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let sharp = ctx.makeImage() else { return }
        let img = CIImage(cgImage: sharp)
        let soft = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.3 * scale])
            .cropped(to: img.extent)
        let bloomed = soft.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 3 * scale, kCIInputIntensityKey: 0.15])
            .cropped(to: img.extent)
        if let out = ci.createCGImage(bloomed, from: img.extent) {
            NSImage(cgImage: out, size: bounds.size).draw(in: bounds)
        }
    }

    private func drawContent(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.72).setFill()
        bounds.fill()
        var u = bounds.height / 70
        if showingHelp { drawHelp(u); return }
        if showingFilm { drawFilm(u); return }
        if showingLenses { drawLenses(u); return }
        if showingList { drawList(u); return }
        // The whole list fits the window, however many items there are.
        u = min(u, bounds.height * 0.92 / (CGFloat(items.count) * 2.9 + 9))
        let w = min(bounds.width * 0.5, 40 * u * 1.4), rowH = 2.9 * u
        let h = CGFloat(items.count) * rowH + 9 * u
        let panel = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        NSColor(white: 0.08, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: panel, xRadius: u, yRadius: u).fill()
        amber.withAlphaComponent(0.5).setStroke()
        NSBezierPath(roundedRect: panel, xRadius: u, yRadius: u).stroke()
        text("VINTAGE CLICK", NSPoint(x: panel.minX + 2 * u, y: panel.minY + 1.6 * u), size: 1.5 * u, color: amber, weight: .bold)
        text("now: \(currentMode)", NSPoint(x: panel.maxX - 16 * u, y: panel.minY + 1.9 * u), size: 1.0 * u,
             color: NSColor(white: 0.6, alpha: 1))
        itemRects = []
        for (i, item) in items.enumerated() {
            let r = NSRect(x: panel.minX + u, y: panel.minY + 5 * u + CGFloat(i) * rowH, width: w - 2 * u, height: rowH - 0.4 * u)
            itemRects.append(r)
            if i == selected {
                amber.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: r, xRadius: 0.5 * u, yRadius: 0.5 * u).fill()
            }
            text((i == selected ? "▶ " : "  ") + item.title, NSPoint(x: r.minX + u, y: r.minY + 0.35 * u), size: 1.15 * u,
                 color: i == selected ? amber : .white)
            text(item.detail, NSPoint(x: r.minX + 3 * u, y: r.minY + 1.7 * u), size: 0.8 * u,
                 color: NSColor(white: 0.55, alpha: 1))
        }
        text("▲▼ choose   A / Enter / click select   B / Esc back", NSPoint(x: panel.minX + 2 * u, y: panel.maxY - 2.6 * u),
             size: 0.9 * u, color: NSColor(white: 0.6, alpha: 1))
    }

    /// The controls guide: every mode, pad and keyboard side by side.
    static let guide: [(title: String, rows: [(String, String, String)])] = [
        ("CAMERA", [
            ("walk / look", "sticks", "WASD · mouse"),
            ("pace: rail ... run (real m/s)", "L3 (steps up)", ",  .  (slower / faster)"),
            ("burst of speed (x3)", "", "hold Shift"),
            ("rise / sink", "R1 / L1", "Space / Ctrl"),
            ("focus ring", "R2 far · L2 near", "mouse wheel"),
            ("aperture", "d-pad ◀ ▶", "[  ]"),
            ("shutter speed", "d-pad ▲ ▼", "-  ="),
            ("fire the shutter", "bottom (A)", "left click"),
            ("depth-of-field preview", "hold right (B)", "hold right click"),
            ("camera bag (change lens)", "left (X)", "B, or 1 - 9 in the collection"),
            ("lens filter (the bag's Filters shelf)", "menu", "V"),
            ("load film (stock, push / pull)", "tap top (Y)", "R"),
            ("tilt / shift the lens", "hold Y + right stick", "hold M + arrows"),
            ("square the lens up again", "hold Y + click R3", "N"),
        ]),
        ("LIGHTING", [
            ("lighting mode on / off", "R3", "L"),
            ("fly a light (its own view)", "d-pad ◀ ▶", "1 - 9"),
            ("back to the camera's view", "right (B)", "0  or  `"),
            ("add a light (you fly it)", "left (X)", "F"),
            ("change the head", "top (Y)", "T"),
            ("gel on the light", "menu", "C"),
            ("modifier: doors, flag, cookie, gobo", "menu", "M"),
            ("gobo focus / cookie distance", "menu", "K"),
            ("flood / spot", "L2 / R2", "mouse wheel"),
            ("dimmer (half stops)", "d-pad ▲ ▼", "-  ="),
            ("remove the light you fly", "via the menu", "Backspace"),
            ("house lights: day ... night", "L3", "G"),
        ]),
        ("LIGHT TABLE", [
            ("open / close", "View (−)", "Tab"),
            ("move the loupe", "either stick", "the mouse"),
            ("loupe power", "L2 / R2", "mouse wheel"),
            ("choose a frame", "d-pad", "arrows"),
            ("mark a keeper", "bottom (A)", "click / Enter"),
            ("another session", "L1 / R1", "Q / E"),
        ]),
        ("ANYWHERE", [
            ("this menu", "Menu (+)", "Esc"),
            ("take / free the mouse", "", "click / Esc"),
        ]),
    ]

    /// The camera bag: collections across the top, their lenses below.
    private func drawLenses(_ u: CGFloat) {
        let shelfNames = lensCollections.map(\.name) + ["Filters"]
        let rowH = 3.3 * u
        let w = min(bounds.width * 0.86, 84 * u)
        let rowsShown = onFilterShelf ? 9 : max(lensCollections[lensShelf].lenses.count, 8)
        let h = CGFloat(rowsShown) * rowH + 15 * u
        let panel = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        NSColor(white: 0.08, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: panel, xRadius: u, yRadius: u).fill()
        text("CAMERA BAG", NSPoint(x: panel.minX + 2 * u, y: panel.minY + 1.5 * u), size: 1.5 * u, color: amber, weight: .bold)
        // The shelves.
        shelfRects = []
        var x = panel.minX + 17 * u
        // As many shelves as there are: the tabs shrink to fit the panel.
        func tabWidth(_ name: String, _ size: CGFloat) -> CGFloat {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.glowFont(size * 1.05)]
            return NSAttributedString(string: name, attributes: attrs).size().width + 2 * size / 1.05
        }
        let room = panel.maxX - 1.5 * u - x
        let natural = shelfNames.reduce(0) { $0 + tabWidth($1, 1.05 * u) + 0.6 * u }
        let fit = min(1, room / natural)
        let ts = 1.05 * u * fit
        for (i, name) in shelfNames.enumerated() {
            let tw = tabWidth(name, ts)
            let r = NSRect(x: x, y: panel.minY + 1.2 * u, width: tw, height: 2.2 * u)
            shelfRects.append(r)
            if i == lensShelf {
                amber.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: r, xRadius: 0.4 * u, yRadius: 0.4 * u).fill()
            }
            text(name, NSPoint(x: r.minX + ts / 1.05, y: r.minY + 0.35 * u + (1.05 * u - ts) / 2), size: ts,
                 color: i == lensShelf ? amber : NSColor(white: 0.7, alpha: 1), weight: .semibold)
            x += tw + 0.6 * u * fit
        }
        if onFilterShelf {
            drawFilterRows(panel, w: w, rowH: rowH, shown: rowsShown, u: u)
            return
        }
        let shelf = lensCollections[lensShelf]
        lensRowFirst = 0
        text(shelf.about, NSPoint(x: panel.minX + 2 * u, y: panel.minY + 4.0 * u), size: 0.9 * u, color: NSColor(white: 0.55, alpha: 1))
        lensRects = []
        let before = lensCollections.prefix(lensShelf).reduce(0) { $0 + $1.lenses.count }
        for (i, l) in shelf.lenses.enumerated() {
            let r = NSRect(x: panel.minX + u, y: panel.minY + 6.2 * u + CGFloat(i) * rowH, width: w - 2 * u, height: rowH - 0.4 * u)
            lensRects.append(r)
            if i == lensChoice {
                amber.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: r, xRadius: 0.5 * u, yRadius: 0.5 * u).fill()
            }
            let mounted = before + i == mountedLens
            text((i == lensChoice ? "▶ " : "  ") + l.name + (mounted ? "  ●" : ""), NSPoint(x: r.minX + u, y: r.minY + 0.4 * u),
                 size: 1.2 * u, color: i == lensChoice ? amber : .white)
            var kind = l.projection == .circularFisheye ? "circular fisheye" : l.projection == .fisheye ? "fisheye" : "\(l.blades == 0 ? "round" : "\(l.blades)-blade") iris"
            let close = l.minFocusM < 1 ? String(format: "%.0f cm", l.minFocusM * 100) : String(format: "%.1f m", l.minFocusM)
            switch l.movement {
            case .tilt(let most): kind += String(format: " · tilts %.0f°", most)
            case .shift(let most): kind += String(format: " · shifts %.0f mm", most)
            case .none: break
            }
            text("\(kind) · close \(close)", NSPoint(x: r.minX + w * 0.5, y: r.minY + 0.55 * u), size: 0.95 * u,
                 color: NSColor(white: 0.72, alpha: 1))
            text(l.inspiredBy, NSPoint(x: r.minX + 3 * u, y: r.minY + 1.95 * u), size: 0.8 * u, color: NSColor(white: 0.5, alpha: 1))
        }
        text("◀▶ collection   ▲▼ lens   A / Enter / click again: mount   B / Esc back      ● on the camera",
             NSPoint(x: panel.minX + 2 * u, y: panel.maxY - 2.6 * u), size: 0.9 * u, color: NSColor(white: 0.6, alpha: 1))
        if shelf.lenses.indices.contains(lensChoice) {
            let how: String?
            switch shelf.lenses[lensChoice].movement {
            case .tilt: how = "tilt it on the camera: hold Y + right stick, or hold M + arrows · Y + R3 or N squares it"
            case .shift: how = "shift it on the camera: hold Y + right stick, or hold M + arrows · Y + R3 or N centres it"
            case .none: how = nil
            }
            if let how {
                text(how, NSPoint(x: panel.minX + 2 * u, y: panel.maxY - 4.2 * u), size: 0.9 * u, color: amber)
            }
        }
    }

    /// The bag's filter shelf: what screws on the front (or drops in at the back).
    private func drawFilterRows(_ panel: NSRect, w: CGFloat, rowH: CGFloat, shown: Int, u: CGFloat) {
        let n = lensFilters.count
        let first = max(0, min(n - shown, lensChoice - shown / 2))
        lensRowFirst = first
        let rearOnly = !filterFits(lensFilters.firstIndex { $0.hasEffect } ?? 0)
        text(rearOnly ? "this lens takes filters at the back: colour and ND only, no effect filters"
                      : "on the front of the lens: the finder, the meter and the film all see through it",
             NSPoint(x: panel.minX + 2 * u, y: panel.minY + 4.0 * u), size: 0.9 * u, color: NSColor(white: 0.55, alpha: 1))
        lensRects = []
        for k in 0..<min(shown, n) {
            let i = first + k
            let f = lensFilters[i]
            let fits = filterFits(i)
            let r = NSRect(x: panel.minX + u, y: panel.minY + 6.2 * u + CGFloat(k) * rowH, width: w - 2 * u, height: rowH - 0.4 * u)
            lensRects.append(r)
            if i == lensChoice {
                amber.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: r, xRadius: 0.5 * u, yRadius: 0.5 * u).fill()
            }
            let dim = NSColor(white: 0.4, alpha: 1)
            text((i == lensChoice ? "▶ " : "  ") + f.name + (i == mountedFilter ? "  ●" : ""), NSPoint(x: r.minX + u, y: r.minY + 0.4 * u),
                 size: 1.2 * u, color: !fits ? dim : (i == lensChoice ? amber : .white))
            let loss = f.stops < 0.05 ? "no light lost" : String(format: "%.1f stops", f.stops)
            text(fits ? "\(f.group) · \(loss)" : "\(f.group) · not on this lens", NSPoint(x: r.minX + w * 0.5, y: r.minY + 0.55 * u),
                 size: 0.95 * u, color: fits ? NSColor(white: 0.72, alpha: 1) : dim)
            text(f.about, NSPoint(x: r.minX + 3 * u, y: r.minY + 1.95 * u), size: 0.8 * u, color: NSColor(white: 0.5, alpha: 1))
        }
        if first > 0 { text("▲ more", NSPoint(x: panel.maxX - 9 * u, y: panel.minY + 4.0 * u), size: 0.8 * u, color: NSColor(white: 0.5, alpha: 1)) }
        if first + shown < n {
            text("▼ more", NSPoint(x: panel.maxX - 9 * u, y: panel.maxY - 4.2 * u), size: 0.8 * u, color: NSColor(white: 0.5, alpha: 1))
        }
        text("◀▶ shelf   ▲▼ filter   A / Enter / click again: put it on   B / Esc back      ● on the lens",
             NSPoint(x: panel.minX + 2 * u, y: panel.maxY - 2.6 * u), size: 0.9 * u, color: NSColor(white: 0.6, alpha: 1))
    }

    /// Loading a roll: the stocks in the bag, and how to rate the roll.
    private func drawFilm(_ u: CGFloat) {
        let rowH = 3.3 * u
        let shown = min(filmStocks.count, 9)
        // Scroll so the choice stays in view.
        let first = max(0, min(filmStocks.count - shown, filmChoice - shown / 2))
        let w = min(bounds.width * 0.7, 70 * u), h = CGFloat(shown) * rowH + 15 * u
        let panel = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        NSColor(white: 0.08, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: panel, xRadius: u, yRadius: u).fill()
        text("LOAD FILM", NSPoint(x: panel.minX + 2 * u, y: panel.minY + 1.5 * u), size: 1.5 * u, color: amber, weight: .bold)
        text("the roll in the camera is rewound and put away", NSPoint(x: panel.minX + 15 * u, y: panel.minY + 1.9 * u),
             size: 0.9 * u, color: NSColor(white: 0.55, alpha: 1))
        filmRects = []
        if first > 0 { text("▲ more", NSPoint(x: panel.maxX - 9 * u, y: panel.minY + 3.6 * u), size: 0.8 * u, color: NSColor(white: 0.5, alpha: 1)) }
        if first + shown < filmStocks.count {
            text("▼ more", NSPoint(x: panel.maxX - 9 * u, y: panel.minY + 5 * u + CGFloat(shown) * rowH), size: 0.8 * u,
                 color: NSColor(white: 0.5, alpha: 1))
        }
        for (i, s) in filmStocks.enumerated() {
            guard i >= first && i < first + shown else { filmRects.append(.zero); continue }
            let r = NSRect(x: panel.minX + u, y: panel.minY + 5 * u + CGFloat(i - first) * rowH, width: w - 2 * u, height: rowH - 0.4 * u)
            filmRects.append(r)
            if i == filmChoice {
                amber.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: r, xRadius: 0.5 * u, yRadius: 0.5 * u).fill()
            }
            let kind = s.blackAndWhite ? "B&W" : (s.contrast > 1.3 ? "slide" : "colour neg")
            text((i == filmChoice ? "▶ " : "  ") + s.name, NSPoint(x: r.minX + u, y: r.minY + 0.4 * u), size: 1.25 * u,
                 color: i == filmChoice ? amber : .white)
            text(String(format: "ISO %.0f · %@ · %d exp", s.iso, kind, s.exposures),
                 NSPoint(x: r.minX + w * 0.42, y: r.minY + 0.55 * u), size: 1.0 * u, color: NSColor(white: 0.75, alpha: 1))
            text(s.inspiredBy, NSPoint(x: r.minX + 3 * u, y: r.minY + 1.95 * u), size: 0.8 * u, color: NSColor(white: 0.5, alpha: 1))
        }
        // The rating: push / pull.
        let s = filmStocks[filmChoice]
        let ei = s.iso * pow(2, Float(filmPush))
        let rating = filmPush == 0 ? "box speed" : (filmPush > 0 ? "push +\(filmPush)" : "pull \(filmPush)")
        let y = panel.maxY - 8.5 * u
        ratingRect = NSRect(x: panel.minX + u, y: y - 0.5 * u, width: 42 * u, height: 2.6 * u)
        text(String(format: "◀  rate at EI %.0f  (%@)  ▶", ei, rating), NSPoint(x: panel.minX + 2 * u, y: y), size: 1.3 * u, color: amber)
        let effect = filmPush > 0 ? "more contrast and grain, deeper shadows, a little fog: for low light"
            : filmPush < 0 ? "softer contrast, finer grain: for harsh light" : "as the maker intended"
        text(effect, NSPoint(x: panel.minX + 2 * u, y: y + 1.9 * u), size: 0.9 * u, color: NSColor(white: 0.6, alpha: 1))
        text("▲▼ stock   ◀▶ push / pull   A / Enter load   B / Esc back", NSPoint(x: panel.minX + 2 * u, y: panel.maxY - 2.6 * u),
             size: 0.9 * u, color: NSColor(white: 0.6, alpha: 1))
    }

    private func drawHelp(_ u: CGFloat) {
        let panel = bounds.insetBy(dx: bounds.width * 0.06, dy: bounds.height * 0.05)
        NSColor(white: 0.08, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: panel, xRadius: u, yRadius: u).fill()
        text("CONTROLS", NSPoint(x: panel.minX + 2 * u, y: panel.minY + 1.5 * u), size: 1.5 * u, color: amber, weight: .bold)
        text("pad buttons by position: Xbox, PlayStation and Switch Pro alike", NSPoint(x: panel.minX + 16 * u, y: panel.minY + 1.9 * u),
             size: 0.9 * u, color: NSColor(white: 0.6, alpha: 1))
        let colW = panel.width / 2 - 3 * u
        var x = panel.minX + 2 * u, y = panel.minY + 5 * u
        let line = 1.55 * u
        for (k, section) in Self.guide.enumerated() {
            let need = CGFloat(section.rows.count + 2) * line
            if k > 0 && y + need > panel.maxY - 3 * u {
                x += colW + 2 * u
                y = panel.minY + 5 * u
            }
            text(section.title, NSPoint(x: x, y: y), size: 1.1 * u, color: amber, weight: .bold)
            text("pad", NSPoint(x: x + colW * 0.46, y: y + 0.15 * u), size: 0.8 * u, color: NSColor(white: 0.5, alpha: 1))
            text("keys / mouse", NSPoint(x: x + colW * 0.72, y: y + 0.15 * u), size: 0.8 * u, color: NSColor(white: 0.5, alpha: 1))
            y += line * 1.2
            for (what, pad, keys) in section.rows {
                text(what, NSPoint(x: x, y: y), size: 0.85 * u, color: .white)
                text(pad, NSPoint(x: x + colW * 0.46, y: y), size: 0.85 * u, color: NSColor(white: 0.8, alpha: 1))
                text(keys, NSPoint(x: x + colW * 0.72, y: y), size: 0.85 * u, color: NSColor(white: 0.8, alpha: 1))
                y += line
            }
            y += line * 0.8
        }
        text("B / Esc / click: back", NSPoint(x: panel.minX + 2 * u, y: panel.maxY - 2.4 * u), size: 0.9 * u,
             color: NSColor(white: 0.6, alpha: 1))
    }
}
