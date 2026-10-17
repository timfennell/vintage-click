import AppKit
import simd

/// The loupe as rendered things, not drawn lines: every pixel of the barrel,
/// the zoom knob and the scale plate is shaded from a surface (a profile and
/// its normal, knurling as bumps, engraving cut in) and a material (glossy
/// black enamel, brass where it has worn through, scratches roughening it),
/// lit by the room as such a thing on a light table is: a soft window up and
/// to the left, and the table's glow along every steep side.
enum LoupeArt {
    // MARK: light and materials

    /// The room as the loupe sees it from where it lies: the window's
    /// direction, and how bright the table is in eight directions around it.
    struct Light: Equatable {
        var window = simd_normalize(SIMD3<Float>(-0.45, -0.6, 0.66))
        var table: [Float] = Array(repeating: 1, count: 8)

        func tableGlow(_ x: Float, _ y: Float) -> Float {
            let a = (atan2(y, x) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1) * 8
            let i = Int(a) % 8, j = (i + 1) % 8
            let t = a - floor(a)
            return table[i] + (table[j] - table[i]) * t
        }
    }

    /// Light arriving from direction `r` (x right, y down, z toward the eye),
    /// blurred by roughness: the window, the dim room, the table at grazing angles.
    static func environment(_ r: SIMD3<Float>, rough: Float, light: Light) -> SIMD3<Float> {
        let width: Float = 0.015 + rough * 0.35
        let d = simd_length_squared(r - light.window)
        let spot: Float = exp(-d / width) * (3.2 / (1 + rough * 5))
        let up = max(r.z, 0)
        let room: Float = 0.06 + 0.06 * up
        let table: Float = 1.25 * pow(1 - up, 4) * light.tableGlow(r.x, r.y)
        let warm = SIMD3<Float>(1.0, 0.97, 0.92), cool = SIMD3<Float>(0.92, 0.95, 1.0)
        return warm * spot + SIMD3<Float>(repeating: room) + cool * table
    }

    struct Surface {
        var normal: SIMD3<Float>
        var brass: Float          // 0 enamel ... 1 bare brass
        var rough: Float
        var cavity: Float = 0     // engraving and knurl valleys: less light gets in
        var paint: Float = 0      // white paint left in an engraving
        var patina: Float = 0     // brass darkened with age (0 bright ... 1 deep)
    }

    /// The colour seen of a surface point (linear light, before tone mapping).
    static func shade(_ s: Surface, light: Light) -> SIMD3<Float> {
        let n = simd_normalize(s.normal)
        let v = SIMD3<Float>(0, 0, 1)
        let nv = max(n.z, 0.001)
        let r = 2 * nv * n - v
        let enamelF0 = SIMD3<Float>(repeating: 0.045)
        // Old brass: deep and warm, darker still where it has tarnished.
        let fresh = SIMD3<Float>(0.80, 0.55, 0.24), aged = SIMD3<Float>(0.46, 0.29, 0.11)
        let brassF0 = fresh + (aged - fresh) * s.patina
        let f0 = enamelF0 + (brassF0 - enamelF0) * s.brass
        let fres = f0 + (SIMD3<Float>(repeating: 1) - f0) * pow(1 - nv, 5) * (1 - s.rough * 0.7) * (1 - 0.6 * s.brass)
        let spec = environment(r, rough: s.rough, light: light) * fres
        let enamelAlbedo = SIMD3<Float>(repeating: 0.022), brassAlbedo = SIMD3<Float>(0.16, 0.09, 0.03)
        let albedo = enamelAlbedo + (brassAlbedo - enamelAlbedo) * s.brass
        let irr: Float = 0.35 + 0.5 * max(0, simd_dot(n, light.window)) + 0.4 * (1 - n.z)
        var c = albedo * irr + spec
        c = c * (1 - 0.6 * s.cavity)
        c = c + (SIMD3<Float>(0.80, 0.80, 0.76) * irr - c) * s.paint
        return c
    }

    static func toByte(_ c: SIMD3<Float>, _ i: Int, _ px: inout [UInt8], alpha: Float) {
        // Soft shoulder, then sRGB, premultiplied.
        func one(_ x: Float) -> UInt8 {
            let t = x / (1 + x * 0.55) * 1.15
            let s = t <= 0.0031308 ? t * 12.92 : 1.055 * pow(t, 1 / 2.4) - 0.055
            return UInt8(max(0, min(255, s * alpha * 255)))
        }
        px[i] = one(c.x); px[i + 1] = one(c.y); px[i + 2] = one(c.z)
        px[i + 3] = UInt8(max(0, min(255, alpha * 255)))
    }

    // MARK: noise

    static func hash(_ x: Int32, _ y: Int32, _ seed: UInt32) -> Float {
        var h = UInt32(bitPattern: x) &* 374761393 &+ UInt32(bitPattern: y) &* 668265263 &+ seed &* 2246822519
        h = (h ^ (h >> 13)) &* 1274126177
        return Float(h ^ (h >> 16)) / Float(UInt32.max)
    }

    static func noise(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
        let xi = Int32(floor(x)), yi = Int32(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi, seed), b = hash(xi + 1, yi, seed)
        let c = hash(xi, yi + 1, seed), d = hash(xi + 1, yi + 1, seed)
        let top = a + (b - a) * sx, low = c + (d - c) * sx
        return top + (low - top) * sy
    }

    static func fbm(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
        var sum: Float = 0, amp: Float = 0.5, f: Float = 1
        for o in 0..<4 {
            sum += amp * noise(x * f, y * f, seed &+ UInt32(o) &* 31)
            amp *= 0.5
            f *= 2.03
        }
        return sum
    }

    /// A mask drawn with AppKit (engraving, scratches), read back per pixel.
    static func mask(_ w: Int, _ h: Int, _ draw: (NSGraphicsContext) -> Void) -> [UInt8] {
        var m = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &m, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return m }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = g
        draw(g)
        NSGraphicsContext.restoreGraphicsState()
        return m
    }

    static func image(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        var data = px
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    // MARK: the barrel

    /// The barrel's surface, worked out once: for each of its pixels, the
    /// normal, the materials, the engraving and scratches. Lighting comes later.
    struct BarrelMaps {
        var side = 0
        var index: [Int32] = []
        var surface: [Surface] = []
        var alpha: [Float] = []
        var glow: [Float] = []       // scratches catching light, and grain
    }

    /// The barrel ring around a glass of radius `R` (pixels), `band` wide,
    /// in an image `side` square centred on the glass.
    static func barrelMaps(R: Float, band: Float, side: Int, engraving: String) -> BarrelMaps {
        let c = Float(side) / 2
        // Engraving round the top and scratches, drawn as masks first.
        let engraved = mask(side, side) { _ in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Futura-Medium", size: CGFloat(band * 0.24)) ?? NSFont.systemFont(ofSize: CGFloat(band * 0.24)),
                .foregroundColor: NSColor.white,
            ]
            let r = CGFloat(R + band * 0.38)
            var a = -CGFloat.pi / 2 - 0.42
            for ch in engraving {
                let str = NSAttributedString(string: String(ch), attributes: attrs)
                let w = str.size().width
                NSGraphicsContext.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: CGFloat(c) + cos(a) * r, yBy: CGFloat(c) + sin(a) * r)
                t.rotate(byRadians: a + .pi / 2)
                t.concat()
                str.draw(at: NSPoint(x: -w / 2, y: -str.size().height / 2))
                NSGraphicsContext.restoreGraphicsState()
                a += (w + CGFloat(band) * 0.03) / r
            }
        }
        var rng = Grit(seed: 4242)
        let scratches = mask(side, side) { _ in
            NSColor.white.setStroke()
            for _ in 0..<70 {
                let a = rng.unit() * 2 * .pi
                let d = CGFloat(R) + CGFloat(band) * (0.1 + 0.85 * rng.unit())
                let l = CGFloat(band) * (0.2 + 1.4 * rng.unit())
                let t = a + .pi / 2 + rng.signed() * 0.8
                let o = NSPoint(x: CGFloat(c) + cos(a) * d, y: CGFloat(c) + sin(a) * d)
                let p = NSBezierPath()
                p.move(to: o)
                p.line(to: NSPoint(x: o.x + cos(t) * l, y: o.y + sin(t) * l))
                p.lineWidth = 0.6 + rng.unit() * 0.8
                p.stroke()
            }
        }
        var m = BarrelMaps()
        m.side = side
        let knurls: Float = 260
        for y in 0..<side {
            for x in 0..<side {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
                let rr = (dx * dx + dy * dy).squareRoot()
                let u = (rr - R) / band
                if u < -0.02 || u > 1.02 { continue }
                let alpha = max(0, min(1, (rr - R) + 0.5)) * max(0, min(1, (R + band - rr) + 0.5))
                if alpha <= 0 { continue }
                let radial = SIMD2<Float>(dx, dy) / max(rr, 1e-3)
                let tangent = SIMD2<Float>(-radial.y, radial.x)
                let theta = atan2(dy, dx)
                // The profile: slope across the band (+ rises outward) and knurl bumps.
                var slope: Float = 0, bump: Float = 0, cavity: Float = 0
                if u < 0.08 {
                    slope = 2.2                                     // the inner lip, rising from the glass
                } else if u < 0.66 {
                    let t = (u - 0.08) / 0.58
                    slope = cos(t * .pi) * 0.75                     // the rounded crown
                } else if u < 0.95 {
                    let k = sin(theta * knurls)
                    bump = 0.55 * k                                 // the knurled grip
                    cavity = 0.35 * max(0, -k)
                } else {
                    slope = -2.6                                    // the outer edge, falling away
                }
                let n2 = -radial * slope + tangent * bump
                var normal = SIMD3<Float>(n2.x, n2.y, 1)
                // Wear: through to the brass on the edges, and where hands hold it.
                let edge = max(max(0, 1 - u / 0.1), max(0, (u - 0.9) / 0.1))
                let held = 0.5 + 0.5 * cos(theta - 2.6) * cos(theta - 2.6)
                let w = fbm(theta * 9, u * 3, 7) * 0.9 + edge * 0.55 + held * 0.15
                var brass = max(0, min(1, (w - 0.78) * 9))
                // Pits and chips in the enamel.
                if fbm(theta * 60, u * 14, 19) > 0.78 { brass = max(brass, 0.85) }
                let i = y * side + x
                let sc = Float(scratches[i]) / 255
                let eg = Float(engraved[i]) / 255
                var rough: Float = 0.14 + 0.25 * brass + 0.35 * sc + 0.2 * fbm(theta * 20, u * 6, 3)
                if u >= 0.66 && u < 0.95 { rough += 0.15 }
                // The engraving: a cut groove, the paint mostly gone.
                normal += SIMD3<Float>(radial.x, radial.y, 0) * (eg * 0.8)
                let paint = eg * max(0, fbm(Float(x) * 0.3, Float(y) * 0.3, 11) - 0.35) * 1.6
                let patina = max(0, min(1, fbm(theta * 14, u * 5, 23) * 1.6 - 0.2))
                m.index.append(Int32(i))
                m.surface.append(Surface(normal: normal, brass: brass, rough: min(1, rough), cavity: cavity + eg * 0.5,
                                         paint: min(1, paint), patina: patina))
                m.alpha.append(alpha)
                m.glow.append(sc * 0.05 + (hash(Int32(x), Int32(y), 5) - 0.5) * 0.12)
            }
        }
        return m
    }

    /// The barrel lit by the room from where the loupe lies.
    static func shadeBarrel(_ m: BarrelMaps, light: Light) -> CGImage? {
        var px = [UInt8](repeating: 0, count: m.side * m.side * 4)
        for k in 0..<m.index.count {
            var col = shade(m.surface[k], light: light)
            col += SIMD3<Float>(repeating: max(0, m.glow[k]) * 0.4)
            col *= 1 + m.glow[k]
            toByte(col, Int(m.index[k]) * 4, &px, alpha: m.alpha[k])
        }
        return image(px, m.side, m.side)
    }

    // MARK: the knob

    /// The zoom knob seen from above, `radius` pixels: a knurled rim, a domed
    /// cap, a brass lock button. `turn` rotates its knurling (radians).
    static func knob(radius: Float, turn: Float, light: Light) -> CGImage? {
        let side = Int(ceil(radius * 2 + 4))
        let c = Float(side) / 2
        var px = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
                let rr = (dx * dx + dy * dy).squareRoot()
                let u = rr / radius
                if u > 1.02 { continue }
                let alpha = max(0, min(1, radius - rr + 0.5))
                let radial = SIMD2<Float>(dx, dy) / max(rr, 1e-3)
                let tangent = SIMD2<Float>(-radial.y, radial.x)
                let theta = atan2(dy, dx) - turn
                var slope: Float = 0, bump: Float = 0, cavity: Float = 0, brass: Float = 0, rough: Float = 0.16
                if u < 0.24 {
                    slope = -u / 0.24 * 0.9                          // the lock button, domed
                    brass = 0.92
                    rough = 0.12
                } else if u < 0.3 {
                    slope = 1.5                                     // its seat
                    cavity = 0.4
                } else if u < 0.62 {
                    slope = -(u - 0.3) / 0.32 * 0.5                  // the cap, gently domed
                } else if u < 0.93 {
                    let k = sin(theta * 28)
                    bump = 0.8 * k                                  // knurled rim
                    cavity = 0.4 * max(0, -k)
                    rough = 0.3
                    brass = max(0, (u - 0.86) * 8) * (0.6 + 0.4 * k)
                } else {
                    slope = -2.5
                    brass = 0.7
                }
                let n2 = -radial * slope + tangent * bump
                var col = shade(Surface(normal: SIMD3<Float>(n2.x, n2.y, 1), brass: min(1, brass), rough: rough, cavity: cavity,
                                        patina: 0.35), light: light)
                col *= 0.94 + 0.12 * hash(Int32(x), Int32(y), 9)
                toByte(col, (y * side + x) * 4, &px, alpha: alpha)
            }
        }
        return image(px, side, side)
    }

    // MARK: the scale plate

    /// Marks engraved in the glass along its edge, from angle `lo` to `hi`
    /// (radians, y down), radii `r0`...`r1` from the image centre: frosted cuts
    /// that scatter light, darker on their shadowed side; the glass itself clear.
    static func plate(side: Int, r0: Float, r1: Float, lo: Float, hi: Float,
                      marks: [(angle: Float, major: Bool, label: String?)], textSize: Float) -> CGImage? {
        let c = Float(side) / 2
        let cuts = mask(side, side) { _ in
            NSColor.white.setStroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Futura-Medium", size: CGFloat(textSize)) ?? NSFont.systemFont(ofSize: CGFloat(textSize)),
                .foregroundColor: NSColor.white,
            ]
            for m in marks {
                let a = CGFloat(m.angle)
                let len = CGFloat((r1 - r0) * (m.major ? 0.34 : 0.2))
                let t = NSBezierPath()
                t.move(to: NSPoint(x: CGFloat(c) + cos(a) * CGFloat(r1 - 1.5), y: CGFloat(c) + sin(a) * CGFloat(r1 - 1.5)))
                t.line(to: NSPoint(x: CGFloat(c) + cos(a) * (CGFloat(r1 - 1.5) - len), y: CGFloat(c) + sin(a) * (CGFloat(r1 - 1.5) - len)))
                t.lineWidth = m.major ? 1.8 : 1.1
                t.stroke()
                if let label = m.label {
                    let str = NSAttributedString(string: label, attributes: attrs)
                    let sz = str.size()
                    let rr = CGFloat(r0 + (r1 - r0) * 0.3)
                    NSGraphicsContext.saveGraphicsState()
                    let tr = NSAffineTransform()
                    tr.translateX(by: CGFloat(c) + cos(a) * rr, yBy: CGFloat(c) + sin(a) * rr)
                    tr.rotate(byRadians: a - .pi / 2)
                    tr.concat()
                    str.draw(at: NSPoint(x: -sz.width / 2, y: -sz.height / 2))
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let span = hi - lo
        for y in 0..<side {
            for x in 0..<side {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
                let rr = (dx * dx + dy * dy).squareRoot()
                if rr < r0 - 1 || rr > r1 + 1 { continue }
                var a = atan2(dy, dx)
                if a < lo - 0.3 { a += 2 * .pi }
                let along = (a - lo) / span
                if along < -0.01 || along > 1.01 { continue }
                let inside = max(0, min(1, rr - r0 + 0.5)) * max(0, min(1, r1 - rr + 0.5))
                    * max(0, min(1, along * span * rr + 0.5)) * max(0, min(1, (1 - along) * span * rr + 0.5))
                if inside <= 0 { continue }
                let i = y * side + x
                let cut = Float(cuts[i]) / 255
                // The cut's far wall catches light, its near wall is in shadow.
                let left = x > 0 ? Float(cuts[i - 1]) / 255 : 0
                let above = y > 0 ? Float(cuts[i - side]) / 255 : 0
                let shadowSide = max(0, left + above - 2 * cut) * 0.5
                // Only the marks: frosted cuts in otherwise clear glass, each
                // with a fine dark edge where its walls bend the light away.
                let right = x + 1 < side ? Float(cuts[i + 1]) / 255 : 0
                let below = y + 1 < side ? Float(cuts[i + side]) / 255 : 0
                let around = max(max(left, right), max(above, below))
                let rimDark = max(0, around - cut) * 0.9
                let frost = cut * (1 - shadowSide * 0.6)
                let alpha = min(1, (cut * 0.85 + shadowSide * 0.45 + rimDark * 0.65) * inside)
                let col = SIMD3<Float>(0.93, 0.96, 1.0) * frost + SIMD3<Float>(repeating: 0.03) * rimDark
                let lin = col / max(alpha, 0.001)
                toByte(lin * 0.9, i * 4, &px, alpha: alpha)
            }
        }
        return image(px, side, side)
    }
}
