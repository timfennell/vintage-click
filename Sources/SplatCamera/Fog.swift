import Foundation
import simd

/// Fog in a scene (from a .vcscene): a haze over everything, thicker low down
/// if it has a height fall-off, and patches of it in places (mist over a pond).
/// Lit by the scene's own light (the house lights), not by the lamps: it
/// thins what lies behind it and veils it in its own colour.
struct SceneFog: Codable, Equatable {
    struct Patch: Codable, Equatable {
        enum Shape: Int, Codable { case box, sphere, cylinder }
        var shape: Shape
        /// Scan space to the unit shape: three rows of a 3x4 matrix.
        var toUnit: [SIMD4<Float>]
        var visibilityM: Float
        var tint: SIMD3<Float>
        /// The share of its size over which its edge fades (0 hard ... 1 all soft).
        var softness: Float
    }

    /// How far you see through the haze (metres); 0: no haze, only patches.
    var visibilityM: Float = 0
    var tint = SIMD3<Float>(1, 1, 1)
    /// Above its base the haze thins, by e every this many metres (0: even everywhere).
    var heightFalloffM: Float = 0
    /// A point at the haze's base (the ground), scan units.
    var base = SIMD3<Float>(0, 0, 0)
    var patches: [Patch] = []

    static let maxPatches = 8
    var isEmpty: Bool { visibilityM <= 0 && patches.isEmpty }

    /// Extinction per metre for a visibility (where contrast falls to 2%).
    static func sigma(visibilityM v: Float) -> Float { v > 0 ? 3.912 / v : 0 }

    /// The shader's rows (background_fill, buffer 2):
    ///   G[0] = (patches, haze extinction per unit, fall-off units (0 even), base height along up)
    ///   G[1] = (haze light rgb, far distance units)   G[2] = (eye, -)   G[3] = (up, -)
    ///   per patch 5 rows: three rows to its unit space, (extinction per unit, softness, shape, -), (light rgb, -)
    /// `light`: the house lights' colour on a white surface, as the frame has it.
    func rows(eye: SIMD3<Float>, up: SIMD3<Float>, metresPerUnit mpu: Float, light: SIMD3<Float>) -> [SIMD4<Float>] {
        let ps = patches.prefix(Self.maxPatches)
        let far = 20_000 / max(mpu, 1e-6)
        var r: [SIMD4<Float>] = [
            SIMD4(Float(ps.count), Self.sigma(visibilityM: visibilityM) * mpu,
                  heightFalloffM > 0 ? heightFalloffM / mpu : 0, simd_dot(base, up)),
            SIMD4(light * tint, far),
            SIMD4(eye, 0),
            SIMD4(up, 0),
        ]
        for p in ps {
            r += p.toUnit.count == 3 ? p.toUnit : [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)]
            r.append(SIMD4(Self.sigma(visibilityM: p.visibilityM) * mpu, max(0.01, min(1, p.softness)), Float(p.shape.rawValue), 0))
            r.append(SIMD4(light * p.tint, 0))
        }
        return r
    }

    /// How much light gets through the fog from `eye` to `point` (scan units):
    /// the shader's fog_depth (Shaders.swift), for a lamp's face and flare.
    func transmittance(from eye: SIMD3<Float>, to point: SIMD3<Float>, up: SIMD3<Float>, metresPerUnit mpu: Float) -> Float {
        let v = point - eye, tmax = simd_length(v)
        guard tmax > 1e-6 else { return 1 }
        let d = v / tmax
        var tau: Float = 0
        let sa = Self.sigma(visibilityM: visibilityM) * mpu
        if sa > 0 {
            let H = heightFalloffM > 0 ? heightFalloffM / mpu : 0
            if H <= 0 { tau += sa * tmax } else {
                let u0 = simd_dot(eye, up) - simd_dot(base, up), s = simd_dot(d, up)
                let tc: Float = abs(s) > 1e-6 ? -u0 / s : -1
                let segs: [Float] = [0, (tc > 0 && tc < tmax) ? tc : tmax, tmax]
                for k in 0..<2 {
                    let a = segs[k], b = segs[k + 1]
                    guard b > a else { continue }
                    let um = u0 + s * (a + b) / 2
                    if um <= 0 { tau += sa * (b - a) }
                    else if abs(s) < 1e-6 { tau += sa * exp(-u0 / H) * (b - a) }
                    else { tau += sa * H / s * (exp(-(u0 + s * a) / H) - exp(-min((u0 + s * b) / H, 80))) }
                }
            }
        }
        for p in patches.prefix(Self.maxPatches) where p.toUnit.count == 3 {
            let r = p.toUnit
            let o = SIMD3(simd_dot(SIMD3(r[0].x, r[0].y, r[0].z), eye) + r[0].w,
                          simd_dot(SIMD3(r[1].x, r[1].y, r[1].z), eye) + r[1].w,
                          simd_dot(SIMD3(r[2].x, r[2].y, r[2].z), eye) + r[2].w)
            let dd = SIMD3(simd_dot(SIMD3(r[0].x, r[0].y, r[0].z), d), simd_dot(SIMD3(r[1].x, r[1].y, r[1].z), d),
                           simd_dot(SIMD3(r[2].x, r[2].y, r[2].z), d))
            // Sampled along the ray (the patch is small beside the haze): 32 steps.
            let soft = max(0.01, min(1, p.softness)), sp = Self.sigma(visibilityM: p.visibilityM) * mpu
            var sum: Float = 0
            for j in 0..<32 {
                let q = o + dd * (tmax * (Float(j) + 0.5) / 32)
                let rr: Float
                switch p.shape {
                case .box: rr = max(abs(q.x), abs(q.y), abs(q.z))
                case .sphere: rr = simd_length(q)
                case .cylinder: rr = max(simd_length(SIMD2(q.x, q.y)), abs(q.z))
                }
                let x = max(0, min(1, (rr - 1) / (-soft)))
                sum += x * x * (3 - 2 * x)
            }
            tau += sp * tmax * sum / 32
        }
        return exp(-tau)
    }
}
