import Foundation
import simd

// Lens flare from the lights placed in the scene (each light can have it on
// or off): what the light sends toward the lens, as the shaders' flare model
// (lens_flare in Shaders.swift) needs it. Brightness is physical: the light's
// beam toward the camera (its traced intensity table, dimmer, lamp colour and
// gel) relative to the light the scan was made in, spread as the lens spreads
// a small part of it into ghosts, glare, a starburst and a ring.

extension BeamTable {
    /// Candela per colour at `theta` off the axis and `phi` around it (radians).
    func intensity(theta: Float, phi: Float) -> SIMD3<Float> {
        let t = min(max(pow(max(theta, 0) / (.pi / 2), 1 / Self.power) * Float(Self.thetaBins) - 0.5, 0), Float(Self.thetaBins - 1))
        // The table covers a quarter turn, mirrored into the other three.
        let turn = abs(phi).truncatingRemainder(dividingBy: 2 * .pi), fold = turn > .pi ? 2 * .pi - turn : turn
        let p = min((fold > .pi / 2 ? .pi - fold : fold) / (.pi / 2), 1) * Float(Self.phiBins - 1)
        let t0 = min(Int(t), Self.thetaBins - 2), p0 = min(Int(p), Self.phiBins - 2)
        let ft = t - Float(t0), fp = p - Float(p0)
        func at(_ a: Int, _ b: Int) -> SIMD3<Float> { cd[a * Self.phiBins + b] }
        let a = at(t0, p0) + (at(t0, p0 + 1) - at(t0, p0)) * fp
        let b = at(t0 + 1, p0) + (at(t0 + 1, p0 + 1) - at(t0 + 1, p0)) * fp
        return a + (b - a) * ft
    }
}

enum Flare {
    static let maxLights = 8
    static var rowCount: Int { 4 + 4 * maxLights }

    /// Older and odd optics are single-coated: brighter, more colourful ghosts.
    static func singleCoated(_ l: Lens) -> Bool {
        ["Exotic", "Toys & Mods"].contains(l.collection) || l.name.contains("Petzval") || l.name.contains("Holga")
    }

    /// A light as seen from the camera: where it is on the frame (0...1, may be
    /// off it), its lit face (round or a panel: two half-extent vectors in
    /// pixels, and its brightness in frame light), and, for the flare, how
    /// bright it would make the whole frame were all its light spread over it.
    struct Source {
        var uv: SIMD2<Float>
        var radius: Float                       // face size over the diagonal (for the filter ghost)
        var rgb: SIMD3<Float>                   // the flare's light
        var distance: Float
        var px: SIMD2<Float>
        var blur: Float = 0                     // the light's own defocus blur over the diagonal
        var faceA: SIMD2<Float> = .zero, faceB: SIMD2<Float> = .zero
        var faceRound = true
        var face: SIMD3<Float> = .zero          // the face's brightness (frame light)
        var flare = false
    }

    static func sources(plot: LightingPlot, view V: [Float], position: SIMD3<Float>, fx: Float, axis: SIMD2<Float>,
                        width W: Int, height H: Int, fisheye: Bool, body b: CameraBody, fNumber n: Float) -> [Source] {
        let diag = simd_length(SIMD2(Float(W), Float(H)))
        // The frame's solid angle: all the source's light spread evenly over it.
        let omega = (Float(W) / fx) * (Float(H) / fx)
        func project(_ q: SIMD3<Float>) -> SIMD2<Float>? {
            let rel = q - position
            let xc = V[0] * rel.x + V[1] * rel.y + V[2] * rel.z
            let yc = V[4] * rel.x + V[5] * rel.y + V[6] * rel.z
            let zc = V[8] * rel.x + V[9] * rel.y + V[10] * rel.z
            if fisheye {
                let d = simd_length(rel), th = acos(max(-1, min(1, zc / max(d, 1e-9)))), r = simd_length(SIMD2(xc, yc))
                guard th < 1.6 else { return nil }
                return axis + (r > 1e-9 ? SIMD2(xc, yc) / r : .zero) * (fx * th)
            }
            guard zc > 1e-6 else { return nil }
            return axis + SIMD2(xc, yc) / zc * fx
        }
        var out: [Source] = []
        for light in plot.lights {
            let rel = light.position - position
            let dist = simd_length(rel)
            guard dist > 1e-6, let px = project(light.position) else { continue }
            let uv = px / SIMD2(Float(W), Float(H))
            guard uv.x > -0.6, uv.x < 1.6, uv.y > -0.6, uv.y < 1.6 else { continue }
            // Its beam toward the camera; seen from behind, nothing.
            let (f, r, u) = light.frame(up: plot.up)
            let toCam = -rel / dist
            let ct = simd_dot(toCam, f)
            guard ct > 0 else { continue }
            let theta = acos(min(ct, 1)), phi = atan2(simd_dot(toCam, u), simd_dot(toCam, r))
            let pk = light.packed(metresPerUnit: b.metresPerUnit, sceneEV: b.sceneEV, up: plot.up)
            let colour = SIMD3(pk.head[2].x, pk.head[2].y, pk.head[2].z)
            let cd = light.beam.intensity(theta: theta, phi: phi)
            let dm = max(dist * b.metresPerUnit, 0.05)
            let e = cd * pk.head[1].w / (dm * dm) * colour
            // The lit face: a Fresnel's or an ellipsoidal's lens, a softlight's panel.
            let k = light.kit, s = k.size
            let round = k.kind != .softlight
            let fw = round ? min(s.x, s.y) * (k.kind == .ellipsoidal ? 0.6 : 0.8) : s.x * 0.9
            let fh = round ? fw : s.y * 0.9
            let area = round ? Float.pi * fw * fh / 4 : fw * fh
            // Its brightness: the candela over the face seen at this angle, as the
            // frame shows a white surface under the scan's own light (pi L / E_ref).
            let face = cd / max(area * ct, 1e-6) * .pi * pk.head[1].w * colour
            let units = 1 / b.metresPerUnit
            let pa = project(light.position + r * (fw / 2 * units)) ?? px
            let pb = project(light.position + u * (fh / 2 * units)) ?? px
            let blur = (b.lens.focalMM / 1000 / n) * abs(1 / dm - 1 / max(b.focusM, 0.05)) * fx / diag
            out.append(Source(uv: uv, radius: fx * max(fw, fh) * 0.5 * units / dist / diag, rgb: e * (.pi / omega),
                              distance: dist, px: px, blur: blur, faceA: pa - px, faceB: pb - px,
                              faceRound: round, face: face, flare: light.flareOn))
            if out.count == maxLights { break }
        }
        return out
    }

    /// The shaders' flare rows: the lens, the filter, then four rows per light (see lens_flare).
    static func uniforms(_ s: [Source], visibility: [Float], lens l: Lens, fNumber n: Float, filter: LensFilter? = nil,
                         axisUV: SIMD2<Float>, aspect: Float) -> [SIMD4<Float>] {
        var seed: UInt32 = 2166136261
        for c in l.name.utf8 { seed = (seed ^ UInt32(c)) &* 16777619 }
        var rows: [SIMD4<Float>] = [
            SIMD4(Float(s.count), Float(l.blades), l.bladeRotation, min(1, l.maxAperture / n)),
            SIMD4(singleCoated(l) ? 1 : 0, Float(seed % 10000), l.obstruction, l.squeeze),
            // Dispersion (from the lens's lateral colour) and how fast ghosts soften
            // away from the axis (field curvature and spherical aberration).
            SIMD4(axisUV.x, axisUV.y, 0.008 + l.lateralCA * 4,
                  0.15 + (abs(l.curvatureRadial) + abs(l.curvatureTangential)) * 0.6 + abs(l.sphericalAberration) * 0.3),
            // The filter on the lens: flat glass (a ghost of its own) and any star or grating.
            SIMD4(filter.map { $0.name != lensFilters[0].name ? 1 : 0 } ?? 0, Float(filter?.starPoints ?? 0),
                  filter?.starStrength ?? 0, (filter?.spectral ?? false) ? 1 : 0),
        ]
        for (i, src) in s.enumerated() {
            rows.append(SIMD4(src.uv.x, src.uv.y, src.radius, i < visibility.count ? visibility[i] : 1))
            rows.append(SIMD4(src.rgb, src.blur))
            rows.append(SIMD4(src.faceA.x, src.faceA.y, src.faceB.x, src.faceB.y))
            rows.append(SIMD4(src.face, (src.flare ? 1 : 0) + (src.faceRound ? 2 : 0)))
        }
        while rows.count < rowCount { rows.append(.zero) }
        return rows
    }

    /// For the visibility probe (flare_probe): pixel, distance along the ray, face radius in pixels.
    static func probes(_ s: [Source], diag: Float) -> [SIMD4<Float>] {
        s.map { SIMD4($0.px.x, $0.px.y, $0.distance, max(2, $0.radius * diag)) }
    }
}
