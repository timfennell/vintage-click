import Foundation
import simd

/// The air round the scene's furniture: a simple steady solver (not a simulation).
/// The space under the snow's ceiling is cut into cells, solid where the scan has
/// splats; a straight wind is made to go round what is solid (no air through it,
/// none piling up anywhere: one pressure solve, as games' fluid solvers do). So
/// the wind splits round a pillar and rises over a pew, quickening over its top.
/// It is solved once for a wind along each of the two ground axes; any wind is a
/// mix of the two (the solve is linear), so gusts and turns cost nothing.
/// What a steady solve doesn't give, the slack, tumbling air in an obstacle's lee,
/// is added where flakes ask for it (`shelter`).
///
/// Long, tall structure (walls, a building's sides) is left out of the air: snow
/// falling indoors still feels the wind (flakes that blow into a wall land on it).
/// Small tall things (pillars, posts, trunks) stay in it.
///
/// Positions are metres in the snow's frame: x along `a`, y along `b` (the
/// horizon's axes), h above the snow's ground.
final class WindField {
    let a: SIMD3<Float>, b: SIMD3<Float>
    let x0: Float, y0: Float, h0: Float, cell: Float
    let nx: Int, ny: Int, nz: Int
    /// Cell-centred velocity for a 1 m/s wind along x, and along y (3 per cell).
    private let fx: [Float16], fy: [Float16]
    /// Where a flake lands (everything solid), and the air's obstacles' tops per column (metres, 0: none).
    private let land: [UInt8]
    private let top: [Float]

    private init(a: SIMD3<Float>, b: SIMD3<Float>, x0: Float, y0: Float, h0: Float, cell: Float,
                 nx: Int, ny: Int, nz: Int, fx: [Float16], fy: [Float16], land: [UInt8], top: [Float]) {
        self.a = a; self.b = b; self.x0 = x0; self.y0 = y0; self.h0 = h0; self.cell = cell
        self.nx = nx; self.ny = ny; self.nz = nz; self.fx = fx; self.fy = fy; self.land = land; self.top = top
    }

    /// The air's velocity (m/s, x y h) at `p` in wind `w` (m/s along x, y). Beyond the
    /// cells the wind is straight.
    @inline(__always) func velocity(_ p: SIMD3<Float>, wind w: SIMD2<Float>) -> SIMD3<Float> {
        let gx = (p.x - x0) / cell - 0.5, gy = (p.y - y0) / cell - 0.5, gz = (p.z - h0) / cell - 0.5
        if gx < -0.5 || gy < -0.5 || gx > Float(nx) - 0.5 || gy > Float(ny) - 0.5 || gz > Float(nz) - 0.5 {
            return SIMD3(w.x, w.y, 0)
        }
        let cx = min(max(gx, 0), Float(nx - 1)), cy = min(max(gy, 0), Float(ny - 1)), cz = min(max(gz, 0), Float(nz - 1))
        let i0 = min(Int(cx), nx - 2 < 0 ? 0 : nx - 2), j0 = min(Int(cy), max(0, ny - 2)), k0 = min(Int(cz), max(0, nz - 2))
        let tx = cx - Float(i0), ty = cy - Float(j0), tz = cz - Float(k0)
        var vx = SIMD3<Float>(repeating: 0), vy = SIMD3<Float>(repeating: 0)
        for dk in 0...1 { for dj in 0...1 { for di in 0...1 {
            let i = min(i0 + di, nx - 1), j = min(j0 + dj, ny - 1), k = min(k0 + dk, nz - 1)
            let wgt = (di == 0 ? 1 - tx : tx) * (dj == 0 ? 1 - ty : ty) * (dk == 0 ? 1 - tz : tz)
            let c = 3 * (i + nx * (j + ny * k))
            vx += SIMD3(Float(fx[c]), Float(fx[c + 1]), Float(fx[c + 2])) * wgt
            vy += SIMD3(Float(fy[c]), Float(fy[c + 1]), Float(fy[c + 2])) * wgt
        } } }
        return vx * w.x + vy * w.y
    }

    /// Whether a flake at `p` has landed on something (or the ground).
    @inline(__always) func landed(_ p: SIMD3<Float>) -> Bool {
        if p.z <= 0 { return true }
        let i = Int(floor((p.x - x0) / cell)), j = Int(floor((p.y - y0) / cell)), k = Int(floor((p.z - h0) / cell))
        guard i >= 0, j >= 0, k >= 0, i < nx, j < ny, k < nz else { return false }
        return land[i + nx * (j + ny * k)] != 0
    }

    /// How sheltered `p` is from wind blowing along `dir` (unit, x y): 0 open air,
    /// 1 tucked close behind something taller. The lee reaches about seven times
    /// the obstacle's height downwind.
    func shelter(_ p: SIMD3<Float>, dir: SIMD2<Float>) -> Float {
        var s: Float = 0
        for j in 1...6 {
            let d = 0.35 * pow(Float(j), 1.5)
            let qx = p.x - dir.x * d, qy = p.y - dir.y * d
            let i = Int(floor((qx - x0) / cell)), jj = Int(floor((qy - y0) / cell))
            guard i >= 0, jj >= 0, i < nx, jj < ny else { continue }
            let ht = top[i + nx * jj]
            guard ht > 0.05 else { continue }
            let under = min(1, max(0, (ht - p.z * 0.7) / ht))
            let near = min(1, max(0, 1 - d / (7 * ht)))
            s = max(s, under * near)
        }
        return s
    }

    // MARK: building

    /// The field for `snow`'s space, from the scan's splats (`means` xyz, `surf` as
    /// RenderLoop's surfaces: the size byte is .w). Nil when there is nothing to solve.
    static func build(means: UnsafePointer<Float>, surf: UnsafePointer<UInt8>, count: Int,
                      snow: SceneSnow, up: SIMD3<Float>, metresPerUnit mpu: Float) -> WindField? {
        let t0 = Date()
        guard count > 0 else { return nil }
        let (a, b) = SceneSnow.horizon(up)
        let groundM = snow.ground * mpu
        @inline(__always) func frame(_ i: Int) -> SIMD3<Float> {
            let p = SIMD3<Float>(means[3 * i], means[3 * i + 1], means[3 * i + 2])
            return SIMD3(simd_dot(p, a) * mpu, simd_dot(p, b) * mpu, simd_dot(p, up) * mpu - groundM)
        }
        // The space: the snowfall's square round its centre, cut down to where the scan is.
        let stride = max(1, count / 400_000)
        var xs: [Float] = [], ys: [Float] = []
        for i in Swift.stride(from: 0, to: count, by: stride) {
            let q = frame(i)
            guard q.x.isFinite, q.y.isFinite else { continue }
            xs.append(q.x); ys.append(q.y)
        }
        guard xs.count > 100 else { return nil }
        xs.sort(); ys.sort()
        func pct(_ v: [Float], _ f: Float) -> Float { v[Int(Float(v.count - 1) * f)] }
        let cx = simd_dot(snow.centre, a) * mpu, cy = simd_dot(snow.centre, b) * mpu
        let R = snow.radiusM
        let xlo = max(cx - R, pct(xs, 0.002) - 1), xhi = min(cx + R, pct(xs, 0.998) + 1)
        let ylo = max(cy - R, pct(ys, 0.002) - 1), yhi = min(cy + R, pct(ys, 0.998) + 1)
        let h0: Float = -0.5, h1 = min(snow.ceilingM, 30) + 0.5
        guard xhi - xlo > 0.5, yhi - ylo > 0.5 else { return nil }
        let vol = (xhi - xlo) * (yhi - ylo) * (h1 - h0)
        let cell = max(0.12, cbrt(vol / 1_500_000))
        let nx = max(2, Int(ceil((xhi - xlo) / cell))), ny = max(2, Int(ceil((yhi - ylo) / cell)))
        let nz = max(2, Int(ceil((h1 - h0) / cell)))
        let N = nx * ny * nz, NC = nx * ny
        @inline(__always) func idx(_ i: Int, _ j: Int, _ k: Int) -> Int { i + nx * (j + ny * k) }

        // 1. Splats per cell (the scan's surfaces; a lone floater doesn't make a wall),
        //    and per column, splats just above the space (what stands taller than it).
        var hits = [UInt8](repeating: 0, count: N)
        var above = [UInt16](repeating: 0, count: NC)
        for i in 0..<count {
            let sizeM = exp2(Float(surf[4 * i + 3]) / 255 * 24 - 20) * mpu
            guard sizeM < 2 else { continue }
            let q = frame(i)
            let ci = Int(floor((q.x - xlo) / cell)), cj = Int(floor((q.y - ylo) / cell))
            guard ci >= 0, cj >= 0, ci < nx, cj < ny else { continue }
            let ck = Int(floor((q.z - h0) / cell))
            if ck >= 0 && ck < nz {
                let c = idx(ci, cj, ck)
                if hits[c] < 255 { hits[c] += 1 }
            } else if q.z > h1 && q.z < h1 + 4 {
                let c = ci + nx * cj
                if above[c] < 65535 { above[c] += 1 }
            }
        }
        // 2. Solid: two splats or more, closed up by a cell (scans have gaps); the ground.
        var solid0 = [UInt8](repeating: 0, count: N)
        for k in 0..<nz {
            let below = h0 + (Float(k) + 0.5) * cell < 0
            for j in 0..<ny { for i in 0..<nx {
                let c = idx(i, j, k)
                if below || hits[c] >= 2 { solid0[c] = 1 }
            } }
        }
        hits = []
        var land = solid0
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where solid0[idx(i, j, k)] == 0 {
            if (i > 0 && solid0[idx(i - 1, j, k)] != 0) || (i < nx - 1 && solid0[idx(i + 1, j, k)] != 0)
                || (j > 0 && solid0[idx(i, j - 1, k)] != 0) || (j < ny - 1 && solid0[idx(i, j + 1, k)] != 0)
                || (k > 0 && solid0[idx(i, j, k - 1)] != 0) || (k < nz - 1 && solid0[idx(i, j, k + 1)] != 0) {
                land[idx(i, j, k)] = 1
            }
        } } }
        solid0 = []
        // 3. Long, tall structure: columns with the scan carrying on above the space,
        //    in runs longer than 4 m (walls; a pillar is a small patch, kept).
        var tall = [UInt8](repeating: 0, count: NC)
        for c in 0..<NC where above[c] >= 3 { tall[c] = 1 }
        var tallD = tall
        for j in 0..<ny { for i in 0..<nx where tall[i + nx * j] == 0 {
            if (i > 0 && tall[i - 1 + nx * j] != 0) || (i < nx - 1 && tall[i + 1 + nx * j] != 0)
                || (j > 0 && tall[i + nx * (j - 1)] != 0) || (j < ny - 1 && tall[i + nx * (j + 1)] != 0) {
                tallD[i + nx * j] = 1
            }
        } }
        var structure = [UInt8](repeating: 0, count: NC)
        var seen = [Bool](repeating: false, count: NC)
        let longCells = Int(4 / cell)
        for start in 0..<NC where tallD[start] != 0 && !seen[start] {
            var stack = [start], comp: [Int] = []
            seen[start] = true
            var ilo = nx, ihi = 0, jlo = ny, jhi = 0
            while let c = stack.popLast() {
                comp.append(c)
                let i = c % nx, j = c / nx
                ilo = min(ilo, i); ihi = max(ihi, i); jlo = min(jlo, j); jhi = max(jhi, j)
                for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let ii = i + di, jj = j + dj
                    guard ii >= 0, jj >= 0, ii < nx, jj < ny else { continue }
                    let n = ii + nx * jj
                    if tallD[n] != 0 && !seen[n] { seen[n] = true; stack.append(n) }
                }
            }
            if max(ihi - ilo, jhi - jlo) > longCells { for c in comp { structure[c] = 1 } }
        }
        // The air's obstacles: everything solid but the structure (and the ground stays).
        var solid = land
        for k in 0..<nz {
            guard h0 + (Float(k) + 0.5) * cell >= 0 else { continue }
            for c in 0..<NC where structure[c] != 0 { solid[c + NC * k] = 0 }
        }
        var top = [Float](repeating: 0, count: NC)
        for c in 0..<NC {
            for k in Swift.stride(from: nz - 1, through: 0, by: -1) where solid[c + NC * k] != 0 {
                let h = h0 + (Float(k) + 1) * cell
                if h > 0.05 { top[c] = h }
                break
            }
        }
        // 4. The two solves.
        let fx = solve(solid: solid, nx: nx, ny: ny, nz: nz, wind: SIMD2(1, 0))
        let fy = solve(solid: solid, nx: nx, ny: ny, nz: nz, wind: SIMD2(0, 1))
        let solidCount = solid.reduce(0) { $0 + Int($1) }
        fputs(String(format: "Wind field: %dx%dx%d cells of %.2f m, %.0f%% solid, %.1fs\n",
                     nx, ny, nz, cell, 100 * Float(solidCount) / Float(N), Date().timeIntervalSince(t0)), stderr)
        return WindField(a: a, b: b, x0: xlo, y0: ylo, h0: h0, cell: cell, nx: nx, ny: ny, nz: nz,
                         fx: fx, fy: fy, land: land, top: top)
    }

    /// A straight wind made to go round what is solid: face velocities (MAC grid),
    /// none through a solid face; open sides and top (the wind comes and goes there),
    /// the ground closed. One pressure solve (red-black SOR) takes out what would
    /// pile up. Returns cell-centred velocities, 3 per cell.
    private static func solve(solid: [UInt8], nx: Int, ny: Int, nz: Int, wind: SIMD2<Float>) -> [Float16] {
        let N = nx * ny * nz
        @inline(__always) func idx(_ i: Int, _ j: Int, _ k: Int) -> Int { i + nx * (j + ny * k) }
        @inline(__always) func iu(_ i: Int, _ j: Int, _ k: Int) -> Int { i + (nx + 1) * (j + ny * k) }
        @inline(__always) func iv(_ i: Int, _ j: Int, _ k: Int) -> Int { i + nx * (j + (ny + 1) * k) }
        @inline(__always) func iw(_ i: Int, _ j: Int, _ k: Int) -> Int { i + nx * (j + ny * k) }
        @inline(__always) func isSolid(_ i: Int, _ j: Int, _ k: Int) -> Bool {
            if k < 0 { return true }                                   // the ground
            if i < 0 || j < 0 || i >= nx || j >= ny || k >= nz { return false }
            return solid[idx(i, j, k)] != 0
        }
        var u = [Float](repeating: wind.x, count: (nx + 1) * ny * nz)
        var v = [Float](repeating: wind.y, count: nx * (ny + 1) * nz)
        var w = [Float](repeating: 0, count: nx * ny * (nz + 1))
        for k in 0..<nz { for j in 0..<ny { for i in 0...nx where isSolid(i - 1, j, k) || isSolid(i, j, k) { u[iu(i, j, k)] = 0 } } }
        for k in 0..<nz { for j in 0...ny { for i in 0..<nx where isSolid(i, j - 1, k) || isSolid(i, j, k) { v[iv(i, j, k)] = 0 } } }
        for k in 0...nz { for j in 0..<ny { for i in 0..<nx where isSolid(i, j, k - 1) || isSolid(i, j, k) { w[iw(i, j, k)] = 0 } } }
        // per air cell: what would pile up, and how many of its faces are open
        var div = [Float](repeating: 0, count: N)
        var open = [UInt8](repeating: 0, count: N)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where !isSolid(i, j, k) {
            let c = idx(i, j, k)
            div[c] = u[iu(i + 1, j, k)] - u[iu(i, j, k)] + v[iv(i, j + 1, k)] - v[iv(i, j, k)] + w[iw(i, j, k + 1)] - w[iw(i, j, k)]
            var m: UInt8 = 0
            for (di, dj, dk) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] where !isSolid(i + di, j + dj, k + dk) { m += 1 }
            open[c] = m
        } } }
        var p = [Float](repeating: 0, count: N)
        let omega: Float = 1.8
        p.withUnsafeMutableBufferPointer { pb in
            let P = pb
            div.withUnsafeBufferPointer { D in
                open.withUnsafeBufferPointer { O in
                    @inline(__always) func pn(_ i: Int, _ j: Int, _ k: Int) -> Float {
                        if i < 0 || j < 0 || i >= nx || j >= ny || k >= nz || k < 0 { return 0 }
                        return P[i + nx * (j + ny * k)]
                    }
                    for _ in 0..<160 {
                        for colour in 0...1 {
                            DispatchQueue.concurrentPerform(iterations: nz) { k in
                                for j in 0..<ny {
                                    var i = (j + k + colour) & 1
                                    while i < nx {
                                        let c = i + nx * (j + ny * k)
                                        let m = O[c]
                                        if m > 0 && solid[c] == 0 {
                                            var s: Float = 0
                                            if !isSolid(i + 1, j, k) { s += pn(i + 1, j, k) }
                                            if !isSolid(i - 1, j, k) { s += pn(i - 1, j, k) }
                                            if !isSolid(i, j + 1, k) { s += pn(i, j + 1, k) }
                                            if !isSolid(i, j - 1, k) { s += pn(i, j - 1, k) }
                                            if !isSolid(i, j, k + 1) { s += pn(i, j, k + 1) }
                                            if !isSolid(i, j, k - 1) { s += pn(i, j, k - 1) }
                                            P[c] = (1 - omega) * P[c] + omega * (s - D[c]) / Float(m)
                                        }
                                        i += 2
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        @inline(__always) func pc(_ i: Int, _ j: Int, _ k: Int) -> Float {
            if i < 0 || j < 0 || i >= nx || j >= ny || k >= nz || k < 0 { return 0 }
            return p[idx(i, j, k)]
        }
        for k in 0..<nz { for j in 0..<ny { for i in 0...nx where !isSolid(i - 1, j, k) && !isSolid(i, j, k) {
            u[iu(i, j, k)] -= pc(i, j, k) - pc(i - 1, j, k)
        } } }
        for k in 0..<nz { for j in 0...ny { for i in 0..<nx where !isSolid(i, j - 1, k) && !isSolid(i, j, k) {
            v[iv(i, j, k)] -= pc(i, j, k) - pc(i, j - 1, k)
        } } }
        for k in 0...nz { for j in 0..<ny { for i in 0..<nx where !isSolid(i, j, k - 1) && !isSolid(i, j, k) {
            w[iw(i, j, k)] -= pc(i, j, k) - pc(i, j, k - 1)
        } } }
        var out = [Float16](repeating: 0, count: 3 * N)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where !isSolid(i, j, k) {
            let c = 3 * idx(i, j, k)
            out[c] = Float16(0.5 * (u[iu(i, j, k)] + u[iu(i + 1, j, k)]))
            out[c + 1] = Float16(0.5 * (v[iv(i, j, k)] + v[iv(i, j + 1, k)]))
            out[c + 2] = Float16(0.5 * (w[iw(i, j, k)] + w[iw(i, j, k + 1)]))
        } } }
        return out
    }
}

/// Falling snow carried by a wind field: each flake rides the air (lagging a little,
/// big clumps more), falls at its own pace, lands on what it meets. Flakes step in
/// fixed 1/60 s steps from spawn times set by the flake and the clock alone, so the
/// snow at a given time is the same however it was reached: a take develops the
/// same snowfall every time. Only the column round the camera (`radiusM`, the
/// near layer) rides the field; the wide, sparse layer beyond drifts in straight wind.
final class SnowDrift {
    static let dt = 1.0 / 60
    private struct State {
        var pos: [SIMD3<Float>] = [], vel: [SIMD3<Float>] = []
        var cyc: [Int32] = [], down: [UInt8] = []
    }
    private var state = State()
    private var step = Int.min
    private var ring: [(step: Int, state: State)] = []
    private var key: [Float] = []
    private weak var field: WindField?

    /// The near layer's flakes at `t` (scan units, xyz + size; size 0: landed, not drawn).
    func flakes(at t: Double, snow: SceneSnow, field f: WindField, eye: SIMD3<Float>, up: SIMD3<Float>,
                metresPerUnit mpu: Float) -> [SIMD4<Float>] {
        let n = min(SceneSnow.maxFlakes / 2, Int(snow.density))
        guard n > 0 else { return [] }
        let k: [Float] = [snow.density, snow.flakeM, snow.fallMS, snow.windMS, snow.windDeg, snow.gust, snow.radiusM,
                          snow.ceilingM, snow.ground, snow.centre.x, snow.centre.y, snow.centre.z, up.x, up.y, up.z, mpu]
        if k != key || field !== f {
            key = k; field = f; state = State(); step = Int.min; ring = []
        }
        let m = Int(floor(t / Self.dt))
        let frac = Float(t / Self.dt - Double(m))
        let sim = Sim(snow: snow, field: f, n: n, mpu: mpu)
        if step != Int.min && m >= step && m - step <= 1500 {
            while step < m { advance(sim) }
        } else if let r = ring.last(where: { $0.step <= m && m - $0.step <= 1500 }) {
            state = r.state; step = r.step
            while step < m { advance(sim) }
        } else {
            state = sim.fresh(at: m)
            step = m
            ring = []
        }
        return sim.output(state, frac: frac, t: t, eye: eye, up: up)
    }

    private func advance(_ sim: Sim) {
        sim.advance(&state, from: step)
        step += 1
        ring.append((step, state))
        if ring.count > 10 { ring.removeFirst() }
    }

    /// The flakes' rules for one snowfall (cheap to make: per query).
    private struct Sim {
        let snow: SceneSnow, field: WindField, n: Int, mpu: Float
        let R: Float, H: Float, cx: Float, cy: Float

        init(snow: SceneSnow, field: WindField, n: Int, mpu: Float) {
            self.snow = snow; self.field = field; self.n = n; self.mpu = mpu
            R = snow.radiusM; H = snow.ceilingM
            cx = simd_dot(snow.centre, field.a) * mpu; cy = simd_dot(snow.centre, field.b) * mpu
        }

        struct Flake { var v: Float, life: Double, phase: Double, tau: Float, u1: Float, u2: Float }
        @inline(__always) func flake(_ i: Int) -> Flake {
            let s = SceneSnow.flakeSpec(UInt32(i), fallMS: snow.fallMS)
            let life = Double(1.1 * H / max(s.v, 0.02))
            return Flake(v: s.v, life: life, phase: Double(s.u3) * life, tau: 0.05 + 0.05 * s.sizeK, u1: s.u1, u2: s.u2)
        }
        @inline(__always) func cycle(_ f: Flake, _ step: Int) -> Int {
            Int(floor((Double(step) * SnowDrift.dt + f.phase) / f.life))
        }
        @inline(__always) func spawnStep(_ f: Flake, _ c: Int) -> Int {
            var s = Int(ceil((Double(c) * f.life - f.phase) / SnowDrift.dt))
            while cycle(f, s) < c { s += 1 }
            while cycle(f, s - 1) >= c { s -= 1 }
            return s
        }
        @inline(__always) func spawn(_ i: Int, _ c: Int, _ f: Flake) -> (SIMD3<Float>, SIMD3<Float>) {
            let seed = UInt32(truncatingIfNeeded: i) &* 7919 &+ UInt32(truncatingIfNeeded: c) &* 104729
            let x = cx - R + SceneSnow.unit(seed, 21) * 2 * R
            let y = cy - R + SceneSnow.unit(seed, 22) * 2 * R
            let h = H * (0.96 + 0.04 * SceneSnow.unit(seed, 23))
            return (SIMD3(x, y, h), SIMD3(0, 0, -f.v))
        }

        /// One step of a flake, from step `s` to the next.
        @inline(__always) func move(_ p: inout SIMD3<Float>, _ vel: inout SIMD3<Float>, _ down: inout UInt8,
                                    _ f: Flake, _ s: Int, wind w: SIMD2<Float>) {
            guard down == 0 else { return }
            let tt = Float((Double(s) * SnowDrift.dt).truncatingRemainder(dividingBy: 100_000))
            var air = field.velocity(p, wind: w)
            let ws = simd_length(w)
            if ws > 0.05 {
                let sh = field.shelter(p, dir: w / ws)
                if sh > 0.01 {
                    // the lee: the air slack, and tumbling
                    air *= 1 - 0.85 * sh
                    let kk: Float = 2 * .pi / 0.9
                    let e = SIMD3<Float>(sin(kk * (0.8 * p.y + 0.6 * p.z) + tt * 1.3),
                                         sin(kk * (0.9 * p.x - 0.5 * p.z) + tt * 1.1 + 1.3),
                                         0.8 * sin(kk * (0.6 * p.x + 0.7 * p.y) + tt * 1.7 + 0.7))
                    air += e * (sh * ws * 0.6)
                }
            }
            // the swirls a gust brings (the flakes are carried round them)
            air += snow.gustSwirl(p.x, p.y, p.z, Double(s) * SnowDrift.dt)
            let fall = f.v * (1 + 0.18 * sin(tt * (0.7 + f.u2) + f.u1 * 6.283))
            let target = air - SIMD3(0, 0, fall)
            vel += (target - vel) * min(1, Float(SnowDrift.dt) / f.tau)
            p += vel * Float(SnowDrift.dt)
            // round the column (the air is the same either side: it wraps)
            if p.x < cx - R { p.x += 2 * R } else if p.x >= cx + R { p.x -= 2 * R }
            if p.y < cy - R { p.y += 2 * R } else if p.y >= cy + R { p.y -= 2 * R }
            if p.z > H { p.z = H; vel.z = min(vel.z, 0) }
            if field.landed(p) { down = 1 }
        }

        func fresh(at m: Int) -> State {
            var st = State()
            st.pos = .init(repeating: .zero, count: n); st.vel = .init(repeating: .zero, count: n)
            st.cyc = .init(repeating: 0, count: n); st.down = .init(repeating: 0, count: n)
            // the wind for each step back as far as the longest life
            let longest = Int(ceil(Double(1.1 * H / max(snow.fallMS * 0.65 * 0.82, 0.02)) / SnowDrift.dt)) + 2
            let first = m - longest
            let winds = (first...m).map { snow.windAt(Double($0) * SnowDrift.dt) }
            let sim = self
            st.pos.withUnsafeMutableBufferPointer { P in
                st.vel.withUnsafeMutableBufferPointer { V in
                    st.cyc.withUnsafeMutableBufferPointer { C in
                        st.down.withUnsafeMutableBufferPointer { D in
                            let parts = 64
                            DispatchQueue.concurrentPerform(iterations: parts) { part in
                                for i in (n * part / parts)..<(n * (part + 1) / parts) {
                                    let f = sim.flake(i)
                                    let c = sim.cycle(f, m)
                                    let s0 = sim.spawnStep(f, c)
                                    var (p, v) = sim.spawn(i, c, f)
                                    var d: UInt8 = 0
                                    var s = s0
                                    while s < m {
                                        let w = s >= first ? winds[s - first] : sim.snow.windAt(Double(s) * SnowDrift.dt)
                                        sim.move(&p, &v, &d, f, s, wind: w)
                                        s += 1
                                    }
                                    P[i] = p; V[i] = v; C[i] = Int32(truncatingIfNeeded: c); D[i] = d
                                }
                            }
                        }
                    }
                }
            }
            return st
        }

        func advance(_ st: inout State, from s: Int) {
            let w = snow.windAt(Double(s) * SnowDrift.dt)
            let sim = self
            st.pos.withUnsafeMutableBufferPointer { P in
                st.vel.withUnsafeMutableBufferPointer { V in
                    st.cyc.withUnsafeMutableBufferPointer { C in
                        st.down.withUnsafeMutableBufferPointer { D in
                            let parts = 16
                            DispatchQueue.concurrentPerform(iterations: parts) { part in
                                for i in (n * part / parts)..<(n * (part + 1) / parts) {
                                    let f = sim.flake(i)
                                    let c = sim.cycle(f, s + 1)
                                    if c != Int(C[i]) {
                                        let (p, v) = sim.spawn(i, c, f)
                                        P[i] = p; V[i] = v; C[i] = Int32(truncatingIfNeeded: c); D[i] = 0
                                    } else {
                                        sim.move(&P[i], &V[i], &D[i], f, s, wind: w)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        func output(_ st: State, frac: Float, t: Double, eye: SIMD3<Float>, up: SIMD3<Float>) -> [SIMD4<Float>] {
            let a = field.a, b = field.b
            let tt = Float(t.truncatingRemainder(dividingBy: 100_000))
            let eyeA = simd_dot(eye, a) * mpu, eyeB = simd_dot(eye, b) * mpu
            let groundM = snow.ground * mpu
            var out = [SIMD4<Float>](repeating: .zero, count: n)
            for i in 0..<n {
                let s = SceneSnow.flakeSpec(UInt32(i), fallMS: snow.fallMS)
                guard st.down[i] == 0 else { continue }       // landed: size 0, not drawn
                let p = st.pos[i] + st.vel[i] * (frac * Float(SnowDrift.dt))
                // the copy of the column nearest the camera
                var x = (p.x - eyeA + R).truncatingRemainder(dividingBy: 2 * R); if x < 0 { x += 2 * R }; x += eyeA - R
                var y = (p.y - eyeB + R).truncatingRemainder(dividingBy: 2 * R); if y < 0 { y += 2 * R }; y += eyeB - R
                let fl = SIMD2(sin(tt * s.fr + s.ph), cos(tt * s.fr * 0.83 + s.ph * 1.3)) * s.swing
                let e = snow.eddy(x, y, p.z, tt)
                x += fl.x + e.x; y += fl.y + e.y
                let pm = a * x + b * y + up * (groundM + p.z + e.z)
                out[i] = SIMD4(pm / mpu, snow.flakeM * s.sizeK / mpu)
            }
            return out
        }
    }
}
