import AppKit

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
    var currentMode = ""

    override var isFlipped: Bool { true }

    private let amber = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.25, alpha: 1)
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
        if !showingHelp, let i = itemRects.firstIndex(where: { $0.contains(p) }), i != selected { selected = i }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if showingHelp { showingHelp = false; return }
        if let i = itemRects.firstIndex(where: { $0.contains(p) }) {
            selected = i
            choose()
        }
    }

    private func text(_ s: String, _ p: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .medium) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color]
        NSAttributedString(string: s, attributes: attrs).draw(at: p)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.72).setFill()
        bounds.fill()
        let u = bounds.height / 60
        if showingHelp { drawHelp(u); return }
        let w = min(bounds.width * 0.6, 46 * u * 1.4), rowH = 3.4 * u
        let h = CGFloat(items.count) * rowH + 9 * u
        let panel = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        NSColor(white: 0.08, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: panel, xRadius: u, yRadius: u).fill()
        amber.withAlphaComponent(0.5).setStroke()
        NSBezierPath(roundedRect: panel, xRadius: u, yRadius: u).stroke()
        text("SPLAT CAMERA", NSPoint(x: panel.minX + 2 * u, y: panel.minY + 1.6 * u), size: 1.5 * u, color: amber, weight: .bold)
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
            text((i == selected ? "▶ " : "  ") + item.title, NSPoint(x: r.minX + u, y: r.minY + 0.5 * u), size: 1.3 * u,
                 color: i == selected ? amber : .white)
            text(item.detail, NSPoint(x: r.minX + 3 * u, y: r.minY + 2.0 * u), size: 0.85 * u,
                 color: NSColor(white: 0.55, alpha: 1))
        }
        text("▲▼ choose   A / Enter / click select   B / Esc back", NSPoint(x: panel.minX + 2 * u, y: panel.maxY - 2.6 * u),
             size: 0.9 * u, color: NSColor(white: 0.6, alpha: 1))
    }

    /// The controls guide: every mode, pad and keyboard side by side.
    static let guide: [(title: String, rows: [(String, String, String)])] = [
        ("CAMERA", [
            ("walk / look", "sticks", "WASD · mouse"),
            ("run", "L3 (toggle)", "hold Shift"),
            ("rise / sink", "R1 / L1", "Space / Ctrl"),
            ("focus ring", "R2 far · L2 near", "mouse wheel"),
            ("aperture", "d-pad ◀ ▶", "[  ]"),
            ("shutter speed", "d-pad ▲ ▼", "-  ="),
            ("fire the shutter", "bottom (A)", "left click"),
            ("depth-of-field preview", "hold right (B)", "hold right click"),
            ("next lens / lens 1-8", "left (X)", "1 - 8"),
            ("load a new roll", "top (Y)", "R"),
        ]),
        ("LIGHTING", [
            ("lighting mode on / off", "R3", "L"),
            ("fly a light (its own view)", "d-pad ◀ ▶", "1 - 9"),
            ("back to the camera's view", "right (B)", "0  or  `"),
            ("add a light (you fly it)", "left (X)", "F"),
            ("change the head", "top (Y)", "T"),
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
            ("another roll", "L1 / R1", "Q / E"),
        ]),
        ("ANYWHERE", [
            ("this menu", "Menu (+)", "Esc"),
            ("take / free the mouse", "", "click / Esc"),
        ]),
    ]

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
