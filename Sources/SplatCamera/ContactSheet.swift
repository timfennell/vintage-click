import AppKit
import ImageIO

/// The only place pictures are seen: a contact print of each roll, laid out
/// as on 8x10 paper (strips of six, film rebate, sprocket holes, edge print),
/// with a red grease-pencil box for the selection and a loupe for one frame.
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
    var loupe = false { didSet { needsDisplay = true } }
    /// Frames shot on the current roll that are still in the darkroom.
    var pending: (roll: Int, frames: [Int]) = (0, [])

    private var thumbs: [URL: NSImage] = [:]
    private var loading: Set<URL> = []
    private var full: (URL, NSImage)?

    override var isFlipped: Bool { true }

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Splat Camera")

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
        rolls = Self.scanRolls()
        if let number, let i = rolls.firstIndex(where: { $0.number == number }) {
            rollIndex = i
        } else {
            rollIndex = max(0, rolls.count - 1)
        }
        selected = min(selected, max(0, frameCount - 1))
        needsDisplay = true
    }

    private var roll: Roll? { rolls.indices.contains(rollIndex) ? rolls[rollIndex] : nil }
    private var frameCount: Int { roll?.frames.count ?? 0 }

    func move(dx: Int, dy: Int) {
        guard frameCount > 0 else { return }
        selected = max(0, min(frameCount - 1, selected + dx + dy * 6))
        needsDisplay = true
    }

    func changeRoll(_ d: Int) {
        guard !rolls.isEmpty else { return }
        rollIndex = max(0, min(rolls.count - 1, rollIndex + d))
        selected = 0
        needsDisplay = true
    }

    private func thumbnail(_ url: URL) -> NSImage? {
        if let t = thumbs[url] { return t }
        if !loading.contains(url) {
            loading.insert(url)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 480,
                      ] as CFDictionary) else { return }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                DispatchQueue.main.async {
                    self?.thumbs[url] = img
                    self?.needsDisplay = true
                }
            }
        }
        return nil
    }

    private func fullImage(_ url: URL) -> NSImage? {
        if let f = full, f.0 == url { return f.1 }
        guard let img = NSImage(contentsOf: url) else { return nil }
        full = (url, img)
        return img
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSColor(white: 0.12, alpha: 1).setFill()
        b.fill()
        guard let roll else {
            label("No rolls developed yet.", at: NSPoint(x: b.midX, y: b.midY), size: 18,
                  color: .white, center: true)
            return
        }
        if loupe, roll.frames.indices.contains(selected), let img = fullImage(roll.frames[selected]) {
            let s = min(b.width * 0.94 / img.size.width, b.height * 0.86 / img.size.height)
            let r = NSRect(x: b.midX - img.size.width * s / 2, y: b.midY - img.size.height * s / 2 - 10,
                           width: img.size.width * s, height: img.size.height * s)
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            label("Roll \(roll.number) · \(roll.stock) · frame \(selected + 1)    B: back to the sheet",
                  at: NSPoint(x: b.midX, y: 14), size: 13, color: .white, center: true)
            return
        }
        // The paper: an 8x10 sheet, six strips of six.
        let paperH = b.height * 0.94, paperW = paperH * 0.8
        let paper = NSRect(x: b.midX - paperW / 2, y: (b.height - paperH) / 2, width: paperW, height: paperH)
        NSColor(white: 0.97, alpha: 1).setFill()
        paper.fill()
        let margin = paperW * 0.05
        let stripW = paperW - 2 * margin
        let frameW = stripW / 6.25, frameH = frameW / 1.5
        let stripH = frameH * 1.55
        let gap = (paperH - 2 * margin - stripH * 6) / 5
        let stockName = roll.stock.uppercased()
        let edge = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.2, alpha: 0.9)
        let pend = pending.roll == roll.number ? pending.frames : []
        let total = max(roll.frames.count, (pend.max() ?? 0))
        for strip in 0..<6 {
            let y = paper.minY + margin + CGFloat(strip) * (stripH + gap)
            let first = strip * 6
            if first >= max(total, 1) && strip > 0 { break }
            let stripRect = NSRect(x: paper.minX + margin, y: y, width: stripW, height: stripH)
            NSColor(white: 0.06, alpha: 1).setFill()
            stripRect.fill()
            // Sprocket holes along both edges.
            NSColor(white: 0.85, alpha: 1).setFill()
            let hole = stripH * 0.06
            var hx = stripRect.minX + hole
            while hx < stripRect.maxX - hole {
                NSBezierPath(roundedRect: NSRect(x: hx, y: y + hole * 0.6, width: hole * 1.1, height: hole * 1.4),
                             xRadius: hole * 0.2, yRadius: hole * 0.2).fill()
                NSBezierPath(roundedRect: NSRect(x: hx, y: y + stripH - hole * 2, width: hole * 1.1, height: hole * 1.4),
                             xRadius: hole * 0.2, yRadius: hole * 0.2).fill()
                hx += hole * 2.6
            }
            label("\(stockName)   SAFETY FILM", at: NSPoint(x: stripRect.minX + 6, y: y + stripH - hole * 3.6),
                  size: hole * 1.3, color: edge, center: false)
            for k in 0..<6 {
                let i = first + k
                let fx = stripRect.minX + frameW * 0.125 + CGFloat(k) * frameW * 1.02
                let fr = NSRect(x: fx, y: y + (stripH - frameH) / 2, width: frameW * 0.98, height: frameH)
                label("\(i + 1)", at: NSPoint(x: fx + frameW * 0.45, y: fr.maxY + hole * 0.3),
                      size: hole * 1.2, color: edge, center: false)
                if i < roll.frames.count {
                    if let t = thumbnail(roll.frames[i]) {
                        t.draw(in: fr, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                } else if pend.contains(i + 1) {
                    label("in the darkroom", at: NSPoint(x: fr.midX, y: fr.midY - 6), size: hole * 1.2,
                          color: NSColor(white: 0.5, alpha: 1), center: true)
                }
                if i == selected {
                    let box = NSBezierPath(rect: fr.insetBy(dx: -3, dy: -3))
                    box.lineWidth = 3
                    NSColor(calibratedRed: 0.85, green: 0.1, blue: 0.08, alpha: 0.9).setStroke()
                    box.stroke()
                }
            }
        }
        label("Roll \(roll.number) of \(rolls.count) · \(roll.stock)     d-pad: choose   A: loupe   L1/R1: roll   B / View: back to the camera",
              at: NSPoint(x: b.midX, y: b.height - 18), size: 12, color: .white, center: true)
    }

    private func label(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor, center: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(size, 7), weight: .semibold),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let w = str.size().width
        str.draw(at: NSPoint(x: center ? p.x - w / 2 : p.x, y: p.y))
    }
}
