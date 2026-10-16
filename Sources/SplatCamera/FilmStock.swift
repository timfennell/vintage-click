import Foundation
import simd

/// A film stock as a development look: how it sees colour (crosstalk and
/// balance), its characteristic curve (contrast, toe, shoulder), grain and
/// halation. Applied to the scene-linear exposure the shutter collects.
struct FilmStock {
    let name: String
    let inspiredBy: String
    let iso: Float
    let exposures: Int
    var blackAndWhite = false
    var bwMix = SIMD3<Float>(0.30, 0.59, 0.11)    // panchromatic response
    var crosstalk = matrix_identity_float3x3       // dye-layer colour mixing
    var balance = SIMD3<Float>(1, 1, 1)            // per-layer gain (daylight = 1)
    var saturation: Float = 1
    var contrast: Float = 1                        // slope of the curve at mid grey
    var toe: Float = 1                             // shadow compression (>1 = deeper blacks)
    var shoulder: Float = 1                        // highlight compression (<1 = more latitude)
    var blackLift: Float = 0.02                    // base + fog
    var grain: Float = 0.3
    var grainSize: Float = 1.2                     // pixels at 1080 lines
    var halation: Float = 0
    var halationTint = SIMD3<Float>(1.0, 0.25, 0.05)

    /// The stock packed for the shaders (see Shaders.swift, `Film`).
    var packed: [SIMD4<Float>] {
        let m = crosstalk.transpose   // rows
        return [
            SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0), SIMD4(m.columns.2, 0),
            SIMD4(balance, blackAndWhite ? 1 : 0),
            SIMD4(bwMix, saturation),
            SIMD4(contrast, blackLift, shoulder, grain * sqrt(iso / 100)),
            SIMD4(halation, halationTint.x, halationTint.y, halationTint.z),
            SIMD4(iso, grainSize, toe, 0),
        ]
    }
}

private func mix(_ r: SIMD3<Float>, _ g: SIMD3<Float>, _ b: SIMD3<Float>) -> simd_float3x3 {
    // rows: how much of scene R, G, B each layer sees
    simd_float3x3(rows: [r, g, b])
}

/// Names are made up; `inspiredBy` says what each one plays.
let filmStocks: [FilmStock] = [
    FilmStock(name: "Sunchrome 64", inspiredBy: "the classic K-14 slide film",
              iso: 64, exposures: 36,
              crosstalk: mix([1.08, -0.05, -0.03], [-0.04, 1.06, -0.02], [-0.02, -0.08, 1.10]),
              balance: [1.04, 1.0, 0.94], saturation: 1.2, contrast: 1.45, toe: 1.25,
              shoulder: 1.1, blackLift: 0.01, grain: 0.10, grainSize: 0.9),
    FilmStock(name: "Portrait 400", inspiredBy: "fine-grained portrait colour negative",
              iso: 400, exposures: 36,
              crosstalk: mix([1.0, 0.02, -0.02], [0.0, 0.98, 0.02], [-0.01, 0.04, 0.97]),
              balance: [1.03, 1.0, 0.96], saturation: 0.9, contrast: 0.85, toe: 0.95,
              shoulder: 0.6, blackLift: 0.035, grain: 0.14, grainSize: 1.1),
    FilmStock(name: "Vivid 50", inspiredBy: "saturated landscape slide film",
              iso: 50, exposures: 36,
              crosstalk: mix([1.12, -0.08, -0.04], [-0.06, 1.14, -0.08], [-0.02, -0.10, 1.12]),
              balance: [1.0, 1.02, 1.0], saturation: 1.45, contrast: 1.6, toe: 1.35,
              shoulder: 1.15, blackLift: 0.008, grain: 0.08, grainSize: 0.8),
    FilmStock(name: "Everyday 200", inspiredBy: "warm consumer colour negative",
              iso: 200, exposures: 24,
              crosstalk: mix([1.02, 0.0, -0.02], [0.02, 1.0, -0.02], [-0.02, 0.02, 0.96]),
              balance: [1.06, 1.02, 0.88], saturation: 1.1, contrast: 1.0, toe: 1.0,
              shoulder: 0.75, blackLift: 0.03, grain: 0.17, grainSize: 1.2),
    FilmStock(name: "Tungsten 800T", inspiredBy: "cinema film without the anti-halation layer",
              iso: 800, exposures: 36,
              crosstalk: mix([1.0, 0.03, -0.03], [0.0, 1.0, 0.0], [-0.02, 0.02, 1.0]),
              balance: [0.80, 1.0, 1.40], saturation: 1.0, contrast: 0.95, toe: 1.05,
              shoulder: 0.7, blackLift: 0.03, grain: 0.17, grainSize: 1.3,
              halation: 0.9, halationTint: [1.0, 0.18, 0.04]),
    FilmStock(name: "Pan-X 400", inspiredBy: "the gritty reportage black-and-white",
              iso: 400, exposures: 36, blackAndWhite: true, bwMix: [0.32, 0.56, 0.12],
              contrast: 1.2, toe: 1.1, shoulder: 0.8, blackLift: 0.025, grain: 0.30,
              grainSize: 1.4),
    FilmStock(name: "Fine Pan 100", inspiredBy: "smooth tabular-grain black-and-white",
              iso: 100, exposures: 36, blackAndWhite: true, bwMix: [0.28, 0.60, 0.12],
              contrast: 1.05, toe: 1.0, shoulder: 0.85, blackLift: 0.02, grain: 0.14,
              grainSize: 1.0),
    FilmStock(name: "Night Pan 3200", inspiredBy: "push-to-the-limit low-light black-and-white",
              iso: 3200, exposures: 36, blackAndWhite: true, bwMix: [0.36, 0.52, 0.12],
              contrast: 1.3, toe: 1.2, shoulder: 0.85, blackLift: 0.04, grain: 0.18,
              grainSize: 1.9),
]
