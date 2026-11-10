// Vintage Click, cross-platform: lens flare from the lights placed in the scene
// (Flare.swift): what each light sends toward the lens, as the shaders' flare
// model (flare.glsl, from Shaders.swift) needs it. Brightness is physical: the
// light's beam toward the camera (its traced intensity table, dimmer, lamp
// colour and gel) relative to the light the scan was made in.
#pragma once
#include "lights.h"
#include <array>

namespace flare {
constexpr int maxLights = 8;
constexpr int rowCount = 4 + 4 * maxLights + maxLights / 4;   // 38
using Rows = std::array<V4, rowCount>;

/// Candela per colour at `theta` off the axis and `phi` around it (radians).
inline V3 intensity(const BeamTable& b, float theta, float phi) {
    const int TB = BeamTable::thetaBins, PB = BeamTable::phiBins;
    float t = std::min(std::max(std::pow(std::max(theta, 0.f) / (float(M_PI) / 2), 1 / BeamTable::power) * float(TB) - 0.5f, 0.f), float(TB - 1));
    // The table covers a quarter turn, mirrored into the other three.
    float turn = std::fmod(std::fabs(phi), 2 * float(M_PI)), fold = turn > float(M_PI) ? 2 * float(M_PI) - turn : turn;
    float p = std::min((fold > float(M_PI) / 2 ? float(M_PI) - fold : fold) / (float(M_PI) / 2), 1.f) * float(PB - 1);
    int t0 = std::min(int(t), TB - 2), p0 = std::min(int(p), PB - 2);
    float ft = t - float(t0), fp = p - float(p0);
    auto at = [&](int a, int bb) { return b.cd[a * PB + bb]; };
    V3 a = at(t0, p0) + (at(t0, p0 + 1) - at(t0, p0)) * fp;
    V3 c = at(t0 + 1, p0) + (at(t0 + 1, p0 + 1) - at(t0 + 1, p0)) * fp;
    return a + (c - a) * ft;
}

/// Older and odd optics are single-coated: brighter, more colourful ghosts.
inline bool singleCoated(const Lens& l) {
    return l.collection == "Exotic" || l.collection == "Toys & Mods" || l.name.find("Petzval") != std::string::npos ||
           l.name.find("Holga") != std::string::npos;
}
/// How much dust and how many cleaning marks a lens's glass carries (0 clean, up to 3).
inline int dustGrade(const Lens& l) {
    if (l.collection == "Toys & Mods") return 3;
    if (l.collection == "Exotic" || l.collection == "Screw-Mount Classics" || l.collection == "Bokeh Monsters") return 2;
    return 1;
}
/// Seed bubbles in the glass: the old Soviet and Jena lenses'.
inline bool bubbles(const Lens& l) {
    for (const char* p : {"Krasnogorsk", "Leningrad", "Jena"}) if (l.name.rfind(p, 0) == 0) return true;
    return false;
}

/// A light as seen from the camera.
struct Source {
    V2 uv;
    float radius = 0;      // face size over the diagonal (for the filter ghost)
    V3 rgb;                // the flare's light
    float distance = 0;
    V2 px;
    float blur = 0;        // the light's own defocus blur over the diagonal
    V2 faceA, faceB;
    bool faceRound = true;
    V3 face;               // the face's brightness (frame light)
    bool flare = false;
    int gel = 0;
};

inline float smooth(float a, float b, float x) { float t = std::clamp((x - a) / (b - a), 0.f, 1.f); return t * t * (3 - 2 * t); }

inline std::vector<Source> sources(const LightingPlot& plot, const std::vector<float>& V, V3 position, float fx, V2 axis, int W, int H,
                                   bool fisheye, const CameraBody& b, float n) {
    float diag = std::sqrt(float(W * W + H * H));
    float omega = (float(W) / fx) * (float(H) / fx);
    const float fisheyeReach = 1.95f;
    auto project = [&](V3 q, float reach, V2& out) {
        V3 rel = q - position;
        float xc = V[0] * rel.x + V[1] * rel.y + V[2] * rel.z;
        float yc = V[4] * rel.x + V[5] * rel.y + V[6] * rel.z;
        float zc = V[8] * rel.x + V[9] * rel.y + V[10] * rel.z;
        if (fisheye) {
            float d = len(rel), th = std::acos(std::clamp(zc / std::max(d, 1e-9f), -1.f, 1.f)), r = std::sqrt(xc * xc + yc * yc);
            if (!(th < reach)) return false;
            out = axis + (r > 1e-9f ? V2{xc / r, yc / r} : V2{}) * (fx * th);
            return true;
        }
        if (!(zc > 1e-6f)) return false;
        out = axis + V2{xc / zc, yc / zc} * fx;
        return true;
    };
    std::vector<Source> out;
    for (const PlacedLight& light : plot.lights) {
        V3 rel = light.position - position;
        float dist = len(rel);
        V2 px;
        if (!(dist > 1e-6f) || !project(light.position, fisheyeReach, px)) continue;
        V2 uv{px.x / W, px.y / H};
        if (!(uv.x > -0.6f && uv.x < 1.6f && uv.y > -0.6f && uv.y < 1.6f)) continue;
        // A light leaving the picture still reaches the front glass a while.
        float beyond = std::max(std::max(-uv.x, uv.x - 1), std::max(-uv.y, uv.y - 1));
        float fade = 1 - smooth(0.2f, 0.6f, beyond);
        if (fisheye) {
            float zc = (V[8] * rel.x + V[9] * rel.y + V[10] * rel.z) / dist;
            fade = std::min(fade, 1 - smooth(float(M_PI) / 2, fisheyeReach, std::acos(std::clamp(zc, -1.f, 1.f))));
        }
        if (!(fade > 0)) continue;
        // Its beam toward the camera; seen from behind, nothing.
        V3 f, r, u;
        light.frame(plot.up, f, r, u);
        V3 toCam = rel * (-1 / dist);
        float ct = dot(toCam, f);
        if (!(ct > 0)) continue;
        float theta = std::acos(std::min(ct, 1.f)), phi = std::atan2(dot(toCam, u), dot(toCam, r));
        std::vector<V4> head, table;
        light.packed(b.metresPerUnit, b.sceneEV, plot.up, head, table);
        V3 colour{head[2].x, head[2].y, head[2].z};
        V3 cd = intensity(light.beam(), theta, phi);
        float dm = std::max(dist * b.metresPerUnit, 0.05f);
        // Fog between the lamp and the lens dims its face and all it throws into the lens.
        float mist = plot.fog.empty() ? 1.f : plot.fog.transmittance(position, light.position, plot.up, b.metresPerUnit);
        V3 e = mul3(cd * (head[1].w / (dm * dm)), colour) * (fade * mist);
        // The lit face: a Fresnel's or an ellipsoidal's lens, a softlight's panel.
        const LightHead& k = light.kit();
        V3 s = k.size;
        bool round = k.kind != LightHead::Kind::Softlight;
        float fw = round ? std::min(s.x, s.y) * (k.kind == LightHead::Kind::Ellipsoidal ? 0.6f : 0.8f) : s.x * 0.9f;
        float fh = round ? fw : s.y * 0.9f;
        float area = round ? float(M_PI) * fw * fh / 4 : fw * fh;
        V3 face = mul3(cd * (1 / std::max(area * ct, 1e-6f)) * (float(M_PI) * head[1].w), colour) * mist;
        float units = 1 / b.metresPerUnit;
        V2 pa = px, pb = px;
        project(light.position + r * (fw / 2 * units), float(M_PI) - 0.05f, pa);
        project(light.position + u * (fh / 2 * units), float(M_PI) - 0.05f, pb);
        float blur = (b.lens().focalMM / 1000 / n) * std::fabs(1 / dm - 1 / std::max(b.focusM, 0.05f)) * fx / diag;
        Source src;
        src.uv = uv; src.radius = fx * std::max(fw, fh) * 0.5f * units / dist / diag; src.rgb = e * (float(M_PI) / omega);
        src.distance = dist; src.px = px; src.blur = blur; src.faceA = pa - px; src.faceB = pb - px;
        src.faceRound = round; src.face = face; src.flare = light.flareOn(); src.gel = light.gel;
        out.push_back(src);
        if (int(out.size()) == maxLights) break;
    }
    return out;
}

/// The shaders' flare rows: the lens, the filter, then four rows per light, then the distances.
inline Rows uniforms(const std::vector<Source>& s, const std::vector<float>& visibility, const Lens& l, float n, V2 axisUV,
                     const LensFilter* filter = nullptr) {
    uint32_t seed = 2166136261u;
    for (unsigned char c : l.name) seed = (seed ^ uint32_t(c)) * 16777619u;
    Rows rows{};
    rows[0] = {float(s.size()), float(l.blades), l.bladeRotation, std::min(1.f, l.maxAperture / n)};
    rows[1] = {singleCoated(l) ? 1.f : 0.f, float(seed % 10000) + 10000 * float(dustGrade(l)) + (bubbles(l) ? 40000.f : 0.f), l.obstruction, l.squeeze};
    rows[2] = {axisUV.x, axisUV.y, 0.008f + l.lateralCA * 4,
               0.15f + (std::fabs(l.curvatureRadial) + std::fabs(l.curvatureTangential)) * 0.6f + std::fabs(l.sphericalAberration) * 0.3f};
    // The filter on the lens: flat glass (a ghost of its own) and any star or grating.
    rows[3] = {filter && filter->name != lensFilters()[0].name ? 1.f : 0.f, float(filter ? filter->starPoints : 0),
               filter ? filter->starStrength : 0.f, filter && filter->spectral ? 1.f : 0.f};
    for (size_t i = 0; i < s.size(); i++) {
        const Source& src = s[i];
        rows[4 + 4 * i] = {src.uv.x, src.uv.y, src.radius, i < visibility.size() ? visibility[i] : 1.f};
        rows[5 + 4 * i] = {src.rgb.x, src.rgb.y, src.rgb.z, src.blur};
        rows[6 + 4 * i] = {src.faceA.x, src.faceA.y, src.faceB.x, src.faceB.y};
        rows[7 + 4 * i] = {src.face.x, src.face.y, src.face.z, (src.flare ? 1.f : 0.f) + (src.faceRound ? 2.f : 0.f) + 4 * float(src.gel)};
    }
    // How far each light is (scene units): its face hides behind anything nearer.
    for (int r = 0; r < maxLights / 4; r++) {
        float d[4] = {0, 0, 0, 0};
        for (int k = 0; k < 4; k++) if (size_t(r * 4 + k) < s.size()) d[k] = s[r * 4 + k].distance;
        rows[4 + 4 * maxLights + r] = {d[0], d[1], d[2], d[3]};
    }
    return rows;
}

/// For the visibility probe (flare_probe): pixel, distance along the ray, face radius in pixels.
inline std::array<V4, maxLights> probes(const std::vector<Source>& s, float diag) {
    std::array<V4, maxLights> p{};
    for (size_t i = 0; i < s.size() && i < p.size(); i++) p[i] = {s[i].px.x, s[i].px.y, s[i].distance, std::max(2.f, s[i].radius * diag)};
    return p;
}
}  // namespace flare
