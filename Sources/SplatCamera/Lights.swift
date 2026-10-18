import Foundation
import simd

/// A studio light head from a 1970s tungsten kit. Photometry is what the
/// relight needs: beam spread and the candela that comes out along it.
struct LightHead {
    enum Kind { case fresnel, softlight, ellipsoidal }
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
    LightHead(name: "Ellipsoidal 750", inspiredBy: "the theatre's ellipsoidal reflector spot: a hard-edged, zooming beam with a gate for metal gobo patterns",
              kind: .ellipsoidal, lumens: 6_500, spotAngle: 20, floodAngle: 50,
              size: [0.24, 0.24, 0.62], shine: 1),
]

/// What can go on or in front of a head: barn doors and flags cut the beam,
/// a cookie (cucoloris) on a stand breaks it into soft dapples, and a gobo
/// (a metal pattern in an ellipsoidal's gate) projects a picture of light.
struct LightModifier {
    enum Kind {
        case none
        /// Leaves or flags closing in from each side, as fractions of the beam's half-width (1 = open).
        case doors(left: Float, right: Float, top: Float, bottom: Float)
        /// A pattern in front of the beam: `layer` in the pattern art, `gobo` in an ellipsoidal's gate.
        case pattern(layer: Int, gobo: Bool)
    }
    let name: String
    let about: String
    let kind: Kind
    /// Which heads take it: gobos only ellipsoidals; doors, flags, cookies the others.
    func fits(_ head: LightHead) -> Bool {
        switch kind {
        case .none: return true
        case .pattern(_, let gobo): return gobo == (head.kind == .ellipsoidal)
        case .doors: return head.kind != .ellipsoidal
        }
    }
}

let lightModifiers: [LightModifier] = [
    LightModifier(name: "Nothing", about: "the open beam", kind: .none),
    LightModifier(name: "Barn doors, nearly open", about: "four hinged leaves just trimming the beam's edges",
                  kind: .doors(left: 0.8, right: 0.8, top: 0.8, bottom: 0.8)),
    LightModifier(name: "Barn doors, a slash", about: "top and bottom leaves closed to a band of light across the set",
                  kind: .doors(left: 1, right: 1, top: 0.22, bottom: 0.22)),
    LightModifier(name: "Barn doors, a slit", about: "side leaves closed to a tall sliver of light",
                  kind: .doors(left: 0.2, right: 0.2, top: 1, bottom: 1)),
    LightModifier(name: "Flag off the top", about: "a black flag on a stand keeping light off the wall above",
                  kind: .doors(left: 1, right: 1, top: 0.1, bottom: 1)),
    LightModifier(name: "Flag off one side", about: "a flag cutting the beam down one side",
                  kind: .doors(left: 0.05, right: 1, top: 1, bottom: 1)),
    LightModifier(name: "Cookie: leaves", about: "a cucoloris with leafy holes: soft dappled light, as through trees",
                  kind: .pattern(layer: 5, gobo: false)),
    LightModifier(name: "Cookie: breakup", about: "a plywood cookie with random holes: broken, uneven light on a wall",
                  kind: .pattern(layer: 6, gobo: false)),
    LightModifier(name: "Cookie: branches", about: "bare branches against the light: winter, menace",
                  kind: .pattern(layer: 7, gobo: false)),
    LightModifier(name: "Gobo: window", about: "a four-pane window thrown onto the wall",
                  kind: .pattern(layer: 0, gobo: true)),
    LightModifier(name: "Gobo: venetian blinds", about: "hard stripes of film noir",
                  kind: .pattern(layer: 1, gobo: true)),
    LightModifier(name: "Gobo: church window", about: "a gothic arch with tracery",
                  kind: .pattern(layer: 2, gobo: true)),
    LightModifier(name: "Gobo: bars", about: "prison bars, or a railing's shadow",
                  kind: .pattern(layer: 3, gobo: true)),
    LightModifier(name: "Gobo: leaf breakup", about: "sharp dappled foliage, the theatre's forest",
                  kind: .pattern(layer: 4, gobo: true)),
]

/// A light standing in the scene.
struct PlacedLight {
    var head: Int                   // index into lightKit
    var position: SIMD3<Float>      // scene units
    var aim: SIMD3<Float>           // unit, where the lens points
    var spot: Float = 0.5           // 0 = full flood, 1 = full spot
    var dimmerStops: Float = 0      // scrims / dimmer: 0 = full, -1 = half
    var gel = 0                     // index into gels (0: none)
    var modifier = 0                // index into lightModifiers (0: nothing)
    /// A gobo's focus (0 sharp ... 1 soft), or how far a cookie stands from the head (0 near: soft ... 1 far: crisper).
    var patternFocus: Float = 0.25

    var kit: LightHead { lightKit[head] }
    func fits(_ m: LightModifier) -> Bool { m.fits(kit) }

    /// Where the light goes, from the head's traced optics at this spot/flood setting.
    var beam: BeamTable { Photometry.table(head: head, spot: spot) }
    /// Full angles (degrees) where the beam falls to 90% (hot), 50% (beam) and 10% (field).
    var beamAngle: Float { beam.angle(at: 0.5) }

    /// For the relight kernel (Shaders.swift, `relight`): four float4s, then the
    /// beam table. Intensities are relative to the illuminance the scan was
    /// captured at, 2.5 * 2^EV lux at ISO 100.
    func packed(metresPerUnit: Float, sceneEV: Float, up: SIMD3<Float>) -> (head: [SIMD4<Float>], table: [SIMD4<Float>]) {
        let eRef = 2.5 * exp2(sceneEV)
        let (f, r, _) = frame(up: up)
        // Its modifier, in the light's own frame (tan of the angle off axis):
        // a pattern mask (layer, half-field it covers, blur, value beyond it)
        // and door / flag limits.
        let halfField = tan(min(beam.angle(at: 0.1) * 0.62, 80) * .pi / 180)
        var pat = SIMD4<Float>(-1, halfField, 0, 1)
        var doors = SIMD4<Float>(-100, 100, -100, 100)
        let mod = fits(lightModifiers[modifier]) ? lightModifiers[modifier] : lightModifiers[0]
        switch mod.kind {
        case .none: break
        case .doors(let l, let rt, let t, let b):
            let hw = tan(beamAngle * .pi / 360) * 1.6
            doors = SIMD4(-hw * l, hw * rt, -hw * b, hw * t)
        case .pattern(let layer, let gobo):
            // A gobo sits in the focused gate: sharp, softened by the focus knob.
            // A cookie on a stand: soft near the head, crisper further out.
            let lod = gobo ? patternFocus * 4 : 2 + (1 - patternFocus) * 3
            pat = SIMD4(Float(layer), halfField * (gobo ? 0.82 : 1), lod, gobo ? 0 : 1)
        }
        return ([
            SIMD4(position, 0),
            SIMD4(f, exp2(dimmerStops) / eRef),
            SIMD4(tungsten * gels[gel].transmission, kit.shine),      // through its gel
            SIMD4(r, metresPerUnit),
            pat,
            doors,
        ], beam.cd.map { SIMD4($0, 0) })
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
        case .ellipsoidal:
            // A long barrel: lamp cap and reflector housing behind, the gate with
            // its four framing shutters, the lens tube in front; yoke below.
            let back = p - f * d * 0.5, gate = p - f * d * 0.05, front = p + f * d * 0.5
            let rb = ring(back, w * 0.42), rg = ring(gate, w * 0.5), rf = ring(front, w * 0.36)
            loop(rb); loop(rg); loop(rf)
            loop(ring(p - f * d * 0.25, w * 0.5))
            for i in stride(from: 0, to: 16, by: 4) {
                segs.append((rb[i], rg[i])); segs.append((rg[i], rf[i]))
            }
            for (a, b) in [(r, u), (-r, u), (u, r), (-u, r)] {
                let c = gate + a * w * 0.5
                segs.append((c - b * w * 0.12, c + a * w * 0.18 - b * w * 0.12))
                segs.append((c + b * w * 0.12, c + a * w * 0.18 + b * w * 0.12))
            }
            segs.append((p - u * h * 0.5, p - u * h * 1.25))
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
    var ambientTint = SIMD3<Float>(1, 1, 1)
    var ambientName = "day"
    var selected = 0
    var carrying = false
    var kitChoice = 1               // what the next light added will be
    var up = SIMD3<Float>(0, -1, 0)     // the world's up, for the heads' yokes

    /// The scan's own light, from full day down to moonlight, as a share of
    /// the light it was captured in (sun at EV 15 is ~80,000 lux): twilight
    /// ~400 lux, a city night's glow ~40 lux, full moon ~0.25 lux. Cooler and
    /// paler as it falls, the eye's (and film's) idea of night. Against these
    /// a 2K Fresnel a few metres off (~1,000 lux) is the sun.
    static let houseLevels: [(name: String, level: Float, tint: SIMD3<Float>)] = [
        ("day", 1, [1, 1, 1]),
        ("overcast", 0.5, [0.95, 0.98, 1.05]),
        ("late afternoon", 0.25, [1.1, 0.95, 0.8]),
        ("dusk", 0.005, [0.75, 0.85, 1.1]),
        ("city night", 0.0005, [0.85, 0.8, 0.9]),
        ("moonlight", 0.000003, [0.55, 0.72, 1.1]),
        ("dark", 0, [1, 1, 1]),
    ]

    mutating func cycleHouseLights() {
        let i = Self.houseLevels.firstIndex(where: { $0.name == ambientName }) ?? 0
        setHouseLights(Self.houseLevels[(i + 1) % Self.houseLevels.count].name)
    }

    mutating func setHouseLights(_ name: String) {
        guard let h = Self.houseLevels.first(where: { $0.name == name }) else { return }
        ambientName = h.name
        ambient = h.level
        ambientTint = h.tint
    }
}
