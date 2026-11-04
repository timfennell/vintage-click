import AppKit

/// The darkroom's monitor: the frame of a take developed last, small in the
/// corner of the finder or the light table while the rest are developing.
final class DarkroomMonitor: NSView {
    private var image: CGImage?
    private var caption = ""

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ image: CGImage, caption: String) {
        self.image = image
        self.caption = caption
        isHidden = false
        needsDisplay = true
    }

    func clear() {
        image = nil
        isHidden = true
    }

    /// Sits in the upper right of `host`, a third of its width, shaped like the frame.
    func place(in host: NSView) {
        if superview !== host {
            removeFromSuperview()
            host.addSubview(self)
        }
        let aspect = image.map { CGFloat($0.height) / CGFloat(max(1, $0.width)) } ?? 2.0 / 3
        let w = (host.bounds.width * 0.3).rounded()
        let h = (w * aspect).rounded() + 22
        frame = NSRect(x: host.bounds.width - w - 24, y: host.isFlipped ? 24 : host.bounds.height - h - 24, width: w, height: h)
        autoresizingMask = host.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pic = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 22)
        NSColor(white: 0, alpha: 0.75).setFill()
        bounds.fill()
        ctx.saveGState()
        // Flipped view: draw the image the right way up.
        ctx.translateBy(x: 0, y: pic.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: NSRect(x: 0, y: 0, width: pic.width, height: pic.height))
        ctx.restoreGState()
        NSColor(white: 1, alpha: 0.35).setStroke()
        let edge = NSBezierPath(rect: pic.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.8),
        ]
        (caption as NSString).draw(at: NSPoint(x: 6, y: pic.maxY + 4), withAttributes: attrs)
    }
}
