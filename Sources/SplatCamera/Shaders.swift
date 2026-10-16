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
//   O[6] = (lateral colour at the corner, -, -, -)
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
    float2 half_size = O[0].xy * 0.5;
    return (p - half_size) / length(half_size);
}

// Lateral colour: red and blue imaged at slightly different magnifications,
// so their fringes grow toward the corners. Each channel read at its own place.
float3 frame_lin_ca(device const float* f, float2 p, constant float4* O) {
    float2 c = O[0].xy * 0.5;
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

// The focusing screen, always: the lens's image (its depth of field, light
// fall-off and colour fringes) on fine-ground glass with a fresnel, a
// split-prism disc (halves shift apart with defocus) and a microprism collar.
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
        col = frame_lin_ca(f, p + float2(shift, 0), O);
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
        col = frame_lin_ca(f, p + shift * float2(cos(a), sin(a)), O);
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
    return float4(to_srgb(col), 1);
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

// Adds one sub-pupil's render to the exposure. L[0] = (lens point, weight,
// reset), L[1] = (colour mask: which of r g b this sub-pupil carries, -).
kernel void accumulate(device const float* f [[buffer(0)]], constant float4* O [[buffer(1)]],
                       device float4* acc [[buffer(2)]], constant float4* L [[buffer(3)]],
                       uint2 p [[thread_position_in_grid]]) {
    if (p.x >= uint(O[0].x) || p.y >= uint(O[0].y)) return;
    uint i = idx(p, O);
    float w = pupil(L[0].xy, field(float2(p) + 0.5, O), O) * L[0].z;
    float4 prev = L[0].w > 0.5 ? float4(0) : acc[i];
    acc[i] = prev + float4(to_lin(frame_rgb(f, p, O)) * L[1].rgb * w, w);
}

float3 acc_at(device const float4* acc, float2 p, constant float4* O) {
    float2 t = p - 0.5;
    int2 i0 = int2(floor(t));
    float2 w = t - floor(t);
    float3 a = acc[idx(clamp_px(i0, O), O)].rgb, b = acc[idx(clamp_px(i0 + int2(1, 0), O), O)].rgb;
    float3 c = acc[idx(clamp_px(i0 + int2(0, 1), O), O)].rgb, d = acc[idx(clamp_px(i0 + int2(1, 1), O), O)].rgb;
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// Develops the exposure into a print. D = per-channel 1 / pupil weight of the full aperture.
kernel void develop(device const float4* acc [[buffer(0)]], constant float4* O [[buffer(1)]],
                    constant float4* F [[buffer(2)]], constant float4& D [[buffer(3)]],
                    device uchar4* out [[buffer(4)]], uint2 p [[thread_position_in_grid]]) {
    uint W = uint(O[0].x), H = uint(O[0].y);
    if (p.x >= W || p.y >= H) return;
    float expo = exp2(O[5].w);
    float2 pc = float2(p) + 0.5, c = O[0].xy * 0.5;
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
    float3 col = film_look(lin, halo, pc, uint(O[5].z), O[0].y, F);
    out[idx(p, O)] = uchar4(uchar3(round(col * 255)), 255);
}

// ---- lights ---------------------------------------------------------------

// Wireframes of the light heads: segments already projected to finder pixels
// (x, y, metres along the axis, alpha). Dimmed where the scene is in front.
struct LineOut { float4 pos [[position]]; float z; float a; };

vertex LineOut wire_vertex(uint vid [[vertex_id]], device const float4* v [[buffer(0)]],
                           constant float4* O [[buffer(1)]]) {
    float4 p = v[vid];
    LineOut o;
    o.pos = float4(p.x / O[0].x * 2 - 1, 1 - p.y / O[0].y * 2, 0, 1);
    o.z = p.z;
    o.a = p.w;
    return o;
}

fragment float4 wire_fragment(LineOut in [[stage_in]], device const float* f [[buffer(0)]],
                              constant float4* O [[buffer(1)]], constant float4& colour [[buffer(2)]]) {
    float zs = frame_z(f, clamp_px(int2(in.pos.xy), O), O);
    float a = in.a * (in.z > zs * 1.01 ? 0.3 : 1.0);
    return float4(colour.rgb, colour.a * a);
}

// Relighting (gs_render's model, made for scans lit from the camera): each
// light reads the scan's broad colour (SH DC + band 1) in its own direction
// for the diffuse, bands 2-3 at the half vector for the shine; the house
// lights give back a share of the scan as captured. Writes new SH DC colours
// straight into the renderer's buffer (render with the higher bands off).
//   G[0] = (camera position, house lights)   G[1] = (lights, N, K higher coeffs, shine colour)
//   per light, 4 float4s (PlacedLight.packed): (pos, softlight), (aim, peak cd / E_ref),
//   (colour, shine), (cos inner, cos outer, metres per unit, -)
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

kernel void relight(device const float* means [[buffer(0)]], device const float* dc0 [[buffer(1)]],
                    device const float* sh0 [[buffer(2)]], device float* out_dc [[buffer(3)]],
                    constant float4* G [[buffer(4)]], constant float4* LT [[buffer(5)]],
                    uint i [[thread_position_in_grid]]) {
    uint N = uint(G[1].y), K = uint(G[1].z), nl = uint(G[1].x);
    if (i >= N) return;
    float3 mean = float3(means[3 * i], means[3 * i + 1], means[3 * i + 2]);
    float3 base = 0.5 + C0 * float3(dc0[3 * i], dc0[3 * i + 1], dc0[3 * i + 2]);
    device const float* sh = sh0 + i * K * 3;
    float ambient = G[0].w;
    float3 v = normalize(mean - G[0].xyz);           // camera -> splat, as 3DGS reads SH
    float3 lin = srgb_to_lin3(base) * ambient;
    float3 shine = 0;
    bool has_sh = K >= 8;
    if (has_sh && ambient > 0) shine += pow(ambient, 1 / 2.2) * sh_sum(v, sh, K, 0, K);
    const float3 lum = float3(0.2126, 0.7152, 0.0722);
    for (uint l = 0; l < nl; l++) {
        constant float4* L = LT + 4 * l;
        float3 d = L[0].xyz - mean;
        float dist_m = max(length(d) * L[3].z, 1e-3);
        float3 ldir = d / max(length(d), 1e-9);
        // Beam: full inside the inner cone, soft edge out to the outer.
        float ca = dot(-ldir, L[1].xyz);
        float profile = saturate((ca - L[3].y) / max(L[3].x - L[3].y, 1e-4));
        profile = profile * profile * (3 - 2 * profile);
        float e = L[1].w * profile / (dist_m * dist_m);
        if (e <= 0) continue;
        float3 col = L[2].rgb;
        // Diffuse: the broad colour seen from the light's side.
        float3 diff = max(base + (K >= 3 ? sh_sum(-ldir, sh, K, 0, 3) : 0.0), 0.0);
        lin += srgb_to_lin3(diff) * e * col;
        if (has_sh) {
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
