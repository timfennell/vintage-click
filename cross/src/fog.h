// Fog in a scene (Fog.swift) and where the camera may go (MovementBounds in
// SceneBundle.swift): both from a .vcscene, both placed by 4x4 matrices.
#pragma once
#include "kit.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

/// A row-major 4x4 (the file's order): m[r * 4 + c].
struct Mat4 {
    std::array<float, 16> m{};
    V3 apply(V3 p) const {
        return {m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3], m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
                m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11]};
    }
    /// The inverse (false when flat).
    bool inverse(Mat4& out) const {
        const auto& a = m;
        std::array<double, 16> inv{};
        inv[0] = a[5] * a[10] * a[15] - a[5] * a[11] * a[14] - a[9] * a[6] * a[15] + a[9] * a[7] * a[14] + a[13] * a[6] * a[11] - a[13] * a[7] * a[10];
        inv[4] = -a[4] * a[10] * a[15] + a[4] * a[11] * a[14] + a[8] * a[6] * a[15] - a[8] * a[7] * a[14] - a[12] * a[6] * a[11] + a[12] * a[7] * a[10];
        inv[8] = a[4] * a[9] * a[15] - a[4] * a[11] * a[13] - a[8] * a[5] * a[15] + a[8] * a[7] * a[13] + a[12] * a[5] * a[11] - a[12] * a[7] * a[9];
        inv[12] = -a[4] * a[9] * a[14] + a[4] * a[10] * a[13] + a[8] * a[5] * a[14] - a[8] * a[6] * a[13] - a[12] * a[5] * a[10] + a[12] * a[6] * a[9];
        inv[1] = -a[1] * a[10] * a[15] + a[1] * a[11] * a[14] + a[9] * a[2] * a[15] - a[9] * a[3] * a[14] - a[13] * a[2] * a[11] + a[13] * a[3] * a[10];
        inv[5] = a[0] * a[10] * a[15] - a[0] * a[11] * a[14] - a[8] * a[2] * a[15] + a[8] * a[3] * a[14] + a[12] * a[2] * a[11] - a[12] * a[3] * a[10];
        inv[9] = -a[0] * a[9] * a[15] + a[0] * a[11] * a[13] + a[8] * a[1] * a[15] - a[8] * a[3] * a[13] - a[12] * a[1] * a[11] + a[12] * a[3] * a[9];
        inv[13] = a[0] * a[9] * a[14] - a[0] * a[10] * a[13] - a[8] * a[1] * a[14] + a[8] * a[2] * a[13] + a[12] * a[1] * a[10] - a[12] * a[2] * a[9];
        inv[2] = a[1] * a[6] * a[15] - a[1] * a[7] * a[14] - a[5] * a[2] * a[15] + a[5] * a[3] * a[14] + a[13] * a[2] * a[7] - a[13] * a[3] * a[6];
        inv[6] = -a[0] * a[6] * a[15] + a[0] * a[7] * a[14] + a[4] * a[2] * a[15] - a[4] * a[3] * a[14] - a[12] * a[2] * a[7] + a[12] * a[3] * a[6];
        inv[10] = a[0] * a[5] * a[15] - a[0] * a[7] * a[13] - a[4] * a[1] * a[15] + a[4] * a[3] * a[13] + a[12] * a[1] * a[7] - a[12] * a[3] * a[5];
        inv[14] = -a[0] * a[5] * a[14] + a[0] * a[6] * a[13] + a[4] * a[1] * a[14] - a[4] * a[2] * a[13] - a[12] * a[1] * a[6] + a[12] * a[2] * a[5];
        inv[3] = -a[1] * a[6] * a[11] + a[1] * a[7] * a[10] + a[5] * a[2] * a[11] - a[5] * a[3] * a[10] - a[9] * a[2] * a[7] + a[9] * a[3] * a[6];
        inv[7] = a[0] * a[6] * a[11] - a[0] * a[7] * a[10] - a[4] * a[2] * a[11] + a[4] * a[3] * a[10] + a[8] * a[2] * a[7] - a[8] * a[3] * a[6];
        inv[11] = -a[0] * a[5] * a[11] + a[0] * a[7] * a[9] + a[4] * a[1] * a[11] - a[4] * a[3] * a[9] - a[8] * a[1] * a[7] + a[8] * a[3] * a[5];
        inv[15] = a[0] * a[5] * a[10] - a[0] * a[6] * a[9] - a[4] * a[1] * a[10] + a[4] * a[2] * a[9] + a[8] * a[1] * a[6] - a[8] * a[2] * a[5];
        double det = a[0] * inv[0] + a[1] * inv[4] + a[2] * inv[8] + a[3] * inv[12];
        if (std::fabs(det) < 1e-12) return false;
        for (int i = 0; i < 16; i++) out.m[i] = float(inv[i] / det);
        return true;
    }
};

enum class Shape { Box, Sphere, Cylinder };

/// Fog in a scene: a haze over everything, thicker low down if it has a height
/// fall-off, and patches of it in places (mist over a pond). Lit by the scene's
/// own light (the house lights): it thins what lies behind it and veils it in its colour.
struct SceneFog {
    struct Patch {
        Shape shape = Shape::Box;
        Mat4 toUnit;              // scan space to the unit shape (its top three rows are used)
        float visibilityM = 10;
        V3 tint{1, 1, 1};
        float softness = 0.4f;    // the share of its size over which its edge fades
    };
    float visibilityM = 0;        // how far you see through the haze; 0: only patches
    V3 tint{1, 1, 1};
    float heightFalloffM = 0;     // above its base the haze thins by e every this many metres (0: even)
    V3 base;                      // a point at the haze's base, scan units
    std::vector<Patch> patches;

    static constexpr int maxPatches = 8;
    bool empty() const { return visibilityM <= 0 && patches.empty(); }
    /// Extinction per metre for a visibility (where contrast falls to 2%).
    static float sigma(float v) { return v > 0 ? 3.912f / v : 0; }

    /// The shader's rows (background_fill's G): G[0] = (patches, haze extinction per unit,
    /// fall-off units, base height along up), G[1] = (haze light, far distance), G[2] = eye,
    /// G[3] = up; per patch: three rows to its unit space, (extinction, softness, shape, -), (light, -).
    std::array<V4, 44> rows(V3 eye, V3 up, float mpu, V3 light) const {
        std::array<V4, 44> r{};
        int n = std::min<int>(int(patches.size()), maxPatches);
        float far = 20000 / std::max(mpu, 1e-6f);
        r[0] = {float(n), sigma(visibilityM) * mpu, heightFalloffM > 0 ? heightFalloffM / mpu : 0, dot(base, up)};
        V3 hl = light * tint;
        r[1] = {hl.x, hl.y, hl.z, far};
        r[2] = {eye.x, eye.y, eye.z, 0};
        r[3] = {up.x, up.y, up.z, 0};
        for (int k = 0; k < n; k++) {
            const Patch& p = patches[k];
            int P = 4 + k * 5;
            for (int j = 0; j < 3; j++) r[P + j] = {p.toUnit.m[j * 4], p.toUnit.m[j * 4 + 1], p.toUnit.m[j * 4 + 2], p.toUnit.m[j * 4 + 3]};
            r[P + 3] = {sigma(p.visibilityM) * mpu, std::clamp(p.softness, 0.01f, 1.f), float(int(p.shape)), 0};
            V3 pl = light * p.tint;
            r[P + 4] = {pl.x, pl.y, pl.z, 0};
        }
        return r;
    }

    /// How much light gets through the fog from `eye` to `point` (scan units): the
    /// shader's fog_depth, for a lamp's face and flare.
    float transmittance(V3 eye, V3 point, V3 up, float mpu) const {
        V3 v = point - eye;
        float tmax = len(v);
        if (tmax <= 1e-6f) return 1;
        V3 d = v * (1 / tmax);
        float tau = 0, sa = sigma(visibilityM) * mpu;
        if (sa > 0) {
            float H = heightFalloffM > 0 ? heightFalloffM / mpu : 0;
            if (H <= 0) tau += sa * tmax;
            else {
                float u0 = dot(eye, up) - dot(base, up), s = dot(d, up);
                float tc = std::fabs(s) > 1e-6f ? -u0 / s : -1;
                float segs[3] = {0, (tc > 0 && tc < tmax) ? tc : tmax, tmax};
                for (int k = 0; k < 2; k++) {
                    float a = segs[k], b = segs[k + 1];
                    if (b <= a) continue;
                    float um = u0 + s * (a + b) / 2;
                    if (um <= 0) tau += sa * (b - a);
                    else if (std::fabs(s) < 1e-6f) tau += sa * std::exp(-u0 / H) * (b - a);
                    else tau += sa * H / s * (std::exp(-(u0 + s * a) / H) - std::exp(-std::min((u0 + s * b) / H, 80.f)));
                }
            }
        }
        for (int k = 0; k < std::min<int>(int(patches.size()), maxPatches); k++) {
            const Patch& p = patches[k];
            V3 o = p.toUnit.apply(eye), e2 = p.toUnit.apply(eye + d);
            V3 dd = e2 - o;
            float soft = std::clamp(p.softness, 0.01f, 1.f), sp = sigma(p.visibilityM) * mpu, sum = 0;
            // Sampled along the ray (the patch is small beside the haze): 32 steps.
            for (int j = 0; j < 32; j++) {
                V3 q = o + dd * (tmax * (j + 0.5f) / 32);
                float rr = p.shape == Shape::Box ? std::max({std::fabs(q.x), std::fabs(q.y), std::fabs(q.z)})
                         : p.shape == Shape::Sphere ? len(q)
                                                    : std::max(std::sqrt(q.x * q.x + q.y * q.y), std::fabs(q.z));
                float x = std::clamp((rr - 1) / -soft, 0.f, 1.f);
                sum += x * x * (3 - 2 * x);
            }
            tau += sp * tmax * sum / 32;
        }
        return std::exp(-tau);
    }
};

/// The space the camera may move in: the union of a few volumes. A move that
/// would leave it slides along the edge instead, so a wall is felt, not a stop.
struct MovementBounds {
    struct Volume {
        Shape shape;
        Mat4 toUnit;
        bool contains(V3 p) const {
            V3 q = toUnit.apply(p);
            switch (shape) {
            case Shape::Box: return std::fabs(q.x) <= 1 && std::fabs(q.y) <= 1 && std::fabs(q.z) <= 1;
            case Shape::Sphere: return q.x * q.x + q.y * q.y + q.z * q.z <= 1;
            default: return q.x * q.x + q.y * q.y <= 1 && std::fabs(q.z) <= 1;
            }
        }
    };
    std::vector<Volume> volumes;
    bool contains(V3 p) const {
        for (auto& v : volumes) if (v.contains(p)) return true;
        return false;
    }
    /// Where a move from `from` to `to` ends up.
    V3 confine(V3 from, V3 to) const {
        if (volumes.empty() || contains(to)) return to;
        // Started outside (a start view outside the bounds): let it walk in.
        if (!contains(from)) return to;
        V3 d = to - from;
        // Slide: the step without one axis, then with only one; the longest that stays in.
        V3 best = from;
        float bestLen = 0;
        static const V3 masks[6] = {{0, 1, 1}, {1, 0, 1}, {1, 1, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
        for (const V3& m : masks) {
            V3 step = d * m;
            float l = len(step);
            if (l > bestLen && contains(from + step)) { best = from + step; bestLen = l; }
        }
        if (bestLen > 0) return best;
        // Nothing slides: go as far as stays inside.
        float lo = 0, hi = 1;
        for (int i = 0; i < 8; i++) {
            float mid = (lo + hi) / 2;
            if (contains(from + d * mid)) lo = mid; else hi = mid;
        }
        return from + d * lo;
    }
};
