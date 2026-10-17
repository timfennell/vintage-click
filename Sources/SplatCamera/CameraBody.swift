import Foundation
import simd

/// The pupil: which lens points pass light, and how much, seen from field
/// position q (0 at the centre, 1 at the frame corner). Lens points are in
/// units of the current aperture radius. Mirrors `pupil` in Shaders.swift:
/// blades shape the aperture, the barrel (fixed, sized to the wide-open
/// aperture) clips off-axis pupils into cat's eyes, the rim can be brighter.
func pupilWeight(_ l: SIMD2<Float>, q: SIMD2<Float>, lens: Lens, fNumber: Float) -> Float {
    let r = simd_length(l)
    if lens.blades >= 3 {
        let seg = 2 * Float.pi / Float(lens.blades)
        let th = atan2(l.y, l.x) - lens.bladeRotation
        let a = fmodf(fmodf(th, seg) + seg, seg) - seg / 2
        if r * cos(a) > cos(Float.pi / Float(lens.blades)) { return 0 }
    } else if r > 1 {
        return 0
    }
    if r < lens.obstruction { return 0 }      // a mirror lens's secondary mirror
    let open = lens.maxAperture / fNumber
    if simd_length(l * open + lens.catsEye * q) > 1 { return 0 }
    return (1 + lens.soapBubble * pow(r, 6)) / (1 + lens.soapBubble * 0.25)
}

/// Vogel sunflower point k of n over the unit disc.
func vogel(_ k: Int, _ n: Int) -> SIMD2<Float> {
    let r = sqrt((Float(k) + 0.5) / Float(n))
    let th = Float(k) * 2.39996323
    return SIMD2(r * cos(th), r * sin(th))
}

/// What the photographer has set, and the optics that follow from it.
struct CameraBody {
    var lensIndex = lensBag.firstIndex { $0.name == "Ohi Kor 50mm f/1.4" } ?? 0
    var apertureIndex = 0
    var shutterIndex = 7                // 1/125
    var focusM: Float = 1               // focus distance, metres
    var stockIndex = 1
    /// The roll's rating against box speed, in stops: -1 pulled ... +3 pushed.
    var push = 0
    var framesShot = 0
    var rollNumber = 1
    var dofPreview = false

    var metresPerUnit: Float = 1
    var sceneEV: Float = 12             // brightness the scan was captured at (EV at ISO 100)

    var lens: Lens { lensBag[lensIndex] }
    var stock: FilmStock { filmStocks[stockIndex] }
    /// The speed the roll is rated (and metered) at.
    var ratedEI: Float { stock.iso * exp2(Float(push)) }
    /// The stock as it will be developed for that rating.
    var developed: FilmStock { stock.developed(push: push) }
    var rollName: String {
        push == 0 ? stock.name : String(format: "%@ at EI %.0f (%@%d)", stock.name, ratedEI, push > 0 ? "push +" : "pull ", push)
    }
    var takingAperture: Float { lens.apertureStops[min(apertureIndex, lens.apertureStops.count - 1)] }
    /// What the finder shows: wide open, unless the preview lever is held.
    var viewingAperture: Float { dofPreview ? takingAperture : lens.maxAperture }
    var shutter: (label: String, seconds: Float) { shutterSpeeds[shutterIndex] }
    var framesLeft: Int { stock.exposures - framesShot }

    /// Stops over (+) or under (-) the exposure the scan was captured at.
    var exposureStops: Float {
        let n = takingAperture, t = shutter.seconds
        let ev = log2(n * n / t) - log2(ratedEI / 100)
        return sceneEV - ev
    }

    /// Sets the shutter speed that best matches the meter reading.
    mutating func meterShutter(sceneLuminance lum: Float) {
        let best = (0..<shutterSpeeds.count).min { a, b in
            var x = self, y = self
            x.shutterIndex = a
            y.shutterIndex = b
            return abs(x.exposureStops + log2(lum / 0.18)) < abs(y.exposureStops + log2(lum / 0.18))
        }!
        shutterIndex = best
    }

    mutating func changeAperture(_ d: Int) {
        apertureIndex = max(0, min(lens.apertureStops.count - 1, apertureIndex + d))
    }
    mutating func changeShutter(_ d: Int) {
        shutterIndex = max(0, min(shutterSpeeds.count - 1, shutterIndex + d))
    }
    mutating func turnFocus(_ rate: Float, dt: Float) {
        focusM = max(lens.minFocusM, min(200, focusM * exp(rate * dt * 1.1)))
    }
    mutating func nextLens() { chooseLens((lensIndex + 1) % lensBag.count) }

    mutating func chooseLens(_ index: Int) {
        // Keep the same f-number where the new lens has it.
        let n = takingAperture
        lensIndex = index % lensBag.count
        let stops = lens.apertureStops
        apertureIndex = stops.enumerated().min(by: { abs($0.1 - n) < abs($1.1 - n) })!.offset
        focusM = max(focusM, lens.minFocusM)
    }
    /// A fresh roll of this stock, rated at box speed + `push` stops.
    mutating func loadRoll(stock index: Int, push p: Int) {
        stockIndex = index
        push = p
        framesShot = 0
        rollNumber += 1
    }

    mutating func loadNextRoll() {
        stockIndex = (stockIndex + 1) % filmStocks.count
        framesShot = 0
        rollNumber += 1
    }

    // MARK: lens parameters for the renderer (docs/notes/lens-defocus.md)

    static let tableSize = 32

    /// Pupil moments against field radius for the lens at f-number `n`:
    /// (mean along q, variance along q, variance across q, light passed).
    static func pupilTable(lens: Lens, fNumber n: Float) -> [SIMD4<Float>] {
        let grid = 72
        var rows: [SIMD4<Float>] = []
        var centreLight: Float = 0
        for i in 0..<tableSize {
            let q = SIMD2<Float>(Float(i) / Float(tableSize - 1) * 1.25, 0)
            var w: Float = 0, mx: Float = 0, my: Float = 0, mxx: Float = 0, myy: Float = 0
            for gy in 0..<grid {
                for gx in 0..<grid {
                    let l = SIMD2<Float>((Float(gx) + 0.5) / Float(grid) * 2 - 1,
                                         (Float(gy) + 0.5) / Float(grid) * 2 - 1)
                    let p = pupilWeight(l, q: q, lens: lens, fNumber: n)
                    if p == 0 { continue }
                    w += p; mx += p * l.x; my += p * l.y
                    mxx += p * l.x * l.x; myy += p * l.y * l.y
                }
            }
            if i == 0 { centreLight = max(w, 1e-6) }
            if w <= 0 {
                rows.append(SIMD4(0, 0, 0, 0))
                continue
            }
            let ux = mx / w
            rows.append(SIMD4(ux, mxx / w - ux * ux, myy / w - (my / w) * (my / w), w / centreLight))
        }
        return rows
    }

    /// Lens parameters for one render. `cells` > 1: a sub-pupil of that many,
    /// blurred by only its own spread (the shutter); 1: the whole pupil (finder).
    func lensParams(fNumber n: Float, focalPx: Float, cells: Int, table: [SIMD4<Float>]?) -> [SIMD4<Float>] {
        let radiusUnits = lens.focalMM / 1000 / n / 2 / metresPerUnit
        let invFocus = metresPerUnit / focusM
        // Blur capped where it would only cost speed (a quarter of the frame height).
        let maxSigma = focalPx * 0.25
        var p: [SIMD4<Float>] = [
            SIMD4(1, invFocus, radiusUnits, cells == 1 && table != nil ? 1 : 0),
            SIMD4(1 / (4 * Float(cells)), 0, 0, maxSigma),
        ]
        p += table ?? []
        return p
    }

    /// The shutter's sub-pupils: centres (in aperture radii) spread evenly over
    /// the aperture shape, as gs_render's lens_samples does.
    func cellCentres(_ k: Int) -> [SIMD2<Float>] {
        (0..<k).map { i in
            var v = vogel(i, k)
            if lens.blades >= 3 {
                let b = Float(lens.blades)
                let seg = 2 * Float.pi / b
                let th = atan2(v.y, v.x)
                let a = fmodf(fmodf(th - lens.bladeRotation, seg) + seg, seg) - seg / 2
                v *= cos(Float.pi / b) / cos(a)
            }
            return v
        }
    }
}
