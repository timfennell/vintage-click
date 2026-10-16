import Foundation

/// A manual-focus 35 mm prime. Optical character is what the thin-lens
/// sampler can show: the aperture's shape (blades), mechanical vignetting
/// that clips off-axis bokeh into cat's eyes (strong enough, it swirls),
/// rim-bright "soap bubble" bokeh, light fall-off wide open, and colour:
/// lateral (fringes toward the corners) and axial (magenta / green bokeh).
struct Lens {
    let name: String
    let inspiredBy: String
    let focalMM: Float
    let maxAperture: Float      // f-number wide open
    let minAperture: Float
    let blades: Int             // 0 = round
    let bladeRotation: Float    // radians
    let catsEye: Float          // barrel clipping offset at the frame corner, in max-aperture radii
    let soapBubble: Float       // extra weight at the aperture rim (0 = even disc)
    let vignette: Float         // fall-off at the corner, wide open
    let minFocusM: Float
    var lateralCA: Float = 0.0005   // red/blue magnification difference at the corner
    var axialCA: Float = 0          // red/blue focus split, dioptres (bokeh fringes)

    /// The clicks on the aperture ring: full stops, plus the wide-open value.
    var apertureStops: [Float] {
        let full: [Float] = [1.0, 1.4, 2, 2.8, 4, 5.6, 8, 11, 16, 22, 32]
        var stops = full.filter { $0 > maxAperture * 1.02 && $0 <= minAperture * 1.02 }
        stops.insert(maxAperture, at: 0)
        return stops
    }
}

/// The camera bag. Names are made up; `inspiredBy` says what each one plays.
let lensBag: [Lens] = [
    Lens(name: "Kestrel 28mm f/2.8", inspiredBy: "classic compact 28 mm wide-angle",
         focalMM: 28, maxAperture: 2.8, minAperture: 22, blades: 7, bladeRotation: 0.2,
         catsEye: 0.30, soapBubble: 0, vignette: 0.35, minFocusM: 0.2,
         lateralCA: 0.0015, axialCA: 0.01),
    Lens(name: "Kestrel 50mm f/1.4", inspiredBy: "the standard fast fifty",
         focalMM: 50, maxAperture: 1.4, minAperture: 16, blades: 7, bladeRotation: 0.1,
         catsEye: 0.45, soapBubble: 0.15, vignette: 0.40, minFocusM: 0.45,
         lateralCA: 0.0005, axialCA: 0.03),
    Lens(name: "Kestrel Night 58mm f/1.2", inspiredBy: "aspheric low-light f/1.2 normal",
         focalMM: 58, maxAperture: 1.2, minAperture: 16, blades: 9, bladeRotation: 0,
         catsEye: 0.65, soapBubble: 0.05, vignette: 0.50, minFocusM: 0.5,
         lateralCA: 0.0006, axialCA: 0.045),
    Lens(name: "Volna 58mm f/2", inspiredBy: "Soviet Biotar-type swirly normal",
         focalMM: 58, maxAperture: 2, minAperture: 16, blades: 0, bladeRotation: 0,
         catsEye: 1.05, soapBubble: 0.2, vignette: 0.45, minFocusM: 0.5,
         lateralCA: 0.0009, axialCA: 0.035),
    Lens(name: "Kestrel Micro 55mm f/3.5", inspiredBy: "1:2 macro for close-ups",
         focalMM: 55, maxAperture: 3.5, minAperture: 32, blades: 6, bladeRotation: 0.3,
         catsEye: 0.15, soapBubble: 0, vignette: 0.20, minFocusM: 0.24,
         lateralCA: 0.0003, axialCA: 0.01),
    Lens(name: "Kestrel 105mm f/2.5", inspiredBy: "the portrait telephoto",
         focalMM: 105, maxAperture: 2.5, minAperture: 22, blades: 7, bladeRotation: 0.15,
         catsEye: 0.25, soapBubble: 0.05, vignette: 0.25, minFocusM: 1.0,
         lateralCA: 0.0004, axialCA: 0.02),
    Lens(name: "Bubbel 100mm f/2.8", inspiredBy: "triplet with soap-bubble bokeh",
         focalMM: 100, maxAperture: 2.8, minAperture: 22, blades: 15, bladeRotation: 0,
         catsEye: 0.35, soapBubble: 1.6, vignette: 0.30, minFocusM: 1.0,
         lateralCA: 0.001, axialCA: 0.03),
    Lens(name: "Kestrel 135mm f/2.8", inspiredBy: "compact 135 mm short tele",
         focalMM: 135, maxAperture: 2.8, minAperture: 22, blades: 6, bladeRotation: 0.0,
         catsEye: 0.20, soapBubble: 0, vignette: 0.20, minFocusM: 1.3,
         lateralCA: 0.0008, axialCA: 0.025),
]

/// The shutter dial, in seconds (the marks are the nominal ones).
let shutterSpeeds: [(label: String, seconds: Float)] = [
    ("1", 1), ("2", 1 / 2), ("4", 1 / 4), ("8", 1 / 8), ("15", 1 / 15), ("30", 1 / 30),
    ("60", 1 / 60), ("125", 1 / 125), ("250", 1 / 250), ("500", 1 / 500),
    ("1000", 1 / 1000), ("2000", 1 / 2000), ("4000", 1 / 4000),
]
