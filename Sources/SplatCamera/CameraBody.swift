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
struct CameraBody: Codable {
    /// Finder blur: strongly blurred splats are drawn at this opacity (enough
    /// to show their whole spread), fewer of them, fading in and out as focus
    /// moves (see projection_fwd.slang). "Fast" draws fewer still, a little
    /// coarser. VC_THIN overrides it (0: every splat at its own, faint, opacity).
    static var finderThinning: Float {
        if let v = ProcessInfo.processInfo.environment["VC_THIN"].flatMap(Float.init) { return v }
        return UserDefaults.standard.bool(forKey: "fastFocus") ? 0.1 : 0.05
    }

    /// The camera itself (its make, model and serial go on every frame).
    var model = CameraModel.ohiKorS2
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
    /// The filter on the lens (index into lensFilters; 0 = none).
    var filterIndex = 0
    var filter: LensFilter { lensFilters[filterIndex] }

    /// Whether this lens can take that filter (rear-filter lenses: colour and ND only).
    func fits(_ f: LensFilter) -> Bool { !(lens.rearFilter && f.hasEffect) }
    /// Lens movements: a tilt lens's tilt (degrees: x turns the focus plane
    /// across the frame, y up and down), a shift lens's shift (mm, right and up).
    var tilt = SIMD2<Float>(0, 0)
    var shift = SIMD2<Float>(0, 0)

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

    /// The scan calibrated against mid grey: stops that bring its own middle
    /// tone (whatever its capture camera made of it) to 0.18, so `sceneEV`
    /// is the light on the scene's middle tone, as a reflected meter reads it.
    var calibration: Float = 0

    /// Stops over (+) or under (-) the exposure the scan was captured at.
    var exposureStops: Float {
        let n = takingAperture, t = shutter.seconds
        let ev = log2(n * n / t) - log2(ratedEI / 100)
        return sceneEV + calibration - ev - closeFocusLoss
    }

    /// The lens's magnification at the distance it is focused to (thin lens,
    /// m = f / (s - f), scaled to the lens's published closest-focus figure).
    var magnification: Float {
        let f = lens.focalMM / 1000
        let simple = f / max(focusM - f, f * 0.05)
        // A macro extends further than a simple lens as it nears its closest
        // focus: blend toward its published figure there, by how close it is
        // (in dioptres, squared: far off it is the simple lens).
        guard lens.maxMagnification > 0 else { return simple }
        let atClosest = f / max(lens.minFocusM - f, f * 0.05)
        let k = lens.maxMagnification / atClosest
        let t = min(1, lens.minFocusM / max(focusM, lens.minFocusM))
        return simple * (1 + (k - 1) * t * t)
    }

    /// Focal length in pixels as focused: the view narrows focusing close as
    /// the lens moves out (breathing), or widens for an internal-focus lens.
    func focalPixels(width: Int, height: Int) -> Float {
        lens.focalPixels(width: width, height: height) * max(0.5, 1 + lens.breathing * magnification)
    }

    /// Light lost focusing close (the bellows factor): the lens moves away
    /// from the film, so the effective aperture is N (1 + m). Barely anything
    /// far off; a 50 mm at 0.45 m about a third of a stop; a macro at 1:1
    /// two stops, at 2:1 three. Behind the lens: the finder dims and the meter
    /// sees it, as on the real camera.
    var closeFocusLoss: Float { 2 * log2(1 + magnification) }

    /// Reciprocity failure: past about 1/4 s film answers less than the time
    /// suggests (black-and-white about a stop down at 1 s, colour about half).
    /// Meters know nothing of it, as on a real camera.
    var reciprocityLoss: Float {
        let t = shutter.seconds
        guard t > 0.25 else { return 0 }
        return (stock.blackAndWhite ? 0.5 : 0.25) * log2(t / 0.25)
    }

    /// The exposure the film actually gets (the meter's, less reciprocity failure).
    var filmStops: Float { exposureStops - reciprocityLoss }

    /// Sets the shutter speed that best matches the meter reading.
    mutating func meterShutter(sceneLuminance lum: Float) {
        let best = (0...model.fastestShutter).min { a, b in
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
        shutterIndex = max(0, min(model.fastestShutter, shutterIndex + d))
    }

    /// Shutter-priority automatic (a body that has it): the camera sets the aperture.
    var autoExposure: Bool? = nil
    var autoOn: Bool { model.shutterPriority && (autoExposure ?? true) }

    /// The aperture that best matches the meter at the set speed (shutter-priority).
    mutating func meterAperture(sceneLuminance lum: Float) {
        let stops = lens.apertureStops.indices
        apertureIndex = stops.min { a, b in
            var x = self, y = self
            x.apertureIndex = a
            y.apertureIndex = b
            return abs(x.exposureStops + log2(lum / 0.18)) < abs(y.exposureStops + log2(lum / 0.18))
        } ?? apertureIndex
    }

    /// Another body: its speeds and modes.
    mutating func chooseBody(_ m: CameraModel) {
        model = m
        shutterIndex = min(shutterIndex, m.fastestShutter)
        // The lens has to fit: a rangefinder takes its own, a reflex the rest.
        if !fits(lens) {
            let want = m.rangefinder ? "Lahntal Summax 50mm f/2" : "Ohi Kor 50mm f/1.4"
            if let i = lensBag.firstIndex(where: { $0.name == want }) { chooseLens(i) }
        }
    }
    func fits(_ l: Lens) -> Bool { model.rangefinder ? l.forRangefinder : l.forReflex }
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
        tilt = .zero
        shift = .zero
        // An effect filter cannot go on the back of a fisheye or mirror lens.
        if !fits(filter) { filterIndex = 0 }
    }

    /// Tilts or shifts the lens by `v` (stick or arrows, per second, times dt),
    /// up to how far it goes. False when the lens has no movements.
    mutating func move(_ v: SIMD2<Float>) -> Bool {
        switch lens.movement {
        case .none: return false
        case .tilt(let most):
            tilt += v * most * 0.6
            if simd_length(tilt) > most { tilt *= most / simd_length(tilt) }
        case .shift(let most):
            shift += v * most * 0.6
            if simd_length(shift) > most { shift *= most / simd_length(shift) }
        }
        return true
    }

    /// Where a shifted lens puts the optical axis, from the frame's centre, in
    /// pixels of an image `width` wide (shifting up moves the scene down the frame).
    func axisOffset(width: Int) -> SIMD2<Float> { SIMD2(-shift.x, shift.y) * Float(width) / 36 }
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

    /// `n` lens points of equal area in rings over the unit disc, the outer ring
    /// on the rim. (A sunflower spiral leaves its outermost points at uneven
    /// distances from the rim: with few of them, rim-bright bokeh came out beaded.)
    func ringCells(_ n: Int, turn: Float) -> [SIMD2<Float>] {
        let rings = max(1, Int((Float(n) / .pi).squareRoot().rounded()))
        let radii = (0..<rings).map { (Float($0) + 0.5) / Float(rings) }
        let total = radii.reduce(0, +)
        var counts = radii.map { max(1, Int((Float(n) * $0 / total).rounded())) }
        counts[rings - 1] = max(1, counts[rings - 1] + n - counts.reduce(0, +))
        var out: [SIMD2<Float>] = []
        for (i, r) in radii.enumerated() {
            let a0 = turn + Float(i) * 2.39996323
            for j in 0..<counts[i] {
                let a = a0 + 2 * .pi * Float(j) / Float(counts[i])
                out.append(SIMD2(r * cos(a), r * sin(a)))
            }
        }
        return Array(out.prefix(n))
    }

    /// Whether an exposure of `cells` sub-pupils splits them by colour (axial colour needs enough of them).
    func splitsColour(cells: Int) -> Bool { lens.axialCA > 0 && cells >= 64 }

    /// Lens parameters for one render. `cells` > 1: a sub-pupil of that many,
    /// blurred by only its own spread (the shutter); 1: the whole pupil (finder).
    /// `axis`: the optical axis in this render's pixels, `fieldRadius`: the
    /// frame's half-diagonal in them, `cell`: the sub-pupil's lens point (scene
    /// units), `patch`: the radius of lens it stands for (aperture radii).
    func lensParams(fNumber n: Float, focalPx: Float, cells: Int, table: [SIMD4<Float>]?,
                    axis: SIMD2<Float>, fieldRadius: Float, cell: SIMD2<Float> = .zero,
                    patch: Float = 0) -> [SIMD4<Float>] {
        let radiusUnits = lens.focalMM / 1000 / n / 2 / metresPerUnit
        let invFocus = metresPerUnit / focusM
        // Blur capped where it would only cost speed (a quarter of the frame height).
        let maxSigma = focalPx * 0.25
        var p: [SIMD4<Float>] = [
            SIMD4(1, invFocus, radiusUnits, cells == 1 && table != nil ? 1 : 0),
            // Each sub-pupil blurs by its share of the aperture, a little more
            // than a disc's own spread (r^2 / 4) so neighbours close the gaps.
            SIMD4(1 / (2 * Float(cells)), 1, cells == 1 && table != nil ? Self.finderThinning : 0, maxSigma),
        ]
        p += table ?? []
        p += [SIMD4<Float>](repeating: .zero, count: Self.tableSize - (table?.count ?? 0))
        // The image surface off the film by d mm moves focus by d / f^2 dioptres.
        let f = lens.focalMM / 1000
        let perMM = 0.001 / (f * f) * metresPerUnit
        let halfDiagonalMM: Float = 21.63
        let deg = Float.pi / 180
        p.append(SIMD4(tan(tilt.x * deg) * halfDiagonalMM * perMM, -tan(tilt.y * deg) * halfDiagonalMM * perMM,
                       lens.curvatureRadial * perMM, lens.curvatureTangential * perMM))
        // Rim focus shift for a sub-pupil (the render widens rim cells to match).
        let open = lens.maxAperture / n
        let rim = cells > 1 ? lens.sphericalAberration * open * open * metresPerUnit : 0
        p.append(SIMD4(cell.x, cell.y, lens.squeeze, rim))
        p.append(SIMD4(axis.x, axis.y, fieldRadius, 0))
        // Sub-pupils: the barrel cuts each one's patch of lens where it is on the
        // frame (in the render, so a cat's eye has a clean edge, not a row of cells).
        p.append(SIMD4(lens.catsEye, open, cells > 1 ? patch : 0, 0))
        return p
    }

    /// The shutter's sub-pupils: centres (in aperture radii) spread evenly over
    /// the aperture shape, as gs_render's lens_samples does.
    /// With axial colour each sub-pupil carries one channel (every third):
    /// each channel then gets a whole set of its own, turned a little.
    func cellCentres(_ k: Int) -> [SIMD2<Float>] {
        let split = splitsColour(cells: k)
        let sets = split ? (0..<3).map { c in ringCells((k - c + 2) / 3, turn: Float(c) * 2.1) } : [ringCells(k, turn: 0)]
        return (0..<k).map { i in
            var v = split ? sets[i % 3][i / 3] : sets[0][i]
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
