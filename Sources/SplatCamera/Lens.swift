import Foundation

/// A manual-focus 35 mm lens. Optical character is what the thin-lens
/// sampler can show: the aperture's shape (blades, or a mirror lens's ring),
/// mechanical vignetting that clips off-axis bokeh into cat's eyes (strong
/// enough, it swirls), rim-bright "soap bubble" bokeh (or rim-dark, smooth),
/// spherical aberration (a soft-focus glow), light fall-off, colour (lateral
/// and axial), and how it maps the world onto film (rectilinear or fisheye).
struct Lens {
    enum Projection { case rectilinear, fisheye, circularFisheye }

    let name: String
    let inspiredBy: String
    let focalMM: Float
    let maxAperture: Float      // f-number wide open
    let minAperture: Float
    let blades: Int             // 0 = round
    let bladeRotation: Float    // radians
    let catsEye: Float          // barrel clipping offset at the frame corner, in max-aperture radii
    let soapBubble: Float       // extra weight at the aperture rim (0 = even disc, < 0 smoother)
    let vignette: Float         // fall-off at the corner, wide open
    let minFocusM: Float
    var lateralCA: Float = 0.0005   // red/blue magnification difference at the corner
    var axialCA: Float = 0          // red/blue focus split, dioptres (bokeh fringes)
    var projection = Projection.rectilinear
    /// A mirror lens's central obstruction, as a share of the aperture's radius (ring bokeh).
    var obstruction: Float = 0
    /// Spherical aberration: how much nearer the rim of the open aperture
    /// focuses, in dioptres (a soft-focus lens's glow; it fades stopped down).
    var sphericalAberration: Float = 0
    /// An oval stop's width over its height (an anamorphic-look insert): tall oval bokeh.
    var squeeze: Float = 1
    /// Field curvature: how far the image surface bends off the film at the
    /// frame's corner, mm, for radial and tangential detail. Tangential far
    /// from radial smears off-axis blur round the centre: a Petzval's swirl.
    var curvatureRadial: Float = 0
    var curvatureTangential: Float = 0
    var movement = Movement.none
    var collection = ""

    /// What the lens can do besides focus: tilt its focus plane (degrees) or shift its axis (mm).
    enum Movement { case none, tilt(Float), shift(Float) }

    var isFisheye: Bool { projection != .rectilinear }

    /// The clicks on the aperture ring: full stops, plus the wide-open value.
    var apertureStops: [Float] {
        let full: [Float] = [1.0, 1.4, 2, 2.8, 4, 5.6, 8, 11, 16, 22, 32]
        var stops = full.filter { $0 > maxAperture * 1.02 && $0 <= minAperture * 1.02 }
        stops.insert(maxAperture, at: 0)
        return stops
    }

    /// Focal length in pixels for an image `width` wide (36 mm film). A
    /// fisheye maps angle straight to radius: full-frame ones reach 90
    /// degrees at the frame's corner, circular ones at the image circle's
    /// edge (the frame's height).
    func focalPixels(width: Int, height: Int) -> Float {
        switch projection {
        case .rectilinear: return Float(width) * focalMM / 36
        case .fisheye: return sqrt(Float(width * width + height * height)) / 2 / (.pi / 2)
        case .circularFisheye: return Float(height) / 2 / (.pi / 2)
        }
    }
}

/// A shelf of the camera bag.
struct LensCollection {
    let name: String
    let about: String
    let lenses: [Lens]
}

private let fieldAssignment: [Lens] = [
    Lens(name: "Ohi Kor 20mm f/3.5", inspiredBy: "compact 20 mm ultra-wide, landscapes and tight interiors",
         focalMM: 20, maxAperture: 3.5, minAperture: 22, blades: 7, bladeRotation: 0.1,
         catsEye: 0.25, soapBubble: 0, vignette: 0.45, minFocusM: 0.3, lateralCA: 0.0018, axialCA: 0.005),
    Lens(name: "Ohi Kor 24mm f/2.8", inspiredBy: "the reportage 24 mm, close and wide",
         focalMM: 24, maxAperture: 2.8, minAperture: 22, blades: 7, bladeRotation: 0.15,
         catsEye: 0.28, soapBubble: 0, vignette: 0.4, minFocusM: 0.3, lateralCA: 0.0015, axialCA: 0.008),
    Lens(name: "Ohi Kor 28mm f/2.8", inspiredBy: "classic compact 28 mm wide-angle",
         focalMM: 28, maxAperture: 2.8, minAperture: 22, blades: 7, bladeRotation: 0.2,
         catsEye: 0.30, soapBubble: 0, vignette: 0.35, minFocusM: 0.2, lateralCA: 0.0015, axialCA: 0.01),
    Lens(name: "Ohi Kor 35mm f/1.4", inspiredBy: "the fast 35 mm for available light",
         focalMM: 35, maxAperture: 1.4, minAperture: 16, blades: 9, bladeRotation: 0,
         catsEye: 0.5, soapBubble: 0.1, vignette: 0.5, minFocusM: 0.3, lateralCA: 0.0008, axialCA: 0.035),
    Lens(name: "Ohi Kor 50mm f/1.4", inspiredBy: "the standard fast fifty",
         focalMM: 50, maxAperture: 1.4, minAperture: 16, blades: 7, bladeRotation: 0.1,
         catsEye: 0.45, soapBubble: 0.15, vignette: 0.40, minFocusM: 0.45, lateralCA: 0.0005, axialCA: 0.03),
    Lens(name: "Ohi Kor 105mm f/2.5", inspiredBy: "the portrait telephoto",
         focalMM: 105, maxAperture: 2.5, minAperture: 22, blades: 7, bladeRotation: 0.15,
         catsEye: 0.25, soapBubble: 0.05, vignette: 0.25, minFocusM: 1.0, lateralCA: 0.0004, axialCA: 0.02),
    Lens(name: "Ohi Kor 180mm f/2.8 ED", inspiredBy: "the low-dispersion 180, sports and wildlife",
         focalMM: 180, maxAperture: 2.8, minAperture: 32, blades: 9, bladeRotation: 0,
         catsEye: 0.2, soapBubble: 0, vignette: 0.2, minFocusM: 1.8, lateralCA: 0.0002, axialCA: 0.006),
    Lens(name: "Ohi Kor 300mm f/4.5 ED", inspiredBy: "the field 300, compressed distance",
         focalMM: 300, maxAperture: 4.5, minAperture: 32, blades: 7, bladeRotation: 0,
         catsEye: 0.15, soapBubble: 0, vignette: 0.15, minFocusM: 3.5, lateralCA: 0.0002, axialCA: 0.008),
]

private let bokehMonsters: [Lens] = [
    Lens(name: "Kwanon 50mm f/0.95 Dream", inspiredBy: "the 1960s 'dream lens' f/0.95 rangefinder fifty",
         focalMM: 50, maxAperture: 0.95, minAperture: 16, blades: 10, bladeRotation: 0,
         catsEye: 0.9, soapBubble: 0.3, vignette: 0.7, minFocusM: 1.0, lateralCA: 0.001, axialCA: 0.06,
         sphericalAberration: 0.12),
    Lens(name: "Ohi Nocturne 58mm f/1.2", inspiredBy: "the 1977-97 aspherical f/1.2 night lens: coma corrected, points of light stay points",
         focalMM: 58, maxAperture: 1.2, minAperture: 16, blades: 9, bladeRotation: 0,
         catsEye: 0.6, soapBubble: 0.05, vignette: 0.50, minFocusM: 0.5, lateralCA: 0.0005, axialCA: 0.035,
         sphericalAberration: 0.03),
    Lens(name: "Ohi Kor 85mm f/1.4", inspiredBy: "the fast portrait 85",
         focalMM: 85, maxAperture: 1.4, minAperture: 16, blades: 9, bladeRotation: 0,
         catsEye: 0.5, soapBubble: 0.1, vignette: 0.4, minFocusM: 0.85, lateralCA: 0.0005, axialCA: 0.05),
    Lens(name: "Ohi Kor 135mm f/2 DC", inspiredBy: "defocus-control 135: rim-dark, creamy bokeh",
         focalMM: 135, maxAperture: 2, minAperture: 16, blades: 9, bladeRotation: 0,
         catsEye: 0.3, soapBubble: -0.6, vignette: 0.3, minFocusM: 1.1, lateralCA: 0.0004, axialCA: 0.02),
    Lens(name: "Kwanon 200mm f/2 White", inspiredBy: "the big white 200/2 of the sidelines",
         focalMM: 200, maxAperture: 2, minAperture: 22, blades: 9, bladeRotation: 0,
         catsEye: 0.25, soapBubble: 0, vignette: 0.25, minFocusM: 2.5, lateralCA: 0.0002, axialCA: 0.01),
    Lens(name: "Krasnogorsk Solnce 58mm f/2", inspiredBy: "Soviet Biotar-type swirly normal",
         focalMM: 58, maxAperture: 2, minAperture: 16, blades: 0, bladeRotation: 0,
         catsEye: 0.9, soapBubble: 0.2, vignette: 0.45, minFocusM: 0.5, lateralCA: 0.0009, axialCA: 0.035,
         curvatureRadial: 0.1, curvatureTangential: 0.45),
    Lens(name: "Görlitz Triplan 100mm f/2.8", inspiredBy: "triplet with soap-bubble bokeh",
         focalMM: 100, maxAperture: 2.8, minAperture: 22, blades: 15, bladeRotation: 0,
         catsEye: 0.35, soapBubble: 1.6, vignette: 0.30, minFocusM: 1.0, lateralCA: 0.001, axialCA: 0.03),
]

private let macroLenses: [Lens] = [
    Lens(name: "Ohi Micro-Kor 55mm f/3.5", inspiredBy: "1:2 macro for close-ups",
         focalMM: 55, maxAperture: 3.5, minAperture: 32, blades: 6, bladeRotation: 0.3,
         catsEye: 0.15, soapBubble: 0, vignette: 0.20, minFocusM: 0.24, lateralCA: 0.0003, axialCA: 0.01),
    Lens(name: "Ohi Micro-Kor 60mm f/2.8", inspiredBy: "life-size (1:1) 60 mm macro",
         focalMM: 60, maxAperture: 2.8, minAperture: 32, blades: 7, bladeRotation: 0.2,
         catsEye: 0.15, soapBubble: 0, vignette: 0.2, minFocusM: 0.219, lateralCA: 0.0003, axialCA: 0.012),
    Lens(name: "Ohi Micro-Kor 105mm f/4", inspiredBy: "1:2 105 mm macro, more working distance",
         focalMM: 105, maxAperture: 4, minAperture: 32, blades: 7, bladeRotation: 0.1,
         catsEye: 0.12, soapBubble: 0, vignette: 0.15, minFocusM: 0.47, lateralCA: 0.0003, axialCA: 0.01),
    Lens(name: "Ohi Micro-Kor 200mm f/4 IF", inspiredBy: "the long macro: shy insects from afar",
         focalMM: 200, maxAperture: 4, minAperture: 32, blades: 9, bladeRotation: 0,
         catsEye: 0.1, soapBubble: 0, vignette: 0.15, minFocusM: 0.71, lateralCA: 0.0002, axialCA: 0.008),
]

private let exoticLenses: [Lens] = [
    Lens(name: "Jena Apollo 50mm f/0.7", inspiredBy: "the f/0.7 satellite lens a director adapted to shoot by candlelight (1975)",
         focalMM: 50, maxAperture: 0.7, minAperture: 16, blades: 0, bladeRotation: 0,
         catsEye: 0.95, soapBubble: 0.2, vignette: 0.8, minFocusM: 1.2, lateralCA: 0.0012, axialCA: 0.09,
         sphericalAberration: 0.15),
    Lens(name: "Ohi Kor 13mm f/5.6", inspiredBy: "the rare 118-degree rectilinear ultra-wide (1976-98): straight lines, almost no distortion",
         focalMM: 13, maxAperture: 5.6, minAperture: 22, blades: 7, bladeRotation: 0,
         catsEye: 0.2, soapBubble: 0, vignette: 0.6, minFocusM: 0.3, lateralCA: 0.002, axialCA: 0.004),
    Lens(name: "Ohi Fisheye-Kor 16mm f/2.8", inspiredBy: "full-frame fisheye: 180 degrees corner to corner",
         focalMM: 16, maxAperture: 2.8, minAperture: 22, blades: 7, bladeRotation: 0,
         catsEye: 0.2, soapBubble: 0, vignette: 0.3, minFocusM: 0.25, lateralCA: 0.002, axialCA: 0.005,
         projection: .fisheye),
    Lens(name: "Ohi Fisheye-Kor 8mm f/2.8 Circular", inspiredBy: "circular fisheye: the whole hemisphere in a disc",
         focalMM: 8, maxAperture: 2.8, minAperture: 22, blades: 7, bladeRotation: 0,
         catsEye: 0.1, soapBubble: 0, vignette: 0.25, minFocusM: 0.3, lateralCA: 0.0025, axialCA: 0.004,
         projection: .circularFisheye),
    Lens(name: "Vienna Petzval 85mm f/2.2", inspiredBy: "19th-century Petzval portrait design: wild swirl",
         focalMM: 85, maxAperture: 2.2, minAperture: 16, blades: 0, bladeRotation: 0,
         catsEye: 0.95, soapBubble: 0.3, vignette: 0.65, minFocusM: 0.75, lateralCA: 0.0012, axialCA: 0.04,
         sphericalAberration: 0.05, curvatureRadial: 0.3, curvatureTangential: 2.0),
    Lens(name: "Ohi Reflex-Kor 500mm f/8", inspiredBy: "catadioptric mirror lens: ring-shaped bokeh",
         focalMM: 500, maxAperture: 8, minAperture: 8, blades: 0, bladeRotation: 0,
         catsEye: 0.1, soapBubble: 0.2, vignette: 0.3, minFocusM: 4.0, lateralCA: 0.0001, axialCA: 0,
         obstruction: 0.45),
    Lens(name: "Munich Imago 120mm f/4.5 Soft", inspiredBy: "soft-focus portrait lens: a glow around everything",
         focalMM: 120, maxAperture: 4.5, minAperture: 22, blades: 0, bladeRotation: 0,
         catsEye: 0.2, soapBubble: 0.2, vignette: 0.25, minFocusM: 1.2, lateralCA: 0.0006, axialCA: 0.02,
         sphericalAberration: 0.35),
]

/// The camera bag, in collections. Names are made up; `inspiredBy` says what each plays.
private let screwMount: [Lens] = [
    Lens(name: "Itabashi Takuma 28mm f/3.5 SC", inspiredBy: "the multi-coated M42 screw-mount 28: crisp, flare-resistant wide",
         focalMM: 28, maxAperture: 3.5, minAperture: 16, blades: 6, bladeRotation: 0,
         catsEye: 0.3, soapBubble: 0, vignette: 0.5, minFocusM: 0.4, lateralCA: 0.0018, axialCA: 0.01),
    Lens(name: "Itabashi Takuma 50mm f/1.4 SC", inspiredBy: "the 1972 multi-coated screw-mount fifty with thoriated glass (later yellows warm)",
         focalMM: 50, maxAperture: 1.4, minAperture: 16, blades: 6, bladeRotation: 0,
         catsEye: 0.6, soapBubble: 0.05, vignette: 0.6, minFocusM: 0.45, lateralCA: 0.001, axialCA: 0.04),
    Lens(name: "Itabashi Takuma 55mm f/1.8 SC", inspiredBy: "the everyday screw-mount kit normal: gentle, smooth rendering",
         focalMM: 55, maxAperture: 1.8, minAperture: 16, blades: 6, bladeRotation: 0,
         catsEye: 0.5, soapBubble: 0, vignette: 0.55, minFocusM: 0.45, lateralCA: 0.001, axialCA: 0.03),
    Lens(name: "Itabashi Takuma 85mm f/1.8 SC", inspiredBy: "the screw-mount portrait 85: soft wide open, sharp by f/4",
         focalMM: 85, maxAperture: 1.8, minAperture: 22, blades: 6, bladeRotation: 0,
         catsEye: 0.45, soapBubble: 0, vignette: 0.55, minFocusM: 0.85, lateralCA: 0.001, axialCA: 0.035),
    Lens(name: "Itabashi Takuma 135mm f/3.5 SC", inspiredBy: "the light, cheap, much-loved screw-mount 135",
         focalMM: 135, maxAperture: 3.5, minAperture: 22, blades: 6, bladeRotation: 0,
         catsEye: 0.25, soapBubble: 0, vignette: 0.4, minFocusM: 1.5, lateralCA: 0.0012, axialCA: 0.02),
    Lens(name: "Itabashi Macro-Takuma 50mm f/4 SC", inspiredBy: "the screw-mount 1:2 macro fifty",
         focalMM: 50, maxAperture: 4, minAperture: 22, blades: 6, bladeRotation: 0,
         catsEye: 0.2, soapBubble: 0, vignette: 0.35, minFocusM: 0.23, lateralCA: 0.0008, axialCA: 0.01),
]

private let toysAndMods: [Lens] = [
    Lens(name: "Leningrad LK-A Minitor 32mm f/2.8", inspiredBy: "the Leningrad snapshot compact's 32 mm: dark corners, soft edges, punchy middle",
         focalMM: 32, maxAperture: 2.8, minAperture: 16, blades: 0, bladeRotation: 0,
         catsEye: 0.35, soapBubble: 0.1, vignette: 0.95, minFocusM: 0.8, lateralCA: 0.002, axialCA: 0.02,
         curvatureRadial: 0.35, curvatureTangential: 0.6),
    Lens(name: "Kowloon Hoga 60mm f/8 Plastic", inspiredBy: "the Hong Kong plastic toy camera's single meniscus: a sharp-ish centre in a smeared, dark frame",
         focalMM: 60, maxAperture: 8, minAperture: 11, blades: 0, bladeRotation: 0,
         catsEye: 0.2, soapBubble: 0, vignette: 1.0, minFocusM: 1.0, lateralCA: 0.0035, axialCA: 0.05,
         sphericalAberration: 0.15, curvatureRadial: 2.0, curvatureTangential: 3.0),
    Lens(name: "Krasnogorsk Solnce 58mm f/2 · Reversed Front", inspiredBy: "the Biotar-type Soviet fifty with its front element turned round: a sharp centre in a whirlpool",
         focalMM: 58, maxAperture: 2, minAperture: 16, blades: 0, bladeRotation: 0,
         catsEye: 0.9, soapBubble: 0.3, vignette: 0.6, minFocusM: 0.5, lateralCA: 0.0018, axialCA: 0.05,
         sphericalAberration: 0.3, curvatureRadial: 0.5, curvatureTangential: 5.0),
    Lens(name: "Krasnogorsk Solnce 58mm f/2 · Anamorfake", inspiredBy: "the same Soviet fifty with an oval insert at the stop: tall oval bokeh, a widescreen look",
         focalMM: 58, maxAperture: 2, minAperture: 16, blades: 0, bladeRotation: 0,
         catsEye: 0.9, soapBubble: 0.25, vignette: 0.5, minFocusM: 0.5, lateralCA: 0.0009, axialCA: 0.035,
         squeeze: 0.5, curvatureRadial: 0.1, curvatureTangential: 0.45),
    Lens(name: "Burnside Bendy 50mm f/2.5", inspiredBy: "the bendy tilting lens: steer a sharp sweet spot anywhere, the rest melts away",
         focalMM: 50, maxAperture: 2.5, minAperture: 22, blades: 0, bladeRotation: 0,
         catsEye: 0.3, soapBubble: 0.1, vignette: 0.45, minFocusM: 0.45, lateralCA: 0.0015, axialCA: 0.04,
         sphericalAberration: 0.15, curvatureRadial: 1.2, curvatureTangential: 1.6, movement: .tilt(15)),
    Lens(name: "Ohi PC-Kor 35mm f/3.5", inspiredBy: "the first perspective-control lens for 35 mm (1962): shift 11 mm to keep buildings straight",
         focalMM: 35, maxAperture: 3.5, minAperture: 32, blades: 6, bladeRotation: 0,
         catsEye: 0.12, soapBubble: 0, vignette: 0.2, minFocusM: 0.3, lateralCA: 0.0012, axialCA: 0.006,
         movement: .shift(11)),
    Lens(name: "Ohi PC-Kor 28mm f/3.5", inspiredBy: "the wider shift lens (1975-83) for architecture and landscape",
         focalMM: 28, maxAperture: 3.5, minAperture: 22, blades: 7, bladeRotation: 0,
         catsEye: 0.12, soapBubble: 0, vignette: 0.22, minFocusM: 0.3, lateralCA: 0.0014, axialCA: 0.006,
         movement: .shift(11)),
]

let lensCollections: [LensCollection] = [
    LensCollection(name: "Field Assignment", about: "the magazine photographer's prime kit of the 70s and 80s", lenses: fieldAssignment),
    LensCollection(name: "Screw-Mount Classics", about: "the multi-coated M42 primes of the early 70s", lenses: screwMount),
    LensCollection(name: "Bokeh Monsters", about: "fast glass for melting backgrounds", lenses: bokehMonsters),
    LensCollection(name: "Macro", about: "close focusing, flat field, sharp corners", lenses: macroLenses),
    LensCollection(name: "Exotic", about: "rare vintage and odd optics", lenses: exoticLenses),
    LensCollection(name: "Toys, Mods & Movements", about: "plastic, reversed, bent and shifted: lenses for breaking the rules", lenses: toysAndMods),
]

/// All of them, collection by collection (a lens's index is its place here).
let lensBag: [Lens] = lensCollections.flatMap { c in c.lenses.map { var l = $0; l.collection = c.name; return l } }

/// The shutter dial, in seconds (the marks are the nominal ones).
let shutterSpeeds: [(label: String, seconds: Float)] = [
    ("1", 1), ("2", 1 / 2), ("4", 1 / 4), ("8", 1 / 8), ("15", 1 / 15), ("30", 1 / 30),
    ("60", 1 / 60), ("125", 1 / 125), ("250", 1 / 250), ("500", 1 / 500),
    ("1000", 1 / 1000), ("2000", 1 / 2000), ("4000", 1 / 4000),
]
