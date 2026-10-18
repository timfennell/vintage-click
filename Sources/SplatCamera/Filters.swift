import Foundation
import simd

/// A filter screwed onto the front of the lens (makers' names are made up,
/// hinting at the ones they recall: Hoshiya, Tiffield, Coquin, Rochester). Everything that reaches the
/// film (and the finder, and the meter behind the lens) goes through it:
/// `transmission` is how much of each colour it passes (linear Rec.709),
/// and the effect filters scatter some of the light: a starburst grating's
/// spikes off bright points (rainbow ones for a diffraction grating), a
/// soft-focus filter's glow round highlights, a mist filter's veil.
struct LensFilter {
    let name: String
    let about: String
    let group: String
    var transmission = SIMD3<Float>(1, 1, 1)
    var starPoints = 0              // 0: none; 2: a single line; 4, 6, 8: a star
    var starStrength: Float = 0
    var spectral = false            // a diffraction grating: the spikes split into rainbows
    var glow: Float = 0             // highlights' halo
    var soften: Float = 0           // the whole image mixed with a little blur
    var veil: Float = 0             // scattered light lifting the shadows (mist, fog)

    /// The light it loses, in stops (what a TTL meter makes up for).
    var stops: Float {
        let t = simd_dot(transmission, SIMD3<Float>(0.2126, 0.7152, 0.0722))
        return -log2(max(t, 1e-4))
    }
    var hasEffect: Bool { starPoints > 0 || glow > 0 || soften > 0 || veil > 0 }

    /// O[9..11] for the shaders (layout in Shaders.swift, "lens filters").
    /// `threshold`: how bright a point must be to throw spikes or a halo.
    func optics(threshold: Float) -> [SIMD4<Float>] {
        [SIMD4(transmission, 0),
         SIMD4(Float(starPoints), starStrength, spectral ? 1 : 0, 0.35),
         SIMD4(glow, soften, veil, threshold)]
    }
}

/// A colour with a given overall transmission: `shape` sets the hue, scaled so
/// its luminance is `t` (no channel above 1).
func filterColour(_ shape: SIMD3<Float>, t: Float) -> SIMD3<Float> {
    let lum = simd_dot(shape, SIMD3<Float>(0.2126, 0.7152, 0.0722))
    var c = shape * (t / max(lum, 1e-4))
    let m = max(c.x, max(c.y, c.z))
    if m > 1 { c /= m }
    return c
}

let lensFilters: [LensFilter] = [
    LensFilter(name: "No filter", about: "just the lens", group: "none"),
    // Neutral density: faster film, or a wider aperture, in bright light.
    LensFilter(name: "Hoshiya ND2", about: "neutral density, 1 stop: open up a stop in bright light", group: "neutral density",
               transmission: SIMD3(repeating: 0.5)),
    LensFilter(name: "Hoshiya ND4", about: "neutral density, 2 stops", group: "neutral density",
               transmission: SIMD3(repeating: 0.25)),
    LensFilter(name: "Hoshiya ND8", about: "neutral density, 3 stops: fast film wide open in daylight", group: "neutral density",
               transmission: SIMD3(repeating: 0.125)),
    LensFilter(name: "Hoshiya ND64", about: "neutral density, 6 stops: long exposures by day", group: "neutral density",
               transmission: SIMD3(repeating: 1.0 / 64)),
    // Contrast filters for black-and-white film.
    LensFilter(name: "Hoshiya Y2 Yellow", about: "b&w: the everyday filter; skies a touch deeper, clouds stand out", group: "black & white",
               transmission: SIMD3(0.98, 0.90, 0.30)),
    LensFilter(name: "Hoshiya G Orange", about: "b&w: dark skies, smooth skin, haze cut through", group: "black & white",
               transmission: SIMD3(0.95, 0.42, 0.04)),
    LensFilter(name: "Hoshiya R1 Red", about: "b&w: dramatic black skies, foliage darkens", group: "black & white",
               transmission: SIMD3(0.90, 0.07, 0.02)),
    LensFilter(name: "Rochester Wrattle No. 29 Deep Red", about: "b&w: near night-for-day; skies all but black", group: "black & white",
               transmission: SIMD3(0.80, 0.015, 0.01)),
    LensFilter(name: "Hoshiya X1 Green", about: "b&w: foliage lightens, skin deepens, skies a little darker", group: "black & white",
               transmission: SIMD3(0.30, 0.78, 0.25)),
    LensFilter(name: "Rochester Wrattle No. 47 Blue", about: "b&w: haze and fog deepen, reds go dark", group: "black & white",
               transmission: SIMD3(0.04, 0.14, 0.86)),
    // Colour correction and warming for colour film.
    LensFilter(name: "Hoshiya Skylight 1A", about: "colour: takes the blue off shade and sky, a faint warmth", group: "colour correction",
               transmission: SIMD3(1.0, 0.97, 0.97)),
    LensFilter(name: "Tiffield 81A Warming", about: "colour: a gentle warm-up, for overcast and shade", group: "colour correction",
               transmission: SIMD3(1.0, 0.92, 0.80)),
    LensFilter(name: "Tiffield 85B Amber", about: "colour: tungsten film in daylight (or a golden look)", group: "colour correction",
               transmission: SIMD3(0.95, 0.66, 0.36)),
    LensFilter(name: "Tiffield 80A Blue", about: "colour: daylight film under tungsten lights", group: "colour correction",
               transmission: SIMD3(0.36, 0.56, 0.98)),
    // Effects.
    LensFilter(name: "Hoshiya Cross Screen 4X", about: "a cross screen: four spikes off every bright point", group: "effects",
               starPoints: 4, starStrength: 1),
    LensFilter(name: "Hoshiya Cross Screen 6X", about: "six spikes off every bright point", group: "effects",
               starPoints: 6, starStrength: 0.85),
    LensFilter(name: "Hoshiya Cross Screen 8X", about: "eight spikes: very 70s", group: "effects",
               starPoints: 8, starStrength: 0.75),
    LensFilter(name: "Coquin Diffractor 040", about: "bright points throw rainbow streaks to either side", group: "effects",
               starPoints: 2, starStrength: 1.2, spectral: true),
    LensFilter(name: "Coquin Spectral Cross 041", about: "rainbow streaks in four directions", group: "effects",
               starPoints: 4, starStrength: 1, spectral: true),
    LensFilter(name: "Coquin Spectral Star 042", about: "an eight-ray rainbow starburst", group: "effects",
               starPoints: 8, starStrength: 0.8, spectral: true),
    LensFilter(name: "Tiffield Soft/Glow 1", about: "a gentle glow round highlights, still sharp beneath", group: "effects",
               glow: 0.35, soften: 0.12),
    LensFilter(name: "Tiffield Soft/Glow 3", about: "a dreamy glow: highlights bloom, edges melt", group: "effects",
               glow: 0.9, soften: 0.35),
    LensFilter(name: "Tiffield Pro-Haze 2", about: "a pale veil over everything, low contrast and soft light", group: "effects",
               glow: 0.3, soften: 0.15, veil: 0.35),
    LensFilter(name: "Tiffield Black Haze 1", about: "halos on the lights, shadows kept deep: night city film", group: "effects",
               glow: 0.6, soften: 0.06),
    LensFilter(name: "Tiffield Fog 2", about: "a heavy fog: the scene recedes into light", group: "effects",
               glow: 0.4, soften: 0.25, veil: 0.8),
]

/// A sheet of coloured film in front of a light head (Leeward and Rosmont:
/// made-up makers, the gel books they recall).
struct Gel {
    let name: String
    let about: String
    let transmission: SIMD3<Float>
}

/// Colour-correction gels from what they do to tungsten (3200 K) and their
/// published light loss; effect colours from their hue and transmission.
let gels: [Gel] = {
    let daylight = SIMD3<Float>(1, 1, 1)
    let toDaylight = daylight / tungsten        // what a full blue gel does to 3200 K
    let toTungsten = tungsten / daylight
    func part(_ c: SIMD3<Float>, _ k: Float) -> SIMD3<Float> {
        SIMD3(pow(c.x, k), pow(c.y, k), pow(c.z, k))
    }
    return [
        Gel(name: "No gel", about: "the lamp's own 3200 K", transmission: SIMD3(1, 1, 1)),
        Gel(name: "Leeward 201 Full CT Blue", about: "colour correction: tungsten to daylight (5500 K), 1½ stops",
            transmission: filterColour(toDaylight, t: 0.36)),
        Gel(name: "Leeward 202 Half CT Blue", about: "colour correction: halfway to daylight, a cool white",
            transmission: filterColour(part(toDaylight, 0.5), t: 0.52)),
        Gel(name: "Leeward 203 Quarter CT Blue", about: "colour correction: a touch cooler",
            transmission: filterColour(part(toDaylight, 0.25), t: 0.69)),
        Gel(name: "Leeward 204 Full CT Orange", about: "colour correction: deeper than tungsten, sunset warm",
            transmission: filterColour(toTungsten, t: 0.55)),
        Gel(name: "Leeward 205 Half CT Orange", about: "colour correction: warmer still, late afternoon",
            transmission: filterColour(part(toTungsten, 0.5), t: 0.70)),
        Gel(name: "Leeward 206 Quarter CT Orange", about: "colour correction: a touch warmer",
            transmission: filterColour(part(toTungsten, 0.25), t: 0.81)),
        Gel(name: "Rosmont 07 Pale Straw", about: "pale warm yellow: sunlight through a window", transmission: filterColour([1, 0.9, 0.55], t: 0.80)),
        Gel(name: "Rosmont 02 Bastard Amber", about: "warm pinkish amber: flattering skin, a 70s staple",
            transmission: filterColour([1, 0.75, 0.55], t: 0.68)),
        Gel(name: "Rosmont 20 Medium Amber", about: "deep gold: firelight, nostalgia", transmission: filterColour([1, 0.62, 0.22], t: 0.50)),
        Gel(name: "Rosmont 26 Primary Red", about: "saturated red: darkrooms, danger, disco", transmission: filterColour([1, 0.03, 0.03], t: 0.12)),
        Gel(name: "Rosmont 46 Magenta", about: "hot pink-purple: nightclub", transmission: filterColour([1, 0.12, 0.85], t: 0.22)),
        Gel(name: "Rosmont 54 Special Lavender", about: "soft violet: dreamy backlight", transmission: filterColour([0.75, 0.55, 1], t: 0.45)),
        Gel(name: "Rosmont 89 Moss Green", about: "strong green: sci-fi, sickness, the uncanny", transmission: filterColour([0.12, 1, 0.18], t: 0.22)),
        Gel(name: "Rosmont 70 Peacock Blue", about: "blue-green cyan: water, cool modern", transmission: filterColour([0.05, 0.75, 0.85], t: 0.30)),
        Gel(name: "Rosmont 66 Steel Blue", about: "cool pale blue: moonlight on tungsten film", transmission: filterColour([0.55, 0.75, 1], t: 0.48)),
        Gel(name: "Rosmont 85 Deep Night Blue", about: "rich dark blue: night exteriors", transmission: filterColour([0.08, 0.2, 1], t: 0.06)),
    ]
}()
