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

struct ShutterSpeed { const char* label; float seconds; };
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
    float takingAperture() const {
        auto s = lens().apertureStops();
        return s[std::min<size_t>(apertureIndex, s.size() - 1)];
    }
    float viewingAperture() const { return dofPreview ? takingAperture() : lens().maxAperture; }
    const ShutterSpeed& shutter() const { return shutterSpeeds()[shutterIndex]; }
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
        int best = 0; float bestErr = 1e9f;
        for (int i = 0; i < int(shutterSpeeds().size()); i++) {
            CameraBody x = *this; x.shutterIndex = i;
            float e = std::fabs(x.exposureStops() + std::log2(lum / 0.18f));
            if (e < bestErr) { bestErr = e; best = i; }
        }
        shutterIndex = best;
    }
    void changeAperture(int d) {
        apertureIndex = std::clamp(apertureIndex + d, 0, int(lens().apertureStops().size()) - 1);
    }
    void changeShutter(int d) { shutterIndex = std::clamp(shutterIndex + d, 0, int(shutterSpeeds().size()) - 1); }
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
                             {1 / (2 * float(cells)), 1, 0, maxSigma}};
        if (table) p.insert(p.end(), table->begin(), table->end());
        p.resize(2 + tableSize);
        float f = L.focalMM / 1000, perMM = 0.001f / (f * f) * metresPerUnit;
        p.push_back({0, 0, L.curvatureRadial * perMM, L.curvatureTangential * perMM});
        float open = L.maxAperture / n;
        float rim = cells > 1 ? L.sphericalAberration * open * open * metresPerUnit : 0;
        p.push_back({cell.x, cell.y, L.squeeze, rim});
        p.push_back({axis.x, axis.y, fieldRadius, 0});
        p.push_back({L.catsEye, open, cells > 1 ? patch : 0, 0});
        return p;
    }
};
