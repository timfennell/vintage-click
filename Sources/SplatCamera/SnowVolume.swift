import Foundation
import simd

/// Snow with depth: real white splats laid where snow lies. Where it lands is read
/// straight from the scan's splats, not from a rendered view: each splat drops into
/// a column of a grid laid level over the snowfall (truly vertical, no perspective),
/// and each column keeps a stack of height bins, a layer cake, so it finds not only
/// the top surface but those beneath (the ground under a table, under branches).
/// The top takes the snow; a surface beneath takes what the wind drifts in, the more
/// the higher the open space above it.
/// How deep: the depth asked for, the build-up score (hollows and corners gather,
/// ridges shed, the lee of what stands upwind drifts), the slope (flat holds it all,
/// 45 degrees a fifth) and how wide the support is (snow piles only about as high
/// as its support is wide: domed caps on posts and stones; wet snow taller, its caps
/// bulging out past their edges, powder sloping down like sand). All in metres.
enum SnowVolume {
    struct Splats {
        var means: [Float] = [], quats: [Float] = [], scales: [Float] = [], opacities: [Float] = [], dc: [Float] = []
        var count: Int { opacities.count }
        mutating func append(_ o: Splats) {
            means += o.means; quats += o.quats; scales += o.scales; opacities += o.opacities; dc += o.dc
        }
    }

    static func build(model m: SplatModel, snow: SceneSnow, up: SIMD3<Float>, metresPerUnit mpu: Float) -> Splats {
        let depthM = snow.depthM ?? 0
        guard depthM > 0 else { return Splats() }
        let (ax, bx) = SceneSnow.horizon(up)
        let hc = snow.centre - up * simd_dot(snow.centre, up)
        let groundM = snow.ground * mpu
        var zhi = groundM + max(snow.ceilingM, depthM * 4)
        // falling through roofs: what stands well above the camera is left out
        if snow.throughRoofs == true { zhi = min(zhi, groundM + max(snow.roofCut(metresPerUnit: mpu, up: up), depthM * 4)) }
        let hcA = simd_dot(hc, ax) * mpu, hcB = simd_dot(hc, bx) * mpu
        // Throughout the scene: the grid spans every splat in the band snow lands in
        // (a sample, trimmed of the farthest stragglers).
        var us: [Float] = [], vs: [Float] = []
        let sampleStep = max(1, m.count / 200_000)
        var zmin0: Float = 1e30
        for i in stride(from: 0, to: m.count, by: sampleStep) {
            let p = SIMD3(m.means[3 * i], m.means[3 * i + 1], m.means[3 * i + 2])
            let z = simd_dot(p, up) * mpu
            guard z < zhi else { continue }
            us.append(abs(simd_dot(p, ax) * mpu - hcA)); vs.append(abs(simd_dot(p, bx) * mpu - hcB))
            zmin0 = min(zmin0, z)
        }
        us.sort(); vs.sort()
        let pick = { (a: [Float]) -> Float in a.isEmpty ? snow.radiusM * 3 : a[Int(Float(a.count - 1) * 0.985)] }
        let Rm = max(snow.radiusM, min(max(pick(us), pick(vs)) * 1.05, snow.radiusM * 40))
        let N = 1024
        let cell = 2 * Rm / Float(N)                          // metres per cell
        let zlo = groundM - max(depthM * 2, (zhi - groundM) * 0.25)
        let Z = max(8, min(96, Int((zhi - zlo) / cell)))
        let dz = (zhi - zlo) / Float(Z)
        // the layer cake: how much splat stands in each cell's height bins
        var occ = [UInt8](repeating: 0, count: N * N * Z)
        // How far overhead cover still shelters: it falls off with the height of the
        // cover, in proportion to the scene (a miniature behaves like the place).
        let shelterL = max(depthM * 4, Rm * 0.12)
        for i in 0..<m.count {
            let op = 1 / (1 + exp(-m.opacities[i]))
            guard op > 0.25 else { continue }
            let p = SIMD3(m.means[3 * i], m.means[3 * i + 1], m.means[3 * i + 2])
            let z = simd_dot(p, up) * mpu
            guard z > zlo, z < zhi else { continue }
            let u = (simd_dot(p, ax) * mpu - hcA + Rm) / cell, v = (simd_dot(p, bx) * mpu - hcB + Rm) / cell
            guard u >= 0, v >= 0, u < Float(N), v < Float(N) else { continue }
            let big = exp(max(m.scales[3 * i], max(m.scales[3 * i + 1], m.scales[3 * i + 2]))) * mpu
            let rc = min(2, Int(big * 1.2 / cell))           // a big splat covers a few cells
            let zi = min(Z - 1, Int((z - zlo) / dz))
            let add = Int(min(200, op * 50))
            let ui = Int(u), vi = Int(v)
            for dv in -rc...rc { for du in -rc...rc {
                let uu = ui + du, vv = vi + dv
                guard uu >= 0, vv >= 0, uu < N, vv < N else { continue }
                let k = (vv * N + uu) * Z + zi
                occ[k] = UInt8(min(255, Int(occ[k]) + add))
            } }
        }
        // each column's surfaces, from the top: solid bins with open air above them
        let solid: UInt8 = 30
        var top = [Float](repeating: -1e30, count: N * N)      // the highest surface (metres)
        var low = [Float](repeating: -1e30, count: N * N)      // the next one down, under cover
        var gap = [Float](repeating: 0, count: N * N)          // open height over the lower surface
        for k in 0..<(N * N) {
            let base = k * Z
            var z = Z - 1
            while z >= 0 && occ[base + z] < solid { z -= 1 }
            guard z >= 0 else { continue }
            top[k] = zlo + (Float(z) + 1) * dz
            var zz = z
            var mass = 0
            while zz >= 0 && occ[base + zz] >= solid { mass += Int(occ[base + zz]); zz -= 1 }
            let openTop = zz
            // thin branches and twigs are no roof: the snow falls past them
            if mass < 200 {
                var g = zz
                while g >= 0 && occ[base + g] < solid { g -= 1 }
                if g >= 0 && openTop - g >= 3 { top[k] = zlo + (Float(g) + 1) * dz; continue }
            }
            while zz >= 0 && occ[base + zz] < solid { zz -= 1 }
            if zz >= 0 && openTop - zz >= 3 {
                low[k] = zlo + (Float(zz) + 1) * dz
                gap[k] = Float(openTop - zz) * dz
            }
        }
        let wa = snow.windDeg * .pi / 180
        let windDir = SIMD2<Float>(cos(wa), sin(wa)), wind01 = min(1, snow.windMS / 6)
        let world: (Int, Float) -> SIMD3<Float> = { k, hM in
            let u = (Float(k % N) + 0.5) * cell - Rm, v = (Float(k / N) + 0.5) * cell - Rm
            return hc + ax * (u / mpu) + bx * (v / mpu) + up * (hM / mpu)
        }
        var out = Splats()
        let topScore = score(top, N: N, cell: cell, windDir: windDir, wind: wind01)
        out.append(lay(top, depth: { k in depthM * (0.4 + 0.6 * topScore[k]) }, N: N, cell: cell, world: world,
                       up: up, along: ax, across: bx, mpu: mpu, sticky: snow.sticky ?? 0.5, depthM: depthM))
        // beneath: what falls through the gaps in the cover round it, and what the wind
        // drifts in (the more the higher the open space over it), blending into the open
        var covered = [Float](repeating: 0, count: N * N)
        for k in 0..<(N * N) where low[k] > -1e29 { covered[k] = 1 }
        let rc = max(3, Int(1.0 / cell))
        covered = boxBlur(covered, N: N, r: rc)
        let drift = 0.1 + 0.6 * wind01
        out.append(lay(low, depth: { k in
            // shelter: how much cover is round about, how close overhead, less what the wind drifts in
            let shelter = (1 - drift) * covered[k] * 0.9 * exp(-gap[k] / shelterL)
            return depthM * (1 - shelter) * min(1, gap[k] / max(depthM * 3, cell * 3))
        }, N: N, cell: cell,
                       world: world, up: up, along: ax, across: bx, mpu: mpu, sticky: snow.sticky ?? 0.5, depthM: depthM))
        return out
    }

    static func boxBlur(_ a: [Float], N: Int, r: Int) -> [Float] {
        var t = a, o = a
        for y in 0..<N {
            var s: Float = 0
            for x in -r...r { s += a[y * N + max(0, min(N - 1, x))] }
            for x in 0..<N {
                t[y * N + x] = s / Float(2 * r + 1)
                s += a[y * N + min(N - 1, x + r + 1)] - a[y * N + max(0, x - r)]
            }
        }
        for x in 0..<N {
            var s: Float = 0
            for y in -r...r { s += t[max(0, min(N - 1, y)) * N + x] }
            for y in 0..<N {
                o[y * N + x] = s / Float(2 * r + 1)
                s += t[min(N - 1, y + r + 1) * N + x] - t[max(0, y - r) * N + x]
            }
        }
        return o
    }

    /// How much gathers at each place of a height map (1 plain, 0 bare, 2 deep).
    static func score(_ h: [Float], N: Int, cell: Float, windDir: SIMD2<Float>, wind: Float) -> [Float] {
        var s = [Float](repeating: 1, count: N * N)
        func at(_ x: Int, _ y: Int, _ k: Int) -> Float {
            let xx = max(0, min(N - 1, x)), yy = max(0, min(N - 1, y))
            let v = h[yy * N + xx]
            return v > -1e29 ? v : h[k]
        }
        let r0 = max(2, Int(0.3 / cell)), r1 = max(4, Int(1.5 / cell))
        for y in 0..<N { for x in 0..<N {
            let k = y * N + x
            guard h[k] > -1e29 else { continue }
            var acc: Float = 1
            for (r, w, sc) in [(r0, Float(0.9), Float(0.15)), (r1, Float(0.6), Float(0.4))] {
                var sum: Float = 0
                for (dx, dy) in [(r, 0), (-r, 0), (0, r), (0, -r), (r, r), (-r, -r), (r, -r), (-r, r)] { sum += at(x + dx, y + dy, k) }
                acc += w * max(-1, min(1.5, (sum / 8 - h[k]) / sc))
            }
            if wind > 0.01 {
                var lee: Float = 0
                for i in 1...12 {
                    let d = Float(i) * 0.25
                    let hu = at(x - Int(windDir.x * d / cell), y - Int(windDir.y * d / cell), k)
                    lee = max(lee, (hu - h[k]) - d * 0.2)
                }
                acc += wind * 1.8 * max(0, min(1.5, lee / 0.15))
            }
            s[k] = max(0, min(2, acc))
        } }
        return s
    }

    /// Snow splats over one layer's height map: deep as `depth` asks, no higher than
    /// its support's width allows, rounded within each support, its sides hanging over.
    static func lay(_ h: [Float], depth: (Int) -> Float, N: Int, cell f: Float, world: (Int, Float) -> SIMD3<Float>,
                    up: SIMD3<Float>, along rgt: SIMD3<Float>, across dn: SIMD3<Float>, mpu: Float,
                    sticky: Float, depthM: Float) -> Splats {
        func valid(_ k: Int) -> Bool { h[k] > -1e29 }
        let stk = max(0, min(1, sticky))
        let pileK = 0.55 + 1.6 * stk * stk
        let hangK = 0.02 + 0.55 * stk
        let step = max(depthM * 0.25, f * 2)
        var dist = [Float](repeating: 1e9, count: N * N)
        for y in 0..<N { for x in 0..<N {
            let k = y * N + x
            guard valid(k) else { continue }
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let xx = x + dx, yy = y + dy
                if xx < 0 || yy < 0 || xx >= N || yy >= N { dist[k] = 0; break }
                let kk = yy * N + xx
                if !valid(kk) || h[k] - h[kk] > step { dist[k] = 0; break }
            }
        } }
        for y in 0..<N { for x in 0..<N {
            let k = y * N + x
            if x > 0 { dist[k] = min(dist[k], dist[k - 1] + 1) }
            if y > 0 { dist[k] = min(dist[k], dist[k - N] + 1) }
            if x > 0 && y > 0 { dist[k] = min(dist[k], dist[k - N - 1] + 1.414) }
            if x < N - 1 && y > 0 { dist[k] = min(dist[k], dist[k - N + 1] + 1.414) }
        } }
        for y in stride(from: N - 1, through: 0, by: -1) { for x in stride(from: N - 1, through: 0, by: -1) {
            let k = y * N + x
            if x < N - 1 { dist[k] = min(dist[k], dist[k + 1] + 1) }
            if y < N - 1 { dist[k] = min(dist[k], dist[k + N] + 1) }
            if x < N - 1 && y < N - 1 { dist[k] = min(dist[k], dist[k + N + 1] + 1.414) }
            if x > 0 && y < N - 1 { dist[k] = min(dist[k], dist[k + N - 1] + 1.414) }
        } }
        var snow = [Float](repeating: 0, count: N * N)
        for y in 1..<(N - 1) { for x in 1..<(N - 1) {
            let k = y * N + x
            guard valid(k), valid(k - 1), valid(k + 1), valid(k - N), valid(k + N) else { continue }
            let gx = (h[k + 1] - h[k - 1]) / (2 * f), gy = (h[k + N] - h[k - N]) / (2 * f)
            let cosT = 1 / (1 + gx * gx + gy * gy).squareRoot()
            let tt = max(0, min(1, (cosT - 0.6) / 0.4))
            let hold = tt * tt * (3 - 2 * tt)
            let ex = Float(min(min(x, N - 1 - x), min(y, N - 1 - y))) / Float(N) * 40
            let taper = min(1, ex)
            let want = depth(k) * hold * taper * taper * (3 - 2 * taper)
            snow[k] = dist[k] < 2 ? 0 : min(want, pileK * dist[k] * f + (0.3 + 0.8 * stk) * f)
        } }
        var top = [Float](repeating: -1e30, count: N * N)
        for k in 0..<(N * N) where snow[k] > 0 { top[k] = h[k] + snow[k] }
        func smoothed(_ src: [Float], r: Int, passes: Int) -> [Float] {
            var a = src
            for pass in 0..<passes {
                var o = a
                for y in 0..<N { for x in 0..<N {
                    let k = y * N + x
                    guard a[k] > -1e29 else { continue }
                    var s: Float = 0, w: Float = 0
                    for t in -r...r {
                        let xx = pass % 2 == 0 ? x + t : x, yy = pass % 2 == 0 ? y : y + t
                        guard xx >= 0, yy >= 0, xx < N, yy < N else { continue }
                        let kk = yy * N + xx
                        guard a[kk] > -1e29, abs(h[kk] - h[k]) < step else { continue }
                        s += a[kk]; w += 1
                    }
                    if w > 0 { o[k] = s / w }
                } }
                a = o
            }
            return a
        }
        let r = max(1, min(10, Int(depthM * 0.5 / f)))
        top = smoothed(top, r: r, passes: 2)
        for k in 0..<(N * N) where top[k] > -1e29 { top[k] = max(top[k], h[k] + 0.2 * snow[k]) }
        let shadeTop = smoothed(top, r: 3, passes: 4)
        var out = Splats()
        let C0: Float = 0.28209479177387814, white: Float = 0.92
        func add(_ p: SIMD3<Float>, _ nrm: SIMD3<Float>, along: Float, across: Float, thin: Float, shade: Float) {
            let nn = simd_normalize(nrm)
            let seed: SIMD3<Float> = abs(nn.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
            let t1 = simd_normalize(simd_cross(nn, seed)), t2 = simd_cross(nn, t1)
            let q = simd_quatf(simd_float3x3(columns: (t1, t2, nn)))
            out.means += [p.x, p.y, p.z]
            out.quats += [q.real, q.imag.x, q.imag.y, q.imag.z]
            out.scales += [log(max(along, 1e-7)), log(max(across, 1e-7)), log(max(thin, 1e-7))]
            out.opacities.append(log(0.97 / 0.03))
            let sky = max(0, simd_dot(nn, up))
            let c = (white * shade * (0.62 + 0.38 * sky) - 0.5) / C0
            out.dc += [c, c, c * 1.02]
        }
        let fu = f / mpu
        for y in 2..<(N - 2) { for x in 2..<(N - 2) {
            let k = y * N + x
            guard snow[k] > max(0.004 * depthM / 0.3, 0.25 * f), top[k] > -1e29 else { continue }
            func sh(_ kk: Int) -> Float { shadeTop[kk] > -1e29 ? shadeTop[kk] : shadeTop[k] }
            let gx = (sh(k + 2) + sh(k + 1) - sh(k - 1) - sh(k - 2)) / (6 * f)
            let gy = (sh(k + 2 * N) + sh(k + N) - sh(k - N) - sh(k - 2 * N)) / (6 * f)
            let nrm = up - rgt * gx - dn * gy
            let jx = Float((x * 73 + y * 151) % 97) / 97 - 0.5, jy = Float((x * 37 + y * 89) % 89) / 89 - 0.5
            let p = world(k, top[k]) + (rgt * jx + dn * jy) * fu * 0.6
            add(p, nrm, along: fu * 0.8, across: fu * 0.8, thin: fu * 0.18, shade: 0.97 + 0.03 * Float((x * 7 + y * 13) % 5) / 4)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let kk = (y + dy) * N + (x + dx)
                let below = top[kk] > -1e29 ? top[kk] : (valid(kk) ? h[kk] : h[k] - snow[k] * 2)
                let drop = top[k] - below
                guard drop > 1.5 * f else { continue }
                let side = min(drop, snow[k] * (1.0 + 0.3 * stk) + f)
                let outward = simd_normalize(rgt * Float(dx) + dn * Float(dy))
                let hang = snow[k] * hangK / mpu
                let rows = max(1, min(24, Int(side / max(f * 0.8, 1e-6))))
                for rr in 0..<rows {
                    let s01 = (Float(rr) + 0.5) / Float(rows)
                    let bulge = hang * sin(Float.pi * min(1, s01 * 1.4))
                    let q = world(k, top[k]) + outward * (fu * 0.5 + bulge) - up * (s01 * side / mpu)
                    add(q, outward + up * 0.15, along: fu * 0.7, across: side / mpu / Float(rows) * 0.75, thin: fu * 0.12, shade: 0.9)
                }
            }
        } }
        return out
    }
}
