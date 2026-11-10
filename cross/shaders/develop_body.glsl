// develop and develop16 (Shaders.swift): the exposure into a print; the shared part.
// develop (Shaders.swift): the exposure into a print. D = per-channel 1 / pupil
// weight of the full aperture (w = 1: the lens streaks).
layout(local_size_x = 16, local_size_y = 16) in;
layout(std430, set = 0, binding = 0) readonly buffer Acc { vec4 acc[]; };
layout(std430, set = 0, binding = 1) readonly buffer Streaks { vec4 streaks[]; };
layout(std430, set = 0, binding = 2) readonly buffer Fx { vec4 fx[]; };
layout(std140, set = 2, binding = 0) uniform Optics { vec4 O[12]; };
layout(std140, set = 2, binding = 1) uniform Film { vec4 F[8]; };
layout(std140, set = 2, binding = 2) uniform Dev { vec4 D; };
layout(std140, set = 2, binding = 3) uniform Flare { vec4 FL[38]; };
#include "vc.glsl"
#include "flare.glsl"

vec3 acc_at(vec2 p) {
    vec2 t = p - 0.5;
    ivec2 i0 = ivec2(floor(t));
    vec2 w = t - floor(t);
    vec3 a = acc[idx(clamp_px(i0))].rgb, b = acc[idx(clamp_px(i0 + ivec2(1, 0)))].rgb;
    vec3 c = acc[idx(clamp_px(i0 + ivec2(0, 1)))].rgb, d = acc[idx(clamp_px(i0 + ivec2(1, 1)))].rgb;
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// A circular fisheye's disc on film: black beyond it but for a soft glow of
// the light near its rim, scattered past it inside the lens (as in the finder).
vec3 fisheye_rim(vec3 lin, vec2 pc, vec2 c, vec3 gain) {
    float rr = length(pc - c), Rc = O[6].z;
    lin *= 1.0 - smoothstep(Rc - 2.0, Rc, rr);
    if (rr <= Rc - 2.0) return lin;
    // Gathered from an arc of the rim that widens with distance (light
    // scattered further comes from more of it), so it stays a haze, not rays.
    float outr = max(rr - Rc, 0.0);
    float th = atan(pc.y - c.y, pc.x - c.x), spread = 0.5 + 1.5 * outr / Rc;
    th += (hash(uvec2(pc), 41u) - 0.5) * spread / 24.0;    // dithered: no pattern lines up
    vec3 rim = vec3(0.0);
    for (int k = 0; k < 24; k++) {
        float a = th + (float(k) / 23.0 - 0.5) * spread;
        float r = Rc * (0.94 - 0.05 * float(k % 3));
        rim += acc_at(c + r * vec2(cos(a), sin(a)));
    }
    rim = rim / 24.0 * gain;
    return lin + rim * (0.14 * exp(-outr / (Rc * 0.035)) + 0.04 * exp(-outr / (Rc * 0.18)));
}

vec3 develop_px(uvec2 p) {
    uint W = uint(O[0].x), H = uint(O[0].y);
    float expo = exp2(O[5].w);
    vec2 pc = vec2(p) + 0.5, c = O[1].xy;
    vec2 q = field(pc);
    float vig = 1.0 - O[3].w * pow(clamp(O[2].z / O[2].y, 0.0, 1.0), 1.5) * dot(q, q);
    // Lateral colour: each channel from its own magnification. Light lost to
    // barrel clipping darkens the corners on its own (no renormalising).
    float k = O[6].x;
    vec3 lin;
    lin.r = acc_at(c + (pc - c) * (1.0 - k)).r;
    lin.g = acc_at(pc).g;
    lin.b = acc_at(c + (pc - c) * (1.0 + k)).b;
    lin *= D.rgb * expo * vig * O[9].rgb;                 // O[9]: the filter's colour
    if (D.w > 0.0) lin += streaks[idx(p)].rgb * expo;    // D.w: the lens streaks
    if (O[10].x > 0.0 || O[11].x > 0.0 || O[11].y > 0.0 || O[11].z > 0.0) lin = max(lin + fx[idx(p)].rgb * vig, 0.0);
    // Lens flare from the lights shining into the lens, through the filter.
    lin += lens_flare((vec2(p) + 0.5) / vec2(W, H), vec2(W, H)) * expo * O[9].rgb;
    // Halation: light past the film base bouncing back, around bright highlights.
    vec3 halo = vec3(0.0);
    if (F[6].x > 0.0) {
        float rad = O[0].y * 0.012;
        for (uint j = 0u; j < 32u; j++) {
            vec2 o = vogel(j, 32u) * rad;
            uvec2 pj = clamp_px(ivec2(pc + o));
            halo += max(acc[idx(pj)].rgb * D.rgb * expo - 0.9, 0.0);
        }
        halo /= 32.0;
    }
    if (O[6].z > 0.0) lin = fisheye_rim(lin, pc, c, D.rgb * expo);
    return film_look(lin, halo, pc, uint(O[5].z), O[0].y, F);
}

