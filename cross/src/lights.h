// Vintage Click, cross-platform: studio lighting. Ported from Lights.swift
// (the kit, modifiers, placed lights, the plot), Photometry.swift (beam tables
// traced through each head's optics), the gels of Filters.swift and
// PatternArt.swift (gobos and cookies). Keep in step with the Swift.
#pragma once
#include "kit.h"
#include "fog.h"
#include <array>
#include <cmath>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <vector>

inline V3 v3(float x, float y, float z) { return {x, y, z}; }
inline V3 mul3(V3 a, V3 b) { return {a.x * b.x, a.y * b.y, a.z * b.z}; }
inline V3 cross3(V3 a, V3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline V3 norm3(V3 a) { float l = len(a); return l > 0 ? a * (1 / l) : a; }

/// A studio light head from a 1970s tungsten kit.
struct LightHead {
    enum class Kind { Fresnel, Softlight, Ellipsoidal };
    std::string name, inspiredBy;
    Kind kind;
    float lumens;           // out of the front of the lamp
    float spotAngle;        // full beam angle at full spot, degrees
    float floodAngle;       // full beam angle at full flood
    V3 size;                // housing width, height, depth (m)
    float shine;            // how much of the scan's shine it raises (small hard source = 1)
};

/// 3200 K tungsten in linear Rec.709, normalised to green (daylight = 1, 1, 1).
inline const V3 tungsten = V3{1.0f, 0.80f, 0.56f} * (1 / 0.80f);

inline const std::vector<LightHead>& lightKit() {
    static const std::vector<LightHead> k = {
        {"Fresnel 650", "the small 650 W studio Fresnel of the 70s", LightHead::Kind::Fresnel, 4800, 14, 52, {0.20f, 0.20f, 0.24f}, 1},
        {"Fresnel 1K", "the 1 kW workhorse Fresnel with a 6-inch lens", LightHead::Kind::Fresnel, 7500, 12, 50, {0.26f, 0.26f, 0.30f}, 1},
        {"Fresnel 2K", "the 2 kW Fresnel with an 8-inch lens", LightHead::Kind::Fresnel, 15000, 10, 48, {0.34f, 0.34f, 0.38f}, 1},
        {"Softlight 2K", "the 2 kW quartz softlight: lamps hidden, all light off a white trough", LightHead::Kind::Softlight, 18000, 100, 100,
         {0.62f, 0.46f, 0.34f}, 0.35f},
        {"Ellipsoidal 750", "the theatre's ellipsoidal reflector spot: a hard-edged, zooming beam with a gate for metal gobo patterns",
         LightHead::Kind::Ellipsoidal, 6500, 20, 50, {0.24f, 0.24f, 0.62f}, 1},
    };
    return k;
}

/// What can go on or in front of a head: barn doors and flags cut the beam,
/// a cookie on a stand breaks it into soft dapples, a gobo projects a picture.
struct LightModifier {
    enum class Kind { None, Doors, Pattern };
    std::string name, about;
    Kind kind;
    float left = 1, right = 1, top = 1, bottom = 1;   // doors: fractions of the beam's half-width (1 = open)
    int layer = 0; bool gobo = false;                  // pattern: layer in the pattern art; in an ellipsoidal's gate
    bool fits(const LightHead& h) const {
        if (kind == Kind::None) return true;
        if (kind == Kind::Pattern) return gobo == (h.kind == LightHead::Kind::Ellipsoidal);
        return h.kind != LightHead::Kind::Ellipsoidal;
    }
};

inline const std::vector<LightModifier>& lightModifiers() {
    using K = LightModifier::Kind;
    auto doors = [](const char* n, const char* a, float l, float r, float t, float b) {
        LightModifier m{n, a, K::Doors}; m.left = l; m.right = r; m.top = t; m.bottom = b; return m;
    };
    auto pattern = [](const char* n, const char* a, int layer, bool gobo) {
        LightModifier m{n, a, K::Pattern}; m.layer = layer; m.gobo = gobo; return m;
    };
    static const std::vector<LightModifier> m = {
        {"Nothing", "the open beam", K::None},
        doors("Barn doors, nearly open", "four hinged leaves just trimming the beam's edges", 0.8f, 0.8f, 0.8f, 0.8f),
        doors("Barn doors, a slash", "top and bottom leaves closed to a band of light across the set", 1, 1, 0.22f, 0.22f),
        doors("Barn doors, a slit", "side leaves closed to a tall sliver of light", 0.2f, 0.2f, 1, 1),
        doors("Flag off the top", "a black flag on a stand keeping light off the wall above", 1, 1, 0.1f, 1),
        doors("Flag off one side", "a flag cutting the beam down one side", 0.05f, 1, 1, 1),
        pattern("Cookie: leaves", "a cucoloris with leafy holes: soft dappled light, as through trees", 5, false),
        pattern("Cookie: breakup", "a plywood cookie with random holes: broken, uneven light on a wall", 6, false),
        pattern("Cookie: branches", "bare branches against the light: winter, menace", 7, false),
        pattern("Gobo: window", "a four-pane window thrown onto the wall", 0, true),
        pattern("Gobo: venetian blinds", "hard stripes of film noir", 1, true),
        pattern("Gobo: church window", "a gothic arch with tracery", 2, true),
        pattern("Gobo: bars", "prison bars, or a railing's shadow", 3, true),
        pattern("Gobo: leaf breakup", "sharp dappled foliage, the theatre's forest", 4, true),
    };
    return m;
}

/// A colour with a given overall transmission: `shape` sets the hue, scaled so
/// its luminance is `t` (no channel above 1).
inline V3 filterColour(V3 shape, float t) {
    float lum = shape.x * 0.2126f + shape.y * 0.7152f + shape.z * 0.0722f;
    V3 c = shape * (t / std::max(lum, 1e-4f));
    float m = std::max(c.x, std::max(c.y, c.z));
    if (m > 1) c = c * (1 / m);
    return c;
}

/// A sheet of coloured film in front of a light head.
struct Gel { std::string name, about; V3 transmission; };

inline const std::vector<Gel>& gels() {
    static const std::vector<Gel> g = [] {
        V3 daylight{1, 1, 1};
        V3 toDaylight{daylight.x / tungsten.x, daylight.y / tungsten.y, daylight.z / tungsten.z};
        V3 toTungsten{tungsten.x / daylight.x, tungsten.y / daylight.y, tungsten.z / daylight.z};
        auto part = [](V3 c, float k) { return V3{std::pow(c.x, k), std::pow(c.y, k), std::pow(c.z, k)}; };
        return std::vector<Gel>{
            {"No gel", "the lamp's own 3200 K", {1, 1, 1}},
            {"Leeward 201 Full CT Blue", "colour correction: tungsten to daylight (5500 K), 1½ stops", filterColour(toDaylight, 0.36f)},
            {"Leeward 202 Half CT Blue", "colour correction: halfway to daylight, a cool white", filterColour(part(toDaylight, 0.5f), 0.52f)},
            {"Leeward 203 Quarter CT Blue", "colour correction: a touch cooler", filterColour(part(toDaylight, 0.25f), 0.69f)},
            {"Leeward 204 Full CT Orange", "colour correction: deeper than tungsten, sunset warm", filterColour(toTungsten, 0.55f)},
            {"Leeward 205 Half CT Orange", "colour correction: warmer still, late afternoon", filterColour(part(toTungsten, 0.5f), 0.70f)},
            {"Leeward 206 Quarter CT Orange", "colour correction: a touch warmer", filterColour(part(toTungsten, 0.25f), 0.81f)},
            {"Rosmont 07 Pale Straw", "pale warm yellow: sunlight through a window", filterColour({1, 0.9f, 0.55f}, 0.80f)},
            {"Rosmont 02 Bastard Amber", "warm pinkish amber: flattering skin, a 70s staple", filterColour({1, 0.75f, 0.55f}, 0.68f)},
            {"Rosmont 20 Medium Amber", "deep gold: firelight, nostalgia", filterColour({1, 0.62f, 0.22f}, 0.50f)},
            {"Rosmont 26 Primary Red", "saturated red: darkrooms, danger, disco", filterColour({1, 0.03f, 0.03f}, 0.12f)},
            {"Rosmont 46 Magenta", "hot pink-purple: nightclub", filterColour({1, 0.12f, 0.85f}, 0.22f)},
            {"Rosmont 54 Special Lavender", "soft violet: dreamy backlight", filterColour({0.75f, 0.55f, 1}, 0.45f)},
            {"Rosmont 89 Moss Green", "strong green: sci-fi, sickness, the uncanny", filterColour({0.12f, 1, 0.18f}, 0.22f)},
            {"Rosmont 70 Peacock Blue", "blue-green cyan: water, cool modern", filterColour({0.05f, 0.75f, 0.85f}, 0.30f)},
            {"Rosmont 66 Steel Blue", "cool pale blue: moonlight on tungsten film", filterColour({0.55f, 0.75f, 1}, 0.48f)},
            {"Rosmont 85 Deep Night Blue", "rich dark blue: night exteriors", filterColour({0.08f, 0.2f, 1}, 0.06f)},
        };
    }();
    return g;
}

// ---------------------------------------------------------------------------
// Photometry: where a head's light actually goes, traced through its optics.

struct BeamTable {
    static constexpr int thetaBins = 32;   // angle off axis, 0..90 degrees, finer near the axis
    static constexpr int phiBins = 8;      // angle around the axis, 0..90 degrees (mirrored)
    static constexpr float power = 1.3f;   // bin edges at 90 * (t / 32)^1.3 degrees
    std::vector<V3> cd = std::vector<V3>(thetaBins * phiBins);   // candela per colour

    static float edge(float t) { return std::pow(t / float(thetaBins), power) * float(M_PI) / 2; }
    static float theta(float t) { return edge(t + 0.5f); }
    static int bin(float th) {
        return std::min(thetaBins - 1, int(std::pow(std::max(0.f, th) / (float(M_PI) / 2), 1 / power) * float(thetaBins)));
    }
    std::vector<float> profile() const {
        std::vector<float> prof(thetaBins, 0.f);
        for (int t = 0; t < thetaBins; t++)
            for (int p = 0; p < phiBins; p++) prof[t] += cd[t * phiBins + p].y / float(phiBins);
        std::vector<float> out(thetaBins);
        for (int t = 0; t < thetaBins; t++) {
            float a = prof[std::max(0, t - 1)], c = prof[std::min(thetaBins - 1, t + 1)];
            out[t] = 0.25f * a + 0.5f * prof[t] + 0.25f * c;
        }
        return out;
    }
    /// Full angle (degrees) where the beam falls to this fraction of its peak.
    float angle(float fraction) const {
        auto prof = profile();
        float top = *std::max_element(prof.begin(), prof.end());
        if (!(top > 0)) return 0;
        int first = int(std::find(prof.begin(), prof.end(), top) - prof.begin());
        for (int t = first; t < thetaBins - 1; t++)
            if (prof[t + 1] < top * fraction) {
                float f = (prof[t] - top * fraction) / std::max(prof[t] - prof[t + 1], 1e-9f);
                float th = theta(float(t)) + (theta(float(t + 1)) - theta(float(t))) * f;
                return 2 * th * 180 / float(M_PI);
            }
        return 180;
    }
    static BeamTable mix(const BeamTable& a, const BeamTable& b, float t) {
        BeamTable o;
        for (size_t i = 0; i < o.cd.size(); i++) o.cd[i] = a.cd[i] + (b.cd[i] - a.cd[i]) * t;
        return o;
    }
};

namespace photometry {
struct FresnelOptics { float lensR, focal, coilR, coilL; };
inline FresnelOptics optics(const LightHead& h) {
    if (h.lumens < 6000) return {0.05f, 0.080f, 0.003f, 0.010f};     // 650 W, 4" lens
    if (h.lumens < 10000) return {0.075f, 0.115f, 0.004f, 0.014f};   // 1 kW, 6"
    return {0.10f, 0.150f, 0.005f, 0.018f};                           // 2 kW, 8"
}
constexpr int steps = 9;

struct Rng {
    uint64_t s;
    float next() { s = s * 6364136223846793005ull + 1442695040888963407ull; return float((s >> 40) & 0xFFFFFF) / 16777216; }
};
inline void accumulate(std::vector<V3>& hist, V3 d, V3 w) {
    if (!(d.z > 0)) return;
    float th = std::acos(std::min(1.f, d.z));
    float ph = std::atan2(std::fabs(d.y), std::fabs(d.x));
    int t = BeamTable::bin(th);
    int p = std::min(BeamTable::phiBins - 1, int(ph / (float(M_PI) / 2) * float(BeamTable::phiBins)));
    hist[t * BeamTable::phiBins + p] = hist[t * BeamTable::phiBins + p] + w;
}
/// Histogram of ray energy -> candela, scaled so the total is the head's lumens.
inline BeamTable toTable(const std::vector<V3>& hist, float lumens) {
    BeamTable table;
    V3 total{};
    for (auto& v : hist) total = total + v;
    V3 nrm{lumens / std::max(total.x, 1e-9f), lumens / std::max(total.y, 1e-9f), lumens / std::max(total.z, 1e-9f)};
    for (int t = 0; t < BeamTable::thetaBins; t++) {
        float a = BeamTable::edge(float(t)), b = BeamTable::edge(float(t + 1));
        float ring = 2 * float(M_PI) * (std::cos(a) - std::cos(b)) / float(BeamTable::phiBins);
        for (int p = 0; p < BeamTable::phiBins; p++)
            table.cd[t * BeamTable::phiBins + p] = mul3(hist[t * BeamTable::phiBins + p], nrm) * (1 / std::max(ring, 1e-6f));
    }
    return table;
}
inline float smoothstepF(float e0, float e1, float x) { float t = std::clamp((x - e0) / (e1 - e0), 0.f, 1.f); return t * t * (3 - 2 * t); }

/// Lens at z = 0 (beam along +z), coil centred at z = -lampAt, upright (along y).
inline BeamTable fresnel(const LightHead& kit, const FresnelOptics& o, float s, float k, float stipple, int rays) {
    Rng rng{0x9E3779B97F4A7C15ull + uint64_t(s * 1e6f)};
    std::vector<V3> hist(BeamTable::thetaBins * BeamTable::phiBins);
    V3 centre{0, 0, -s};
    // The lens bends blue a little more than red: its colour fringe.
    float focal[3] = {o.focal * 1.012f, o.focal, o.focal * 0.988f};
    for (int ray = 0; ray < rays; ray++) {
        float a = rng.next() * 2 * float(M_PI);
        V3 p = centre + V3{o.coilR * std::cos(a), (rng.next() - 0.5f) * o.coilL, o.coilR * std::sin(a)};
        float w = 1;
        bool reflected = rng.next() < 0.5f;
        if (reflected) { p = centre * 2 - p; w = 0.85f; }
        float r = o.lensR * std::sqrt(rng.next()), b = rng.next() * 2 * float(M_PI);
        V3 lp{r * std::cos(b), r * std::sin(b), 0};
        V3 v = lp - p;
        float dist = len(v);
        V3 din = v * (1 / dist);
        w *= din.z / (dist * dist);
        if (reflected) {
            float tc = dot(centre - p, din);
            V3 closest = p + din * tc - centre;
            if (std::fabs(closest.y) < o.coilL / 2 && std::sqrt(closest.x * closest.x + closest.z * closest.z) < o.coilR * 0.9f) w *= 0.25f;
        }
        w *= 0.85f;
        if (rng.next() < 0.06f) {
            float u = rng.next(), c = rng.next() * 2 * float(M_PI);
            float st = std::sqrt(u) * 0.9f;
            V3 d{st * std::cos(c), st * std::sin(c), std::sqrt(std::max(0.f, 1 - st * st))};
            accumulate(hist, d, V3{w, w, w});
            continue;
        }
        float sx = din.x / din.z, sy = din.y / din.z;
        float rr = r / o.lensR;
        float sa = k * rr * rr * rr;
        V2 rad = r > 1e-6f ? V2{lp.x / r, lp.y / r} : V2{1, 0};
        float jx = rng.next() + rng.next() + rng.next() - 1.5f;
        float jy = rng.next() + rng.next() + rng.next() - 1.5f;
        V2 jitter{jx * (stipple * 2), jy * (stipple * 2)};
        for (int c = 0; c < 3; c++) {
            float ox = sx - lp.x / focal[c] - sa * rad.x + jitter.x;
            float oy = sy - lp.y / focal[c] - sa * rad.y + jitter.y;
            V3 d = norm3(V3{ox, oy, 1});
            V3 wc{c == 0 ? w : 0, c == 1 ? w : 0, c == 2 ? w : 0};
            accumulate(hist, d, wc);
        }
    }
    return toTable(hist, kit.lumens);
}

/// An ellipsoidal spot: an even field with a sharp edge, slightly brighter in the middle.
inline BeamTable ellipsoidal(const LightHead& kit, float fieldDegrees) {
    std::vector<V3> hist(BeamTable::thetaBins * BeamTable::phiBins);
    float half = fieldDegrees * float(M_PI) / 360, edge = 1.2f * float(M_PI) / 180;
    for (int t = 0; t < BeamTable::thetaBins; t++) {
        float th = BeamTable::theta(float(t));
        float a = BeamTable::edge(float(t)), b = BeamTable::edge(float(t + 1));
        float ring = 2 * float(M_PI) * (std::cos(a) - std::cos(b)) / float(BeamTable::phiBins);
        float inside = 1 - smoothstepF(half - edge, half + edge, th);
        float hot = 1 - 0.15f * (th / std::max(half, 1e-3f)) * (th / std::max(half, 1e-3f));
        float v = std::max(0.f, inside * hot) * ring;
        for (int p = 0; p < BeamTable::phiBins; p++) hist[t * BeamTable::phiBins + p] = {v, v, v};
    }
    return toTable(hist, kit.lumens);
}

/// Open-fronted box with a white diffusing trough at the back; the box walls absorb.
inline BeamTable softlight(const LightHead& kit) {
    Rng rng{0xC0FFEE};
    std::vector<V3> hist(BeamTable::thetaBins * BeamTable::phiBins);
    float w = kit.size.x, h = kit.size.y, depth = kit.size.z;
    for (int i = 0; i < 400000; i++) {
        float x = (rng.next() - 0.5f) * w * 0.95f, y = (rng.next() - 0.5f) * h * 0.95f;
        float z = -depth * (1 - 0.5f * std::pow(2 * y / h, 2.f));
        float u = rng.next(), c = rng.next() * 2 * float(M_PI);
        float st = std::sqrt(u);
        V3 d{st * std::cos(c), st * std::sin(c), std::sqrt(std::max(0.f, 1 - u))};
        float t = -z / d.z;
        float ox = x + d.x * t, oy = y + d.y * t;
        if (!(std::fabs(ox) < w / 2 && std::fabs(oy) < h / 2)) continue;
        accumulate(hist, d, {1, 1, 1});
    }
    return toTable(hist, kit.lumens);
}

inline const std::vector<BeamTable>& tablesFor(int head) {
    static std::mutex m;
    static std::map<int, std::vector<BeamTable>> cache;
    {
        std::lock_guard<std::mutex> l(m);
        auto it = cache.find(head);
        if (it != cache.end()) return it->second;
    }
    const LightHead& kit = lightKit()[head];
    std::vector<BeamTable> tables;
    if (kit.kind == LightHead::Kind::Softlight) {
        tables.assign(steps, softlight(kit));
    } else if (kit.kind == LightHead::Kind::Ellipsoidal) {
        for (int i = 0; i < steps; i++) {
            float t = float(i) / float(steps - 1);
            tables.push_back(ellipsoidal(kit, kit.floodAngle + (kit.spotAngle - kit.floodAngle) * t));
        }
    } else {
        FresnelOptics o = optics(kit);
        // Calibrate to the head's published angles: the stipple sets the full
        // spot, the lamp's closest approach to the lens the full flood.
        const float k = 0.04f;
        float lo = 0, hi = 0.25f;
        for (int it = 0; it < 10; it++) {
            float d = (lo + hi) / 2;
            float a = fresnel(kit, o, o.focal, k, d, 60000).angle(0.5f);
            if (a < kit.spotAngle) lo = d; else hi = d;
        }
        float stipple = (lo + hi) / 2;
        float nearLo = 0.2f, nearHi = 1.0f;
        for (int it = 0; it < 10; it++) {
            float mm = (nearLo + nearHi) / 2;
            float a = fresnel(kit, o, o.focal * mm, k, stipple, 60000).angle(0.5f);
            if (a > kit.floodAngle) nearLo = mm; else nearHi = mm;
        }
        float flood = (nearLo + nearHi) / 2;
        for (int i = 0; i < steps; i++) {
            float t = float(i) / float(steps - 1);
            float s = o.focal * (flood + (1 - flood) * std::pow(t, 0.6f));
            tables.push_back(fresnel(kit, o, s, k, stipple, 400000));
        }
    }
    std::lock_guard<std::mutex> l(m);
    return cache.emplace(head, std::move(tables)).first->second;
}

/// The head's beam at this spot/flood setting (0 = full flood, 1 = full spot).
inline BeamTable table(int head, float spot) {
    const auto& tables = tablesFor(head);
    float x = std::clamp(spot, 0.f, 1.f) * float(steps - 1);
    int i = std::min(int(x), steps - 2);
    return BeamTable::mix(tables[i], tables[i + 1], x - float(i));
}
}  // namespace photometry

// ---------------------------------------------------------------------------
// Lights in the scene.

/// A light standing in the scene.
struct PlacedLight {
    int head = 1;              // index into lightKit
    V3 position;               // scene units
    V3 aim{0, 0, 1};           // unit, where the lens points
    float spot = 0.5f;         // 0 = full flood, 1 = full spot
    float dimmerStops = 0;     // scrims / dimmer: 0 = full, -1 = half
    int gel = 0;               // index into gels (0: none)
    int modifier = 0;          // index into lightModifiers (0: nothing)
    float patternFocus = 0.25f;   // a gobo's focus (0 sharp ... 1 soft), or a cookie's distance (0 near ... 1 far)
    int flare = -1;            // lens flare from this light: -1 unset (off), 0 off, 1 on
    bool flareOn() const { return flare == 1; }

    const LightHead& kit() const { return lightKit()[head]; }
    bool fits(const LightModifier& m) const { return m.fits(kit()); }
    BeamTable beam() const { return photometry::table(head, spot); }
    float beamAngle() const { return beam().angle(0.5f); }

    /// The light's own axes: forward along the aim, up as close to world up as it goes.
    void frame(V3 up, V3& f, V3& r, V3& u) const {
        f = norm3(aim);
        r = cross3(f, up);
        if (len(r) < 1e-4f) r = cross3(f, {1, 0, 0});
        r = norm3(r);
        u = cross3(r, f);
    }

    /// For the relight kernel: six float4s, then the beam table (256 rows).
    /// Intensities are relative to the illuminance the scan was captured at,
    /// 2.5 * 2^EV lux at ISO 100.
    void packed(float metresPerUnit, float sceneEV, V3 up, std::vector<V4>& head, std::vector<V4>& tableRows) const {
        float eRef = 2.5f * std::exp2(sceneEV);
        V3 f, r, u;
        frame(up, f, r, u);
        BeamTable b = beam();
        float halfField = std::tan(std::min(b.angle(0.1f) * 0.62f, 80.f) * float(M_PI) / 180);
        V4 pat{-1, halfField, 0, 1};
        V4 doors{-100, 100, -100, 100};
        const LightModifier& mod = fits(lightModifiers()[modifier]) ? lightModifiers()[modifier] : lightModifiers()[0];
        if (mod.kind == LightModifier::Kind::Doors) {
            float hw = std::tan(b.angle(0.5f) * float(M_PI) / 360) * 1.6f;
            doors = {-hw * mod.left, hw * mod.right, -hw * mod.bottom, hw * mod.top};
        } else if (mod.kind == LightModifier::Kind::Pattern) {
            float lod = mod.gobo ? patternFocus * 4 : 2 + (1 - patternFocus) * 3;
            pat = {float(mod.layer), halfField * (mod.gobo ? 0.82f : 1.f), lod, mod.gobo ? 0.f : 1.f};
        }
        V3 col = mul3(tungsten, gels()[gel].transmission);
        head.push_back({position.x, position.y, position.z, 0});
        head.push_back({f.x, f.y, f.z, std::exp2(dimmerStops) / eRef});
        head.push_back({col.x, col.y, col.z, kit().shine});
        head.push_back({r.x, r.y, r.z, metresPerUnit});
        head.push_back(pat);
        head.push_back(doors);
        for (auto& c : b.cd) tableRows.push_back({c.x, c.y, c.z, 0});
    }

    /// Wireframe of the head (world-space segments), sized in metres.
    std::vector<std::pair<V3, V3>> wireframe(V3 up, float metresPerUnit, float beamTo) const {
        V3 f, r, u;
        frame(up, f, r, u);
        float s = 1 / metresPerUnit;
        float w = kit().size.x * s, h = kit().size.y * s, d = kit().size.z * s;
        V3 p = position;
        std::vector<std::pair<V3, V3>> segs;
        auto ring = [&](V3 c, float rad, int n = 16) {
            std::vector<V3> pts;
            for (int i = 0; i < n; i++) {
                float a = float(i) / float(n) * 2 * float(M_PI);
                pts.push_back(c + (r * std::cos(a) + u * std::sin(a)) * rad);
            }
            return pts;
        };
        auto loop = [&](const std::vector<V3>& pts) {
            for (size_t i = 0; i < pts.size(); i++) segs.push_back({pts[i], pts[(i + 1) % pts.size()]});
        };
        switch (kit().kind) {
        case LightHead::Kind::Fresnel: {
            V3 front = p + f * (d * 0.5f), back = p - f * (d * 0.5f);
            auto fr = ring(front, w * 0.5f), br = ring(back, w * 0.46f);
            loop(fr); loop(br);
            for (int i = 0; i < 16; i += 4) segs.push_back({fr[i], br[i]});
            loop(ring(front + f * (w * 0.01f), w * 0.32f, 12));
            loop(ring(front + f * (w * 0.01f), w * 0.16f, 8));
            segs.push_back({back + u * (w * 0.46f), back + u * (w * 0.6f)});
            segs.push_back({front + u * (w * 0.5f), front + u * (w * 0.6f)});
            segs.push_back({back + u * (w * 0.6f), front + u * (w * 0.6f)});
            float yoke = w * 0.62f;
            segs.push_back({p + r * yoke, p + r * yoke - u * (h * 0.75f)});
            segs.push_back({p - r * yoke, p - r * yoke - u * (h * 0.75f)});
            segs.push_back({p + r * yoke - u * (h * 0.75f), p - r * yoke - u * (h * 0.75f)});
            segs.push_back({p - u * (h * 0.75f), p - u * (h * 1.3f)});
            break;
        }
        case LightHead::Kind::Softlight: {
            V3 fc = p + f * (d * 0.5f), bc = p - f * (d * 0.5f);
            V3 fw = r * (w * 0.5f), fh = u * (h * 0.5f);
            const float corners[4][2] = {{-1, -1}, {1, -1}, {1, 1}, {-1, 1}};
            std::vector<V3> front, back;
            for (auto& c : corners) {
                front.push_back(fc + fw * c[0] + fh * c[1]);
                back.push_back(bc + (fw * c[0] + fh * c[1]) * 0.7f);
            }
            loop(front); loop(back);
            for (int i = 0; i < 4; i++) segs.push_back({front[i], back[i]});
            for (int k = 1; k <= 3; k++) {
                float t = float(k) / 4, y = -0.5f + t;
                float depth = 0.35f * (1 - 4 * (t - 0.5f) * (t - 0.5f));
                segs.push_back({fc - fw + u * (h * y) - f * (d * depth), fc + fw + u * (h * y) - f * (d * depth)});
            }
            segs.push_back({p - u * (h * 0.5f), p - u * (h * 1.2f)});
            break;
        }
        case LightHead::Kind::Ellipsoidal: {
            V3 back = p - f * (d * 0.5f), gate = p - f * (d * 0.05f), front = p + f * (d * 0.5f);
            auto rb = ring(back, w * 0.42f), rg = ring(gate, w * 0.5f), rf = ring(front, w * 0.36f);
            loop(rb); loop(rg); loop(rf);
            loop(ring(p - f * (d * 0.25f), w * 0.5f));
            for (int i = 0; i < 16; i += 4) { segs.push_back({rb[i], rg[i]}); segs.push_back({rg[i], rf[i]}); }
            const V3 pairs[4][2] = {{r, u}, {r * -1, u}, {u, r}, {u * -1, r}};
            for (auto& ab : pairs) {
                V3 a = ab[0], bb = ab[1];
                V3 c = gate + a * (w * 0.5f);
                segs.push_back({c - bb * (w * 0.12f), c + a * (w * 0.18f) - bb * (w * 0.12f)});
                segs.push_back({c + bb * (w * 0.12f), c + a * (w * 0.18f) + bb * (w * 0.12f)});
            }
            segs.push_back({p - u * (h * 0.5f), p - u * (h * 1.25f)});
            break;
        }
        }
        // The beam, out to the subject: where the light falls.
        if (beamTo > 0) {
            float half = beamAngle() * float(M_PI) / 360;
            V3 end = p + f * beamTo;
            float rad = beamTo * std::tan(half);
            auto edge = ring(end, rad, 24);
            loop(edge);
            for (int i = 0; i < 24; i += 6) segs.push_back({p + f * (d * 0.5f), edge[i]});
        }
        return segs;
    }
};

/// What the gaffer has set: the lights, the house lights, and which is in hand.
struct LightingPlot {
    std::vector<PlacedLight> lights;
    float ambient = 1;              // the house lights: share of the scan as captured
    V3 ambientTint{1, 1, 1};
    std::string ambientName = "day";
    int selected = 0;
    bool carrying = false;
    int kitChoice = 1;              // what the next light added will be
    V3 up{0, -1, 0};                // the world's up, for the heads' yokes
    /// The scene's fog, lit by the house lights (a .vcscene's; empty: clear air).
    SceneFog fog;
    /// The fog's light: the house lights on a white surface, as the frame shows it.
    V3 fogLight() const { return ambientTint * (ambient * 0.75f); }

    struct House { const char* name; float level; V3 tint; };
    /// The scan's own light, from full day down to moonlight, as a share of the light it was captured in.
    static const std::vector<House>& houseLevels() {
        static const std::vector<House> h = {
            {"day", 1, {1, 1, 1}},
            {"overcast", 0.5f, {0.95f, 0.98f, 1.05f}},
            {"late afternoon", 0.25f, {1.1f, 0.95f, 0.8f}},
            {"dusk", 0.005f, {0.75f, 0.85f, 1.1f}},
            {"city night", 0.0005f, {0.85f, 0.8f, 0.9f}},
            {"moonlight", 0.000003f, {0.55f, 0.72f, 1.1f}},
            {"dark", 0, {1, 1, 1}},
        };
        return h;
    }
    void setHouseLights(const std::string& name) {
        for (auto& h : houseLevels())
            if (name == h.name) { ambientName = h.name; ambient = h.level; ambientTint = h.tint; }
    }
    void cycleHouseLights() {
        auto& h = houseLevels();
        size_t i = 0;
        for (size_t k = 0; k < h.size(); k++) if (ambientName == h[k].name) i = k;
        setHouseLights(h[(i + 1) % h.size()].name);
    }
};

// ---------------------------------------------------------------------------
// The cut patterns lights shine through (PatternArt.swift): white passes
// light, black stops it. 256 x 256, eight layers; the GPU makes the mips.

namespace pattern_art {
constexpr int size = 256;

struct Grit {
    uint64_t state;
    explicit Grit(uint64_t seed) : state(seed * 6364136223846793005ull + 1442695040888963407ull) {}
    uint64_t next() { state = state * 6364136223846793005ull + 1442695040888963407ull; return state >> 33; }
    double unit() { return double(next() % 1000000) / 1000000; }
};

/// A tiny anti-aliased painter in Core Graphics' coordinates (y up, origin
/// bottom-left): each pixel 4 x 4 samples, a shape's coverage composited in grey.
struct Painter {
    std::vector<float> px = std::vector<float>(size * size, 0.f);   // row 0 at the bottom
    float grey = 1;
    // Transform: the current translate + rotate.
    double tx = 0, ty = 0, rot = 0;
    void fillWith(const std::function<bool(double, double)>& inside, double x0, double y0, double x1, double y1) {
        int ix0 = std::max(0, int(std::floor(x0))), iy0 = std::max(0, int(std::floor(y0)));
        int ix1 = std::min(size - 1, int(std::ceil(x1))), iy1 = std::min(size - 1, int(std::ceil(y1)));
        for (int y = iy0; y <= iy1; y++)
            for (int x = ix0; x <= ix1; x++) {
                int c = 0;
                for (int sy = 0; sy < 4; sy++)
                    for (int sx = 0; sx < 4; sx++)
                        if (inside(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4)) c++;
                if (c) { float a = c / 16.f; float& v = px[size_t(y) * size + x]; v = v * (1 - a) + grey * a; }
            }
    }
    void rect(double x, double y, double w, double h) {
        fillWith([&](double px_, double py_) { return px_ >= x && px_ < x + w && py_ >= y && py_ < y + h; }, x, y, x + w, y + h);
    }
    /// An ellipse in the current transform's frame.
    void ellipse(double x, double y, double w, double h) {
        double cx = x + w / 2, cy = y + h / 2, a = w / 2, b = h / 2;
        double c = std::cos(rot), s = std::sin(rot);
        double R = std::max(a, b);
        double wx = tx + c * cx - s * cy, wy = ty + s * cx + c * cy;
        fillWith([&](double px_, double py_) {
            double dx = px_ - tx, dy = py_ - ty;
            double lx = c * dx + s * dy - cx, ly = -s * dx + c * dy - cy;
            return (lx * lx) / (a * a) + (ly * ly) / (b * b) <= 1;
        }, wx - R, wy - R, wx + R, wy + R);
    }
    /// An ellipse's outline, `lw` wide.
    void strokeEllipse(double x, double y, double w, double h, double lw) {
        double cx = x + w / 2, cy = y + h / 2, a = w / 2, b = h / 2;
        fillWith([&](double px_, double py_) {
            double dx = (px_ - cx) / a, dy = (py_ - cy) / b;
            double r = std::sqrt(dx * dx + dy * dy);
            double dist = std::fabs(r - 1) * std::min(a, b);
            return dist <= lw / 2;
        }, cx - a - lw, cy - b - lw, cx + a + lw, cy + b + lw);
    }
    /// A closed polygon (even-odd).
    void polygon(const std::vector<std::pair<double, double>>& pts) {
        double x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
        for (auto& p : pts) { x0 = std::min(x0, p.first); y0 = std::min(y0, p.second); x1 = std::max(x1, p.first); y1 = std::max(y1, p.second); }
        fillWith([&](double px_, double py_) {
            bool in = false;
            for (size_t i = 0, j = pts.size() - 1; i < pts.size(); j = i++) {
                auto& a = pts[i]; auto& b = pts[j];
                if ((a.second > py_) != (b.second > py_) &&
                    px_ < (b.first - a.first) * (py_ - a.second) / (b.second - a.second) + a.first) in = !in;
            }
            return in;
        }, x0, y0, x1, y1);
    }
    /// A line with round caps.
    void line(double ax, double ay, double bx, double by, double lw) {
        double r = lw / 2;
        fillWith([&](double px_, double py_) {
            double vx = bx - ax, vy = by - ay, wx = px_ - ax, wy = py_ - ay;
            double t = std::clamp((wx * vx + wy * vy) / std::max(vx * vx + vy * vy, 1e-12), 0.0, 1.0);
            double dx = wx - t * vx, dy = wy - t * vy;
            return dx * dx + dy * dy <= r * r;
        }, std::min(ax, bx) - r, std::min(ay, by) - r, std::max(ax, bx) + r, std::max(ay, by) + r);
    }
};

inline void disc(Painter& c, double s) { c.grey = 1; c.ellipse(s * 0.02, s * 0.02, s * 0.96, s * 0.96); }

inline void window(Painter& c, double s) {
    c.grey = 1;
    double w = s * 0.62, h = s * 0.78, x0 = (s - w) / 2, y0 = (s - h) / 2, bar = s * 0.035;
    double pw = (w - bar) / 2, ph = (h - bar) / 2;
    for (int i = 0; i < 2; i++)
        for (int j = 0; j < 2; j++) c.rect(x0 + i * (pw + bar), y0 + j * (ph + bar), pw, ph);
}
inline void blinds(Painter& c, double s) {
    disc(c, s);
    c.grey = 0;
    const int n = 11;
    for (int k = 0; k < n; k++) c.rect(0, s * (k + 0.55) / n, s, s / n * 0.42);
}
/// A gothic lancet window with a round rose above two lights.
inline void church(Painter& c, double s) {
    c.grey = 1;
    double w = s * 0.5, x0 = (s - w) / 2, base = s * 0.08, spring = s * 0.55;
    std::vector<std::pair<double, double>> pts = {{x0, base}, {x0, spring}};
    // Arc about (x0 + w, spring) from 180 to 120 degrees, then about (x0, spring) from 60 to 0 degrees (clockwise in CG).
    for (int k = 0; k <= 24; k++) { double a = M_PI - (M_PI / 3) * k / 24; pts.push_back({x0 + w + w * std::cos(a), spring + w * std::sin(a)}); }
    for (int k = 0; k <= 24; k++) { double a = M_PI / 3 - (M_PI / 3) * k / 24; pts.push_back({x0 + w * std::cos(a), spring + w * std::sin(a)}); }
    pts.push_back({x0 + w, base});
    c.polygon(pts);
    c.grey = 0;
    c.rect(s / 2 - s * 0.014, base, s * 0.028, spring - base + s * 0.04);
    c.rect(x0, spring * 0.62, w, s * 0.022);
    c.strokeEllipse(s / 2 - s * 0.08, spring + s * 0.07, s * 0.16, s * 0.16, s * 0.022);
}
inline void bars(Painter& c, double s) {
    disc(c, s);
    c.grey = 0;
    for (int k = 0; k < 7; k++) { double x = s * (k + 0.5) / 7; c.rect(x - s * 0.018, 0, s * 0.036, s); }
    c.rect(0, s * 0.18, s, s * 0.04);
    c.rect(0, s * 0.78, s, s * 0.04);
}
/// Leaves: dark ellipses at all angles over light, a few gaps.
inline void leaves(Painter& c, double s, int count, uint64_t seed, bool open) {
    if (open) disc(c, s); else { c.grey = 1; c.rect(0, 0, s, s); }
    c.grey = 0;
    Grit r(seed);
    for (int i = 0; i < count; i++) {
        double x = r.unit() * s, y = r.unit() * s;
        double l = s * (0.04 + 0.07 * r.unit()), w = l * (0.35 + 0.25 * r.unit());
        c.tx = x; c.ty = y; c.rot = r.unit() * M_PI;
        c.ellipse(-l / 2, -w / 2, l, w);
        c.tx = c.ty = c.rot = 0;
    }
}
/// A plywood cookie: board with random rounded holes.
inline void breakup(Painter& c, double s) {
    c.grey = 1;
    Grit r(37);
    for (int i = 0; i < 38; i++) {
        double x = r.unit() * s, y = r.unit() * s, rad = s * (0.025 + 0.06 * r.unit());
        std::vector<std::pair<double, double>> pts;
        for (int k = 0; k < 10; k++) {
            double a = double(k) / 10 * 2 * M_PI;
            double rr = rad * (0.7 + 0.5 * r.unit());
            double px_ = x + std::cos(a) * rr;
            double py_ = y + std::sin(a) * rr * (0.6 + 0.6 * r.unit());
            pts.push_back({px_, py_});
        }
        c.polygon(pts);
    }
}
/// Bare branches: dark forking lines over light.
inline void branches(Painter& c, double s) {
    c.grey = 1;
    c.rect(0, 0, s, s);
    c.grey = 0;
    Grit r(53);
    std::function<void(double, double, double, double, double, int)> branch =
        [&](double px_, double py_, double a, double len_, double width, int depth) {
            if (depth <= 0 || len_ <= 2) return;
            double qx = px_ + std::cos(a) * len_, qy = py_ + std::sin(a) * len_;
            c.line(px_, py_, qx, qy, width);
            for (int k = 0; k < 2; k++) branch(qx, qy, a + (r.unit() - 0.5) * 1.3, len_ * (0.62 + 0.2 * r.unit()), width * 0.68, depth - 1);
        };
    branch(s * 0.15, -s * 0.05, 1.15, s * 0.32, s * 0.05, 7);
    branch(s * 0.95, s * 0.1, 2.3, s * 0.28, s * 0.04, 6);
}

/// The eight layers, as Core Graphics' bitmap memory holds them (top row first), 0...255.
inline std::vector<uint8_t> make() {
    using Draw = void (*)(Painter&, double);
    static const Draw layers[] = {
        window, blinds, church, bars,
        [](Painter& c, double s) { leaves(c, s, 150, 11, true); },
        [](Painter& c, double s) { leaves(c, s, 120, 23, false); },
        breakup, branches};
    std::vector<uint8_t> out;
    for (auto draw : layers) {
        Painter p;
        draw(p, double(size));
        for (int y = size - 1; y >= 0; y--)
            for (int x = 0; x < size; x++) out.push_back(uint8_t(std::clamp(p.px[size_t(y) * size + x], 0.f, 1.f) * 255 + 0.5f));
    }
    return out;
}
}  // namespace pattern_art
