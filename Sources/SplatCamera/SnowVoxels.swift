import Foundation
import simd

/// Lying snow as a volume. Each column of the layer's height map gets snow above
/// its surface as deep as the snow lies there; the object beneath counts as solid.
/// Both are blurred in 3D and the snow is where the blurred mass passes a
/// threshold: edges round over into buns and baguettes that meet their support at
/// its rim, a narrow support holds little (its snow melts away in the blur), small
/// litter merges into the blanket, and wet snow (a lower threshold) bulges past the
/// edges it sits on. Splats are laid on that volume's skin, on its smooth surface
/// (not the voxels' steps), facing out of it and shaded by that facing.
extension SnowVolume {
    static func layVolume(_ h: [Float], depth: (Int) -> Float, N: Int, cell f: Float, world: (Int, Float) -> SIMD3<Float>,
                          up: SIMD3<Float>, along rgt: SIMD3<Float>, across dn: SIMD3<Float>, mpu: Float,
                          sticky: Float, depthM: Float, K: Int = 0) -> Splats {
        let t0 = Date()
        let stk = max(0, min(1, sticky))
        let NN = N * N
        @inline(__always) func valid(_ k: Int) -> Bool { h[k] > -1e29 }
        let step = max(depthM * 0.25, f * 2)

        // 1. How deep the snow would lie on each column: the depth asked, as much as the
        //    surface is flat enough to hold it, tapering at the map's edge.
        var want = [Float](repeating: 0, count: NN)
        var maxWant: Float = 0
        for y in 1..<(N - 1) { for x in 1..<(N - 1) {
            let k = y * N + x
            guard valid(k) else { continue }
            func hn(_ kk: Int) -> Float { valid(kk) && abs(h[kk] - h[k]) < step ? h[kk] : h[k] }
            let gx = (hn(k + 1) - hn(k - 1)) / (2 * f), gy = (hn(k + N) - hn(k - N)) / (2 * f)
            let cosT = 1 / (1 + gx * gx + gy * gy).squareRoot()
            let tt = max(0, min(1, (cosT - 0.6) / 0.4))
            let hold = tt * tt * (3 - 2 * tt)
            let ex = min(1, Float(min(min(x, N - 1 - x), min(y, N - 1 - y))) / Float(N) * 40)
            let w = depth(k) * hold * ex * ex * (3 - 2 * ex)
            want[k] = w
            maxWant = max(maxWant, w)
        } }
        guard maxWant > f else { return Splats() }

        // 2. The voxels: one column per map cell, a band of heights from a little under
        //    its surface to over the deepest snow (cells are cubes, side f).
        let r = max(2, min(7, Int((depthM * (0.6 - 0.2 * stk) / f).rounded())))   // the rounding's reach: about half the depth, so snow stands no taller than its support is wide
        let below = 2 * r
        let B = min(120, Int((maxWant * 1.1 / f).rounded(.up)) + below + 2 * r + 2)
        var slot = [Int32](repeating: -1, count: NN)
        var base = [Int32]()
        var cols = [Int32]()
        for k in 0..<NN where valid(k) {
            slot[k] = Int32(cols.count); cols.append(Int32(k))
            base.append(Int32((h[k] / f).rounded(.down)) - Int32(below))
        }
        let S = cols.count
        // two fields: snow, and support (the object, solid beneath its surface)
        var snowF = [UInt8](repeating: 0, count: S * B), supF = [UInt8](repeating: 0, count: S * B)
        for s in 0..<S {
            let k = Int(cols[s]), b0 = Int(base[s])
            for i in 0..<B {
                let zc = (Float(b0 + i) + 0.5) * f
                if zc < h[k] { supF[s * B + i] = 255 } else if zc < h[k] + want[k] { snowF[s * B + i] = 255 }
            }
        }
        // value of a field at column k, absolute height index zi (outside a band: under it
        // is the solid object, over it air; no column: air)
        @inline(__always) func at(_ a: UnsafeBufferPointer<UInt8>, _ k: Int, _ zi: Int, under: UInt8) -> Int {
            let s = Int(slot[k]); if s < 0 { return 0 }
            let i = zi - Int(base[s])
            if i < 0 { return Int(under) }
            if i >= B { return 0 }
            return Int(a[s * B + i])
        }
        // 3. Blur both in 3D (twice each way: near a gaussian, so it rounds, not chamfers).
        func blur(_ field: inout [UInt8], under: UInt8) {
            var tmp = field
            let n = Float(2 * r + 1)
            for _ in 0..<2 {
                for axis in 0..<3 {
                    field.withUnsafeBufferPointer { src in
                        tmp.withUnsafeMutableBufferPointer { dst in
                            for s in 0..<S {
                                let k = Int(cols[s]), x = k % N, y = k / N, b0 = Int(base[s])
                                for i in 0..<B {
                                    var sum = 0
                                    let zi = b0 + i
                                    switch axis {
                                    case 0:
                                        for d in -r...r { let xx = x + d; if xx >= 0 && xx < N { sum += at(src, k + d, zi, under: under) } }
                                    case 1:
                                        for d in -r...r { let yy = y + d; if yy >= 0 && yy < N { sum += at(src, k + d * N, zi, under: under) } }
                                    default:
                                        for d in -r...r {
                                            let ii = i + d
                                            sum += ii < 0 ? Int(under) : (ii >= B ? 0 : Int(src[s * B + ii]))
                                        }
                                    }
                                    dst[s * B + i] = UInt8(min(255, Int((Float(sum) / n).rounded())))
                                }
                            }
                        }
                    }
                    swap(&field, &tmp)
                }
            }
        }
        blur(&snowF, under: 0)
        blur(&supF, under: 255)

        // 4. Snow is where the mass (snow and object) passes the threshold, outside the
        //    object, and near enough real snow (so objects' sides don't frost over).
        let thr = Int((0.5 - 0.05 * stk) * 255), sMin = Int((0.3 - 0.08 * stk) * 255)
        var isSnow = [Bool](repeating: false, count: S * B)
        for s in 0..<S {
            let k = Int(cols[s]), b0 = Int(base[s])
            for i in 0..<B {
                let zc = (Float(b0 + i) + 0.5) * f
                guard zc >= h[k] else { continue }
                let sn = Int(snowF[s * B + i]), sp = Int(supF[s * B + i])
                if sn >= sMin && sn + sp >= thr { isSnow[s * B + i] = true }
            }
        }
        @inline(__always) func snowAt(_ k: Int, _ zi: Int) -> Bool {
            let s = Int(slot[k]); if s < 0 { return false }
            let i = zi - Int(base[s]); if i < 0 || i >= B { return false }
            return isSnow[s * B + i]
        }
        @inline(__always) func solidAt(_ k: Int, _ zi: Int) -> Bool {     // inside an object
            let s = Int(slot[k]); if s < 0 { return false }
            return (Float(zi) + 0.5) * f < h[k]
        }

        // 5. Splats on the skin: each snow voxel with open air beside it, moved onto the
        //    smooth surface along the mass's gradient, facing out, shaded by its facing.
        var out = Splats()
        var rng = UInt64(0x9E3779B97F4A7C15)
        func rnd() -> Float { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Float(rng & 0xFFFFFF) / Float(0x7FFFFF) - 1 }
        let C0: Float = 0.28209479177387814, white: Float = 0.92
        let fu = f / mpu
        func add(_ p: SIMD3<Float>, _ nn: SIMD3<Float>, size: Float, thin: Float, shade: Float) {
            let seed: SIMD3<Float> = abs(nn.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
            let t1 = simd_normalize(simd_cross(nn, seed)), t2 = simd_cross(nn, t1)
            let q = simd_quatf(simd_float3x3(columns: (t1, t2, nn)))
            out.means += [p.x, p.y, p.z]
            out.quats += [q.real, q.imag.x, q.imag.y, q.imag.z]
            out.scales += [log(size), log(size), log(thin)]
            out.opacities.append(log(0.995 / 0.005))
            let sky = simd_dot(nn, up)
            let lit = max(0, sky), under = max(0, -sky)
            // tops bright, sides cool and greyer, undersides darker still (sky light only)
            let lum = white * shade * (0.52 + 0.48 * lit * lit) * (1 - 0.3 * under)
            let cl = min(1, 0.85 * (1 - lit) + 0.3 * under)
            out.dc += [(lum * (1 - 0.09 * cl) - 0.5) / C0, (lum * (1 - 0.035 * cl) - 0.5) / C0, (lum * (1 + 0.05 * cl) - 0.5) / C0]
            if K > 0 {
                let strong: Float = (rng >> 20) % 8 == 0 ? 0.1 : 0.025
                for c in 0..<K { let a = rnd() * strong * (c < 3 ? 0.7 : 1.0); out.sh += [a, a, a] }
            }
        }
        let sumF: (Int, Int) -> Int = { k, zi in
            snowF.withUnsafeBufferPointer { a in at(a, k, zi, under: 0) } + supF.withUnsafeBufferPointer { a in at(a, k, zi, under: 255) }
        }
        // the mass between voxels: (map x, map y, absolute height index), trilinear
        func tri(_ q: SIMD3<Float>) -> Float {
            let x0 = Int(floor(q.x)), y0 = Int(floor(q.y)), z0 = Int(floor(q.z))
            let fx = q.x - Float(x0), fy = q.y - Float(y0), fz = q.z - Float(z0)
            var acc: Float = 0
            for dy in 0...1 { for dx in 0...1 {
                let xx = min(N - 1, max(0, x0 + dx)), yy = min(N - 1, max(0, y0 + dy))
                let kk = yy * N + xx
                let w = (dx == 0 ? 1 - fx : fx) * (dy == 0 ? 1 - fy : fy)
                let a = Float(sumF(kk, z0)), b = Float(sumF(kk, z0 + 1))
                acc += w * (a * (1 - fz) + b * fz)
            } }
            return acc / 255
        }
        var count = 0
        for s in 0..<S {
            let k = Int(cols[s]), x = k % N, y = k / N, b0 = Int(base[s])
            guard x > 0, y > 0, x < N - 1, y < N - 1 else { continue }
            for i in 0..<B where isSnow[s * B + i] {
                let zi = b0 + i
                var open = false
                for (kk, dz) in [(k + 1, 0), (k - 1, 0), (k + N, 0), (k - N, 0), (k, 1), (k, -1)] {
                    if !snowAt(kk, zi + dz) && !solidAt(kk, zi + dz) { open = true; break }
                }
                guard open else { continue }
                // the mass's gradient (per voxel), pointing out of the snow
                let gxv = Float(sumF(k + 1, zi) - sumF(k - 1, zi)) / 510
                let gyv = Float(sumF(k + N, zi) - sumF(k - N, zi)) / 510
                let gzv = Float(sumF(k, zi + 1) - sumF(k, zi - 1)) / 510
                let g = SIMD3<Float>(gxv, gyv, gzv)
                let gl = simd_length(g)
                var nrm = gl > 1e-4 ? -g / gl : SIMD3<Float>(0, 0, 1)      // (map x, map y, up)
                if nrm.z < -0.95 { nrm = SIMD3(0, 0, -1) }
                let nWorld = simd_normalize(rgt * nrm.x + dn * nrm.y + up * nrm.z)
                // Small splats across this voxel's piece of skin, each snapped onto the smooth
                // surface (the threshold, sampled between voxels): small and exact, so the snow
                // has a defined edge, not a cloudy one. They're laid on the voxel's face across
                // its main axis and slid along that axis onto the surface, so neighbours' pieces
                // tile a slope with no gaps between the voxel steps; a slope gets more of them,
                // since one voxel's piece of a slope is longer than its face.
                let an = SIMD3<Float>(abs(nrm.x), abs(nrm.y), abs(nrm.z))
                let d = an.z >= an.x && an.z >= an.y ? 2 : (an.x >= an.y ? 0 : 1)
                let ea = (d + 1) % 3, eb = (d + 2) % 3
                let nd = max(an[d], 0.5)
                let ma = min(3, Int(ceil(2 * (1 + an[ea] * an[ea] / (nd * nd)).squareRoot() - 0.15)))
                let mb = min(3, Int(ceil(2 * (1 + an[eb] * an[eb] / (nd * nd)).squareRoot() - 0.15)))
                let thrF = Float(thr) / 255
                let gd = nrm[d] * max(gl, 0.05)
                for ia in 0..<ma { for ib in 0..<mb {
                    var q = SIMD3<Float>(Float(x), Float(y), Float(zi))
                    q[ea] += (Float(ia) + 0.5 + rnd() * 0.45) / Float(ma) - 0.5
                    q[eb] += (Float(ib) + 0.5 + rnd() * 0.45) / Float(mb) - 0.5
                    for _ in 0..<3 {
                        let v = tri(q)
                        q[d] += max(-0.8, min(0.8, (v - thrF) / gd))
                    }
                    let p = world(k, (q.z + 0.5) * f) + (rgt * (q.x - Float(x)) + dn * (q.y - Float(y))) * fu
                    // fine sugar, not tiles: each grain a little different in size, tilt and shade
                    let tilt = simd_normalize(nWorld + (rgt * rnd() + dn * rnd() + up * rnd()) * 0.12)
                    add(p, tilt, size: fu * (0.36 + 0.09 * rnd()), thin: fu * 0.1, shade: 0.965 + 0.035 * rnd())
                    count += 1
                } }
                // now and then a crystal catching the light
                if (x * 2654435761 &+ y * 40503 &+ zi * 97) % 11 == 0 && simd_dot(nWorld, up) > 0.3 {
                    let p = world(k, (Float(zi) + 0.5) * f)
                    add(p + nWorld * (fu * 0.2), simd_normalize(nWorld + (rgt * rnd() + dn * rnd()) * 0.4), size: fu * 0.06, thin: fu * 0.02, shade: 1.18)
                }
            }
        }
        if ProcessInfo.processInfo.environment["VC_SNOWDBG"] != nil {
            print("snowvox N=\(N) f=\(f) r=\(r) B=\(B) cols=\(S) splats=\(count) in \(Date().timeIntervalSince(t0))s")
        }
        return out
    }
}
