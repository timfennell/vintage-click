// Vintage Click, cross-platform: the focusing screen and the film, on the CPU
// (the lens's optics are the renderer's; this is what Shaders.swift does after it).
#pragma once
#include "kit.h"
#include <cstdint>
#include <functional>
#include <thread>

/// A render from the renderer: display rgb (premultiplied), transmittance and
/// median ray depth (scene units), all W*H.
struct Frame {
    int w = 0, h = 0;
    std::vector<float> rgb, T, z;
};

inline float sat(float x) { return std::clamp(x, 0.f, 1.f); }
inline float smoothstepf(float a, float b, float x) { float t = sat((x - a) / (b - a)); return t * t * (3 - 2 * t); }
inline float srgb2lin(float c) { return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f); }
inline float lin2srgb(float c) { c = sat(c); return c <= 0.0031308f ? c * 12.92f : 1.055f * std::pow(c, 1 / 2.4f) - 0.055f; }
inline V3 toLin(V3 c) { return {srgb2lin(std::max(c.x, 0.f)), srgb2lin(std::max(c.y, 0.f)), srgb2lin(std::max(c.z, 0.f))}; }
inline V3 toSrgb(V3 c) { return {lin2srgb(c.x), lin2srgb(c.y), lin2srgb(c.z)}; }
inline float hashf(uint32_t x, uint32_t y, uint32_t s) {
    uint32_t h = x * 0x8da6b343u ^ y * 0xd8163841u ^ s * 0xcb1ab31fu;
    h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
    return float(h & 0xffffffu) / 16777215.0f;
}
inline float valueNoise(float px, float py, uint32_t s) {
    float ix = std::floor(px), iy = std::floor(py), tx = px - ix, ty = py - iy;
    tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty);
    uint32_t ax = uint32_t(int(ix) + 65536), ay = uint32_t(int(iy) + 65536);
    float v00 = hashf(ax, ay, s), v10 = hashf(ax + 1, ay, s), v01 = hashf(ax, ay + 1, s), v11 = hashf(ax + 1, ay + 1, s);
    float a = v00 + (v10 - v00) * tx, b = v01 + (v11 - v01) * tx;
    return a + (b - a) * ty;
}

/// Runs f(y0, y1) over rows on every core.
inline void parallelRows(int h, const std::function<void(int, int)>& f) {
    unsigned n = std::max(1u, std::thread::hardware_concurrency());
    std::vector<std::thread> ts;
    for (unsigned t = 0; t < n; t++) ts.emplace_back([&, t] { f(int(h * t / n), int(h * (t + 1) / n)); });
    for (auto& t : ts) t.join();
}

/// What the screen and the film need of the lens and the scene.
struct Optics {
    int W = 0, H = 0;            // the frame
    float fx = 1;
    V2 axis;                     // optical axis, pixels
    float metresPerUnit = 1, focusM = 1, focalM = 0.05f, N = 1.4f, Nopen = 1.4f;
    float vignette = 0, lateralCA = 0, circleR = 0;   // circular fisheye's image radius (0 none)
    V3 background{0.08f, 0.08f, 0.09f};
    bool place = false;          // nothing should show through: rescale the blend's leak
    float brightness = 1;        // the finder's (aperture, close focus, eyes adapting)
    float prismR = 0;            // split-image radius, pixels (0: no focusing aids)
};

inline V3 frameRGB(const Frame& f, int x, int y, const Optics& o) {
    x = std::clamp(x, 0, f.w - 1); y = std::clamp(y, 0, f.h - 1);
    size_t i = size_t(y) * f.w + x;
    V3 c{f.rgb[3 * i], f.rgb[3 * i + 1], f.rgb[3 * i + 2]};
    float t = f.T[i];
    V3 lit = c + o.background * t;
    if (o.place) {
        float keep = smoothstepf(0.85f, 0.97f, t);
        V3 full = c * (1 / std::max(1 - t, 0.03f));
        return full * (1 - keep) + lit * keep;
    }
    return lit;
}
inline float frameZ(const Frame& f, int x, int y, const Optics& o) {
    x = std::clamp(x, 0, f.w - 1); y = std::clamp(y, 0, f.h - 1);
    size_t i = size_t(y) * f.w + x;
    float T = f.T[i], d = f.z[i];
    if (T > 0.97f || !(d > 0)) return 1e5f;
    float ux = (x + 0.5f - o.axis.x) / o.fx, uy = (y + 0.5f - o.axis.y) / o.fx;
    return d / std::sqrt(1 + ux * ux + uy * uy) * o.metresPerUnit;
}
inline float cocPx(float z, const Optics& o) {
    float f = o.focalM, s = std::max(o.focusM, f * 1.01f);
    float c = (f / o.N) * f * (z - s) / (z * (s - f));
    return c / 0.036f * o.W;
}
inline V2 fieldOf(V2 p, const Optics& o) {
    float r = std::sqrt(o.W * o.W * 0.25f + o.H * o.H * 0.25f);
    return {(p.x - o.axis.x) / r, (p.y - o.axis.y) / r};
}
inline V3 linCA(const Frame& f, V2 p, const Optics& o) {
    V2 c = o.axis; float k = o.lateralCA;
    V2 pr = c + (p - c) * (1 - k), pb = c + (p - c) * (1 + k);
    return {toLin(frameRGB(f, int(pr.x), int(pr.y), o)).x, toLin(frameRGB(f, int(p.x), int(p.y), o)).y,
            toLin(frameRGB(f, int(pb.x), int(pb.y), o)).z};
}
inline V3 linSmooth(const Frame& f, V2 p, const Optics& o) {
    float tx = p.x - 0.5f, ty = p.y - 0.5f, ix = std::floor(tx), iy = std::floor(ty), wx = tx - ix, wy = ty - iy;
    V3 a = linCA(f, {ix + 0.5f, iy + 0.5f}, o), b = linCA(f, {ix + 1.5f, iy + 0.5f}, o);
    V3 c = linCA(f, {ix + 0.5f, iy + 1.5f}, o), d = linCA(f, {ix + 1.5f, iy + 1.5f}, o);
    V3 top = a + (b - a) * wx, bot = c + (d - c) * wx;
    return top + (bot - top) * wy;
}
inline float prismDepth(const Frame& f, V2 p, float reach, const Optics& o) {
    float z = 1e5f;
    for (int dy = -2; dy <= 2; dy++)
        for (int dx = -2; dx <= 2; dx++) z = std::min(z, frameZ(f, int(p.x + dx * reach), int(p.y + dy * reach), o));
    return z;
}
inline V3 prismSample(const Frame& f, V2 p, V2 shift, float z, const Optics& o) {
    V2 q = p + shift;
    float zq = frameZ(f, int(q.x), int(q.y), o);
    float keep = smoothstepf(z * 0.7f, z * 0.9f, zq);
    V3 a = linSmooth(f, p, o), b = linSmooth(f, q, o);
    return a + (b - a) * keep;
}

/// The focusing screen at frame pixel p (linear light, before the window).
inline V3 groundGlass(const Frame& f, V2 p, const Optics& o) {
    V2 c{o.W * 0.5f, o.H * 0.5f};
    float R = o.prismR, r = len(p - c);
    V3 col;
    if (R > 0 && r < R) {
        float side = p.y < c.y ? 1.f : -1.f;
        float z = prismDepth(f, {c.x, c.y - side * R * 0.5f}, R * 0.18f, o);
        float shift = std::clamp(cocPx(z, o) * 0.6f, -R * 0.45f, R * 0.45f) * side;
        col = prismSample(f, p, {shift, 0}, z, o);
        float dark = sat((o.N - 4.f) / 3.f);
        if (side > 0) col = col * (1 - 0.85f * dark);
        if (std::fabs(p.y - c.y) < 0.6f) col = col * 0.4f;
    } else if (R > 0 && r < R * 1.75f) {
        float cell = std::max(3.f, o.H / 300.f);
        float gx = std::floor(p.x / cell), gy = std::floor(p.y / cell);
        float a = (std::floor(hashf(uint32_t(gx + 4096), uint32_t(gy + 4096), 23) * 6) + 0.5f) * float(M_PI) / 3;
        V2 centre{(gx + 0.5f) * cell, (gy + 0.5f) * cell};
        float z = prismDepth(f, centre, cell * 0.5f, o);
        float coc = std::fabs(cocPx(z, o));
        float sh = std::min(coc * 0.5f, cell * 2.5f);
        col = prismSample(f, p, {sh * std::cos(a), sh * std::sin(a)}, z, o);
        col = col * (1 - 0.35f * smoothstepf(cell * 2, cell * 10, coc));
    } else {
        col = linCA(f, p, o);
        float tooth = valueNoise(p.x / 1.4f, p.y / 1.4f, 7) + 0.5f * valueNoise(p.x / 0.7f, p.y / 0.7f, 11) - 0.75f;
        col = col * (1 + 0.10f * tooth);
    }
    if (R > 0 && (std::fabs(r - R) < 0.8f || std::fabs(r - R * 1.75f) < 0.8f)) col = col * 0.55f;
    float ring = std::fmod(r / std::max(o.H / 70.f, 4.f), 1.f);
    col = col * (1 - 0.035f * smoothstepf(0.85f, 1.0f, ring));
    V2 q = fieldOf(p, o);
    float qq = q.x * q.x + q.y * q.y;
    float vig = 1 - o.vignette * std::pow(sat(o.Nopen / o.N), 1.5f) * qq;
    col = col * (vig * (1 - 0.22f * qq) * o.brightness);
    if (o.circleR > 0) col = col * (1 - smoothstepf(o.circleR - 2, o.circleR, r));
    return col;
}

/// One stock's look on scene-linear light (film_look in Shaders.swift).
inline V3 filmLook(V3 lin, V3 halo, float px, float py, uint32_t seed, float lines, const FilmStock& F) {
    lin = lin + F.halationTint * halo * F.halation;
    if (F.falseColourIR) {
        float lum = 0.2126f * lin.x + 0.7152f * lin.y + 0.0722f * lin.z;
        float leaf = sat(3.f * (lin.y - std::max(lin.x, lin.z)) / std::max(lin.y, 1e-4f));
        float sky = sat((lin.z - std::max(lin.x, lin.y)) / std::max(lin.z, 1e-4f));
        float reds = sat((lin.x - std::max(lin.y, lin.z)) / std::max(lin.x, 1e-4f));
        float ir = lum * (1 + 3.f * leaf) * (1 - 0.75f * sky) + 0.9f * reds * lin.x;
        V3 c{lin.x - lum, lin.y - lum, lin.z - lum};
        float strength = smoothstepf(0.06f, 0.3f, len(c) / std::max(lum, 1e-4f));
        V3 sw{ir - lum, c.x * strength, c.y * strength - 0.45f * leaf * lin.y + 0.35f * sky * lin.z};
        lin = V3{std::max(lum + sw.x, 0.f), std::max(lum + sw.y, 0.f), std::max(lum + sw.z, 0.f)} * (1 - 0.3f * sky);
    }
    V3 c{dot(F.crosstalk[0], lin), dot(F.crosstalk[1], lin), dot(F.crosstalk[2], lin)};
    c = c * F.balance;
    if (F.blackAndWhite) { float m = dot(F.bwMix, c); c = {m, m, m}; }
    float luma = 0.2126f * c.x + 0.7152f * c.y + 0.0722f * c.z;
    c = {std::max(luma + (c.x - luma) * F.saturation, 0.f), std::max(luma + (c.y - luma) * F.saturation, 0.f),
         std::max(luma + (c.z - luma) * F.saturation, 0.f)};
    float k = F.contrast * 0.34f;
    auto curve = [&](float v) {
        float x = std::log2(std::max(v, 1e-6f) / 0.18f);
        float xs = x > 0 ? x * F.shoulder : x * F.toe;
        float y = 0.5f + 0.5f * std::tanh(k * xs);
        return F.blackLift + (1 - F.blackLift) * y;
    };
    V3 y{curve(c.x), curve(c.y), curve(c.z)};
    float size = F.grainSize * lines / 1080.f;
    float gx = px / std::max(size, 0.5f), gy = py / std::max(size, 0.5f);
    float amp = F.grain * std::sqrt(F.iso / 100.f) * 0.16f;
    float mono = valueNoise(gx, gy, seed) + valueNoise(gx * 2.1f + 17, gy * 2.1f + 17, seed + 1) * 0.5f - 0.75f;
    V3 n{mono, mono, mono};
    if (!F.blackAndWhite)
        n = n + V3{valueNoise(gx + 31, gy + 31, seed + 2) - 0.5f, valueNoise(gx + 57, gy + 57, seed + 3) - 0.5f,
                   valueNoise(gx + 83, gy + 83, seed + 4) - 0.5f} * 0.35f;
    y = {y.x + amp * n.x * 4 * y.x * (1 - y.x), y.y + amp * n.y * 4 * y.y * (1 - y.y), y.z + amp * n.z * 4 * y.z * (1 - y.z)};
    return {sat(y.x), sat(y.y), sat(y.z)};
}
