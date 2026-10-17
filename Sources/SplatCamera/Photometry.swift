import Foundation
import simd

/// Where a light head's light actually goes: an intensity table (candela,
/// per colour) over angle off the beam axis and around it, made by tracing
/// rays through a model of the head's optics, not by a falloff formula.
///
/// Fresnel: a coiled tungsten filament with a spherical reflector behind it
/// (which sends the back half forward again, through the coil -- the coil
/// shades its own reflection) and a stepped Fresnel lens in front. The lamp
/// slides toward the lens to flood. What comes out: the image of the coil (a
/// hot core with a soft edge, a little taller than wide), a dark centre at
/// full flood, the lens's colour fringe at the beam edge, and stray light
/// off the steps of the lens.
///
/// Softlight: the lamps are hidden; all the light comes off a big white
/// trough at the back of an open box, so the beam is broad and the box walls
/// cut it off more quickly across the short side.
struct BeamTable {
    static let thetaBins = 32      // angle off axis, 0..90 degrees, finer near the axis
    static let phiBins = 8         // angle around the axis, 0..90 degrees (mirrored)
    static let power: Float = 1.3  // bin edges at 90 * (t / 32)^1.3 degrees: ~1 degree on axis
    var cd = [SIMD3<Float>](repeating: .zero, count: thetaBins * phiBins)   // candela per colour

    /// Edge t of the off-axis bins (radians), t in 0...thetaBins.
    static func edge(_ t: Float) -> Float { pow(t / Float(thetaBins), power) * .pi / 2 }
    /// Middle of bin t: where its value sits.
    static func theta(_ t: Float) -> Float { edge(t + 0.5) }
    static func bin(_ theta: Float) -> Int {
        min(thetaBins - 1, Int(pow(max(0, theta) / (.pi / 2), 1 / power) * Float(thetaBins)))
    }

    /// Off-axis profile (green, averaged around the axis, lightly smoothed).
    private var profile: [Float] {
        var prof = [Float](repeating: 0, count: Self.thetaBins)
        for t in 0..<Self.thetaBins {
            for p in 0..<Self.phiBins { prof[t] += cd[t * Self.phiBins + p].y / Float(Self.phiBins) }
        }
        return (0..<Self.thetaBins).map { t in
            let a = prof[max(0, t - 1)], c = prof[min(Self.thetaBins - 1, t + 1)]
            return 0.25 * a + 0.5 * prof[t] + 0.25 * c
        }
    }

    var peak: Float { profile.max() ?? 0 }
    var centre: Float { profile[0] }

    /// Full angle (degrees) where the beam falls to this fraction of its peak,
    /// going out from the peak: 0.9 hot spot, 0.5 beam, 0.1 field.
    func angle(at fraction: Float) -> Float {
        let prof = profile
        let top = prof.max() ?? 0
        guard top > 0, let first = prof.firstIndex(of: top) else { return 0 }
        for t in first..<(Self.thetaBins - 1) where prof[t + 1] < top * fraction {
            let f = (prof[t] - top * fraction) / max(prof[t] - prof[t + 1], 1e-9)
            let th = Self.theta(Float(t)) + (Self.theta(Float(t + 1)) - Self.theta(Float(t))) * f
            return 2 * th * 180 / .pi
        }
        return 180
    }

    static func mix(_ a: BeamTable, _ b: BeamTable, _ t: Float) -> BeamTable {
        var o = BeamTable()
        for i in 0..<o.cd.count { o.cd[i] = a.cd[i] + (b.cd[i] - a.cd[i]) * t }
        return o
    }
}

enum Photometry {
    /// The optics of each kit head: Fresnel lens radius and focal length (m),
    /// coil radius and length (m).
    struct FresnelOptics { let lensR: Float, focal: Float, coilR: Float, coilL: Float }

    static func optics(_ head: LightHead) -> FresnelOptics {
        switch head.lumens {
        case ..<6000: return FresnelOptics(lensR: 0.05, focal: 0.080, coilR: 0.003, coilL: 0.010)    // 650 W, 4" lens
        case ..<10000: return FresnelOptics(lensR: 0.075, focal: 0.115, coilR: 0.004, coilL: 0.014)  // 1 kW, 6"
        default: return FresnelOptics(lensR: 0.10, focal: 0.150, coilR: 0.005, coilL: 0.018)          // 2 kW, 8"
        }
    }

    private static let lock = NSLock()
    private static var cache: [Int: [BeamTable]] = [:]     // head -> tables from flood (0) to spot (8)
    static let steps = 9

    /// The head's beam at this spot/flood setting (0 = full flood, 1 = full spot).
    static func table(head: Int, spot: Float) -> BeamTable {
        let tables = tablesFor(head)
        let x = max(0, min(1, spot)) * Float(steps - 1)
        let i = min(Int(x), steps - 2)
        return BeamTable.mix(tables[i], tables[i + 1], x - Float(i))
    }

    static func tablesFor(_ head: Int) -> [BeamTable] {
        lock.lock()
        if let t = cache[head] { lock.unlock(); return t }
        lock.unlock()
        let kit = lightKit[head]
        var tables: [BeamTable]
        switch kit.kind {
        case .softlight:
            let t = softlight(kit)
            tables = Array(repeating: t, count: steps)
        case .fresnel:
            let o = optics(kit)
            // Calibrate to the head's published angles: the stipple on the lens
            // (which smooths the beam) sets the full spot, the lamp's closest
            // approach to the lens the full flood.
            let k: Float = 0.04
            var lo: Float = 0, hi: Float = 0.25
            for _ in 0..<10 {
                let d = (lo + hi) / 2
                let a = fresnel(kit, o, lampAt: o.focal, aberration: k, stipple: d, rays: 60_000).angle(at: 0.5)
                if a < kit.spotAngle { lo = d } else { hi = d }
            }
            let stipple = (lo + hi) / 2
            var nearLo: Float = 0.2, nearHi: Float = 1.0
            for _ in 0..<10 {
                let m = (nearLo + nearHi) / 2
                let a = fresnel(kit, o, lampAt: o.focal * m, aberration: k, stipple: stipple, rays: 60_000).angle(at: 0.5)
                if a > kit.floodAngle { nearLo = m } else { nearHi = m }
            }
            let flood = (nearLo + nearHi) / 2
            tables = (0..<steps).map { i in
                let t = Float(i) / Float(steps - 1)
                // Spot/flood knob: even steps in beam angle feel right, so ease the lamp travel.
                let s = o.focal * (flood + (1 - flood) * pow(t, 0.6))
                return fresnel(kit, o, lampAt: s, aberration: k, stipple: stipple, rays: 400_000)
            }
        }
        lock.lock()
        cache[head] = tables
        lock.unlock()
        return tables
    }

    // MARK: ray tracing

    private struct Rng {
        var s: UInt64
        mutating func next() -> Float {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float((s >> 40) & 0xFFFFFF) / 16777216
        }
    }

    private static func accumulate(_ hist: inout [SIMD3<Float>], dir d: SIMD3<Float>, w: SIMD3<Float>) {
        guard d.z > 0 else { return }
        let theta = acos(min(1, d.z))
        let phi = atan2(abs(d.y), abs(d.x))
        let t = BeamTable.bin(theta)
        let p = min(BeamTable.phiBins - 1, Int(phi / (.pi / 2) * Float(BeamTable.phiBins)))
        hist[t * BeamTable.phiBins + p] += w
    }

    /// Histogram of ray energy -> candela, scaled so the total is the head's lumens.
    private static func toTable(_ hist: [SIMD3<Float>], lumens: Float) -> BeamTable {
        var table = BeamTable()
        var total = SIMD3<Float>(repeating: 0)
        for v in hist { total += v }
        let norm = SIMD3<Float>(repeating: lumens) / simd_max(total, SIMD3(repeating: 1e-9))
        for t in 0..<BeamTable.thetaBins {
            // Solid angle of this bin's ring segment.
            let a = BeamTable.edge(Float(t)), b = BeamTable.edge(Float(t + 1))
            let ring = 2 * Float.pi * (cos(a) - cos(b)) / Float(BeamTable.phiBins)
            for p in 0..<BeamTable.phiBins {
                table.cd[t * BeamTable.phiBins + p] = hist[t * BeamTable.phiBins + p] * norm / max(ring, 1e-6)
            }
        }
        return table
    }

    /// Lens at z = 0 (beam along +z), coil centred at z = -lampAt, upright (along y).
    static func fresnel(_ kit: LightHead, _ o: FresnelOptics, lampAt s: Float, aberration k: Float,
                        stipple: Float, rays: Int) -> BeamTable {
        var rng = Rng(s: 0x9E3779B97F4A7C15 &+ UInt64(s * 1e6))
        var hist = [SIMD3<Float>](repeating: .zero, count: BeamTable.thetaBins * BeamTable.phiBins)
        let centre = SIMD3<Float>(0, 0, -s)
        // The lens bends blue a little more than red: its colour fringe.
        let focal = SIMD3<Float>(o.focal * 1.012, o.focal, o.focal * 0.988)
        for _ in 0..<rays {
            // A point on the coil.
            let a = rng.next() * 2 * .pi
            var p = centre + SIMD3(o.coilR * cos(a), (rng.next() - 0.5) * o.coilL, o.coilR * sin(a))
            var w: Float = 1
            // Half the light leaves backwards: the reflector images it back through
            // the coil's centre (inverted), and the coil shades some of it.
            let reflected = rng.next() < 0.5
            if reflected {
                p = 2 * centre - p
                w = 0.85
            }
            // Toward a point on the lens.
            let r = o.lensR * sqrt(rng.next()), b = rng.next() * 2 * .pi
            let lp = SIMD3<Float>(r * cos(b), r * sin(b), 0)
            let v = lp - p
            let dist = simd_length(v)
            let din = v / dist
            w *= din.z / (dist * dist)                      // the lens area as the coil sees it
            if reflected {
                // Passing back through the coil: blocked where it crosses it.
                let tc = simd_dot(centre - p, din)
                let closest = p + din * tc - centre
                if abs(closest.y) < o.coilL / 2 && simd_length(SIMD2(closest.x, closest.z)) < o.coilR * 0.9 { w *= 0.25 }
            }
            w *= 0.85                                       // lens transmission
            if rng.next() < 0.06 {
                // Off the risers of the lens steps: stray light into a wide glow.
                let u = rng.next(), c = rng.next() * 2 * .pi
                let st = sqrt(u) * 0.9
                let d = SIMD3<Float>(st * cos(c), st * sin(c), sqrt(max(0, 1 - st * st)))
                accumulate(&hist, dir: d, w: SIMD3(repeating: w))
                continue
            }
            // Thin-lens refraction, per colour, with the lens's spherical aberration
            // (outer zones bend too much) and the stippled surface's scatter.
            let sx = din.x / din.z, sy = din.y / din.z
            let rr = r / o.lensR
            let sa = k * rr * rr * rr
            let rad = r > 1e-6 ? SIMD2<Float>(lp.x, lp.y) / r : SIMD2<Float>(1, 0)
            // Stipple: a roughly Gaussian spread of directions (sum of uniforms).
            let jitter = SIMD2<Float>(rng.next() + rng.next() + rng.next() - 1.5,
                                      rng.next() + rng.next() + rng.next() - 1.5) * (stipple * 2)
            for c in 0..<3 {
                let ox = sx - lp.x / focal[c] - sa * rad.x + jitter.x
                let oy = sy - lp.y / focal[c] - sa * rad.y + jitter.y
                let d = simd_normalize(SIMD3<Float>(ox, oy, 1))
                var wc = SIMD3<Float>(repeating: 0)
                wc[c] = w
                accumulate(&hist, dir: d, w: wc)
            }
        }
        return toTable(hist, lumens: kit.lumens)
    }

    /// Open-fronted box (opening w x h at z = 0, depth d) with a white
    /// diffusing trough at the back; the box walls absorb.
    static func softlight(_ kit: LightHead) -> BeamTable {
        var rng = Rng(s: 0xC0FFEE)
        var hist = [SIMD3<Float>](repeating: .zero, count: BeamTable.thetaBins * BeamTable.phiBins)
        let w = kit.size.x, h = kit.size.y, depth = kit.size.z
        for _ in 0..<400_000 {
            // A point on the trough (curved top to bottom), diffuse (cosine) emission.
            let x = (rng.next() - 0.5) * w * 0.95, y = (rng.next() - 0.5) * h * 0.95
            let z = -depth * (1 - 0.5 * pow(2 * y / h, 2))
            let u = rng.next(), c = rng.next() * 2 * .pi
            let st = sqrt(u)
            let d = SIMD3<Float>(st * cos(c), st * sin(c), sqrt(max(0, 1 - u)))
            // Out through the opening, or lost on the walls.
            let t = -z / d.z
            let ox = x + d.x * t, oy = y + d.y * t
            guard abs(ox) < w / 2, abs(oy) < h / 2 else { continue }
            accumulate(&hist, dir: d, w: SIMD3(repeating: 1))
        }
        return toTable(hist, lumens: kit.lumens)
    }
}
