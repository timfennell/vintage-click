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
    /// Snow lying on what faces up and is open to the sky (0...1), and hoarfrost (0...1).
    var settled: Float = 0
    var frost: Float = 0
    /// The column of falling snow: its radius round the camera, and its ceiling above the ground.
    var radiusM: Float = 15
    var ceilingM: Float = 8
    /// The ground's height along up (scan units), and the middle of the snowfall
    /// for what settles (scan units): where the sky view looks down from.
    var ground: Float = 0
    var centre = SIMD3<Float>(0, 0, 0)

    var isEmpty: Bool { density <= 0 && settled <= 0 && frost <= 0 }
    static let maxFlakes = 40_000

    /// Two horizontal axes for `up` (as FlyCamera's horizon).
    static func horizon(_ up: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let seed: SIMD3<Float> = abs(up.x) < 0.9 ? [1, 0, 0] : [0, 0, 1]
        let a = simd_normalize(seed - simd_dot(seed, up) * up)
        return (a, simd_cross(up, a))
    }

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
        let R = radiusM, H = ceilingM
        let n = min(Self.maxFlakes, Int(density))
        guard n > 0 else { return [] }
        let (a, b) = Self.horizon(up)
        let tt = Float(t.truncatingRemainder(dividingBy: 100_000))
        let wa = windDeg * .pi / 180
        let wind = SIMD2<Float>(cos(wa), sin(wa)) * windMS
        // Gusts: the wind rises and falls, slowly, the same for all.
        let g = 1 + gust * (0.6 * sin(tt * 0.37) + 0.4 * sin(tt * 1.13 + 1.7))
        // The camera in metres, on the ground plane and up.
        let eyeA = simd_dot(eye, a) * mpu, eyeB = simd_dot(eye, b) * mpu
        let groundM = ground * mpu
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(n)
        for i in 0..<UInt32(n) {
            let u1 = Self.hash(i, 1), u2 = Self.hash(i, 2), u3 = Self.hash(i, 3), u4 = Self.hash(i, 4)
            let v = fallMS * (0.7 + 0.6 * u4)
            let ph = Self.hash(i, 5) * 6.283, fr = 0.4 + 0.8 * Self.hash(i, 6)
            // drift with the wind (and gusts), sway as it falls
            let drift = wind * (tt * g) + SIMD2(sin(tt * fr + ph), cos(tt * fr * 0.8 + ph)) * (0.15 + 0.1 * u4)
            var x = u1 * 2 * R + drift.x, y = u2 * 2 * R + drift.y
            // wrap round the camera: the column moves with you
            x = (x - eyeA + R).truncatingRemainder(dividingBy: 2 * R); if x < 0 { x += 2 * R }; x += eyeA - R
            y = (y - eyeB + R).truncatingRemainder(dividingBy: 2 * R); if y < 0 { y += 2 * R }; y += eyeB - R
            var h = (u3 * H - v * tt).truncatingRemainder(dividingBy: H); if h < 0 { h += H }
            let pm = a * x + b * y + up * (groundM + h)
            let size = flakeM * (0.5 + Self.hash(i, 7))
            out.append(SIMD4(pm / mpu, size / mpu))
        }
        return out
    }

    /// The flakes as one view sees them, sorted into 32-pixel bins for the
    /// shader (background_fill). `blur`: how much of the lens's blur circle to
    /// spread each flake by (0 in the finder's smooth mode, which blurs after).
    struct Binned {
        var flakes: [SIMD4<Float>] = []     // per drawn flake: (px, py, radius px, alpha), (ray depth, light index, -, -)
        var bins: [UInt32] = []             // per bin: start, count
        var index: [UInt32] = []            // flake numbers, bin by bin
        var binsW = 0, binsH = 0
        static let size = 32
    }

    static func bin(_ flakes: [SIMD4<Float>], later: [SIMD4<Float>]? = nil, view V: [Float], eye: SIMD3<Float>, fx: Float, cx: Float, cy: Float,
                    width W: Int, height H: Int, invFocus: Float, apertureUnits: Float, blur: Float) -> Binned {
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
            guard zc > f.w * 4 else { continue }        // behind, or against the lens
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
            var alpha = min(1, 0.85 * (max(f.w * 0.5 / zc * fx, 0.05) / r) * (max(f.w * 0.5 / zc * fx, 0.05) / r))
            // a streak spreads the same light along its length
            let len = (sx * sx + sy * sy).squareRoot()
            alpha *= r / (r + len * 0.5)
            guard alpha > 0.004 else { continue }
            let reach = r * 3 + len
            guard len.isFinite, px.isFinite, py.isFinite else { continue }
            let id = UInt32(drawn.count / 2)
            drawn.append(SIMD4(px, py, r, alpha))
            drawn.append(SIMD4(simd_length(rel), Float(k), sx, sy))
            let mx = px + sx * 0.5, my = py + sy * 0.5, rr = r * 3 + len * 0.5
            // (kept to the frame before turning into bin numbers: a long streak can run far off it)
            func binOf(_ v: Float, _ n: Int) -> Int { Int(max(-1, min(Float(n), (v / Float(bs)).rounded(.down)))) }
            let x0 = max(0, binOf(mx - rr, out.binsW)), x1 = min(out.binsW - 1, binOf(mx + rr, out.binsW))
            let y0 = max(0, binOf(my - rr, out.binsH)), y1 = min(out.binsH - 1, binOf(my + rr, out.binsH))
            guard x0 <= x1, y0 <= y1, (x1 - x0 + 1) * (y1 - y0 + 1) <= 400 else { continue }   // off the frame, or too faint to matter
            for by in y0...y1 { for bx in x0...x1 { lists[by * out.binsW + bx].append(id) } }
        }
        out.flakes = drawn.isEmpty ? [SIMD4<Float>](repeating: .zero, count: 2) : drawn
        out.bins.reserveCapacity(lists.count * 2)
        for l in lists {
            out.bins.append(UInt32(out.index.count))
            out.bins.append(UInt32(l.count))
            out.index += l
        }
        return out
    }
}
