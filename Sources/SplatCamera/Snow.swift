import Foundation
import simd

/// Snow in a scene: flakes falling in a column of air round the camera (it moves
/// with you, wrapping, so it never reaches a scan's sky dome), snow settled on
/// what faces up and is open to the sky, and hoarfrost on everything the cold
/// reaches (most on fine, exposed detail). Set in the game (Menu > Lights > Snow)
/// or a .vcscene. All lengths in metres; `ground` in scan units along up.
struct SceneSnow: Codable, Equatable {
    /// How many flakes fill the falling column (0: none falling): the same at any
    /// scale, so a miniature snows as thickly as a forest.
    var density: Float = 0
    /// A flake's size (metres) and fall speed (m/s).
    var flakeM: Float = 0.006
    var fallMS: Float = 1.0
    /// Wind: speed (m/s), the way it blows (degrees round the up axis), gustiness (0...1).
    var windMS: Float = 0
    var windDeg: Float = 0
    var gust: Float = 0.3
    /// Snow lying on what faces up and is open to the sky (0...2: past 1 heavy, filling
    /// the bare spots and clinging to steeper faces), and hoarfrost (0...1).
    var settled: Float = 0
    var frost: Float = 0
    /// Snow lying with depth (metres, as the scene measures; nil or 0: none): real
    /// snow splats laid over what it lands on (SnowVolume).
    var depthM: Float? = nil
    /// 0 dry powder (piles like sand) ... 1 wet and sticky (caps wider than their base); nil: in between.
    var sticky: Float? = nil
    /// Snow indoors (or anywhere it never would): what stands well above the camera
    /// (a vault, a roof, beams) shelters nothing; the snow falls through it.
    var throughRoofs: Bool? = nil
    /// The height above the ground over which, falling through roofs, nothing shelters (metres).
    func roofCut(metresPerUnit mpu: Float, up: SIMD3<Float>) -> Float {
        let eye = max(0.01, (simd_dot(centre, up) - ground) * mpu)
        return eye * 1.6
    }
    /// The column of falling snow: its radius round the camera, and its ceiling above the ground.
    var radiusM: Float = 15
    var ceilingM: Float = 8
    /// The ground's height along up (scan units), and the middle of the snowfall
    /// for what settles (scan units): where the sky view looks down from.
    var ground: Float = 0
    var centre = SIMD3<Float>(0, 0, 0)

    var isEmpty: Bool { density <= 0 && settled <= 0 && frost <= 0 && (depthM ?? 0) <= 0 }
    static let maxFlakes = 40_000

    /// Two horizontal axes for `up` (as FlyCamera's horizon).
    static func horizon(_ up: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let seed: SIMD3<Float> = abs(up.x) < 0.9 ? [1, 0, 0] : [0, 0, 1]
        let a = simd_normalize(seed - simd_dot(seed, up) * up)
        return (a, simd_cross(up, a))
    }

    /// A flake's own constants (the same in the plain fall and riding a wind field).
    struct FlakeSpec { var u1, u2, u3, u4, sizeK, v, ph, fr, swing: Float }
    static func flakeSpec(_ i: UInt32, fallMS: Float) -> FlakeSpec {
        let u1 = hash(i, 1), u2 = hash(i, 2), u3 = hash(i, 3), u4 = hash(i, 4)
        // sizes spread as real snow does: mostly small, now and then a big clump
        let gsz = (-2 * log(max(hash(i, 7), 1e-6))).squareRoot() * cos(6.283 * hash(i, 8))
        let sizeK = min(4, exp(0.55 * gsz))
        let ph = hash(i, 5) * 6.283, fr = (0.5 + 1.2 * hash(i, 6)) * 2
        let swing = fallMS * (0.04 + 0.1 * hash(i, 9)) * (0.6 + 0.4 * sizeK)
        return FlakeSpec(u1: u1, u2: u2, u3: u3, u4: u4, sizeK: sizeK, v: fallMS * (0.65 + 0.5 * u4), ph: ph, fr: fr, swing: swing)
    }

    /// Gusts: how far the wind has risen at `tt` (1 the mean), and the bursts that blow
    /// even when there is no steady wind (0...1). The same for all flakes.
    private func gustRise(_ tt: Double) -> Double {
        1 + Double(gust) * (0.6 * sin(tt * 0.37) + 0.4 * sin(tt * 1.13 + 1.7))
    }
    private func gustBurst(_ tt: Double) -> Double {
        0.3 * (1 - cos(tt * 0.37)) + 0.2 * (1 - cos(tt * 1.13 + 1.7))
    }
    /// How hard the bursts blow at their peak (m/s, at full gustiness).
    private static let burstMS = 2.5

    /// The wind at `t` (m/s along the horizon's axes): the steady wind rising and
    /// falling with the gusts, the bursts, and the gusts swinging it a little.
    func windAt(_ t: Double) -> SIMD2<Float> {
        let tt = t.truncatingRemainder(dividingBy: 100_000)
        let speed = Double(windMS) * gustRise(tt) + Double(gust) * Self.burstMS * gustBurst(tt)
        let ang = Double(windDeg) * .pi / 180 + Double(gust) * 0.2 * sin(tt * 0.23)
        return SIMD2(Float(cos(ang) * speed), Float(sin(ang) * speed))
    }

    /// How far the wind has carried the air by `t` (metres, along the wind's way): the
    /// wind and its gusts summed over time (not wind x time x the gust now, which
    /// threw the flakes back and forth harder the longer a take ran).
    private func windTravel(_ t: Double) -> Double {
        let tt = t.truncatingRemainder(dividingBy: 100_000), g = Double(gust)
        let rise = tt + g * (0.6 * (1 - cos(tt * 0.37)) / 0.37 + 0.4 * (cos(1.7) - cos(tt * 1.13 + 1.7)) / 1.13)
        let burst = 0.3 * (tt - sin(tt * 0.37) / 0.37) + 0.2 * (tt - (sin(tt * 1.13 + 1.7) - sin(1.7)) / 1.13)
        return Double(windMS) * rise + g * Self.burstMS * burst
    }

    /// The air's slow eddies: a few waves of drift, the same for flakes close together,
    /// so they swirl as one; scaled to how fast the snow falls (metres, x y h).
    func eddy(_ x: Float, _ y: Float, _ h: Float, _ tt: Float) -> SIMD3<Float> {
        let L = max(0.2, 3 * fallMS)                       // an eddy's size (m)
        let amount = 0.35 * fallMS * (1 + 0.6 * gust) + 0.15 * windMS
        let k = 2 * Float.pi / L
        let ax = sin(k * (0.8 * y + 0.3 * h) + tt * 0.41) + 0.6 * sin(k * (1.7 * y - 0.9 * x) + tt * 0.83 + 2.1)
        let ay = sin(k * (0.9 * x - 0.2 * h) + tt * 0.37 + 1.3) + 0.6 * sin(k * (1.5 * x + 1.1 * y) + tt * 0.71 + 4.0)
        let az = 0.35 * sin(k * (0.7 * x + 0.6 * y) + tt * 0.53 + 0.7)
        return SIMD3(ax, ay, az) * amount * 0.6
    }

    /// The swirls a gust brings (m/s, x y h): spinning cells of air a metre or three
    /// across, carried along with the wind, rolling a little up and down; they
    /// build as a gust rises and die away with it. Spun from a stream function, so
    /// the air goes round rather than piling up.
    func gustSwirl(_ x: Float, _ y: Float, _ h: Float, _ t: Double) -> SIMD3<Float> {
        guard gust > 0 else { return .zero }
        let tt = t.truncatingRemainder(dividingBy: 100_000)
        let strength = Float(Double(gust) * (Self.burstMS * gustBurst(tt) + Double(windMS) * 0.35 * gustRise(tt)) * 0.7)
        guard strength > 1e-3 else { return .zero }
        // where the air that is here now was carried from (the swirls ride the wind)
        let wa = Double(windDeg) * .pi / 180, travel = windTravel(t)
        let X = Double(x) - cos(wa) * travel, Y = Double(y) - sin(wa) * travel
        func cells(_ L: Double, _ rot: Double, _ p1: Double, _ p2: Double) -> SIMD2<Float> {
            let k = 2 * .pi / L, c = cos(rot), s = sin(rot)
            let u = X * c + Y * s, v = -X * s + Y * c
            let a = k * u + p1, b = k * v + p2
            // psi = sin(a) sin(b): velocity (d psi/dv, -d psi/du) in the rotated frame, per k
            let du = sin(a) * cos(b), dv = -cos(a) * sin(b)
            return SIMD2(Float(du * c - dv * s), Float(du * s + dv * c))
        }
        let big = cells(2.6, 0.3, 0.31 * tt, 0.27 * tt + 1.1)
        let small = cells(1.3, 0.95, -0.47 * tt + 2.0, 0.41 * tt + 0.4)
        let hz = big + small * 0.5
        // rolls: the air lifting and dipping as the swirls pass
        let roll = Float(sin(2 * .pi / 2.2 * (X * cos(wa) + Y * sin(wa)) + 0.4 * tt)) * cos(Float(2 * .pi / 3.0) * h)
        // less near the ground (it drags the air)
        let drag: Float = min(1, max(0.25, h / 0.6))
        let k: Float = strength * drag
        return SIMD3<Float>(hz.x, hz.y, 0.45 * roll) * k
    }

    static func unit(_ i: UInt32, _ k: UInt32) -> Float { hash(i, k) }

    private static func hash(_ i: UInt32, _ k: UInt32) -> Float {
        var x = i &* 0x9E3779B1 ^ (k &* 0x85EBCA77)
        x ^= x >> 15; x = x &* 0x2C1B3C6D; x ^= x >> 12; x = x &* 0x297A2D39; x ^= x >> 15
        return Float(x & 0xFFFFFF) / Float(0x1000000)
    }

    /// The flakes at time `t` (seconds) round `eye`: positions (scan units) and
    /// their sizes (scan units), xyz + w. The same t gives the same snow: a take
    /// develops the same snowfall each time.
    func flakes(at t: Double, eye: SIMD3<Float>, up: SIMD3<Float>, metresPerUnit mpu: Float) -> [SIMD4<Float>] {
        guard density > 0, radiusM > 0, ceilingM > 0 else { return [] }
        // Two layers: the column round you, and a wider one four times as far, so it
        // snows through the whole scene, not only in front of the lens.
        let near = layer(at: t, eye: eye, up: up, mpu: mpu, R: radiusM, H: ceilingM,
                         n: min(Self.maxFlakes / 2, Int(density)), seed: 0)
        return near + farFlakes(at: t, eye: eye, up: up, metresPerUnit: mpu)
    }

    /// Whether there is any wind for flakes to ride (a field round the furniture).
    var windy: Bool { density > 0 && (windMS > 0 || gust > 0) }

    /// The wide, sparse layer of flakes beyond the column round the camera.
    func farFlakes(at t: Double, eye: SIMD3<Float>, up: SIMD3<Float>, metresPerUnit mpu: Float) -> [SIMD4<Float>] {
        guard density > 0, radiusM > 0, ceilingM > 0 else { return [] }
        let far = layer(at: t, eye: eye, up: up, mpu: mpu, R: radiusM * 4, H: ceilingM * 1.5,
                        n: min(Self.maxFlakes / 2, Int(density * 1.5)), seed: 1_000_003)
        return far
    }

    private func layer(at t: Double, eye: SIMD3<Float>, up: SIMD3<Float>, mpu: Float, R: Float, H: Float,
                       n: Int, seed: UInt32) -> [SIMD4<Float>] {
        guard n > 0 else { return [] }
        let (a, b) = Self.horizon(up)
        let tt = Float(t.truncatingRemainder(dividingBy: 100_000))
        let wa = Double(windDeg) * .pi / 180
        // how far the wind has carried the air (wrapped: the column repeats every 2R)
        let travel = windTravel(t)
        let period = Double(2 * R)
        let carried = SIMD2(Float((cos(wa) * travel).truncatingRemainder(dividingBy: period)),
                            Float((sin(wa) * travel).truncatingRemainder(dividingBy: period)))
        // The camera in metres, on the ground plane and up.
        let eyeA = simd_dot(eye, a) * mpu, eyeB = simd_dot(eye, b) * mpu
        let groundM = ground * mpu
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(n)
        for j in 0..<UInt32(n) {
            let i = j &+ seed
            let s = Self.flakeSpec(i, fallMS: fallMS)
            // each falls at its own pace, which rises and falls
            let v = s.v * (1 + 0.18 * sin(tt * (0.7 + s.u2) + s.u1 * 6.283))
            // drift with the wind (and gusts), flutter in a loose spiral as it falls
            let flutter = SIMD2(sin(tt * s.fr + s.ph), cos(tt * s.fr * 0.83 + s.ph * 1.3)) * s.swing
            let drift = carried + flutter
            var x = s.u1 * 2 * R + drift.x, y = s.u2 * 2 * R + drift.y
            // wrap round the camera: the column moves with you
            x = (x - eyeA + R).truncatingRemainder(dividingBy: 2 * R); if x < 0 { x += 2 * R }; x += eyeA - R
            y = (y - eyeB + R).truncatingRemainder(dividingBy: 2 * R); if y < 0 { y += 2 * R }; y += eyeB - R
            var h = (s.u3 * H - v * tt).truncatingRemainder(dividingBy: H); if h < 0 { h += H }
            // the gusts' swirls (here a sway of the flake about its path)
            let w = eddy(x, y, h, tt) + gustSwirl(x, y, h, t) * 0.6
            let pm = a * (x + w.x) + b * (y + w.y) + up * (groundM + h + w.z)
            out.append(SIMD4(pm / mpu, flakeM * s.sizeK / mpu))
        }
        return out
    }

    /// The flakes as one view sees them, sorted into 32-pixel bins for the
    /// shader (background_fill). `blur`: how much of the lens's blur circle to
    /// spread each flake by (0 in the finder's smooth mode, which blurs after).
    struct Binned {
        var flakes: [SIMD4<Float>] = []     // per drawn flake: (px, py, radius px, alpha), (ray depth, light index, streak px),
                                            // (its long axis cos, sin, how much longer than wide, -)
        var bins: [UInt32] = []             // per bin: start, count
        var index: [UInt32] = []            // flake numbers, bin by bin
        var binsW = 0, binsH = 0
        static let size = 32
    }

    static func bin(_ flakes: [SIMD4<Float>], later: [SIMD4<Float>]? = nil, view V: [Float], eye: SIMD3<Float>, fx: Float, cx: Float, cy: Float,
                    width W: Int, height H: Int, invFocus: Float, apertureUnits: Float, blur: Float, t: Double = 0) -> Binned {
        let tt = Float(t.truncatingRemainder(dividingBy: 100_000))
        var out = Binned()
        let bs = Binned.size
        out.binsW = (W + bs - 1) / bs
        out.binsH = (H + bs - 1) / bs
        var lists = [[UInt32]](repeating: [], count: out.binsW * out.binsH)
        var drawn: [SIMD4<Float>] = []
        drawn.reserveCapacity(flakes.count * 2)
        for (k, f) in flakes.enumerated() {
            let rel = SIMD3(f.x, f.y, f.z) - eye
            let xc = V[0] * rel.x + V[1] * rel.y + V[2] * rel.z
            let yc = V[4] * rel.x + V[5] * rel.y + V[6] * rel.z
            let zc = V[8] * rel.x + V[9] * rel.y + V[10] * rel.z
            guard f.w > 0, zc > f.w * 4 else { continue }        // landed; behind, or against the lens
            let px = cx + xc / zc * fx, py = cy + yc / zc * fx
            // where it is at the slice's end (a streak), unless it wrapped round the column
            var sx: Float = 0, sy: Float = 0
            if let later, k < later.count {
                let r2 = SIMD3(later[k].x, later[k].y, later[k].z) - eye
                let x2 = V[0] * r2.x + V[1] * r2.y + V[2] * r2.z, y2 = V[4] * r2.x + V[5] * r2.y + V[6] * r2.z
                let z2 = V[8] * r2.x + V[9] * r2.y + V[10] * r2.z
                if z2 > f.w * 4 && simd_distance(SIMD3(later[k].x, later[k].y, later[k].z), SIMD3(f.x, f.y, f.z)) < f.w * 400 {
                    sx = cx + x2 / z2 * fx - px; sy = cy + y2 / z2 * fx - py
                }
            }
            // its own size, and the lens's blur at its distance
            let r0 = max(0.5, f.w * 0.5 / zc * fx)
            let coc = fx * apertureUnits * abs(invFocus - 1 / zc) * blur
            let r = sqrt(r0 * r0 + coc * coc * 0.25)
            // a sub-pixel flake keeps its light: fainter, not bigger
            // flakes are lacy: some nearly solid, some faint
            let lace = 0.45 + 0.5 * hash(UInt32(k), 11)
            var alpha = min(1, lace * (max(f.w * 0.5 / zc * fx, 0.05) / r) * (max(f.w * 0.5 / zc * fx, 0.05) / r))
            // a streak spreads the same light along its length
            let len = (sx * sx + sy * sy).squareRoot()
            alpha *= r / (r + len * 0.5)
            guard alpha > 0.004 else { continue }
            let reach = r * 3 + len
            guard len.isFinite, px.isFinite, py.isFinite else { continue }
            let id = UInt32(drawn.count / 3)
            drawn.append(SIMD4(px, py, r, alpha))
            drawn.append(SIMD4(simd_length(rel), Float(k), sx, sy))
            // an irregular oval, tumbling as it falls (round again when blurred far out of focus)
            let ang = hash(UInt32(k), 12) * 6.283 + tt * (hash(UInt32(k), 13) - 0.5) * 6
            let sharpness = r0 / r
            // nearly round: the streak through the shutter gives the length, along its path
            let aspect = 1 + 0.25 * hash(UInt32(k), 14) * sharpness
            drawn.append(SIMD4(cos(ang), sin(ang), aspect, 0))
            let mx = px + sx * 0.5, my = py + sy * 0.5, rr = r * 3 + len * 0.5
            // (kept to the frame before turning into bin numbers: a long streak can run far off it)
            func binOf(_ v: Float, _ n: Int) -> Int { Int(max(-1, min(Float(n), (v / Float(bs)).rounded(.down)))) }
            let x0 = max(0, binOf(mx - rr, out.binsW)), x1 = min(out.binsW - 1, binOf(mx + rr, out.binsW))
            let y0 = max(0, binOf(my - rr, out.binsH)), y1 = min(out.binsH - 1, binOf(my + rr, out.binsH))
            guard x0 <= x1, y0 <= y1, (x1 - x0 + 1) * (y1 - y0 + 1) <= 400 else { continue }   // off the frame, or too faint to matter
            for by in y0...y1 { for bx in x0...x1 { lists[by * out.binsW + bx].append(id) } }
        }
        out.flakes = drawn.isEmpty ? [SIMD4<Float>](repeating: .zero, count: 3) : drawn
        out.bins.reserveCapacity(lists.count * 2)
        for l in lists {
            out.bins.append(UInt32(out.index.count))
            out.bins.append(UInt32(l.count))
            out.index += l
        }
        return out
    }
}
