// Metal shaders, compiled at launch (the Command Line Tools have no `metal`).
//
// Depth of field is made by the render, not here: Spirula's projection blurs
// each splat by the lens pupil (sr_set_lens, docs in the spirula fork's
// docs/notes/lens-defocus.md), and the shutter adds up renders from sub-pupils.
// These shaders hold the same pupil function (CameraBody.pupilWeight mirrors
// it) for the per-pixel cat's-eye clipping of each sub-pupil, plus the
// focusing screen (split-prism, microprisms), the meter and development.
//
// Buffers are Spirula frames: W*H float3 premultiplied display rgb, then W*H
// transmittance, then W*H median ray depth (scene units).
//
// Optics, as float4s:
//   O[0] = (W, H, fx, fy)            O[1] = (cx, cy, metres per unit, focus m)
//   O[2] = (focal m, N, N wide open, blades)
//   O[3] = (cat's eye, soap bubble, blade rotation, vignette)
//   O[4] = background (display rgb)  O[5] = (prism radius px, film preview, seed, exposure stops)
// Film (FilmStock.packed): F[0..2] crosstalk rows, F[3] = (balance, b&w),
//   F[4] = (b&w mix, saturation), F[5] = (contrast, black lift, shoulder, grain),
//   F[6] = (halation, tint), F[7] = (iso, grain size, toe, -)

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

constant float FILM_WIDTH_M = 0.036;

struct VOut { float4 pos [[position]]; };

vertex VOut fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2 - 1, 0, 1);
    return o;
}

// ---- frames ---------------------------------------------------------------

float srgb_to_lin(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
float lin_to_srgb(float c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055; }
float3 to_lin(float3 c) { c = saturate(c); return float3(srgb_to_lin(c.r), srgb_to_lin(c.g), srgb_to_lin(c.b)); }
float3 to_srgb(float3 c) { c = saturate(c); return float3(lin_to_srgb(c.r), lin_to_srgb(c.g), lin_to_srgb(c.b)); }

uint2 clamp_px(int2 p, constant float4* O) {
    return uint2(clamp(p, int2(0), int2(O[0].xy) - 1));
}
uint idx(uint2 p, constant float4* O) { return p.y * uint(O[0].x) + p.x; }

// Display colour over the background.
float3 frame_rgb(device const float* f, uint2 p, constant float4* O) {
    uint n = uint(O[0].x * O[0].y), i = idx(p, O);
    float3 c = float3(f[3 * i], f[3 * i + 1], f[3 * i + 2]);
    return c + f[3 * n + i] * O[4].rgb;
}

// Distance along the view axis in metres (far away where nothing was hit).
float frame_z(device const float* f, uint2 p, constant float4* O) {
    uint n = uint(O[0].x * O[0].y), i = idx(p, O);
    float T = f[3 * n + i], d = f[4 * n + i];
    if (T > 0.97 || !(d > 0)) return 1e5;
    float2 uv = (float2(p) + 0.5 - O[1].xy) / O[0].zw;
    return d / sqrt(1 + dot(uv, uv)) * O[1].z;
}

// ---- the lens -------------------------------------------------------------

// Signed circle of confusion, in pixels of diameter: + behind focus, - in front.
float coc_px(float z, constant float4* O) {
    float f = O[2].x, N = O[2].y, s = max(O[1].w, f * 1.01);
    float c = (f / N) * f * (z - s) / (z * (s - f));
    return c / FILM_WIDTH_M * O[0].x;
}

// Where in the field a pixel is: (0,0) centre, length 1 at the frame corner.
float2 field(float2 p, constant float4* O) {
    float2 half_size = O[0].xy * 0.5;
    return (p - half_size) / length(half_size);
}

// Pupil weight of lens point l (unit = the current aperture's radius) seen from
// field position q: 0 outside the blades or clipped by the barrel, else the
// soap-bubble rim weighting. Stopping down shrinks the aperture inside the fixed
// barrel, so cat's eyes round up at small apertures as on a real lens.
float pupil(float2 l, float2 q, constant float4* O) {
    float r = length(l);
    float blades = O[2].w;
    if (blades >= 3) {
        float seg = 2 * M_PI_F / blades;
        float th = atan2(l.y, l.x) - O[3].z;
        float a = fmod(fmod(th, seg) + seg, seg) - seg / 2;
        if (r * cos(a) > cos(M_PI_F / blades)) return 0;
    } else if (r > 1) {
        return 0;
    }
    float open = O[2].z / O[2].y;   // current radius in wide-open radii
    if (length(l * open + O[3].x * q) > 1) return 0;
    float soap = O[3].y;
    return (1 + soap * pow(r, 6)) / (1 + soap * 0.25);
}

// Vogel sunflower point k of n over the unit disc.
float2 vogel(uint k, uint n) {
    float r = sqrt((float(k) + 0.5) / float(n));
    float th = float(k) * 2.39996323;
    return r * float2(cos(th), sin(th));
}

// ---- film -----------------------------------------------------------------

float hash(uint2 p, uint s) {
    uint h = p.x * 0x8da6b343u ^ p.y * 0xd8163841u ^ s * 0xcb1ab31fu;
    h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
    return float(h & 0xffffffu) / 16777215.0;
}
float value_noise(float2 p, uint s) {
    float2 i = floor(p), t = fract(p);
    t = t * t * (3 - 2 * t);
    uint2 a = uint2(int2(i) + 65536);
    float v00 = hash(a, s), v10 = hash(a + uint2(1, 0), s);
    float v01 = hash(a + uint2(0, 1), s), v11 = hash(a + uint2(1, 1), s);
    return mix(mix(v00, v10, t.x), mix(v01, v11, t.x), t.y);
}

// Scene-linear exposure (already scaled by the exposure) to a print.
float3 film_look(float3 lin, float3 halo, float2 px, uint seed, float lines, constant float4* F) {
    lin += F[6].x * F[6].yzw * halo;
    float3 c = float3(dot(F[0].xyz, lin), dot(F[1].xyz, lin), dot(F[2].xyz, lin)) * F[3].xyz;
    bool bw = F[3].w > 0.5;
    if (bw) c = float3(dot(F[4].xyz, c));
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = max(luma + (c - luma) * F[4].w, 0.0);
    // Characteristic curve in stops about mid grey: toe below, shoulder above.
    float3 x = log2(max(c, 1e-6) / 0.18);
    float k = F[5].x * 0.34;
    float3 xs = select(x * F[7].z, x * F[5].z, x > 0);
    float3 y = 0.5 + 0.5 * tanh(k * xs);
    y = F[5].y + (1 - F[5].y) * y;
    // Grain: strongest in the midtones, finer on slower stocks.
    float size = F[7].y * lines / 1080.0;
    float2 g = px / max(size, 0.5);
    float amp = F[5].w * 0.16;
    float3 n;
    float mono = value_noise(g, seed) + value_noise(g * 2.1 + 17.0, seed + 1) * 0.5 - 0.75;
    if (bw) {
        n = float3(mono);
    } else {
        float3 chroma = float3(value_noise(g + 31.0, seed + 2), value_noise(g + 57.0, seed + 3),
                               value_noise(g + 83.0, seed + 4)) - 0.5;
        n = mono + 0.35 * chroma;
    }
    y += amp * n * 4 * y * (1 - y);
    return saturate(y);
}

// ---- viewfinder -----------------------------------------------------------

// The focusing screen: a split-prism disc (halves shift apart with defocus),
// a microprism collar (shimmers until focused) and fresnel matte everywhere else.
fragment float4 viewfinder(VOut in [[stage_in]], device const float* f [[buffer(0)]],
                           constant float4* O [[buffer(1)]], constant float4* F [[buffer(2)]]) {
    float2 p = in.pos.xy;
    float2 c = O[0].xy * 0.5;
    float R = O[5].x;
    float r = length(p - c);
    float3 col;
    if (r < R) {
        // Split image: each half displaced by the defocus at the point it shows.
        float side = p.y < c.y ? 1 : -1;
        float z = frame_z(f, clamp_px(int2(p), O), O);
        float shift = coc_px(z, O) * 0.6 * side;
        col = to_lin(frame_rgb(f, clamp_px(int2(p + float2(shift, 0)), O), O));
        // A prism needs a fast lens: it blacks out half when stopped down.
        float dark = saturate((O[2].y - 4.0) / 3.0);
        if (side > 0) col *= 1 - 0.85 * dark;
        if (abs(p.y - c.y) < 0.6) col *= 0.4;
    } else if (r < R * 1.75) {
        // Microprisms: a fine grid of tiny prisms, each displacing by the defocus.
        float cell = max(3.0, O[0].y / 300);
        float2 g = floor(p / cell);
        float a = (fmod(g.x + g.y, 4.0) + 0.5) * M_PI_F / 2;
        float z = frame_z(f, clamp_px(int2(p), O), O);
        float shift = coc_px(z, O) * 0.5;
        col = to_lin(frame_rgb(f, clamp_px(int2(p + shift * float2(cos(a), sin(a))), O), O));
    } else {
        col = to_lin(frame_rgb(f, clamp_px(int2(p), O), O));
    }
    if (abs(r - R) < 0.8 || abs(r - R * 1.75) < 0.8) col *= 0.55;
    float3 outc;
    if (O[5].y > 0.5) {
        float2 q = field(p, O);
        float vig = 1 - O[3].w * pow(saturate(O[2].z / O[2].y), 1.5) * dot(q, q);
        outc = film_look(col * exp2(O[5].w) * vig, 0, p, uint(O[5].z), O[0].y, F);
    } else {
        // Brighter finder at the edges is lost to the condenser; a hint of it.
        float2 q = field(p, O);
        outc = to_srgb(col * (1 - 0.18 * dot(q, q)));
    }
    return float4(outc, 1);
}

// Centre-weighted meter: one sample per cell, linear luminance.
kernel void meter(device const float* f [[buffer(0)]], constant float4* O [[buffer(1)]],
                  device float* out [[buffer(2)]], uint2 g [[thread_position_in_grid]],
                  uint2 grid [[threads_per_grid]]) {
    float2 p = (float2(g) + 0.5) / float2(grid) * O[0].xy;
    float3 c = to_lin(frame_rgb(f, clamp_px(int2(p), O), O));
    out[g.y * grid.x + g.x] = dot(c, float3(0.2126, 0.7152, 0.0722));
}

// ---- shutter --------------------------------------------------------------

// Adds one lens sample's render to the exposure. L = (lens point, weight scale, reset).
kernel void accumulate(device const float* f [[buffer(0)]], constant float4* O [[buffer(1)]],
                       device float4* acc [[buffer(2)]], constant float4& L [[buffer(3)]],
                       uint2 p [[thread_position_in_grid]]) {
    if (p.x >= uint(O[0].x) || p.y >= uint(O[0].y)) return;
    uint i = idx(p, O);
    float w = pupil(L.xy, field(float2(p) + 0.5, O), O) * L.z;
    float4 prev = L.w > 0.5 ? float4(0) : acc[i];
    acc[i] = prev + float4(to_lin(frame_rgb(f, p, O)) * w, w);
}

// Develops the exposure into a print. D = (1 / total pupil weight of a full disc, -, -, -).
kernel void develop(device const float4* acc [[buffer(0)]], constant float4* O [[buffer(1)]],
                    constant float4* F [[buffer(2)]], constant float4& D [[buffer(3)]],
                    device uchar4* out [[buffer(4)]], uint2 p [[thread_position_in_grid]]) {
    uint W = uint(O[0].x), H = uint(O[0].y);
    if (p.x >= W || p.y >= H) return;
    float expo = exp2(O[5].w);
    float2 q = field(float2(p) + 0.5, O);
    float vig = 1 - O[3].w * pow(saturate(O[2].z / O[2].y), 1.5) * dot(q, q);
    // Light lost to barrel clipping darkens the corners on its own (no renormalising).
    float3 lin = acc[idx(p, O)].rgb * D.x * expo * vig;
    // Halation: light past the film base bouncing back, around bright highlights.
    float3 halo = 0;
    if (F[6].x > 0) {
        float rad = O[0].y * 0.012;
        for (uint k = 0; k < 32; k++) {
            float2 o = vogel(k, 32) * rad;
            uint2 pj = clamp_px(int2(float2(p) + o), O);
            halo += max(acc[idx(pj, O)].rgb * D.x * expo - 0.9, 0.0);
        }
        halo /= 32;
    }
    float3 c = film_look(lin, halo, float2(p), uint(O[5].z), O[0].y, F);
    out[idx(p, O)] = uchar4(uchar3(round(c * 255)), 255);
}

// Shows a developed print.
fragment float4 show_print(VOut in [[stage_in]], device const uchar4* img [[buffer(0)]],
                           constant float4* O [[buffer(1)]]) {
    uint2 p = clamp_px(int2(in.pos.xy), O);
    return float4(float4(img[idx(p, O)]).rgb / 255.0, 1);
}
"""
