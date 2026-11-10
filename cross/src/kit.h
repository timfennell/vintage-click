// Vintage Click, cross-platform: the camera's kit (lenses, film) and the body
// that holds it, ported from the Swift app (Lens.swift, FilmStock.swift,
// CameraBody.swift). Units and behaviour match it line for line.
#pragma once
#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

struct V2 { float x = 0, y = 0; };
struct V3 { float x = 0, y = 0, z = 0; };
struct V4 { float x = 0, y = 0, z = 0, w = 0; };
inline V2 operator+(V2 a, V2 b) { return {a.x + b.x, a.y + b.y}; }
inline V2 operator-(V2 a, V2 b) { return {a.x - b.x, a.y - b.y}; }
inline V2 operator*(V2 a, float k) { return {a.x * k, a.y * k}; }
inline float len(V2 a) { return std::sqrt(a.x * a.x + a.y * a.y); }
inline V3 operator+(V3 a, V3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline V3 operator-(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline V3 operator*(V3 a, float k) { return {a.x * k, a.y * k, a.z * k}; }
inline V3 operator*(V3 a, V3 b) { return {a.x * b.x, a.y * b.y, a.z * b.z}; }
inline float dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline V3 cross(V3 a, V3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline float len(V3 a) { return std::sqrt(dot(a, a)); }
inline V3 norm(V3 a) { float l = len(a); return l > 1e-12f ? a * (1 / l) : a; }

enum class Projection { Rectilinear, Fisheye, CircularFisheye };
enum class Movement { None, Tilt, Shift };

struct Lens {
    std::string name, inspiredBy;
    float focalMM, maxAperture, minAperture, bladeRotation;
    int blades;
    float catsEye, soapBubble, vignette, minFocusM, lateralCA, axialCA;
    Projection projection;
    float obstruction, sphericalAberration, squeeze, curvatureRadial, curvatureTangential;
    Movement movement;
    float movementAmount;
    bool rearFilter;
    float maxMagnification, breathing, streak;
    int unused;
    std::string collection;

    bool isFisheye() const { return projection != Projection::Rectilinear; }
    /// Which bodies take it: the rangefinder its own lenses (and the f/0.95 Dream), a reflex the rest.
    bool forRangefinder() const { return collection == "Rangefinder" || name.rfind("Kwanon 50mm f/0.95", 0) == 0; }
    bool forReflex() const { return collection != "Rangefinder"; }
    std::vector<float> apertureStops() const {
        static const float full[] = {1.0f, 1.4f, 2, 2.8f, 4, 5.6f, 8, 11, 16, 22, 32};
        std::vector<float> s{maxAperture};
        for (float f : full)
            if (f > maxAperture * 1.02f && f <= minAperture * 1.02f) s.push_back(f);
        return s;
    }
    float focalPixels(int width, int height) const {
        switch (projection) {
        case Projection::Rectilinear: return float(width) * focalMM / 36;
        case Projection::Fisheye:
            return std::sqrt(float(width * width + height * height)) / 2 / (float(M_PI) / 2);
        case Projection::CircularFisheye: return float(height) / 2 / (float(M_PI) / 2);
        }
        return float(width) * focalMM / 36;
    }
};

struct LensShelf { std::string name, about; int count; };

struct FilmStock {
    std::string name, inspiredBy;
    float iso;
    int exposures;
    bool blackAndWhite;
    V3 bwMix;
    V3 crosstalk[3];      // rows: how much of scene R, G, B each layer sees
    V3 balance;
    float saturation, contrast, toe, shoulder, blackLift, grain, grainSize, halation;
    V3 halationTint;
    bool falseColourIR;

    FilmStock developed(int push) const {
        if (push == 0) return *this;
        FilmStock s = *this;
        float x = float(push);
        if (push > 0) {
            s.contrast *= 1 + 0.12f * x; s.toe *= 1 + 0.06f * x; s.shoulder *= 1 + 0.08f * x;
            s.grain *= 1 + 0.3f * x; s.blackLift += 0.006f * x; s.saturation *= 1 + 0.04f * x;
        } else {
            s.contrast *= 1 + 0.10f * x; s.shoulder *= 1 + 0.08f * x; s.grain *= 1 + 0.15f * x;
        }
        return s;
    }
};

#include "data_gen.h"

struct ShutterSpeed { std::string label; float seconds; };
inline const std::vector<ShutterSpeed>& shutterSpeeds() {
    static const std::vector<ShutterSpeed> s = {
        {"1", 1}, {"2", 1 / 2.f}, {"4", 1 / 4.f}, {"8", 1 / 8.f}, {"15", 1 / 15.f}, {"30", 1 / 30.f},
        {"60", 1 / 60.f}, {"125", 1 / 125.f}, {"250", 1 / 250.f}, {"500", 1 / 500.f},
        {"1000", 1 / 1000.f}, {"2000", 1 / 2000.f}, {"4000", 1 / 4000.f}};
    return s;
}

/// Vogel sunflower point k of n over the unit disc.
inline V2 vogel(int k, int n) {
    float r = std::sqrt((k + 0.5f) / n), th = k * 2.39996323f;
    return {r * std::cos(th), r * std::sin(th)};
}

/// The pupil seen from field position q (see CameraBody.swift, pupilWeight).
inline float pupilWeight(V2 l, V2 q, const Lens& lens, float fNumber) {
    float r = len(l);
    if (lens.blades >= 3) {
        float seg = 2 * float(M_PI) / lens.blades;
        float th = std::atan2(l.y, l.x) - lens.bladeRotation;
        float a = std::fmod(std::fmod(th, seg) + seg, seg) - seg / 2;
        if (r * std::cos(a) > std::cos(float(M_PI) / lens.blades)) return 0;
    } else if (r > 1) {
        return 0;
    }
    if (r < lens.obstruction) return 0;
    float open = lens.maxAperture / fNumber;
    if (len(l * open + q * lens.catsEye) > 1) return 0;
    return (1 + lens.soapBubble * std::pow(r, 6.f)) / (1 + lens.soapBubble * 0.25f);
}

/// A filter screwed onto the front of the lens (Filters.swift). Everything that
/// reaches the film (and the finder, and the meter behind the lens) goes through
/// it: `transmission` is how much of each colour it passes (linear Rec.709), and
/// the effect filters scatter some of the light.
struct LensFilter {
    std::string name, about, group;
    V3 transmission{1, 1, 1};
    int starPoints = 0;          // 0: none; 2: a single line; 4, 6, 8: a star
    float starStrength = 0;
    bool spectral = false;       // a diffraction grating: the spikes split into rainbows
    float glow = 0, soften = 0, veil = 0;
    /// The light it loses, in stops (what a TTL meter makes up for).
    float stops() const { return -std::log2(std::max(transmission.x * 0.2126f + transmission.y * 0.7152f + transmission.z * 0.0722f, 1e-4f)); }
    bool hasEffect() const { return starPoints > 0 || glow > 0 || soften > 0 || veil > 0; }
    /// O[9..11] for the shaders. `threshold`: how bright a point must be to throw spikes or a halo.
    void optics(float threshold, V4* o) const {
        o[0] = {transmission.x, transmission.y, transmission.z, 0};
        o[1] = {float(starPoints), starStrength, spectral ? 1.f : 0.f, 0.35f};
        o[2] = {glow, soften, veil, threshold};
    }
};

inline const std::vector<LensFilter>& lensFilters() {
    auto t = [](const char* n, const char* a, const char* g, V3 tr) { LensFilter f{n, a, g}; f.transmission = tr; return f; };
    auto star = [](const char* n, const char* a, int pts, float s, bool spec) {
        LensFilter f{n, a, "effects"}; f.starPoints = pts; f.starStrength = s; f.spectral = spec; return f;
    };
    auto soft = [](const char* n, const char* a, float glow, float soften, float veil) {
        LensFilter f{n, a, "effects"}; f.glow = glow; f.soften = soften; f.veil = veil; return f;
    };
    static const std::vector<LensFilter> f = {
        LensFilter{"No filter", "just the lens", "none"},
        t("Hoshiya ND2", "neutral density, 1 stop: open up a stop in bright light", "neutral density", {0.5f, 0.5f, 0.5f}),
        t("Hoshiya ND4", "neutral density, 2 stops", "neutral density", {0.25f, 0.25f, 0.25f}),
        t("Hoshiya ND8", "neutral density, 3 stops: fast film wide open in daylight", "neutral density", {0.125f, 0.125f, 0.125f}),
        t("Hoshiya ND64", "neutral density, 6 stops: long exposures by day", "neutral density", {1.f / 64, 1.f / 64, 1.f / 64}),
        t("Hoshiya Y2 Yellow", "b&w: the everyday filter; skies a touch deeper, clouds stand out", "black & white", {0.98f, 0.90f, 0.30f}),
        t("Hoshiya G Orange", "b&w: dark skies, smooth skin, haze cut through", "black & white", {0.95f, 0.42f, 0.04f}),
        t("Hoshiya R1 Red", "b&w: dramatic black skies, foliage darkens", "black & white", {0.90f, 0.07f, 0.02f}),
        t("Rochester Wrattle No. 29 Deep Red", "b&w: near night-for-day; skies all but black", "black & white", {0.80f, 0.015f, 0.01f}),
        t("Hoshiya X1 Green", "b&w: foliage lightens, skin deepens, skies a little darker", "black & white", {0.30f, 0.78f, 0.25f}),
        t("Rochester Wrattle No. 47 Blue", "b&w: haze and fog deepen, reds go dark", "black & white", {0.04f, 0.14f, 0.86f}),
        t("Hoshiya Skylight 1A", "colour: takes the blue off shade and sky, a faint warmth", "colour correction", {1.0f, 0.97f, 0.97f}),
        t("Tiffield 81A Warming", "colour: a gentle warm-up, for overcast and shade", "colour correction", {1.0f, 0.92f, 0.80f}),
        t("Tiffield 85B Amber", "colour: tungsten film in daylight (or a golden look)", "colour correction", {0.95f, 0.66f, 0.36f}),
        t("Tiffield 80A Blue", "colour: daylight film under tungsten lights", "colour correction", {0.36f, 0.56f, 0.98f}),
        star("Hoshiya Cross Screen 4X", "a cross screen: four spikes off every bright point", 4, 1, false),
        star("Hoshiya Cross Screen 6X", "six spikes off every bright point", 6, 0.85f, false),
        star("Hoshiya Cross Screen 8X", "eight spikes: very 70s", 8, 0.75f, false),
        star("Coquin Diffractor 040", "bright points throw rainbow streaks to either side", 2, 1.2f, true),
        star("Coquin Spectral Cross 041", "rainbow streaks in four directions", 4, 1, true),
        star("Coquin Spectral Star 042", "an eight-ray rainbow starburst", 8, 0.8f, true),
        soft("Tiffield Soft/Glow 1", "a gentle glow round highlights, still sharp beneath", 0.35f, 0.12f, 0),
        soft("Tiffield Soft/Glow 3", "a dreamy glow: highlights bloom, edges melt", 0.9f, 0.35f, 0),
        soft("Tiffield Pro-Haze 2", "a pale veil over everything, low contrast and soft light", 0.3f, 0.15f, 0.35f),
        soft("Tiffield Black Haze 1", "halos on the lights, shadows kept deep: night city film", 0.6f, 0.06f, 0),
        soft("Tiffield Fog 2", "a heavy fog: the scene recedes into light", 0.4f, 0.25f, 0.8f),
    };
    return f;
}

/// The camera the photographer carries (CameraModel in Exif.swift): its make,
/// model and serial go on every frame.
struct CameraModel {
    std::string make, model, serial;
    int year;
    std::string fullName() const { return make + " " + model; }
    bool rangefinder() const { return make == "Lahntal"; }
    bool shutterPriority() const { return make == "Kwanon" && model == "EF"; }
    /// A movie camera: frame rate and shutter angle, not a speed dial.
    bool isMotion() const { return make == "Wilmont"; }
    /// The fastest speed it has (index into shutterSpeeds; the slowest is 1 s).
    int fastestShutter() const {
        int last = int(shutterSpeeds().size()) - 1;
        if (!(shutterPriority() || rangefinder())) return last;
        for (int i = 0; i <= last; i++) if (std::string(shutterSpeeds()[i].label) == "1000") return i;
        return last;
    }
    std::string about() const {
        if (isMotion()) return "1955 · 8-perf horizontal motion picture, reflex finder, frame rate and shutter angle";
        if (rangefinder()) return "1971 · rangefinder: bright frames, a focusing patch, its own lenses, 1 s to 1/1000";
        return shutterPriority() ? "1973 · shutter-priority auto, needle on an aperture scale, 1 s to 1/1000"
                                 : "1974 · manual, needle on a speed scale, LED readouts, 1 s to 1/4000";
    }
    /// The bodies in the bag: the Ohi Kor S2; the Kwanon EF (inspired by the 1973
    /// Canon EF); the Lahntal R5 (the early-70s Leica M5).
    static const std::vector<CameraModel>& all() {
        static const std::vector<CameraModel> a = {{"Ohi Kor", "S2", "7392051", 1974}, {"Kwanon", "EF", "0213874", 1973},
                                                   {"Lahntal", "R5", "1287415", 1971}};
        return a;
    }
    /// The bag's and the hidden one: the Wilmont W11 (inspired by the Wilcam W-11, an
    /// 8-perf horizontal 35 mm motion picture camera; every lens covers its frame).
    static const std::vector<CameraModel>& every() {
        static const std::vector<CameraModel> a = [] {
            auto v = all();
            v.push_back({"Wilmont", "W11", "0110457", 1955});
            return v;
        }();
        return a;
    }
    static constexpr int wilmont = 3;   // its index in every()
};

struct CameraBody {
    int lensIndex = 4;          // the 50 mm f/1.4
    int apertureIndex = 0;
    int shutterIndex = 7;       // 1/125
    float focusM = 1;
    int stockIndex = 1;
    int push = 0;
    int framesShot = 0;
    int rollNumber = 1;
    bool dofPreview = false;
    float metresPerUnit = 1;
    float sceneEV = 12;
    float calibration = 0;
    /// Lens movements: a tilt lens's tilt (degrees: x turns the focus plane
    /// across the frame, y up and down), a shift lens's shift (mm, right and up).
    V2 tilt, shift;
    int modelIndex = 0;                 // into CameraModel::every()
    const CameraModel& model() const { return CameraModel::every()[modelIndex]; }
    /// Shutter-priority automatic (a body that has it): the camera sets the aperture.
    int autoExposure = -1;              // -1 unset (on), 0 off, 1 on
    bool autoOn() const { return model().shutterPriority() && autoExposure != 0; }
    /// The lens has to fit: a rangefinder takes its own, a reflex the rest.
    bool fits(const Lens& l) const { return model().isMotion() || (model().rangefinder() ? l.forRangefinder() : l.forReflex()); }
    int filterIndex = 0;
    const LensFilter& filter() const { return lensFilters()[filterIndex]; }
    /// Whether this lens can take that filter (rear-filter lenses: colour and ND only).
    bool fits(const LensFilter& f) const { return !(lens().rearFilter && f.hasEffect()); }
    /// Finder blur (classic): strongly blurred splats are drawn at this opacity,
    /// fewer of them (CameraBody.finderThinning; "fast" focus 0.1).
    static inline float finderThinning = 0.05f;

    /// Tilts or shifts the lens by `v` (stick or arrows, per second, times dt),
    /// up to how far it goes. False when the lens has no movements.
    bool move(V2 v) {
        float most = lens().movementAmount;
        V2* m = lens().movement == Movement::Tilt ? &tilt : lens().movement == Movement::Shift ? &shift : nullptr;
        if (!m) return false;
        *m = *m + v * (most * 0.6f);
        float l = std::sqrt(m->x * m->x + m->y * m->y);
        if (l > most) *m = *m * (most / l);
        return true;
    }
    /// Where a shifted lens puts the optical axis, from the frame's centre, in
    /// pixels of an image `width` wide (shifting up moves the scene down the frame).
    V2 axisOffset(int width) const { return V2{-shift.x, shift.y} * (float(width) / 36); }

    const Lens& lens() const { return lensBag()[lensIndex]; }
    const FilmStock& stock() const { return filmStocks()[stockIndex]; }
    float ratedEI() const { return stock().iso * std::exp2(float(push)); }
    FilmStock developed() const { return stock().developed(push); }
    std::string rollName() const {
        if (push == 0) return stock().name;
        char b[160];
        snprintf(b, sizeof b, "%s at EI %.0f (%s%d)", stock().name.c_str(), ratedEI(), push > 0 ? "push +" : "pull ", push);
        return b;
    }
    /// A stop between the clicks: a take pulling the iris from one key's to the next's (0: none).
    float stopBetween = 0;
    float takingAperture() const {
        if (stopBetween > 0) return stopBetween;
        auto s = lens().apertureStops();
        return s[std::min<size_t>(apertureIndex, s.size() - 1)];
    }
    float viewingAperture() const { return dofPreview ? takingAperture() : lens().maxAperture; }
    ShutterSpeed shutter() const {
        if (!model().isMotion()) return shutterSpeeds()[shutterIndex];
        // A movie camera's rotating shutter: open for its angle of each turn,
        // one turn a frame (180° at 24 fps is 1/48 s).
        char b[16];
        snprintf(b, sizeof b, shutterAngle == std::round(shutterAngle) ? "%.0f°" : "%.1f°", shutterAngle);
        return {b, shutterAngle / 360 / frameRate};
    }

    // ---- a movie camera (the Wilmont)
    static const std::vector<float>& frameRates() { static const std::vector<float> r = {24, 25, 30, 48}; return r; }
    static const std::vector<float>& shutterAngles() { static const std::vector<float> a = {180, 172.8f, 144, 90, 45, 22.5f}; return a; }
    float frameRate = 24;
    /// Degrees: any angle (a take eases between its keys'), set by the dial in steps.
    float shutterAngle = 180;
    int shutterAngleIndex() const {
        int best = 0;
        for (int i = 0; i < int(shutterAngles().size()); i++)
            if (std::fabs(shutterAngles()[i] - shutterAngle) < std::fabs(shutterAngles()[best] - shutterAngle)) best = i;
        return best;
    }
    void setShutterAngleIndex(int i) { shutterAngle = shutterAngles()[std::clamp(i, 0, int(shutterAngles().size()) - 1)]; }
    int framesLeft() const { return stock().exposures - framesShot; }

    float magnification() const {
        float f = lens().focalMM / 1000;
        float simple = f / std::max(focusM - f, f * 0.05f);
        if (lens().maxMagnification <= 0) return simple;
        float atClosest = f / std::max(lens().minFocusM - f, f * 0.05f);
        float k = lens().maxMagnification / atClosest;
        float t = std::min(1.f, lens().minFocusM / std::max(focusM, lens().minFocusM));
        return simple * (1 + (k - 1) * t * t);
    }
    float focalPixels(int w, int h) const {
        return lens().focalPixels(w, h) * std::max(0.5f, 1 + lens().breathing * magnification());
    }
    float closeFocusLoss() const { return 2 * std::log2(1 + magnification()); }
    float exposureStops() const {
        float n = takingAperture(), t = shutter().seconds;
        float ev = std::log2(n * n / t) - std::log2(ratedEI() / 100);
        return sceneEV + calibration - ev - closeFocusLoss();
    }
    float reciprocityLoss() const {
        float t = shutter().seconds;
        if (t <= 0.25f) return 0;
        return (stock().blackAndWhite ? 0.5f : 0.25f) * std::log2(t / 0.25f);
    }
    float filmStops() const { return exposureStops() - reciprocityLoss(); }

    void meterShutter(float lum) {
        // A movie camera keeps its angle: the operator sets the stop.
        if (model().isMotion()) return;
        int best = 0; float bestErr = 1e9f;
        for (int i = 0; i <= model().fastestShutter(); i++) {
            CameraBody x = *this; x.shutterIndex = i;
            float e = std::fabs(x.exposureStops() + std::log2(lum / 0.18f));
            if (e < bestErr) { bestErr = e; best = i; }
        }
        shutterIndex = best;
    }
    /// The aperture that best matches the meter at the set speed (shutter-priority).
    void meterAperture(float lum) {
        int best = apertureIndex; float bestErr = 1e9f;
        for (int i = 0; i < int(lens().apertureStops().size()); i++) {
            CameraBody x = *this; x.apertureIndex = i;
            float e = std::fabs(x.exposureStops() + std::log2(lum / 0.18f));
            if (e < bestErr) { bestErr = e; best = i; }
        }
        apertureIndex = best;
    }
    void changeAperture(int d) {
        apertureIndex = std::clamp(apertureIndex + d, 0, int(lens().apertureStops().size()) - 1);
    }
    void changeShutter(int d) {
        // Faster (+) is a narrower angle.
        if (model().isMotion()) { setShutterAngleIndex(shutterAngleIndex() + d); return; }
        shutterIndex = std::clamp(shutterIndex + d, 0, model().fastestShutter()); }
    /// Another body: its speeds and modes; the lens has to fit.
    void chooseBody(int i) {
        modelIndex = i % int(CameraModel::every().size());
        shutterIndex = std::min(shutterIndex, model().fastestShutter());
        if (!fits(lens())) {
            const char* want = model().rangefinder() ? "Lahntal Summax 50mm f/2" : "Ohi Kor 50mm f/1.4";
            for (int k = 0; k < int(lensBag().size()); k++) if (lensBag()[k].name == want) { chooseLens(k); break; }
        }
    }
    void turnFocus(float rate, float dt) {
        focusM = std::clamp(focusM * std::exp(rate * dt * 1.1f), lens().minFocusM, 200.f);
    }
    void chooseLens(int index) {
        float n = takingAperture();
        lensIndex = index % int(lensBag().size());
        auto stops = lens().apertureStops();
        int best = 0;
        for (int i = 0; i < int(stops.size()); i++)
            if (std::fabs(stops[i] - n) < std::fabs(stops[best] - n)) best = i;
        apertureIndex = best;
        focusM = std::max(focusM, lens().minFocusM);
        tilt = {}; shift = {};
        // An effect filter cannot go on the back of a fisheye or mirror lens.
        if (!fits(filter())) filterIndex = 0;
    }
    void loadRoll(int stock, int p) { stockIndex = stock; push = p; framesShot = 0; rollNumber += 1; }

    // ---- lens parameters for the renderer (spirula fork, docs/notes/lens-defocus.md)
    static constexpr int tableSize = 32;

    static std::vector<V4> pupilTable(const Lens& lens, float n) {
        const int grid = 72;
        std::vector<V4> rows;
        float centreLight = 0;
        for (int i = 0; i < tableSize; i++) {
            V2 q{float(i) / (tableSize - 1) * 1.25f, 0};
            float w = 0, mx = 0, my = 0, mxx = 0, myy = 0;
            for (int gy = 0; gy < grid; gy++)
                for (int gx = 0; gx < grid; gx++) {
                    V2 l{(gx + 0.5f) / grid * 2 - 1, (gy + 0.5f) / grid * 2 - 1};
                    float p = pupilWeight(l, q, lens, n);
                    if (p == 0) continue;
                    w += p; mx += p * l.x; my += p * l.y; mxx += p * l.x * l.x; myy += p * l.y * l.y;
                }
            if (i == 0) centreLight = std::max(w, 1e-6f);
            if (w <= 0) { rows.push_back({0, 0, 0, 0}); continue; }
            float ux = mx / w;
            rows.push_back({ux, mxx / w - ux * ux, myy / w - (my / w) * (my / w), w / centreLight});
        }
        return rows;
    }

    std::vector<V2> ringCells(int n, float turn) const {
        int rings = std::max(1, int(std::lround(std::sqrt(n / float(M_PI)))));
        std::vector<float> radii; float total = 0;
        for (int i = 0; i < rings; i++) { radii.push_back((i + 0.5f) / rings); total += radii.back(); }
        std::vector<int> counts; int sum = 0;
        for (float r : radii) { counts.push_back(std::max(1, int(std::lround(n * r / total)))); sum += counts.back(); }
        counts.back() = std::max(1, counts.back() + n - sum);
        std::vector<V2> out;
        for (int i = 0; i < rings; i++) {
            float a0 = turn + i * 2.39996323f;
            for (int j = 0; j < counts[i]; j++) {
                float a = a0 + 2 * float(M_PI) * j / counts[i];
                out.push_back({radii[i] * std::cos(a), radii[i] * std::sin(a)});
            }
        }
        out.resize(std::min<size_t>(out.size(), n));
        return out;
    }
    bool splitsColour(int cells) const { return lens().axialCA > 0 && cells >= 64; }
    std::vector<V2> cellCentres(int k) const {
        bool split = splitsColour(k);
        std::vector<std::vector<V2>> sets;
        if (split) for (int c = 0; c < 3; c++) sets.push_back(ringCells((k - c + 2) / 3, c * 2.1f));
        else sets.push_back(ringCells(k, 0));
        std::vector<V2> out;
        for (int i = 0; i < k; i++) {
            V2 v = split ? sets[i % 3][std::min<size_t>(i / 3, sets[i % 3].size() - 1)] : sets[0][i];
            if (lens().blades >= 3) {
                float b = float(lens().blades), seg = 2 * float(M_PI) / b;
                float th = std::atan2(v.y, v.x);
                float a = std::fmod(std::fmod(th - lens().bladeRotation, seg) + seg, seg) - seg / 2;
                v = v * (std::cos(float(M_PI) / b) / std::cos(a));
            }
            out.push_back(v);
        }
        return out;
    }

    std::vector<V4> lensParams(float n, float focalPx, int cells, const std::vector<V4>* table,
                               V2 axis, float fieldRadius, V2 cell = {}, float patch = 0) const {
        const Lens& L = lens();
        float radiusUnits = L.focalMM / 1000 / n / 2 / metresPerUnit;
        float invFocus = metresPerUnit / focusM;
        float maxSigma = focalPx * 0.25f;
        std::vector<V4> p = {{1, invFocus, radiusUnits, (cells == 1 && table) ? 1.f : 0.f},
                             {1 / (2 * float(cells)), 1, (cells == 1 && table) ? finderThinning : 0.f, maxSigma}};
        if (table) p.insert(p.end(), table->begin(), table->end());
        p.resize(2 + tableSize);
        // The image surface off the film by d mm moves focus by d / f^2 dioptres.
        float f = L.focalMM / 1000, perMM = 0.001f / (f * f) * metresPerUnit;
        const float halfDiagonalMM = 21.63f, deg = float(M_PI) / 180;
        p.push_back({std::tan(tilt.x * deg) * halfDiagonalMM * perMM, -std::tan(tilt.y * deg) * halfDiagonalMM * perMM,
                     L.curvatureRadial * perMM, L.curvatureTangential * perMM});
        float open = L.maxAperture / n;
        float rim = cells > 1 ? L.sphericalAberration * open * open * metresPerUnit : 0;
        p.push_back({cell.x, cell.y, L.squeeze, rim});
        p.push_back({axis.x, axis.y, fieldRadius, 0});
        p.push_back({L.catsEye, open, cells > 1 ? patch : 0, 0});
        return p;
    }
};
