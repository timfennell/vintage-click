import AppKit
import Metal

/// The cut patterns lights shine through: gobos (etched metal discs for an
/// ellipsoidal's gate) and cookies (cucolorises on stands). White passes
/// light, black stops it. Drawn once, into the layers of a mipmapped texture
/// array: a blurrier level is a softer focus or a cookie nearer the lamp.
/// Layer numbers are the ones `lightModifiers` refers to.
enum PatternArt {
    static let size = 256

    static func make(device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        let layers: [(CGContext, CGFloat) -> Void] = [window, blinds, church, bars, leafGobo, leafCookie, breakup, branches]
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .r8Unorm
        d.width = size
        d.height = size
        d.arrayLength = layers.count
        d.mipmapLevelCount = Int(log2(Double(size))) + 1
        d.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        for (i, draw) in layers.enumerated() {
            var px = [UInt8](repeating: 0, count: size * size)
            guard let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { continue }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            draw(ctx, CGFloat(size))
            tex.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, slice: i,
                        withBytes: px, bytesPerRow: size, bytesPerImage: size * size)
        }
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return tex
    }

    private static func white(_ c: CGContext) { c.setFillColor(gray: 1, alpha: 1) }
    private static func black(_ c: CGContext) { c.setFillColor(gray: 0, alpha: 1) }

    /// A disc gobo's opening: most patterns sit inside the gate's circle.
    private static func disc(_ c: CGContext, _ s: CGFloat) {
        white(c)
        c.fillEllipse(in: CGRect(x: s * 0.02, y: s * 0.02, width: s * 0.96, height: s * 0.96))
    }

    /// Four panes, a thick frame and mullions, a little in perspective.
    private static func window(_ c: CGContext, _ s: CGFloat) {
        white(c)
        let w = s * 0.62, h = s * 0.78, x0 = (s - w) / 2, y0 = (s - h) / 2
        let bar = s * 0.035
        let pw = (w - bar) / 2, ph = (h - bar) / 2
        for (i, j) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            c.fill(CGRect(x: x0 + CGFloat(i) * (pw + bar), y: y0 + CGFloat(j) * (ph + bar), width: pw, height: ph))
        }
    }

    private static func blinds(_ c: CGContext, _ s: CGFloat) {
        disc(c, s)
        black(c)
        let n = 11
        for k in 0..<n {
            let y = s * (CGFloat(k) + 0.55) / CGFloat(n)
            c.fill(CGRect(x: 0, y: y, width: s, height: s / CGFloat(n) * 0.42))
        }
    }

    /// A gothic lancet window with a round rose above two lights.
    private static func church(_ c: CGContext, _ s: CGFloat) {
        white(c)
        let w = s * 0.5, x0 = (s - w) / 2, base = s * 0.08, spring = s * 0.55
        let arch = CGMutablePath()
        arch.move(to: CGPoint(x: x0, y: base))
        arch.addLine(to: CGPoint(x: x0, y: spring))
        arch.addArc(center: CGPoint(x: x0 + w, y: spring), radius: w, startAngle: .pi, endAngle: .pi * 2 / 3, clockwise: true)
        arch.addArc(center: CGPoint(x: x0, y: spring), radius: w, startAngle: .pi / 3, endAngle: 0, clockwise: true)
        arch.addLine(to: CGPoint(x: x0 + w, y: base))
        arch.closeSubpath()
        c.addPath(arch)
        c.fillPath()
        // Tracery: a centre mullion, a transom, a ring.
        black(c)
        c.fill(CGRect(x: s / 2 - s * 0.014, y: base, width: s * 0.028, height: spring - base + s * 0.04))
        c.fill(CGRect(x: x0, y: spring * 0.62, width: w, height: s * 0.022))
        c.setStrokeColor(gray: 0, alpha: 1)
        c.setLineWidth(s * 0.022)
        c.strokeEllipse(in: CGRect(x: s / 2 - s * 0.08, y: spring + s * 0.07, width: s * 0.16, height: s * 0.16))
    }

    private static func bars(_ c: CGContext, _ s: CGFloat) {
        disc(c, s)
        black(c)
        for k in 0..<7 {
            let x = s * (CGFloat(k) + 0.5) / 7
            c.fill(CGRect(x: x - s * 0.018, y: 0, width: s * 0.036, height: s))
        }
        c.fill(CGRect(x: 0, y: s * 0.18, width: s, height: s * 0.04))
        c.fill(CGRect(x: 0, y: s * 0.78, width: s, height: s * 0.04))
    }

    /// Leaves: dark ellipses at all angles over light, a few gaps.
    private static func leaves(_ c: CGContext, _ s: CGFloat, count: Int, seed: UInt64, open: Bool) {
        if open { disc(c, s) } else { white(c); c.fill(CGRect(x: 0, y: 0, width: s, height: s)) }
        black(c)
        var r = Grit(seed: seed)
        for _ in 0..<count {
            let x = r.unit() * s, y = r.unit() * s
            let l = s * (0.04 + 0.07 * r.unit()), w = l * (0.35 + 0.25 * r.unit())
            c.saveGState()
            c.translateBy(x: x, y: y)
            c.rotate(by: r.unit() * .pi)
            c.fillEllipse(in: CGRect(x: -l / 2, y: -w / 2, width: l, height: w))
            c.restoreGState()
        }
    }
    private static func leafGobo(_ c: CGContext, _ s: CGFloat) { leaves(c, s, count: 150, seed: 11, open: true) }
    private static func leafCookie(_ c: CGContext, _ s: CGFloat) { leaves(c, s, count: 120, seed: 23, open: false) }

    /// A plywood cookie: board with random rounded holes.
    private static func breakup(_ c: CGContext, _ s: CGFloat) {
        white(c)
        var r = Grit(seed: 37)
        for _ in 0..<38 {
            let x = r.unit() * s, y = r.unit() * s, rad = s * (0.025 + 0.06 * r.unit())
            let path = CGMutablePath()
            for k in 0..<10 {
                let a = CGFloat(k) / 10 * 2 * .pi
                let rr = rad * (0.7 + 0.5 * r.unit())
                let p = CGPoint(x: x + cos(a) * rr, y: y + sin(a) * rr * (0.6 + 0.6 * r.unit()))
                if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            c.addPath(path)
            c.fillPath()
        }
    }

    /// Bare branches: dark forking lines over light.
    private static func branches(_ c: CGContext, _ s: CGFloat) {
        white(c)
        c.fill(CGRect(x: 0, y: 0, width: s, height: s))
        c.setStrokeColor(gray: 0, alpha: 1)
        c.setLineCap(.round)
        var r = Grit(seed: 53)
        func branch(_ p: CGPoint, _ a: CGFloat, _ len: CGFloat, _ width: CGFloat, _ depth: Int) {
            guard depth > 0, len > 2 else { return }
            let q = CGPoint(x: p.x + cos(a) * len, y: p.y + sin(a) * len)
            c.setLineWidth(width)
            c.move(to: p)
            c.addLine(to: q)
            c.strokePath()
            for _ in 0..<2 {
                branch(q, a + (r.unit() - 0.5) * 1.3, len * (0.62 + 0.2 * r.unit()), width * 0.68, depth - 1)
            }
        }
        branch(CGPoint(x: s * 0.15, y: -s * 0.05), 1.15, s * 0.32, s * 0.05, 7)
        branch(CGPoint(x: s * 0.95, y: s * 0.1), 2.3, s * 0.28, s * 0.04, 6)
    }
}
