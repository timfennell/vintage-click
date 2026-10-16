import Foundation
import simd

/// A studio light head from a 1970s tungsten kit. Photometry is what the
/// relight needs: beam spread and the candela that comes out along it.
struct LightHead {
    enum Kind { case fresnel, softlight }
    let name: String
    let inspiredBy: String
    let kind: Kind
    let lumens: Float               // out of the front of the lamp
    let spotAngle: Float            // full beam angle at full spot, degrees
    let floodAngle: Float           // full beam angle at full flood
    let size: SIMD3<Float>          // housing width, height, depth (m)
    let shine: Float                // how much of the scan's shine it raises (small hard source = 1)
}

/// 3200 K tungsten in linear Rec.709, normalised to green (daylight = 1, 1, 1).
let tungsten = SIMD3<Float>(1.0, 0.80, 0.56) / 0.80

let lightKit: [LightHead] = [
    LightHead(name: "Fresnel 650", inspiredBy: "the small 650 W studio Fresnel of the 70s",
              kind: .fresnel, lumens: 4_800, spotAngle: 14, floodAngle: 52,
              size: [0.20, 0.20, 0.24], shine: 1),
    LightHead(name: "Fresnel 1K", inspiredBy: "the 1 kW workhorse Fresnel with a 6-inch lens",
              kind: .fresnel, lumens: 7_500, spotAngle: 12, floodAngle: 50,
              size: [0.26, 0.26, 0.30], shine: 1),
    LightHead(name: "Fresnel 2K", inspiredBy: "the 2 kW Fresnel with an 8-inch lens",
              kind: .fresnel, lumens: 15_000, spotAngle: 10, floodAngle: 48,
              size: [0.34, 0.34, 0.38], shine: 1),
    LightHead(name: "Softlight 2K", inspiredBy: "the 2 kW quartz softlight: lamps hidden, all light off a white trough",
              kind: .softlight, lumens: 18_000, spotAngle: 100, floodAngle: 100,
              size: [0.62, 0.46, 0.34], shine: 0.35),
]

/// A light standing in the scene.
struct PlacedLight {
    var head: Int                   // index into lightKit
    var position: SIMD3<Float>      // scene units
    var aim: SIMD3<Float>           // unit, where the lens points
    var spot: Float = 0.5           // 0 = full flood, 1 = full spot
    var dimmerStops: Float = 0      // scrims / dimmer: 0 = full, -1 = half

    var kit: LightHead { lightKit[head] }

    var beamAngle: Float { kit.floodAngle + (kit.spotAngle - kit.floodAngle) * spot }

    /// Peak intensity (candela): the same light squeezed into a narrower beam.
    var candela: Float {
        let half = beamAngle * .pi / 360
        let solid = 2 * Float.pi * (1 - cos(half * 1.25))     // to the soft edge
        return kit.lumens / solid * exp2(dimmerStops)
    }

    /// For the relight kernel (Shaders.swift, `relight`): relative to the
    /// illuminance the scan was captured at, 2.5 * 2^EV lux at ISO 100.
    func packed(metresPerUnit: Float, sceneEV: Float) -> [SIMD4<Float>] {
        let half = beamAngle * .pi / 360
        let eRef = 2.5 * exp2(sceneEV)
        return [
            SIMD4(position, kit.kind == .softlight ? 1 : 0),
            SIMD4(simd_normalize(aim), candela / eRef),
            SIMD4(tungsten, kit.shine),
            SIMD4(cos(half * 0.6), cos(min(half * 1.5, .pi * 0.499)), metresPerUnit, 0),
        ]
    }

    /// The light's own axes: forward along the aim, up as close to world up as it goes.
    func frame(up: SIMD3<Float>) -> (f: SIMD3<Float>, r: SIMD3<Float>, u: SIMD3<Float>) {
        let f = simd_normalize(aim)
        var r = simd_cross(f, up)
        if simd_length(r) < 1e-4 { r = simd_cross(f, [1, 0, 0]) }
        r = simd_normalize(r)
        return (f, r, simd_cross(r, f))
    }

    /// Wireframe of the head (world-space segments), sized in metres.
    func wireframe(up: SIMD3<Float>, metresPerUnit: Float, beamTo: Float?) -> [(SIMD3<Float>, SIMD3<Float>)] {
        let (f, r, u) = frame(up: up)
        let s = 1 / metresPerUnit
        let w = kit.size.x * s, h = kit.size.y * s, d = kit.size.z * s
        let p = position
        var segs: [(SIMD3<Float>, SIMD3<Float>)] = []
        func ring(_ c: SIMD3<Float>, _ rad: Float, _ n: Int = 16) -> [SIMD3<Float>] {
            (0..<n).map { i in
                let a = Float(i) / Float(n) * 2 * .pi
                return c + (r * cos(a) + u * sin(a)) * rad
            }
        }
        func loop(_ pts: [SIMD3<Float>]) {
            for i in 0..<pts.count { segs.append((pts[i], pts[(i + 1) % pts.count])) }
        }
        switch kit.kind {
        case .fresnel:
            // Drum housing, the stepped lens in front, cooling top, yoke and spigot.
            let front = p + f * d * 0.5, back = p - f * d * 0.5
            let fr = ring(front, w * 0.5), br = ring(back, w * 0.46)
            loop(fr); loop(br)
            for i in stride(from: 0, to: 16, by: 4) { segs.append((fr[i], br[i])) }
            loop(ring(front + f * w * 0.01, w * 0.32, 12))
            loop(ring(front + f * w * 0.01, w * 0.16, 8))
            segs.append((back + u * w * 0.46, back + u * w * 0.6))
            segs.append((front + u * w * 0.5, front + u * w * 0.6))
            segs.append((back + u * w * 0.6, front + u * w * 0.6))
            let yoke = w * 0.62
            segs.append((p + r * yoke, p + r * yoke - u * h * 0.75))
            segs.append((p - r * yoke, p - r * yoke - u * h * 0.75))
            segs.append((p + r * yoke - u * h * 0.75, p - r * yoke - u * h * 0.75))
            segs.append((p - u * h * 0.75, p - u * h * 1.3))
        case .softlight:
            // Open-fronted box with a curved white trough inside, yoke below.
            let fc = p + f * d * 0.5, bc = p - f * d * 0.5
            let fw = r * w * 0.5, fh = u * h * 0.5
            let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
            let front: [SIMD3<Float>] = corners.map { (a, b) -> SIMD3<Float> in fc + fw * a + fh * b }
            let back: [SIMD3<Float>] = corners.map { (a, b) -> SIMD3<Float> in bc + (fw * a + fh * b) * 0.7 }
            loop(front); loop(back)
            for i in 0..<4 { segs.append((front[i], back[i])) }
            for k in 1...3 {
                let t = Float(k) / 4
                let y = -0.5 + t
                let depth = 0.35 * (1 - 4 * (t - 0.5) * (t - 0.5))
                segs.append((fc - fw + u * h * y - f * d * depth, fc + fw + u * h * y - f * d * depth))
            }
            segs.append((p - u * h * 0.5, p - u * h * 1.2))
        }
        // The beam, out to the subject: where the light falls.
        if let dist = beamTo {
            let half = beamAngle * .pi / 360
            let end = p + f * dist
            let rad = dist * tan(half)
            let edge = ring(end, rad, 24)
            loop(edge)
            for i in stride(from: 0, to: 24, by: 6) { segs.append((p + f * d * 0.5, edge[i])) }
        }
        return segs
    }
}

/// What the gaffer has set: the lights, the house lights, and which is in hand.
struct LightingPlot {
    var lights: [PlacedLight] = []
    var ambient: Float = 1          // the house lights: share of the scan as captured
    var selected = 0
    var carrying = false
    var kitChoice = 1               // what the next light added will be

    static let houseLevels: [Float] = [1, 0.5, 0.25, 0.1, 0]

    mutating func cycleHouseLights() {
        let i = Self.houseLevels.firstIndex(where: { abs($0 - ambient) < 1e-3 }) ?? 0
        ambient = Self.houseLevels[(i + 1) % Self.houseLevels.count]
    }
}
