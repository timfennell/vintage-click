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
//   O[4] = background (display rgb)  O[5] = (prism radius px, finder brightness, seed, exposure stops)
//   O[6] = (lateral colour at the corner, axial colour, circular fisheye's image radius px (0: none),
//           mirror lens's central obstruction in aperture radii)
//   O[7] = finder only: where the image sits in the window (origin px, scale, corner radius px)
//   O[8] = (oval stop's width over height, 0 = round)
// (cx, cy) is the optical axis: the frame's centre, unless the lens is shifted.
// Film (FilmStock.packed): F[0..2] crosstalk rows, F[3] = (balance, b&w),
//   F[4] = (b&w mix, saturation), F[5] = (contrast, black lift, shoulder, grain),
//   F[6] = (halation, tint), F[7] = (iso, grain size, toe, colour infrared)

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
// No upper clamp: relit highlights may run past display white and still print.
float3 to_lin(float3 c) { c = max(c, 0.0); return float3(srgb_to_lin(c.r), srgb_to_lin(c.g), srgb_to_lin(c.b)); }
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
    // From the optical axis (off centre on a shifted lens), 1 at a corner's distance.
    return (p - O[1].xy) / length(O[0].xy * 0.5);
}

// Lateral colour: red and blue imaged at slightly different magnifications,
// so their fringes grow toward the corners. Each channel read at its own place.
float3 frame_lin_ca(device const float* f, float2 p, constant float4* O) {
    float2 c = O[1].xy;
    float k = O[6].x;
    float3 out;
    out.r = to_lin(frame_rgb(f, clamp_px(int2(c + (p - c) * (1 - k)), O), O)).r;
    out.g = to_lin(frame_rgb(f, clamp_px(int2(p), O), O)).g;
    out.b = to_lin(frame_rgb(f, clamp_px(int2(c + (p - c) * (1 + k)), O), O)).b;
    return out;
}

// Pupil weight of lens point l (unit = the current aperture's radius) seen from
// field position q: 0 outside the blades or clipped by the barrel, else the
// soap-bubble rim weighting. Stopping down shrinks the aperture inside the fixed
// barrel, so cat's eyes round up at small apertures as on a real lens.
float pupil(float2 l, float2 q, constant float4* O, float cell = 0) {
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
    if (r < O[6].w) return 0;       // a mirror lens's secondary mirror
    float open = O[2].z / O[2].y;   // current radius in wide-open radii
    float soap = O[3].y;
    float rim = (1 + soap * pow(r, 6)) / (1 + soap * 0.25);
    l.x *= O[8].x > 0 ? O[8].x : 1.0;    // an oval stop, narrower across
    // Sub-pupils (cell > 0) are cut by the barrel in the render itself, splat by splat.
    if (cell > 0) return rim;
    return length(l * open + O[3].x * q) > 1 ? 0 : rim;
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
    if (F[7].w > 0.5) {
        // Colour infrared. A scan has no infrared, so estimate it: leaves (greener
        // than both red and blue) glow, blue sky is dark, neutrals stay as they are.
        // The layers see infrared, red and green, and print red, green and blue.
        float lum = dot(lin, float3(0.2126, 0.7152, 0.0722));
        // Even faintly green leaves are alive: they glow in infrared.
        float leaf = saturate(3.0 * (lin.g - max(lin.r, lin.b)) / max(lin.g, 1e-4));
        float sky = saturate((lin.b - max(lin.r, lin.g)) / max(lin.b, 1e-4));
        float reds = saturate((lin.r - max(lin.g, lin.b)) / max(lin.r, 1e-4));    // many reds reflect infrared too
        float ir = lum * (1 + 3.0 * leaf) * (1 - 0.75 * sky) + 0.9 * reds * lin.r;
        // Swap the colour, not the faint tints: whites and greys stay as they are
        // (a warm-grey wall would otherwise go green).
        float3 c = lin - lum;
        float strength = smoothstep(0.06, 0.3, length(c) / max(lum, 1e-4));
        float3 swapped = float3(ir - lum, c.r * strength,
                                c.g * strength - 0.45 * leaf * lin.g + 0.35 * sky * lin.b);
        lin = max(lum + swapped, 0.0) * (1 - 0.3 * sky);
    }
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

// The surface a prism looks through to near p: the nearest depth in a small
// neighbourhood, so a soft (part-transparent) edge moves with its subject
// instead of each edge pixel taking the background's shift.
float prism_depth(device const float* f, float2 p, float reach, constant float4* O) {
    float z = 1e5;
    for (int dy = -2; dy <= 2; dy++)
        for (int dx = -2; dx <= 2; dx++)
            z = min(z, frame_z(f, clamp_px(int2(p + float2(dx, dy) * reach), O), O));
    return z;
}

// The lens's image at a fractional position (bilinear, with lateral colour).
float3 frame_lin_smooth(device const float* f, float2 p, constant float4* O) {
    float2 t = p - 0.5;
    float2 i = floor(t), w = t - i;
    float3 a = frame_lin_ca(f, i + 0.5, O), b = frame_lin_ca(f, i + float2(1.5, 0.5), O);
    float3 c = frame_lin_ca(f, i + float2(0.5, 1.5), O), d = frame_lin_ca(f, i + 1.5, O);
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// What a prism shows at p: the image displaced by `shift`, the defocus of the
// surface it looks through to (depth z). Light through a prism beside an edge
// comes from what is behind it there, so a sample landing on something much
// nearer (a focused antenna, for a background pixel) is not its light: it
// keeps its own place instead.
float3 prism_sample(device const float* f, float2 p, float2 shift, float z, constant float4* O) {
    float2 q = p + shift;
    float zq = frame_z(f, clamp_px(int2(q), O), O);
    if (zq < z * 0.85) q = p;
    return frame_lin_smooth(f, q, O);
}

// The focusing screen, always: the lens's image (its depth of field, light
// fall-off and colour fringes) on fine-ground glass with a fresnel, a
// split-prism disc (halves shift apart with defocus) and a microprism collar.
// The finder: the screen's image, a rounded-corner window in a black surround (sRGB).
float3 finder_base(float2 pos, device const float* f, constant float4* O) {
    float2 p = (pos - O[7].xy) / O[7].z;
    float2 halfSize = O[0].xy * 0.5;
    float2 dq = abs(p - halfSize) - (halfSize - O[7].w);
    float edge = length(max(dq, 0.0)) + min(max(dq.x, dq.y), 0.0) - O[7].w;   // < 0 inside
    if (edge > 1.0) {
        float g = 0.022 + 0.01 * value_noise(pos / 3.0, 31);              // the surround's black
        return float3(g, g, g * 1.05);
    }
    float2 c = O[0].xy * 0.5;
    float R = O[5].x;
    float r = length(p - c);
    float3 col;
    if (r < R) {
        // Split image: each half shows the image displaced by its own defocus.
        float side = p.y < c.y ? 1 : -1;
        float z = prism_depth(f, p, 1.5, O);
        float shift = coc_px(z, O) * 0.6 * side;
        col = prism_sample(f, p, float2(shift, 0), z, O);
        // A prism needs a fast lens: it blacks out half when stopped down.
        float dark = saturate((O[2].y - 4.0) / 3.0);
        if (side > 0) col *= 1 - 0.85 * dark;
        if (abs(p.y - c.y) < 0.6) col *= 0.4;
    } else if (r < R * 1.75) {
        // Microprisms: a fine grid of tiny prisms. Each moves as one, by the
        // defocus at its centre, so an out-of-focus image breaks up and
        // shimmers while a focused one sits still.
        float cell = max(3.0, O[0].y / 300);
        float2 g = floor(p / cell);
        // Each tiny pyramid sends its cell one of six ways (scattered, not in rows).
        float a = (floor(hash(uint2(g + 4096), 23) * 6) + 0.5) * M_PI_F / 3;
        float2 centre = (g + 0.5) * cell;
        float z = prism_depth(f, centre, cell * 0.5, O);
        float shift = coc_px(z, O) * 0.5;
        col = prism_sample(f, p, shift * float2(cos(a), sin(a)), z, O);
    } else {
        col = frame_lin_ca(f, p, O);
        // Fine matte: the ground glass's own tooth, still while the image moves.
        float tooth = value_noise(p / 1.4, 7) + 0.5 * value_noise(p / 0.7, 11) - 0.75;
        col *= 1 + 0.10 * tooth;
    }
    if (abs(r - R) < 0.8 || abs(r - R * 1.75) < 0.8) col *= 0.55;
    // The fresnel's grooves: faint rings centred on the axis.
    float ring = fract(r / max(O[0].y / 70, 4.0));
    col *= 1 - 0.035 * smoothstep(0.85, 1.0, ring);
    // Light fall-off: the lens's own (at the aperture it is set to) and the
    // condenser's toward the corners of the screen.
    float2 q = field(p, O);
    float vig = 1 - O[3].w * pow(saturate(O[2].z / O[2].y), 1.5) * dot(q, q);
    col *= vig * (1 - 0.22 * dot(q, q)) * O[5].y;
    // A circular fisheye's image is a disc: black beyond it.
    if (O[6].z > 0) col *= 1 - smoothstep(O[6].z - 2.0, O[6].z, length(p - c));
    // The window's edge: a soft dark lip, then the surround.
    col *= smoothstep(0.0, O[7].w * 0.9, -edge) * 0.25 + 0.75;
    float3 outc = to_srgb(col);
    return mix(outc, float3(0.022), saturate(edge + 0.5));
}

// The meter, seen through the eyepiece. Its scale is light projected beside
// the image (as framelines are): soft, with a faint bloom and colour
// fringes, as bright as the light the scene sends in. The needle is a dark
// wire in front, its shadow faint on the scale. M[0] = the scale's texture
// rect (px), M[1] = needle pivot and tip (px), M[2] = (on, u px, -, -).
float3 meter_light(float3 outc, float2 pos, device const float* f, constant float4* O,
                   constant float4* M, texture2d<float> plate) {
    constexpr sampler sm(filter::linear, address::clamp_to_zero);
    float u = M[2].y;
    float4 R = M[0];
    float3 lin = to_lin(outc);
    float2 lo = R.xy - 2.5 * u, hi = R.xy + R.zw + 2.5 * u;
    float shade = 0;
    if (all(pos > lo) && all(pos < hi)) {
        // How much light reaches the scale: what the scene sends to the screen's edge.
        float L = 0;
        for (uint k = 0; k < 6; k++) {
            uint2 sp = uint2(O[0].x * 0.08, O[0].y * (0.15 + 0.14 * float(k)));
            L += dot(to_lin(frame_rgb(f, sp, O)), float3(0.2126, 0.7152, 0.0722));
        }
        float I = min(1.6, (0.25 + 1.3 * L / 6) * O[5].y);
        float3 core = 0, glow = 0;
        for (uint k = 0; k < 12; k++) {
            float2 o = vogel(k, 12);
            float2 a = (pos + o * 1.4 - R.xy) / R.zw;
            float2 ca = float2(0.7, 0) / R.zw;
            core += float3(plate.sample(sm, a + ca).r, plate.sample(sm, a).g, plate.sample(sm, a - ca).b);
            glow += plate.sample(sm, (pos + o * 0.9 * u - R.xy) / R.zw).rgb;
        }
        float3 light = to_lin(saturate(core / 12)) + 0.35 * to_lin(saturate(glow / 12));
        lin += light * I;
        shade = plate.sample(sm, (pos - R.xy) / R.zw).a;
    }
    // The needle, and its shadow on the scale.
    float2 a = M[1].xy, b = M[1].zw;
    float2 ab = b - a;
    float t = saturate(dot(pos - a, ab) / dot(ab, ab));
    float d = length(pos - (a + t * ab));
    float w = max(0.7, 0.12 * u);
    lin *= 1 - 0.85 * (1 - smoothstep(w - 1.6, w + 1.6, d));     // a little out of focus
    float2 off = float2(0.25, 0.3) * u;
    float t2 = saturate(dot(pos - off - a, ab) / dot(ab, ab));
    float d2 = length(pos - off - (a + t2 * ab));
    lin *= 1 - 0.3 * shade * (1 - smoothstep(w, w + 0.5 * u, d2));
    return to_srgb(lin);
}

fragment float4 viewfinder(VOut in [[stage_in]], device const float* f [[buffer(0)]],
                           constant float4* O [[buffer(1)]], constant float4* F [[buffer(2)]],
                           constant float4* M [[buffer(3)]], texture2d<float> plate [[texture(0)]]) {
    float3 outc = finder_base(in.pos.xy, f, O);
    if (M[2].x > 0) outc = meter_light(outc, in.pos.xy, f, O, M, plate);
    return float4(outc, 1);
}

// What is under the finder's crosshair: the nearest surface's ray depth (scene
// units) around the centre, and how solid it is there. For measuring.
kernel void probe(device const float* f [[buffer(0)]], constant float4* O [[buffer(1)]],
                  device float* out [[buffer(2)]], uint g [[thread_position_in_grid]]) {
    if (g > 0) return;
    uint n = uint(O[0].x * O[0].y);
    int2 c = int2(O[0].xy * 0.5);
    float best = 0, solid = 0;
    for (int dy = -2; dy <= 2; dy++)
        for (int dx = -2; dx <= 2; dx++) {
            uint i = idx(clamp_px(c + int2(dx, dy), O), O);
            float T = f[3 * n + i], d = f[4 * n + i];
            if (T < 0.5 && d > 0 && (best == 0 || d < best)) { best = d; solid = 1 - T; }
        }
    out[0] = best;
    out[1] = solid;
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

// Adds one tile of one sub-pupil's render to the exposure (exposures render
// in finder-sized tiles, so a big scene's photo needs no more memory than the
// finder). L[0] = (lens point, weight, reset), L[1] = (colour mask: which of
// r g b this sub-pupil carries, 1: the render has cut it by the barrel),
// L[2] = (tile origin, tile size) in the photo.
kernel void accumulate(device const float* f [[buffer(0)]], constant float4* O [[buffer(1)]],
                       device float4* acc [[buffer(2)]], constant float4* L [[buffer(3)]],
                       uint2 g [[thread_position_in_grid]]) {
    uint tw = uint(L[2].z), th = uint(L[2].w);
    uint2 p = g + uint2(L[2].xy);
    if (g.x >= tw || g.y >= th || p.x >= uint(O[0].x) || p.y >= uint(O[0].y)) return;
    uint n = tw * th, j = g.y * tw + g.x;
    float3 c = float3(f[3 * j], f[3 * j + 1], f[3 * j + 2]) + f[3 * n + j] * O[4].rgb;
    uint i = idx(p, O);
    float w = pupil(L[0].xy, field(float2(p) + 0.5, O), O, L[1].w) * L[0].z;
    float4 prev = L[0].w > 0.5 ? float4(0) : acc[i];
    acc[i] = prev + float4(to_lin(c) * L[1].rgb * w, w);
}

float3 acc_at(device const float4* acc, float2 p, constant float4* O) {
    float2 t = p - 0.5;
    int2 i0 = int2(floor(t));
    float2 w = t - floor(t);
    float3 a = acc[idx(clamp_px(i0, O), O)].rgb, b = acc[idx(clamp_px(i0 + int2(1, 0), O), O)].rgb;
    float3 c = acc[idx(clamp_px(i0 + int2(0, 1), O), O)].rgb, d = acc[idx(clamp_px(i0 + int2(1, 1), O), O)].rgb;
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// A thin vertical wire across the stop (the Anamorfake's monofilament)
// diffracts a share of all light sideways: a horizontal line whose tails fall
// off with distance, a little longer in red than blue (the spread goes with
// wavelength). Made per row as a sum of four exponentials, each a forward and
// a backward running sum, so a one-pixel highlight streaks as well as a lamp.
// Z = (shortest length px, share of light, -, -). Clipped highlights stand
// for far brighter sources than the scan could record, so count them up.
kernel void streak(device const float4* acc [[buffer(0)]], constant float4* O [[buffer(1)]],
                   constant float4& D [[buffer(3)]], constant float4& Z [[buffer(4)]],
                   device float4* out [[buffer(5)]], uint y [[thread_position_in_grid]]) {
    uint W = uint(O[0].x), H = uint(O[0].y);
    if (y >= H) return;
    uint row = y * W;
    for (uint i = 0; i < W; i++) out[row + i] = 0;
    for (uint j = 0; j < 4; j++) {
        float len = Z.x * pow(4.0, float(j));
        float3 a = exp(-1.0 / (len * float3(1.15, 1.0, 0.85)));
        float3 norm = (1 - a) / (1 + a) * (Z.y / 4);
        float3 run = 0;
        for (uint i = 0; i < W; i++) {
            float3 v = acc[row + i].rgb * D.rgb;
            v += max(v - 0.85, 0.0) * 12;
            run = v + a * run;
            out[row + i].rgb += norm * run;
        }
        run = 0;
        for (int i = int(W) - 1; i >= 0; i--) {
            float3 v = acc[row + uint(i)].rgb * D.rgb;
            v += max(v - 0.85, 0.0) * 12;
            run = v + a * run;
            out[row + uint(i)].rgb += norm * (run - v);
        }
    }
}

// Develops the exposure into a print. D = per-channel 1 / pupil weight of the full aperture.
kernel void develop(device const float4* acc [[buffer(0)]], constant float4* O [[buffer(1)]],
                    constant float4* F [[buffer(2)]], constant float4& D [[buffer(3)]],
                    device uchar4* out [[buffer(4)]], device const float4* streaks [[buffer(5)]],
                    uint2 p [[thread_position_in_grid]]) {
    uint W = uint(O[0].x), H = uint(O[0].y);
    if (p.x >= W || p.y >= H) return;
    float expo = exp2(O[5].w);
    float2 pc = float2(p) + 0.5, c = O[1].xy;
    float2 q = field(pc, O);
    float vig = 1 - O[3].w * pow(saturate(O[2].z / O[2].y), 1.5) * dot(q, q);
    // Lateral colour: each channel from its own magnification. Light lost to
    // barrel clipping darkens the corners on its own (no renormalising).
    float k = O[6].x;
    float3 lin;
    lin.r = acc_at(acc, c + (pc - c) * (1 - k), O).r;
    lin.g = acc_at(acc, pc, O).g;
    lin.b = acc_at(acc, c + (pc - c) * (1 + k), O).b;
    lin *= D.rgb * expo * vig;
    if (D.w > 0) lin += streaks[idx(p, O)].rgb * expo;    // D.w: the lens streaks
    // Halation: light past the film base bouncing back, around bright highlights.
    float3 halo = 0;
    if (F[6].x > 0) {
        float rad = O[0].y * 0.012;
        for (uint j = 0; j < 32; j++) {
            float2 o = vogel(j, 32) * rad;
            uint2 pj = clamp_px(int2(pc + o), O);
            halo += max(acc[idx(pj, O)].rgb * D.rgb * expo - 0.9, 0.0);
        }
        halo /= 32;
    }
    if (O[6].z > 0) lin *= 1 - smoothstep(O[6].z - 2.0, O[6].z, length(pc - c));
    float3 col = film_look(lin, halo, pc, uint(O[5].z), O[0].y, F);
    out[idx(p, O)] = uchar4(uchar3(round(col * 255)), 255);
}

// The digital negative: the same exposure as `develop` reads (lens fall-off,
// lateral colour, the exposure), as linear light before any film, unclipped:
// three half floats per pixel, for a DNG. Values past 1 are highlights the
// print would burn out but the negative keeps.
kernel void negative(device const float4* acc [[buffer(0)]], constant float4* O [[buffer(1)]],
                     constant float4& D [[buffer(3)]], device half* out [[buffer(4)]],
                     device const float4* streaks [[buffer(5)]], uint2 p [[thread_position_in_grid]]) {
    uint W = uint(O[0].x), H = uint(O[0].y);
    if (p.x >= W || p.y >= H) return;
    float expo = exp2(O[5].w);
    float2 pc = float2(p) + 0.5, c = O[1].xy;
    float2 q = field(pc, O);
    float vig = 1 - O[3].w * pow(saturate(O[2].z / O[2].y), 1.5) * dot(q, q);
    float k = O[6].x;
    float3 lin;
    lin.r = acc_at(acc, c + (pc - c) * (1 - k), O).r;
    lin.g = acc_at(acc, pc, O).g;
    lin.b = acc_at(acc, c + (pc - c) * (1 + k), O).b;
    lin = max(lin * D.rgb * expo * vig, 0.0);
    if (D.w > 0) lin += streaks[idx(p, O)].rgb * expo;
    if (O[6].z > 0) lin *= 1 - smoothstep(O[6].z - 2.0, O[6].z, length(pc - c));
    uint i = idx(p, O) * 3;
    out[i] = half(min(lin.r, 60000.0)); out[i + 1] = half(min(lin.g, 60000.0)); out[i + 2] = half(min(lin.b, 60000.0));
}

// ---- lights ---------------------------------------------------------------

// Wireframes of the light heads: segments already projected to finder pixels
// (x, y, metres along the axis, alpha). Dimmed where the scene is in front.
struct LineOut { float4 pos [[position]]; float z; float a; };

vertex LineOut wire_vertex(uint vid [[vertex_id]], device const float4* v [[buffer(0)]],
                           constant float4* O [[buffer(1)]]) {
    float4 p = v[vid];
    LineOut o;
    // Image pixels into the window (the finder's image is inset, O[7]).
    float2 w = O[7].xy + p.xy * O[7].z;
    o.pos = float4(w.x / O[0].x * 2 - 1, 1 - w.y / O[0].y * 2, 0, 1);   // the window is the frame's size
    o.z = p.z;
    o.a = p.w;
    return o;
}

fragment float4 wire_fragment(LineOut in [[stage_in]], device const float* f [[buffer(0)]],
                              constant float4* O [[buffer(1)]], constant float4& colour [[buffer(2)]]) {
    float zs = frame_z(f, clamp_px(int2((in.pos.xy - O[7].xy) / O[7].z), O), O);
    float a = in.a * (in.z > zs * 1.01 ? 0.3 : 1.0);
    return float4(colour.rgb, colour.a * a);
}

// Relighting (gs_render's model, made for scans lit from the camera): each
// light reads the scan's broad colour (SH DC + band 1) in its own direction
// for the diffuse, bands 2-3 at the half vector for the shine; the house
// lights give back a share of the scan as captured. Writes new SH DC colours
// straight into the renderer's buffer (render with the higher bands off).
//   G[0] = (camera position, house lights)   G[1] = (lights, N, K higher coeffs, shine colour)
//   G[2] = (house lights' colour, shadows on)   G[3] = (shadow quality, version, daylight scan, -)   VIS = per splat, per light, the light let through (0-255)
//   per light, 4 float4s (PlacedLight.packed): (pos, -), (aim, dimmer / E_ref),
//   (colour, shine), (right, metres per unit); and its beam table B (candela per
//   colour; 32 bins off axis with edges at 90 (t/32)^1.3 degrees, x 8 around it).
constant float C0 = 0.28209479177387814;
constant float C1 = 0.4886025119029199;

void sh_basis(float3 d, thread float* B) {
    float x = d.x, y = d.y, z = d.z, xx = x * x, yy = y * y, zz = z * z;
    B[0] = -C1 * y; B[1] = C1 * z; B[2] = -C1 * x;
    B[3] = 1.0925484305920792 * x * y; B[4] = -1.0925484305920792 * y * z;
    B[5] = 0.31539156525252005 * (2 * zz - xx - yy); B[6] = -1.0925484305920792 * x * z;
    B[7] = 0.5462742152960396 * (xx - yy);
    B[8] = -0.5900435899266435 * y * (3 * xx - yy); B[9] = 2.890611442640554 * x * y * z;
    B[10] = -0.4570457994644658 * y * (4 * zz - xx - yy);
    B[11] = 0.3731763325901154 * z * (2 * zz - 3 * xx - 3 * yy);
    B[12] = -0.4570457994644658 * x * (4 * zz - xx - yy); B[13] = 1.445305721320277 * z * (xx - yy);
    B[14] = -0.5900435899266435 * x * (xx - 3 * yy);
}

float3 sh_sum(float3 d, device const float* sh, uint K, uint first, uint last) {
    float B[15];
    sh_basis(d, B);
    float3 s = 0;
    for (uint k = first; k < min(last, K); k++)
        s += B[k] * float3(sh[3 * k], sh[3 * k + 1], sh[3 * k + 2]);
    return s;
}

float3 srgb_to_lin3(float3 c) { c = max(c, 0.0); return float3(srgb_to_lin(c.r), srgb_to_lin(c.g), srgb_to_lin(c.b)); }
float3 lin_to_srgb3(float3 c) { c = max(c, 0.0); return float3(lin_to_srgb(c.r), lin_to_srgb(c.g), lin_to_srgb(c.b)); }

// Shadows: how much of one light reaches each splat, from that light's
// shadow map (Spirula's render from the head: transmittance and median depth
// per texel). A blocker search finds how far in front the occluders are; the
// penumbra then widens with the head's source size (the lit face of the
// Fresnel lens, or a softlight's opening) times the occluder-to-receiver
// gap, as real soft shadows do; the filter averages the light let through.
// Occluders fade in over a short depth (fur shadows itself gradually).
//   S[0..2] = the light's view rows (world -> light, OpenCV axes)
//   S[3] = (fx, map size, metres per unit, source radius in scene units)
//   S[4] = (blocker taps, filter taps, largest penumbra in texels, light slot)
float2 shadow_tap(device const float* map, int2 t, uint res) {
    t = clamp(t, int2(0), int2(res) - 1);
    uint n = res * res, j = uint(t.y) * res + uint(t.x);
    return float2(map[3 * n + j], map[4 * n + j]);   // transmittance, median ray depth
}

kernel void shadow_vis(device const float* means [[buffer(0)]], device const float* map [[buffer(1)]],
                       constant float4* S [[buffer(2)]], device uchar* vis [[buffer(3)]],
                       constant uint& N [[buffer(4)]], uint i [[thread_position_in_grid]]) {
    if (i >= N) return;
    uint slot = uint(S[4].w);
    float3 m = float3(means[3 * i], means[3 * i + 1], means[3 * i + 2]);
    float3 pc = float3(dot(S[0].xyz, m) + S[0].w, dot(S[1].xyz, m) + S[1].w, dot(S[2].xyz, m) + S[2].w);
    float fx = S[3].x, res = S[3].y;
    if (pc.z <= 0) { vis[i * 8 + slot] = 255; return; }
    float2 uv = float2(fx * pc.x / pc.z, fx * pc.y / pc.z) + res * 0.5;
    if (any(uv < 0) || any(uv >= res)) { vis[i * 8 + slot] = 255; return; }
    float dr = length(pc);
    // Self-shadowing guard: a little in front of the receiver, more far off.
    // ... and a few texels' depth, for surfaces the light grazes.
    float bias = 0.012 * dr + 0.004 / S[3].z + 3 * dr / fx;
    float ramp = 0.03 * dr;
    uint nb = uint(S[4].x), nf = uint(S[4].y);
    // Blockers: occluders in front, near this texel.
    float search = min(S[4].z, max(2.0, S[3].w / dr * fx * 0.5));
    float dsum = 0, cnt = 0;
    for (uint k = 0; k < nb; k++) {
        float2 o = vogel(k, nb) * search;
        float2 tp = shadow_tap(map, int2(uv + o), uint(res));
        if (tp.x < 0.97 && tp.y > 0 && tp.y < dr - bias) { dsum += tp.y; cnt += 1; }
    }
    if (cnt == 0) { vis[i * 8 + slot] = 255; return; }
    float db = dsum / cnt;
    // Penumbra: source size x (receiver - blocker) / blocker, in texels.
    float pen = clamp(S[3].w * (dr - db) / max(db, 1e-6) / dr * fx, 1.0, S[4].z);
    float lit = 0;
    for (uint k = 0; k < nf; k++) {
        float2 o = vogel(k, nf) * pen;
        float2 tp = shadow_tap(map, int2(uv + o), uint(res));
        float occl = 0;
        if (tp.x < 0.97 && tp.y > 0) occl = (1 - tp.x) * saturate((dr - bias - tp.y) / ramp);
        lit += 1 - occl;
    }
    vis[i * 8 + slot] = uchar(clamp(lit / float(nf), 0.0, 1.0) * 255 + 0.5);
}

kernel void relight(device const float* means [[buffer(0)]], device const float* dc0 [[buffer(1)]],
                    device const float* sh0 [[buffer(2)]], device float* out_dc [[buffer(3)]],
                    constant float4* G [[buffer(4)]], constant float4* LT [[buffer(5)]],
                    device const float4* BT [[buffer(6)]], device const uchar* VIS [[buffer(7)]],
                    uint i [[thread_position_in_grid]]) {
    uint N = uint(G[1].y), K = uint(G[1].z), nl = uint(G[1].x);
    if (i >= N) return;
    float3 mean = float3(means[3 * i], means[3 * i + 1], means[3 * i + 2]);
    float3 base = 0.5 + C0 * float3(dc0[3 * i], dc0[3 * i + 1], dc0[3 * i + 2]);
    device const float* sh = sh0 + i * K * 3;
    float ambient = G[0].w;
    float3 v = normalize(mean - G[0].xyz);           // camera -> splat, as 3DGS reads SH
    float3 tint = G[2].rgb;
    float3 lin = srgb_to_lin3(base) * ambient * tint;
    float3 shine = 0;
    bool has_sh = K >= 8;
    if (has_sh && ambient > 0) shine += pow(ambient * tint, 1 / 2.2) * sh_sum(v, sh, K, 0, K);
    const float3 lum = float3(0.2126, 0.7152, 0.0722);
    for (uint l = 0; l < nl; l++) {
        constant float4* L = LT + 4 * l;
        float3 d = L[0].xyz - mean;
        float dist_m = max(length(d) * L[3].w, 1e-3);
        float3 ldir = d / max(length(d), 1e-9);
        // The head's traced beam, by angle off its axis and around it.
        float3 w = -ldir, aim = L[1].xyz, right = L[3].xyz, upl = cross(right, aim);
        float ct = dot(w, aim);
        if (ct <= 0) continue;
        float th = acos(min(ct, 1.0));
        float ph = atan2(abs(dot(w, upl)), abs(dot(w, right)));
        float tb = clamp(pow(th / (M_PI_F / 2), 1 / 1.3) * 32.0 - 0.5, 0.0, 31.0);
        float pb = clamp(ph / (M_PI_F / 2) * 8.0 - 0.5, 0.0, 7.0);
        int t0 = min(int(tb), 30), p0 = min(int(pb), 6);
        float ft = tb - t0, fp = pb - p0;
        device const float4* B = BT + l * 256;
        float3 cd = mix(mix(B[t0 * 8 + p0].rgb, B[t0 * 8 + p0 + 1].rgb, fp),
                        mix(B[(t0 + 1) * 8 + p0].rgb, B[(t0 + 1) * 8 + p0 + 1].rgb, fp), ft);
        float3 e3 = cd * L[1].w / (dist_m * dist_m);
        if (G[2].w > 0.5) e3 *= float(VIS[i * 8 + l]) / 255.0;     // shadowed
        float e = dot(e3, float3(0.2126, 0.7152, 0.0722));
        if (e <= 0) continue;
        float3 col = L[2].rgb * (e3 / e);
        // Diffuse: the broad colour seen from the light's side.
        // (A daylight scan's band 1 is the sun's doing: read from a new direction
        // it gives false colour, so those relight from the base colour alone.)
        bool camera_lit = G[3].z < 0.5;
        float3 diff = max(base + (K >= 3 && camera_lit ? sh_sum(-ldir, sh, K, 0, 3) : 0.0), 0.0);
        lin += srgb_to_lin3(diff) * e * col;
        if (has_sh && camera_lit) {
            float3 h = normalize(v - ldir);
            float3 S = sh_sum(h, sh, K, 3, K);
            float3 full = max(base + sh_sum(h, sh, K, 0, 3) + S, 0.0);
            float Lf = dot(full, lum);
            float3 chroma = Lf > 1e-3 ? full / Lf : float3(1);
            float k = G[1].w;
            float3 sh_at = dot(S, lum) * ((1 - k) + k * chroma);
            shine += pow(max(e * col, 0.0), 1 / 2.2) * sh_at * L[2].w;
        }
    }
    float3 o = max(lin_to_srgb3(lin) + shine, 0.0);
    float3 dc = (o - 0.5) / C0;
    out_dc[3 * i] = dc.x; out_dc[3 * i + 1] = dc.y; out_dc[3 * i + 2] = dc.z;
}
"""
