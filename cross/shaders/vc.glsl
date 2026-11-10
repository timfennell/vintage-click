// Vintage Click's GPU kernels: the shared functions. A line-for-line translation
// of the Metal in Sources/SplatCamera/Shaders.swift (Metal -> GLSL: float3 ->
// vec3, saturate -> clamp, select -> mix with a bvec, fmod kept as the same
// floored double-mod), so Windows prints are the Mac's. Keep the two in step.
//
// A kernel declares its optics `O` (as Shaders.swift's header documents them)
// before including this file. Frames are Spirula's: W*H rgb (premultiplied
// display colour), then W*H transmittance, then W*H median ray depth.

const float M_PI_F = 3.14159265358979;
const float FILM_WIDTH_M = 0.036;

// ---- frames ----------------------------------------------------------------

float srgb_to_lin(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
float lin_to_srgb(float c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055; }
// No upper clamp: relit highlights may run past display white and still print.
vec3 to_lin(vec3 c) { c = max(c, 0.0); return vec3(srgb_to_lin(c.r), srgb_to_lin(c.g), srgb_to_lin(c.b)); }
vec3 to_srgb(vec3 c) { c = clamp(c, 0.0, 1.0); return vec3(lin_to_srgb(c.r), lin_to_srgb(c.g), lin_to_srgb(c.b)); }

uvec2 clamp_px(ivec2 p) { return uvec2(clamp(p, ivec2(0), ivec2(O[0].xy) - 1)); }
uint idx(uvec2 p) { return p.y * uint(O[0].x) + p.x; }

// ---- the lens --------------------------------------------------------------

// Signed circle of confusion, in pixels of diameter: + behind focus, - in front.
float coc_px(float z) {
    float f = O[2].x, N = O[2].y, s = max(O[1].w, f * 1.01);
    float c = (f / N) * f * (z - s) / (z * (s - f));
    return c / FILM_WIDTH_M * O[0].x;
}

// Where in the field a pixel is: from the optical axis (off centre on a
// shifted lens), length 1 at a corner's distance.
vec2 field(vec2 p) { return (p - O[1].xy) / length(O[0].xy * 0.5); }

// Metal's fmod (truncated) for the blade angle.
float fmod_t(float a, float b) { return a - b * trunc(a / b); }

// Pupil weight of lens point l (unit = the current aperture's radius) seen from
// field position q: 0 outside the blades or clipped by the barrel, else the
// soap-bubble rim weighting. Stopping down shrinks the aperture inside the fixed
// barrel, so cat's eyes round up at small apertures as on a real lens.
float pupil(vec2 l, vec2 q, float cell) {
    float r = length(l);
    float blades = O[2].w;
    if (blades >= 3.0) {
        float seg = 2.0 * M_PI_F / blades;
        float th = atan(l.y, l.x) - O[3].z;
        float a = fmod_t(fmod_t(th, seg) + seg, seg) - seg / 2.0;
        if (r * cos(a) > cos(M_PI_F / blades)) return 0.0;
    } else if (r > 1.0) {
        return 0.0;
    }
    if (r < O[6].w) return 0.0;        // a mirror lens's secondary mirror
    float open = O[2].z / O[2].y;      // current radius in wide-open radii
    float soap = O[3].y;
    float rim = (1.0 + soap * pow(r, 6.0)) / (1.0 + soap * 0.25);
    l.x *= O[8].x > 0.0 ? O[8].x : 1.0;   // an oval stop, narrower across
    // Sub-pupils (cell > 0) are cut by the barrel in the render itself, splat by splat.
    if (cell > 0.0) return rim;
    return length(l * open + O[3].x * q) > 1.0 ? 0.0 : rim;
}

// Vogel sunflower point k of n over the unit disc.
vec2 vogel(uint k, uint n) {
    float r = sqrt((float(k) + 0.5) / float(n));
    float th = float(k) * 2.39996323;
    return r * vec2(cos(th), sin(th));
}

// ---- film ------------------------------------------------------------------

float hash(uvec2 p, uint s) {
    uint h = p.x * 0x8da6b343u ^ p.y * 0xd8163841u ^ s * 0xcb1ab31fu;
    h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
    return float(h & 0xffffffu) / 16777215.0;
}
float value_noise(vec2 p, uint s) {
    vec2 i = floor(p), t = fract(p);
    t = t * t * (3.0 - 2.0 * t);
    uvec2 a = uvec2(ivec2(i) + 65536);
    float v00 = hash(a, s), v10 = hash(a + uvec2(1, 0), s);
    float v01 = hash(a + uvec2(0, 1), s), v11 = hash(a + uvec2(1, 1), s);
    return mix(mix(v00, v10, t.x), mix(v01, v11, t.x), t.y);
}

// Scene-linear exposure (already scaled by the exposure) to a print.
// F: FilmStock.packed (Shaders.swift's header).
vec3 film_look(vec3 lin, vec3 halo, vec2 px, uint seed, float lines, vec4 F[8]) {
    lin += F[6].x * F[6].yzw * halo;
    if (F[7].w > 0.5) {
        // Colour infrared. A scan has no infrared, so estimate it: leaves (greener
        // than both red and blue) glow, blue sky is dark, neutrals stay as they are.
        float lum = dot(lin, vec3(0.2126, 0.7152, 0.0722));
        float leaf = clamp(3.0 * (lin.g - max(lin.r, lin.b)) / max(lin.g, 1e-4), 0.0, 1.0);
        float sky = clamp((lin.b - max(lin.r, lin.g)) / max(lin.b, 1e-4), 0.0, 1.0);
        float reds = clamp((lin.r - max(lin.g, lin.b)) / max(lin.r, 1e-4), 0.0, 1.0);
        float ir = lum * (1.0 + 3.0 * leaf) * (1.0 - 0.75 * sky) + 0.9 * reds * lin.r;
        vec3 c = lin - lum;
        float strength = smoothstep(0.06, 0.3, length(c) / max(lum, 1e-4));
        vec3 swapped = vec3(ir - lum, c.r * strength, c.g * strength - 0.45 * leaf * lin.g + 0.35 * sky * lin.b);
        lin = max(lum + swapped, 0.0) * (1.0 - 0.3 * sky);
    }
    vec3 c = vec3(dot(F[0].xyz, lin), dot(F[1].xyz, lin), dot(F[2].xyz, lin)) * F[3].xyz;
    bool bw = F[3].w > 0.5;
    if (bw) c = vec3(dot(F[4].xyz, c));
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    c = max(luma + (c - luma) * F[4].w, 0.0);
    // Characteristic curve in stops about mid grey: toe below, shoulder above.
    vec3 x = log2(max(c, 1e-6) / 0.18);
    float k = F[5].x * 0.34;
    vec3 xs = mix(x * F[7].z, x * F[5].z, greaterThan(x, vec3(0.0)));
    vec3 y = 0.5 + 0.5 * tanh(k * xs);
    y = F[5].y + (1.0 - F[5].y) * y;
    // Grain: strongest in the midtones, finer on slower stocks.
    float size = F[7].y * lines / 1080.0;
    vec2 g = px / max(size, 0.5);
    float amp = F[5].w * 0.16;
    vec3 n;
    float mono = value_noise(g, seed) + value_noise(g * 2.1 + 17.0, seed + 1u) * 0.5 - 0.75;
    if (bw) {
        n = vec3(mono);
    } else {
        vec3 chroma = vec3(value_noise(g + 31.0, seed + 2u), value_noise(g + 57.0, seed + 3u),
                           value_noise(g + 83.0, seed + 4u)) - 0.5;
        n = mono + 0.35 * chroma;
    }
    y += amp * n * 4.0 * y * (1.0 - y);
    return clamp(y, 0.0, 1.0);
}
