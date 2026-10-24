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
//   O[8] = (oval stop's width over height, 0 = round; 1 = mirror up: no image)
//   O[9..11] = the lens filter (see "lens filters" below)
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
    float t = f[3 * n + i];
    // In a place (O[4].w = 2) the scan surrounds you: what shows through is
    // the blend's leak, not a background. Blurred splats over each other
    // never add back up to solid (a single layer leaks about a third), so
    // scale back up to full cover; only an all-but-empty pixel shows the dark.
    if (O[4].w > 1.5) {
        float keep = smoothstep(0.85, 0.97, t);
        return mix(c / max(1 - t, 0.03), c + t * O[4].rgb, keep);
    }
    return c + t * O[4].rgb;
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
    // Eased, not switched: a hard either/or carved sharp edges into soft blur.
    float keep = smoothstep(z * 0.7, z * 0.9, zq);
    return mix(frame_lin_smooth(f, p, O), frame_lin_smooth(f, q, O), keep);
}

// The focusing screen, always: the lens's image (its depth of field, light
// fall-off and colour fringes) on fine-ground glass with a fresnel, a
// split-prism disc (halves shift apart with defocus) and a microprism collar.
// ---- lens filters ----------------------------------------------------------
//
// O[9] = (the filter's transmission rgb, -), O[10] = (star points, star
// strength, 1 = diffraction grating, angle), O[11] = (glow, soften, veil,
// highlight threshold). A filter is in front of the lens: the finder, the
// meter and the film all see through it.

struct AccSource {
    device const float4* acc; constant float4* O; float3 k;
    float3 at(float2 q) const { return acc[idx(clamp_px(int2(q), O), O)].rgb * k; }
};
struct FrameSource {
    device const float* f; constant float4* O; float3 k;
    float3 at(float2 q) const { return to_lin(frame_rgb(f, clamp_px(int2(q), O), O)) * k; }
};

// Light brighter than `thr`, keeping its colour (a cut per channel would tint it).
float3 above(float3 v, float thr) {
    float lum = dot(v, float3(0.2126, 0.7152, 0.0722));
    return v * (max(lum - thr, 0.0) / max(lum, 1e-4));
}

// A spectrum colour, h from 0 (violet) to 1 (red), roughly even in brightness.
float3 spectrum(float h) {
    float3 c = float3(smoothstep(0.40, 0.85, h) + 0.4 * (1 - smoothstep(0.0, 0.12, h)),
                      1 - saturate(abs(h - 0.52) * 2.4),
                      1 - smoothstep(0.08, 0.50, h));
    return saturate(c) * 1.4;
}

// The light an effect filter adds at p (or takes, for soften and veil) to
// `base`, the light already there. `steps`: samples along each star ray.
template <typename S>
float3 filter_fx(thread const S& src, float2 p, float3 base, constant float4* O, int steps) {
    float3 add = 0;
    float thr = O[11].w, H = O[0].y;
    int points = int(O[10].x);
    // Each pixel's samples start at its own offset, so their spacing never shows.
    float jitter = hash(uint2(p), 57);
    if (points > 0) {
        bool spectral = O[10].z > 0.5;
        float L = H * (spectral ? 0.20 : 0.15);
        // Rays both ways along each line: a 4-point star is two lines.
        int lines = max(1, points / 2);
        int n = spectral ? steps * 2 : steps;
        float3 star = 0;
        for (int j = 0; j < lines; j++) {
            float a = O[10].w + float(j) * M_PI_F / float(lines);
            float2 dir = float2(cos(a), sin(a));
            for (int s = 0; s < n; s++) {
                float t = (float(s) + jitter) / float(n);
                float d = L * t * t;
                float w = exp(-3.2 * t) * (2.0 * t / float(n)) * 3.0;
                for (int side = -1; side <= 1; side += 2) {
                    float3 v = above(src.at(p - dir * d * float(side)), thr);
                    if (spectral) {
                        // A grating sends each order's spectrum further out, violet
                        // nearest: the spike is rainbow bands repeating along it,
                        // white only at its root.
                        float lum = dot(v, float3(0.2126, 0.7152, 0.0722));
                        float h = fract(t * 3.2 + 0.15);
                        float3 c = mix(float3(1), spectrum(h), smoothstep(0.02, 0.10, t));
                        star += lum * c * w * 1.3;
                    } else {
                        star += v * w;
                    }
                }
            }
        }
        add += star * O[10].y;
    }
    if (O[11].x > 0 || O[11].y > 0 || O[11].z > 0) {
        // Discs of samples, spread evenly by area and turned at random per pixel.
        float rot = jitter * 6.2831853;
        // Soft-focus filters scatter from everything bright, not only clipped
        // highlights; each sample's bright part first, then spread (a small lamp
        // averaged with the dark round it would never pass the threshold).
        float gthr = thr * 0.45;
        float3 near = 0, far = 0, nearHi = 0, farHi = 0;
        // Samples crowd toward the middle (radius ~ t^2): a halo bright near the
        // light, fading smoothly, with no edge.
        for (uint k = 0; k < 20; k++) {
            float t = (float(k) + 0.5) / 20, a = float(k) * 2.39996323 + rot;
            float3 v = src.at(p + float2(cos(a), sin(a)) * t * t * H * 0.02);
            near += v; nearHi += above(v, gthr);
        }
        for (uint k = 0; k < 28; k++) {
            float t = (float(k) + 0.5) / 28, a = float(k) * 2.39996323 + rot;
            float3 v = src.at(p + float2(cos(a), sin(a)) * t * t * H * 0.09);
            far += v; farHi += above(v, gthr);
        }
        near /= 20; far /= 28; nearHi /= 20; farHi /= 28;
        add += O[11].x * (nearHi * 1.2 + farHi * 1.6);
        add += O[11].y * (near - base);
        add += O[11].z * ((far - base) * 0.6 + far * 0.12);
    }
    return add;
}

// The eyepiece is not perfect: what sits on the screen (the window's edge,
// the meter, the wireframes) is seen with a little pincushion, a touch more
// in red than in blue. `pos` in window pixels; returns where to look on the
// screen for what the eye sees at `pos`. The scene's own image is the lens's
// business and is left alone.
constant float EYEPIECE_K = 0.018, EYEPIECE_CA = 0.0035;
float2 eyepiece(float2 pos, constant float4* O, float k) {
    float2 c = O[0].xy * 0.5;
    float2 d = pos - c;
    return c + d * (1 - k * dot(d, d) / dot(c, c));
}
float2 eyepiece_forward(float2 pos, constant float4* O, float k) {
    float2 c = O[0].xy * 0.5;
    float2 d = pos - c;
    return c + d * (1 + k * dot(d, d) / dot(c, c));
}

// The lit screen glows faintly past its mask: the black surround near each
// part of the window's edge takes a soft halo of the image just inside it (`pe`: where
// the eye sees, in image pixels; `edge`: how far outside, px). sRGB.
float3 surround(float2 pos, float2 pe, float edge, device const float* f, constant float4* O) {
    float g = 0.022 + 0.01 * value_noise(pos / 3.0, 31);              // the surround's black
    float3 lin = to_lin(float3(g, g, g * 1.05));
    float inset = O[7].w + 4;
    float2 q = clamp(pe, float2(inset), O[0].xy - inset);
    // Diffuse: gathered from a patch inside the edge that widens with distance.
    float spread = O[0].y * 0.05 + max(edge, 0.0) * 1.2;
    float2 inward = normalize(O[0].xy * 0.5 - q + 1e-3);
    float2 centre = q + inward * spread * 0.6;
    float3 near = 0;
    for (uint k = 0; k < 16; k++) {
        float2 t = centre + vogel(k, 16) * spread;
        near += to_lin(frame_rgb(f, clamp_px(int2(t), O), O));
    }
    near /= 16;
    float h = O[0].y;
    // Very faint: the glass itself stays clean; only the black catches a little.
    float halo = 0.035 * exp(-max(edge, 0.0) / (h * 0.025)) + 0.01 * exp(-max(edge, 0.0) / (h * 0.11));
    return to_srgb(lin + near * halo * O[5].y);
}

// The finder: the screen's image, a rounded-corner window in a black surround (sRGB).
float3 finder_base(float2 pos, device const float* f, constant float4* O) {
    float2 p = (pos - O[7].xy) / O[7].z;
    float2 halfSize = O[0].xy * 0.5;
    // The window's edge as the eyepiece shows it.
    float2 pe = (eyepiece(pos, O, EYEPIECE_K) - O[7].xy) / O[7].z;
    float2 dq = abs(pe - halfSize) - (halfSize - O[7].w);
    float edge = length(max(dq, 0.0)) + min(max(dq.x, dq.y), 0.0) - O[7].w;   // < 0 inside
    // Mirror up (O[8].y): no image on the screen, so no glow round it either.
    bool dark = O[8].y > 0.5;
    if (edge > 1.0) return dark ? float3(0.022) : surround(pos, pe, edge, f, O);
    float2 c = O[0].xy * 0.5;
    float R = O[5].x;
    float r = length(p - c);
    float3 col;
    if (r < R) {
        // Split image: each half shows the image displaced by its own defocus.
        float side = p.y < c.y ? 1 : -1;
        // One depth for each half, read across it: the wedge moves its half as
        // one (per-pixel depths jump about in blur and tore seams through it).
        float z = prism_depth(f, float2(c.x, c.y - side * R * 0.5), R * 0.18, O);
        // Displacement follows defocus but levels off (a wedge bends light only
        // so far): badly out of focus the halves stay apart, not flung away.
        float shift = clamp(coc_px(z, O) * 0.6, -R * 0.45, R * 0.45) * side;
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
        float coc = abs(coc_px(z, O));
        // Each facet moves its bit of image a little way (a few facets at most):
        // far out of focus the collar shimmers finely and dims, never scatters.
        float shift = min(coc * 0.5, cell * 2.5);
        col = prism_sample(f, p, shift * float2(cos(a), sin(a)), z, O);
        col *= 1 - 0.35 * smoothstep(cell * 2, cell * 10, coc);
    } else {
        col = frame_lin_ca(f, p, O);
        // Fine matte: the ground glass's own tooth, still while the image moves.
        float tooth = value_noise(p / 1.4, 7) + 0.5 * value_noise(p / 0.7, 11) - 0.75;
        col *= 1 + 0.10 * tooth;
    }
    // The filter on the lens: its colour, and what an effect filter scatters.
    col *= O[9].rgb;
    if (O[10].x > 0 || O[11].x > 0 || O[11].y > 0 || O[11].z > 0) {
        FrameSource src = { f, O, O[9].rgb };
        col = max(col + filter_fx(src, p, col, O, 16), 0.0);
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
    // A circular fisheye's image is a disc: black beyond it, but for a soft
    // glow of the light near its rim scattered past it inside the lens.
    if (O[6].z > 0) {
        float rr = length(p - c), Rc = O[6].z;
        col *= 1 - smoothstep(Rc - 2.0, Rc, rr);
        if (rr > Rc - 2.0) {
            float out = max(rr - Rc, 0.0);
            float th = atan2(p.y - c.y, p.x - c.x), spread = 0.5 + 1.5 * out / Rc;
            th += (hash(uint2(p), 41) - 0.5) * spread / 16;
            float3 rim = 0;
            for (int k = 0; k < 16; k++) {
                float a = th + (float(k) / 15 - 0.5) * spread;
                float r = Rc * (0.94 - 0.05 * float(k % 3));
                rim += frame_lin_ca(f, c + r * float2(cos(a), sin(a)), O);
            }
            rim /= 16;
            col += rim * (0.14 * exp(-out / (Rc * 0.035)) + 0.04 * exp(-out / (Rc * 0.18))) * O[5].y;
        }
    }
    // The window's edge: a soft dark lip, then the surround.
    col *= smoothstep(0.0, O[7].w * 0.9, -edge) * 0.25 + 0.75;
    float3 outc = dark ? float3(0) : to_srgb(col);
    return mix(outc, dark ? float3(0.022) : surround(pos, pe, edge, f, O), saturate(edge + 0.5));
}

// The meter, seen through the eyepiece. Its scale is light projected beside
// the image (as framelines are): soft, with a faint bloom and colour
// fringes, as bright as the light the scene sends in. The needle is lit red.
// M[0] = the scale's texture rect (px), M[1] = needle pivot and tip (px),
// M[2] = (on, u px, -, -).
float3 meter_light(float3 outc, float2 pos, device const float* f, constant float4* O,
                   constant float4* M, texture2d<float> plate) {
    constexpr sampler sm(filter::linear, address::clamp_to_zero);
    float u = M[2].y;
    float4 R = M[0];
    float3 lin = to_lin(outc);
    float2 lo = R.xy - 2.5 * u, hi = R.xy + R.zw + 2.5 * u;
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
    }
    // The needle: lit red, as the LEDs are, a little out of focus, with a
    // soft glow round it (it lights itself, so it shows in any light).
    float2 a = M[1].xy, b = M[1].zw;
    float2 ab = b - a;
    float t = saturate(dot(pos - a, ab) / dot(ab, ab));
    float d = length(pos - (a + t * ab));
    float w = max(0.7, 0.11 * u);
    float core = 1 - smoothstep(w - 1.2, w + 1.2, d);
    float glow = exp(-d * d / (0.12 * u * u));
    // Lit only inside the frame: it fades out toward the frame's edge, where
    // it swings in from the dark surround.
    float edgeX = O[7].x;
    float lit = smoothstep(edgeX, edgeX + 3.5 * u, pos.x);
    float3 red = float3(0.9, 0.08, 0.05);
    lin = mix(lin, red * 0.75, core * 0.75 * lit) + red * glow * 0.03 * lit;
    return to_srgb(lin);
}

fragment float4 viewfinder(VOut in [[stage_in]], device const float* f [[buffer(0)]],
                           constant float4* O [[buffer(1)]], constant float4* F [[buffer(2)]],
                           constant float4* M [[buffer(3)]], texture2d<float> plate [[texture(0)]]) {
    float3 outc = finder_base(in.pos.xy, f, O);
    if (M[2].x > 0) {
        // The meter through the eyepiece: each colour from its own place.
        float3 r = meter_light(outc, eyepiece(in.pos.xy, O, EYEPIECE_K + EYEPIECE_CA), f, O, M, plate);
        float3 g = meter_light(outc, eyepiece(in.pos.xy, O, EYEPIECE_K), f, O, M, plate);
        float3 b = meter_light(outc, eyepiece(in.pos.xy, O, EYEPIECE_K - EYEPIECE_CA), f, O, M, plate);
        outc = float3(r.r, g.g, b.b);
    }
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
    float3 c = to_lin(frame_rgb(f, clamp_px(int2(p), O), O)) * O[9].rgb;    // TTL: through the filter
    out[g.y * grid.x + g.x] = dot(c, float3(0.2126, 0.7152, 0.0722));
}

// ---- shutter --------------------------------------------------------------

// Adds one tile of one sub-pupil's render to the exposure (exposures render
// in finder-sized tiles, so a big scene's photo needs no more memory than the
// finder). L[0] = (lens point, weight, reset), L[1] = (colour mask: which of
// r g b this sub-pupil carries, 1: the render has cut it by the barrel),
// L[2] = (tile origin, tile size) in the photo.
// What lies behind the live render: distant shells (the far splats, baked
// into six cube faces of colour and distance from where the camera stood),
// then the sky (.hdr), then the plain background. Fills where the render is
// empty (as frame_rgb judges it) and leaves the frame opaque, so everything
// after is unchanged.
//   K[0] = (W, H, fx, fy)  K[1] = (cx, cy, fisheye, sky mip)
//   K[2..4] = view rows (right, down, forward)  K[5] = (world up, sky yaw)
//   K[6] = (sky scale, place, has sky, has shells)  K[7] = (background rgb, face fx / size)
//   K[8] = (camera - bake centre, shell radius)  K[9] = (aperture diameter m, focus m, metres per unit, pupil samples)
//   K[10..15] face forwards, K[16..21] rights, K[22..27] downs; K[28..] pupil samples (x, y, weight, -)
float shell_face(float3 u, constant float4* K, thread float2& uv) {
    int best = 0; float bd = -2;
    for (int k = 0; k < 6; k++) { float dd = dot(u, K[10 + k].xyz); if (dd > bd) { bd = dd; best = k; } }
    uv = float2(dot(u, K[16 + best].xyz), dot(u, K[22 + best].xyz)) / bd * K[7].w + 0.5;
    return float(best);
}
// The shell along the ray o + t d (o from the bake centre): where it meets the
// baked surface, found from the stored distance (two refinements).
float4 shell_at(texture2d_array<float> col, texture2d_array<float> dep, float3 o, float3 d,
                constant float4* K, thread float& dist) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float rho = K[8].w * 2;
    float3 u = d;
    for (int it = 0; it < 3; it++) {
        float b = dot(o, d), c = dot(o, o) - rho * rho;
        float t = -b + sqrt(max(b * b - c, 0.0));
        u = normalize(o + t * d);
        if (it == 2) break;
        float2 uv; float f = shell_face(u, K, uv);
        rho = max(dep.sample(s, uv, uint(f)).r, K[8].w);
    }
    dist = rho;
    float2 uv; float f = shell_face(u, K, uv);
    return col.sample(s, uv, uint(f));
}
float3 sky_at(texture2d<float> sky, float3 d, float mip, constant float4* K) {
    float3 up = K[5].xyz;
    float3 seed = abs(up.x) < 0.9 ? float3(1, 0, 0) : float3(0, 0, 1);
    float3 a = normalize(seed - dot(seed, up) * up), b = cross(up, a);
    float el = asin(clamp(dot(d, up), -1.0, 1.0));
    float az = atan2(dot(d, b), dot(d, a)) + K[5].w;
    constexpr sampler s(filter::linear, mip_filter::linear, s_address::repeat, t_address::clamp_to_edge);
    float3 lin = sky.sample(s, float2(fract(0.5 + az / (2 * M_PI_F)), 0.5 - el / M_PI_F), level(mip)).rgb * K[6].x;
    return float3(lin_to_srgb(lin.x), lin_to_srgb(lin.y), lin_to_srgb(lin.z));
}
kernel void background_fill(device float* f [[buffer(0)]], constant float4* K [[buffer(1)]],
                            texture2d<float> sky [[texture(0)]], texture2d_array<float> shellCol [[texture(1)]],
                            texture2d_array<float> shellDep [[texture(2)]], uint2 p [[thread_position_in_grid]]) {
    uint W = uint(K[0].x), H = uint(K[0].y);
    if (p.x >= W || p.y >= H) return;
    uint n = W * H, i = p.y * W + p.x;
    float t = f[3 * n + i];
    if (t < 1e-3) return;
    float2 q = (float2(p) + 0.5 - K[1].xy) / K[0].zw;
    float3 dc;
    if (K[1].z > 0.5) {                    // equidistant fisheye: radius = angle
        float th = length(q);
        dc = float3(th > 1e-6 ? q / th * sin(th) : q, cos(th));
    } else {
        dc = normalize(float3(q, 1));
    }
    float3 d = normalize(K[2].xyz * dc.x + K[3].xyz * dc.y + K[4].xyz * dc.z);
    float3 back = K[6].z > 0.5 ? sky_at(sky, d, K[1].w, K) : K[7].rgb;
    if (K[6].w > 0.5) {
        // The shells, blurred by the lens: the pupil's shape gathered over the
        // blur circle at the shell's distance (one depth, so one convolution).
        float3 o = K[8].xyz;
        float dist;
        float4 c0 = shell_at(shellCol, shellDep, o, d, K, dist);
        float zm = max(dist * K[9].z, 0.01);
        float th = 0.5 * K[9].x * abs(1 / zm - 1 / max(K[9].y, 0.01));
        int np = int(K[9].w);
        float4 acc = 0; float wsum = 0;
        if (np > 0 && th * K[0].z > 1.0) {
            for (int j = 0; j < np; j++) {
                float4 ps = K[28 + j];
                float3 dj = normalize(d + th * (ps.x * K[2].xyz + ps.y * K[3].xyz));
                float dj_dist;
                acc += shell_at(shellCol, shellDep, o, dj, K, dj_dist) * ps.z;
                wsum += ps.z;
            }
            acc /= max(wsum, 1e-6);
        } else {
            acc = c0;
        }
        back = acc.rgb + (1 - acc.a) * back;
        // The focusing aids read depth: where the live render found little,
        // the shell's distance along the view axis.
        if (t > 0.5 && c0.a > 0.5) f[4 * n + i] = dist * dc.z;
    }
    float3 c = float3(f[3 * i], f[3 * i + 1], f[3 * i + 2]);
    float3 o3;
    if (K[6].y > 0.5) {                    // a place: renormalise the leak, the background where empty
        float keep = smoothstep(0.85, 0.97, t);
        o3 = mix(c / max(1 - t, 0.03), c + t * back, keep);
    } else {
        o3 = c + t * back;
    }
    f[3 * i] = o3.x; f[3 * i + 1] = o3.y; f[3 * i + 2] = o3.z;
    f[3 * n + i] = 0;
}

// One cube face of the distant shells, from a far-only render seen from the
// bake centre: colour (made opaque where a place leaks, as frame_rgb does) and
// distance from the centre (huge where nothing is).
//   B = (face size, face fx, place, -)
kernel void shell_store(device const float* f [[buffer(0)]], constant float4& B [[buffer(1)]],
                        texture2d_array<float, access::write> col [[texture(0)]],
                        texture2d_array<float, access::write> dep [[texture(1)]],
                        constant uint& face [[buffer(2)]], uint2 p [[thread_position_in_grid]]) {
    uint S = uint(B.x);
    if (p.x >= S || p.y >= S) return;
    uint n = S * S, i = p.y * S + p.x;
    float3 c = float3(f[3 * i], f[3 * i + 1], f[3 * i + 2]);
    float t = f[3 * n + i], med = f[4 * n + i];
    float a = 1 - t;
    if (B.z > 0.5) {
        float keep = smoothstep(0.85, 0.97, t);
        c = mix(c / max(1 - t, 0.03), c, keep);
        a = mix(1.0, 1 - t, keep);
    }
    float2 q = (float2(p) + 0.5 - float(S) * 0.5) / B.y;
    float dist = (a < 0.03 || !(med > 0) || med > 1e8) ? 1e6 : med * sqrt(1 + dot(q, q));
    col.write(float4(c, a), p, face);
    dep.write(float4(dist), p, face);
}


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

// What an effect filter adds to the exposure, from the whole of it (written
// before develop reads it). In exposed light, as develop adds it.
kernel void lens_fx(device const float4* acc [[buffer(0)]], constant float4* O [[buffer(1)]],
                    constant float4& D [[buffer(3)]], device float4* out [[buffer(5)]],
                    uint2 p [[thread_position_in_grid]]) {
    if (p.x >= uint(O[0].x) || p.y >= uint(O[0].y)) return;
    float3 k = D.rgb * exp2(O[5].w) * O[9].rgb;
    AccSource src = { acc, O, k };
    uint i = idx(p, O);
    float2 pc = float2(p) + 0.5;
    out[i] = float4(filter_fx(src, pc, acc[i].rgb * k, O, 20), 0);
}

// A circular fisheye's disc on film: black beyond it but for a soft glow of
// the light near its rim, scattered past it inside the lens (as in the finder).
float3 fisheye_rim(float3 lin, device const float4* acc, float2 pc, float2 c, float3 gain, constant float4* O) {
    float rr = length(pc - c), Rc = O[6].z;
    lin *= 1 - smoothstep(Rc - 2.0, Rc, rr);
    if (rr <= Rc - 2.0) return lin;
    // Gathered from an arc of the rim that widens with distance (light
    // scattered further comes from more of it), so it stays a haze, not rays.
    float out = max(rr - Rc, 0.0);
    float th = atan2(pc.y - c.y, pc.x - c.x), spread = 0.5 + 1.5 * out / Rc;
    th += (hash(uint2(pc), 41) - 0.5) * spread / 24;    // dithered: no pattern lines up
    float3 rim = 0;
    for (int k = 0; k < 24; k++) {
        float a = th + (float(k) / 23 - 0.5) * spread;
        float r = Rc * (0.94 - 0.05 * float(k % 3));
        rim += acc_at(acc, c + r * float2(cos(a), sin(a)), O);
    }
    rim = rim / 24 * gain;
    return lin + rim * (0.14 * exp(-out / (Rc * 0.035)) + 0.04 * exp(-out / (Rc * 0.18)));
}

// Develops the exposure into a print. D = per-channel 1 / pupil weight of the full aperture.
kernel void develop(device const float4* acc [[buffer(0)]], constant float4* O [[buffer(1)]],
                    constant float4* F [[buffer(2)]], constant float4& D [[buffer(3)]],
                    device uchar4* out [[buffer(4)]], device const float4* streaks [[buffer(5)]],
                    device const float4* fx [[buffer(6)]], uint2 p [[thread_position_in_grid]]) {
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
    lin *= D.rgb * expo * vig * O[9].rgb;                 // O[9]: the filter's colour
    if (D.w > 0) lin += streaks[idx(p, O)].rgb * expo;    // D.w: the lens streaks
    if (O[10].x > 0 || O[11].x > 0 || O[11].y > 0 || O[11].z > 0) lin = max(lin + fx[idx(p, O)].rgb * vig, 0.0);
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
    if (O[6].z > 0) lin = fisheye_rim(lin, acc, pc, c, D.rgb * expo, O);
    float3 col = film_look(lin, halo, pc, uint(O[5].z), O[0].y, F);
    out[idx(p, O)] = uchar4(uchar3(round(col * 255)), 255);
}

// The digital negative: the same exposure as `develop` reads (lens fall-off,
// lateral colour, the exposure), as linear light before any film, unclipped:
// three half floats per pixel, for a DNG. Values past 1 are highlights the
// print would burn out but the negative keeps.
kernel void negative(device const float4* acc [[buffer(0)]], constant float4* O [[buffer(1)]],
                     constant float4& D [[buffer(3)]], device half* out [[buffer(4)]],
                     device const float4* streaks [[buffer(5)]], device const float4* fx [[buffer(6)]],
                     uint2 p [[thread_position_in_grid]]) {
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
    lin = max(lin * D.rgb * expo * vig * O[9].rgb, 0.0);
    if (D.w > 0) lin += streaks[idx(p, O)].rgb * expo;
    if (O[10].x > 0 || O[11].x > 0 || O[11].y > 0 || O[11].z > 0) lin = max(lin + fx[idx(p, O)].rgb * vig, 0.0);
    if (O[6].z > 0) lin = fisheye_rim(lin, acc, pc, c, D.rgb * expo, O);
    uint i = idx(p, O) * 3;
    out[i] = half(min(lin.r, 60000.0)); out[i + 1] = half(min(lin.g, 60000.0)); out[i + 2] = half(min(lin.b, 60000.0));
}

// ---- lights ---------------------------------------------------------------

// Wireframes of the light heads: segments already projected to finder pixels
// (x, y, metres along the axis, alpha). Dimmed where the scene is in front.
struct LineOut { float4 pos [[position]]; float z; float a; float across; };

// The light heads' wireframes as light projected into the finder (as
// framelines are): each segment a soft band, W = (half width px, -, -, -),
// drawn twice, a fine core and a faint wide glow, added onto the scene.
vertex LineOut wire_vertex(uint vid [[vertex_id]], device const float4* v [[buffer(0)]],
                           constant float4* O [[buffer(1)]], constant float4& W [[buffer(2)]]) {
    uint seg = vid / 6, k = vid % 6;
    float4 p0 = v[2 * seg], p1 = v[2 * seg + 1];
    // Image pixels into the window (the finder's image is inset, O[7]).
    float2 a = O[7].xy + p0.xy * O[7].z, b = O[7].xy + p1.xy * O[7].z;
    float2 d = b - a;
    float len = max(length(d), 1e-3);
    d /= len;
    float2 n = float2(-d.y, d.x);
    // Two triangles: corners (end, side) = (0,-)(1,-)(0,+) (0,+)(1,-)(1,+).
    bool far = k == 1 || k == 4 || k == 5;
    float side = (k == 2 || k == 3 || k == 5) ? 1.0 : -1.0;
    float hw = W.x;
    float2 w = (far ? b + d * hw : a - d * hw) + n * side * hw;
    w = eyepiece_forward(w, O, EYEPIECE_K);
    LineOut o;
    o.pos = float4(w.x / O[0].x * 2 - 1, 1 - w.y / O[0].y * 2, 0, 1);   // the window is the frame's size
    float4 p = far ? p1 : p0;
    o.z = p.z;
    o.a = p.w;
    o.across = side;
    return o;
}

fragment float4 wire_fragment(LineOut in [[stage_in]], device const float* f [[buffer(0)]],
                              constant float4* O [[buffer(1)]], constant float4& colour [[buffer(2)]]) {
    // Where the eye sees this, in image pixels: the lines live on the screen,
    // so they stop at the window's rounded edge as the eyepiece shows it.
    float2 halfSize = O[0].xy * 0.5;
    float2 pe = (eyepiece(in.pos.xy, O, EYEPIECE_K) - O[7].xy) / O[7].z;
    float2 dq = abs(pe - halfSize) - (halfSize - O[7].w);
    float edge = length(max(dq, 0.0)) + min(max(dq.x, dq.y), 0.0) - O[7].w;   // < 0 inside
    float inside = 1 - smoothstep(-2.0, 0.0, edge);
    if (inside <= 0) discard_fragment();
    float zs = frame_z(f, clamp_px(int2(pe), O), O);
    float behind = in.z > zs * 1.01 ? 0.3 : 1.0;
    // Soft across the band, brightest along its middle.
    float x = abs(in.across);
    float profile = exp(-x * x * 3.2) * (1 - smoothstep(0.85, 1.0, x));
    float a = in.a * behind * profile * colour.a * inside;
    return float4(colour.rgb * a, a);
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
                    texture2d_array<float> patterns [[texture(0)]],
                    uint i [[thread_position_in_grid]]) {
    constexpr sampler pat(filter::linear, mip_filter::linear, address::clamp_to_edge);
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
        constant float4* L = LT + 6 * l;
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
        // Modifiers, in the light's frame: barn doors and flags cut the beam
        // (L[5]: limits left, right, bottom, top, as tan of the angle off axis,
        // edges softened by the lamp's size); a gobo or cookie is a mask
        // (L[4]: layer, the half-field it covers, blur, value beyond it).
        float2 xy = float2(dot(w, right), dot(w, upl)) / max(ct, 1e-3);
        float soft = 0.025;
        float cut = smoothstep(L[5].x - soft, L[5].x + soft, xy.x) * (1 - smoothstep(L[5].y - soft, L[5].y + soft, xy.x))
                  * smoothstep(L[5].z - soft, L[5].z + soft, xy.y) * (1 - smoothstep(L[5].w - soft, L[5].w + soft, xy.y));
        e3 *= cut;
        if (L[4].x >= 0) {
            float2 uv = 0.5 + 0.5 * float2(xy.x, -xy.y) / L[4].y;
            float m = patterns.sample(pat, uv, uint(L[4].x), level(L[4].z)).r;
            float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
            e3 *= mix(L[4].w, m, inside);
        }
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
