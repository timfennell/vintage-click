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
        /// Higher SH, K x 3 per splat (coefficient-major): random, so each grain's
        /// brightness changes with the angle it is seen from, like crystal faces.
        var sh: [Float] = []
        var count: Int { opacities.count }
        mutating func append(_ o: Splats) {
            means += o.means; quats += o.quats; scales += o.scales; opacities += o.opacities; dc += o.dc; sh += o.sh
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
        let N = 1536
        let cell = 2 * Rm / Float(N)                          // metres per cell
        let zlo = groundM - max(depthM * 2, (zhi - groundM) * 0.25)
        let Z = max(8, min(72, Int((zhi - zlo) / cell)))
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
        // Cling to the model: the surface is the highest splat actually in that bin,
        // not the bin's top (a bin can be a hand's breadth tall: snow would hover).
        var topBin = [Int16](repeating: -1, count: N * N), lowBin = [Int16](repeating: -1, count: N * N)
        for k in 0..<(N * N) {
            if top[k] > -1e29 { topBin[k] = Int16(max(0, min(Z - 1, Int((top[k] - zlo) / dz) - 1))) }
            if low[k] > -1e29 { lowBin[k] = Int16(max(0, min(Z - 1, Int((low[k] - zlo) / dz) - 1))) }
        }
        var topZ = [Float](repeating: 0, count: N * N), lowZ = [Float](repeating: 0, count: N * N)
        var topW = [Float](repeating: 0, count: N * N), lowW = [Float](repeating: 0, count: N * N)
        for i in 0..<m.count {
            let op = 1 / (1 + exp(-m.opacities[i]))
            guard op > 0.25 else { continue }
            let p = SIMD3(m.means[3 * i], m.means[3 * i + 1], m.means[3 * i + 2])
            let z = simd_dot(p, up) * mpu
            guard z > zlo, z < zhi else { continue }
            let u = (simd_dot(p, ax) * mpu - hcA + Rm) / cell, v = (simd_dot(p, bx) * mpu - hcB + Rm) / cell
            guard u >= 0, v >= 0, u < Float(N), v < Float(N) else { continue }
            let zi = Int16(min(Z - 1, Int((z - zlo) / dz)))
            let k = Int(v) * N + Int(u)
            // the visible surface: where the top splats' opacity sits (their weighted middle),
            // not the single highest one (a stray splat would lift the snow off the object)
            if zi == topBin[k] || zi == topBin[k] + 1 { topZ[k] += op * z; topW[k] += op }
            if zi == lowBin[k] || zi == lowBin[k] + 1 { lowZ[k] += op * z; lowW[k] += op }
        }
        for k in 0..<(N * N) {
            if top[k] > -1e29 && topW[k] > 0 { top[k] = topZ[k] / topW[k] }
            if low[k] > -1e29 && lowW[k] > 0 { low[k] = lowZ[k] / lowW[k] }
        }
        let wa = snow.windDeg * .pi / 180
        let windDir = SIMD2<Float>(cos(wa), sin(wa)), wind01 = min(1, snow.windMS / 6)
        let world: (Int, Float) -> SIMD3<Float> = { k, hM in
            let u = (Float(k % N) + 0.5) * cell - Rm, v = (Float(k / N) + 0.5) * cell - Rm
            return hc + ax * (u / mpu) + bx * (v / mpu) + up * (hM / mpu)
        }
        var out = Splats()
        let topScore = score(top, N: N, cell: cell, windDir: windDir, wind: wind01)
        let K = max(0, (m.shDegree + 1) * (m.shDegree + 1) - 1)
        out.append(layVolume(top, depth: { k in depthM * (0.4 + 0.6 * topScore[k]) }, N: N, cell: cell, world: world,
                       up: up, along: ax, across: bx, mpu: mpu, sticky: snow.sticky ?? 0.5, depthM: depthM, K: K))
        // beneath: what falls through the gaps in the cover round it, and what the wind
        // drifts in (the more the higher the open space over it), blending into the open
        var covered = [Float](repeating: 0, count: N * N)
        for k in 0..<(N * N) where low[k] > -1e29 { covered[k] = 1 }
        let rc = max(3, Int(1.0 / cell))
        covered = boxBlur(covered, N: N, r: rc)
        let drift = 0.1 + 0.6 * wind01
        out.append(layVolume(low, depth: { k in
            // shelter: how much cover is round about, how close overhead, less what the wind drifts in
            let shelter = (1 - drift) * covered[k] * 0.9 * exp(-gap[k] / shelterL)
            return depthM * (1 - shelter) * min(1, gap[k] / max(depthM * 3, cell * 3))
        }, N: N, cell: cell,
                       world: world, up: up, along: ax, across: bx, mpu: mpu, sticky: snow.sticky ?? 0.5, depthM: depthM, K: K))
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
                    sticky: Float, depthM: Float, K: Int = 0) -> Splats {
        var rng = UInt64(0x9E3779B97F4A7C15)
        func rnd() -> Float {                                    // -1...1
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Float(rng & 0xFFFFFF) / Float(0x7FFFFF) - 1
        }
        func valid(_ k: Int) -> Bool { h[k] > -1e29 }
        let stk = max(0, min(1, sticky))
        let pileK = 0.55 + 1.6 * stk * stk
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
        // The support's width at each spot: the widest point (deepest from its rim)
        // of the same support within reach. Snow stands no taller than about that
        // width (wet), half of it (powder): a pew's top edge holds a thin ridge
        // while the seat and floor beside it fill deep.
        let reach = max(1, min(48, Int((depthM * 1.5 / f).rounded(.up))))
        var ridge = dist
        for pass in 0..<2 {
            let src = ridge
            for y in 0..<N { for x in 0..<N {
                let k = y * N + x
                guard valid(k), src[k] < 1e8 else { continue }
                var m = src[k]
                for sgn in [-1, 1] {                     // out each way, stopping at a gap or a step
                    var prev = k
                    for t in 1...reach {
                        let xx = pass == 0 ? x + sgn * t : x, yy = pass == 0 ? y : y + sgn * t
                        guard xx >= 0, yy >= 0, xx < N, yy < N else { break }
                        let kk = yy * N + xx
                        guard valid(kk), src[kk] < 1e8, abs(h[kk] - h[prev]) < step else { break }
                        m = max(m, src[kk]); prev = kk
                    }
                }
                ridge[k] = m
            } }
        }
        let widthK = 0.5 + 0.5 * stk
        var dbgPre: Float = 0, dbgPost: Float = 0, dbgN = 0, dbgW: Float = 0, dbgWant: Float = 0, dbgD: Float = 0
        defer { if ProcessInfo.processInfo.environment["VC_SNOWDBG"] != nil {
            let c = Float(max(dbgN, 1)); print("snowdbg f=\(f) depthM=\(depthM) cells=\(dbgN) want=\(dbgWant/c) pre=\(dbgPre/c) post=\(dbgPost/c) width=\(dbgW/c) dist=\(dbgD/c) step=\(step)") } }
        var snow = [Float](repeating: 0, count: N * N)
        var holds = [Float](repeating: 0, count: N * N)
        for y in 1..<(N - 1) { for x in 1..<(N - 1) {
            let k = y * N + x
            guard valid(k), valid(k - 1), valid(k + 1), valid(k - N), valid(k + N) else { continue }
            let gx = (h[k + 1] - h[k - 1]) / (2 * f), gy = (h[k + N] - h[k - N]) / (2 * f)
            let cosT = 1 / (1 + gx * gx + gy * gy).squareRoot()
            let tt = max(0, min(1, (cosT - 0.6) / 0.4))
            let hold = tt * tt * (3 - 2 * tt)
            holds[k] = hold
            let ex = Float(min(min(x, N - 1 - x), min(y, N - 1 - y))) / Float(N) * 40
            let taper = min(1, ex)
            let want = depth(k) * hold * taper * taper * (3 - 2 * taper)
            // The profile in from the support's rim: a bun (wet snow rounds over its
            // shoulder, an ellipse) or a sand-pile cone (powder), reaching full depth a
            // shoulder's width in; a narrow support never gets that far: a low dome.
            let shoulder = max(want / pileK, f * 2)
            let s01 = min(1, max(0, (dist[k] - 0.5 + 0.35 * stk) * f / shoulder))
            let bun = (s01 * (2 - s01)).squareRoot()
            snow[k] = want * (s01 * (1 - stk) + bun * stk)
            let width = (2 * ridge[k] + 1) * f                      // metres across
            dbgPre += snow[k]; dbgN += snow[k] > 0 ? 1 : 0; dbgW += width; dbgWant += want; dbgD += dist[k]
            snow[k] = min(snow[k], max(f * 0.5, width * widthK))
            dbgPost += snow[k]
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
        // Snow buries what is small: anything lower than the snow around it is filled over
        // (by no more than the snow's depth), so litter and twigs go under one blanket
        // instead of each standing up as its own little cap.
        do {
            let rb = max(2, min(24, Int(depthM * 0.6 / f)))
            var level = top
            for pass in 0..<4 {
                let src = level
                for y in 0..<N { for x in 0..<N {
                    let k = y * N + x
                    guard valid(k) else { continue }
                    var s: Float = 0, w: Float = 0
                    for t in -rb...rb {
                        let xx = pass % 2 == 0 ? x + t : x, yy = pass % 2 == 0 ? y : y + t
                        guard xx >= 0, yy >= 0, xx < N, yy < N else { continue }
                        let kk = yy * N + xx
                        guard src[kk] > -1e29 else { continue }
                        s += src[kk]; w += 1
                    }
                    if w > 0 { level[k] = s / w }
                } }
            }
            for k in 0..<(N * N) where valid(k) && holds[k] > 0.5 && level[k] > -1e29 && level[k] > max(top[k], h[k])
                && level[k] - h[k] < min(depth(k), depthM) * 1.3 {      // a shallow dip, not a gap between tall things
                let cap = h[k] + min(depth(k), depthM)
                if cap > max(top[k], h[k]) { top[k] = min(level[k], cap); snow[k] = top[k] - h[k] }
            }
        }
        let r = max(1, min(16, Int(depthM * 0.9 / f)))
        top = smoothed(top, r: r, passes: 2)
        for k in 0..<(N * N) where top[k] > -1e29 { top[k] = max(top[k], h[k] + 0.2 * snow[k]) }
        // Snow's own texture: a fine grain and a slight crust on the top (a few
        // per cent of its depth, centimetre-scale), so it isn't a smooth cloud.
        func vnoise(_ x: Float, _ y: Float) -> Float {
            let xi = floor(x), yi = floor(y), fx = x - xi, fy = y - yi
            func hsh(_ a: Float, _ b: Float) -> Float { let v = sin(a * 127.1 + b * 311.7) * 43758.5453; return v - floor(v) }
            let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
            return (hsh(xi, yi) * (1 - u) + hsh(xi + 1, yi) * u) * (1 - v) + (hsh(xi, yi + 1) * (1 - u) + hsh(xi + 1, yi + 1) * u) * v
        }
        var grain = [Float](repeating: 0, count: N * N)
        let gScale = max(f, 0.01)                              // ~1 cm and up
        for y in 0..<N { for x in 0..<N {
            let k = y * N + x
            guard top[k] > -1e29 else { continue }
            let px = Float(x) * f, py = Float(y) * f
            // fine sugar only: real snow is smooth at large scale (no lumps), its texture tiny
            let g = 0.4 * vnoise(px / (gScale * 2), py / (gScale * 2)) + 0.6 * vnoise(px / gScale, py / gScale)
            grain[k] = (g - 0.5) * min(snow[k] * 0.03, depthM * 0.012)
            top[k] += grain[k]
        } }
        let shadeTop = smoothed(top, r: 5, passes: 4)
        let broad = smoothed(top, r: 8, passes: 2)
        var out = Splats()
        let C0: Float = 0.28209479177387814, white: Float = 0.92
        func add(_ p: SIMD3<Float>, _ nrm: SIMD3<Float>, along: Float, across: Float, thin: Float, shade: Float, cool: Float = 0,
                 dir: SIMD3<Float>? = nil) {
            let nn = simd_normalize(nrm)
            var t1: SIMD3<Float>
            if let d = dir, simd_length(d - nn * simd_dot(d, nn)) > 1e-4 {
                t1 = simd_normalize(d - nn * simd_dot(d, nn))      // `along` runs this way
            } else {
                let seed: SIMD3<Float> = abs(nn.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
                t1 = simd_normalize(simd_cross(nn, seed))
            }
            let t2 = simd_cross(nn, t1)
            let q = simd_quatf(simd_float3x3(columns: (t1, t2, nn)))
            out.means += [p.x, p.y, p.z]
            out.quats += [q.real, q.imag.x, q.imag.y, q.imag.z]
            out.scales += [log(max(along, 1e-7)), log(max(across, 1e-7)), log(max(thin, 1e-7))]
            out.opacities.append(log(0.995 / 0.005))
            let sky = max(0, simd_dot(nn, up))
            let lum = white * shade * (0.5 + 0.5 * sky * sky)
            // shade in snow goes cool, blue-grey (it is lit by the sky, not the sun): the
            // more a face turns from the sky, the bluer
            let cl = min(1, cool + 0.9 * (1 - sky))
            let r = (lum * (1 - 0.09 * cl) - 0.5) / C0, g = (lum * (1 - 0.035 * cl) - 0.5) / C0, b = (lum * (1 + 0.05 * cl) - 0.5) / C0
            out.dc += [r, g, b]
            // view-dependent glints: random SH, most faint, one in eight strong
            if K > 0 {
                let strong: Float = (rng >> 20) % 8 == 0 ? 0.1 : 0.025   // faint: strong SH turns splats dark from some sides (blotches)
                for c in 0..<K {
                    let a = rnd() * strong * (c < 3 ? 0.7 : 1.0)     // white: the same in each channel
                    out.sh += [a, a, a]
                }
            }
        }
        let fu = f / mpu
        func b0(_ k: Int) -> Float { max(top[k] - h[k], 1e-4) }
        for y in 2..<(N - 2) { for x in 2..<(N - 2) {
            let k = y * N + x
            guard snow[k] > max(0.004 * depthM / 0.3, 0.25 * f), top[k] > -1e29 else { continue }
            func sh(_ kk: Int) -> Float { shadeTop[kk] > -1e29 ? shadeTop[kk] : shadeTop[k] }
            let gx = (sh(k + 2) + sh(k + 1) - sh(k - 1) - sh(k - 2)) / (6 * f)
            let gy = (sh(k + 2 * N) + sh(k + N) - sh(k - N) - sh(k - 2 * N)) / (6 * f)
            // micro facets: the grain's own slope on top of the drift's
            let ggx = (grain[k + 1] - grain[k - 1]) / (2 * f), ggy = (grain[k + N] - grain[k - N]) / (2 * f)
            let nrm = up - rgt * (gx + ggx * 0.8) - dn * (gy + ggy * 0.8)
            let jx = Float((x * 73 + y * 151) % 97) / 97 - 0.5, jy = Float((x * 37 + y * 89) % 89) / 89 - 0.5
            let p = world(k, top[k]) + (rgt * jx + dn * jy) * fu * 0.4
            // hollows a touch darker, and nearer the support's edge the snow is firmer, crisper
            let hollow = max(0, min(1, (broad[k] - top[k]) / max(depthM * 0.15, f)))
            let nearEdge = dist[k] < 4
            let sz: Float = nearEdge ? 0.5 : 0.62
            // On a steep face a cell's piece of surface is longer than the cell is wide:
            // stretch the splat down the slope so the face stays closed (no see-through steps).
            func same(_ kk: Int) -> Bool { top[kk] > -1e29 && valid(kk) && abs(h[kk] - h[k]) < step }
            let tx = (same(k + 1) && same(k - 1)) ? (top[k + 1] - top[k - 1]) / (2 * f) : gx
            let ty = (same(k + N) && same(k - N)) ? (top[k + N] - top[k - N]) / (2 * f) : gy
            let g = min(6, (tx * tx + ty * ty).squareRoot())
            let downhill = g > 0.05 ? (rgt * tx + dn * ty) / g + up * g : rgt
            _ = downhill
            add(p, nrm, along: fu * sz, across: fu * sz, thin: fu * 0.12,
                shade: (0.97 + 0.03 * Float((x * 7 + y * 13) % 5) / 4) * (1 - 0.05 * hollow), cool: hollow * 0.5)
            // now and then a grain catching the light (a crystal face)
            if (x * 2654435761 &+ y * 40503) % 11 == 0 {
                add(p + up * (fu * 0.04), up + (rgt * jy - dn * jx) * 0.6, along: fu * 0.07, across: fu * 0.07, thin: fu * 0.03, shade: 1.18)
            }
            // Solid snow: where this spot's side is exposed (a neighbour lies lower), fill
            // its column from the top down to what it rests on with round splats, so a cap
            // or drift is a mass sitting on its support, with sides that darken toward the
            // base, not a sheet hovering over it.
            var foot = top[k]
            var away = SIMD3<Float>(0, 0, 0), rim = SIMD3<Float>(0, 0, 0)
            for (kk, d) in [(k + 1, rgt), (k - 1, -rgt), (k + N, dn), (k - N, -dn)] {
                if (!valid(kk) || h[k] - h[kk] > depthM) && (top[kk] < -1e29 || top[kk] < h[k]) { rim += d }   // a raised cap's rim
                let nb = top[kk] > -1e29 ? top[kk] : (valid(kk) && h[kk] > h[k] ? top[k] : -1e30)   // a neighbour's snow hides this side
                let fl = max(nb, h[k])
                away += d * max(0, top[k] - fl)
                foot = min(foot, fl)
            }
            let depthHere = min(top[k] - foot, depthM)        // a side no taller than the snow is deep
            let narrow = (2 * ridge[k] + 1) * f <= depthM
            if narrow && b0(k) > f && depthHere > 0.5 * f {
                // a narrow support's cap: its own body, between its top and the support
                // (never taller than the cap's own snow, itself no taller than the support is wide)
                let hh = min(b0(k), depthHere)
                add(world(k, top[k] - hh * 0.5), simd_length(away) > 1e-6 ? up + simd_normalize(away) * 0.6 : up,
                    along: fu * 0.6, across: fu * 0.6, thin: hh * 0.45 / mpu, shade: 0.88, cool: 0.5)
            }
            if depthHere > 1.2 * f && !narrow {
                let pitch = f * 0.6
                let n = min(80, Int((depthHere / pitch).rounded(.down)))
                // wet snow at its support's rim: a cap wider than its base, bulging out
                // most a third of the way down and tucking back in to the rim at the foot
                let rimDir = simd_length(rim) > 0.5 ? simd_normalize(rim) : SIMD3<Float>(0, 0, 0)
                let bulgeMax = simd_length(rimDir) > 0 ? min(b0(k), depthM) * 0.3 * stk : 0
                if n >= 1 {
                    for i in 1...n {
                        let z = top[k] - Float(i) * depthHere / Float(n) + pitch * 0.2
                        let t = (top[k] - z) / max(b0(k), f)         // 0 at the top ... 1 at the base
                        let jz = Float(((x + i) * 61 + y * 29) % 53) / 53 - 0.5
                        let tt = min(1, max(0, t))
                        let bulge = bulgeMax * sin(Float.pi * pow(tt, 0.6))
                        let q0 = world(k, z) + (rgt * jy - dn * jx) * fu * 0.3 + up * (jz * pitch * 0.3 / mpu)
                        // fill out to the bulge (the overhang is solid, not a lip)
                        let nb = Int((bulge / (f * 0.6)).rounded(.down))
                        if nb >= 1 {
                            for j in 1...nb {
                                let qb = q0 + rimDir * (Float(j) * f * 0.6 / mpu)
                                let ub = Float.pi * 0.5 * min(1.6, 0.35 + tt * 1.25)   // turning under past the widest
                                add(qb, up * cos(ub) + rimDir * sin(ub), along: fu * 0.55, across: fu * 0.55, thin: fu * 0.4,
                                    shade: 0.92 - 0.3 * tt * tt, cool: 0.3 + 0.7 * tt)
                            }
                        }
                        let q = q0
                        // facing out of the mass, tipping down toward the base: its side shades as a curve
                        let out = simd_length(away) > 1e-6 ? simd_normalize(away) : rgt
                        let ang = Float.pi * 0.5 * min(1.25, 0.35 + t)
                        add(q, up * cos(ang) + out * sin(ang), along: fu * 0.55, across: fu * 0.55, thin: fu * 0.42,
                            shade: 0.93 - 0.2 * min(1, t) * min(1, t), cool: 0.3 + 0.7 * min(1, t))
                    }
                }
            }
        } }
        return out
    }
}
