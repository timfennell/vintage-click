// Reading a Spirula frame `f` (declared by the kernel, with its optics `O`):
// frame_rgb ... prism_sample in Shaders.swift, line for line.

// Display colour over the background.
vec3 frame_rgb(uvec2 p) {
    uint n = uint(O[0].x * O[0].y), i = idx(p);
    vec3 c = vec3(f[3 * i], f[3 * i + 1], f[3 * i + 2]);
    float t = f[3 * n + i];
    // In a place (O[4].w = 2) the scan surrounds you: what shows through is
    // the blend's leak, not a background. Blurred splats over each other
    // never add back up to solid (a single layer leaks about a third), so
    // scale back up to full cover; only an all-but-empty pixel shows the dark.
    if (O[4].w > 1.5) {
        float keep = smoothstep(0.85, 0.97, t);
        return mix(c / max(1.0 - t, 0.03), c + t * O[4].rgb, keep);
    }
    return c + t * O[4].rgb;
}

// Distance along the view axis in metres (far away where nothing was hit).
float frame_z(uvec2 p) {
    uint n = uint(O[0].x * O[0].y), i = idx(p);
    float T = f[3 * n + i], d = f[4 * n + i];
    if (T > 0.97 || !(d > 0.0)) return 1e5;
    vec2 uv = (vec2(p) + 0.5 - O[1].xy) / O[0].zw;
    return d / sqrt(1.0 + dot(uv, uv)) * O[1].z;
}

// Lateral colour: red and blue imaged at slightly different magnifications,
// so their fringes grow toward the corners. Each channel read at its own place.
vec3 frame_lin_ca(vec2 p) {
    vec2 c = O[1].xy;
    float k = O[6].x;
    vec3 outc;
    outc.r = to_lin(frame_rgb(clamp_px(ivec2(c + (p - c) * (1.0 - k))))).r;
    outc.g = to_lin(frame_rgb(clamp_px(ivec2(p)))).g;
    outc.b = to_lin(frame_rgb(clamp_px(ivec2(c + (p - c) * (1.0 + k))))).b;
    return outc;
}

// The surface a prism looks through to near p: the nearest depth in a small
// neighbourhood, so a soft (part-transparent) edge moves with its subject
// instead of each edge pixel taking the background's shift.
float prism_depth(vec2 p, float reach) {
    float z = 1e5;
    for (int dy = -2; dy <= 2; dy++)
        for (int dx = -2; dx <= 2; dx++)
            z = min(z, frame_z(clamp_px(ivec2(p + vec2(dx, dy) * reach))));
    return z;
}

// The lens's image at a fractional position (bilinear, with lateral colour).
vec3 frame_lin_smooth(vec2 p) {
    vec2 t = p - 0.5;
    vec2 i = floor(t), w = t - i;
    vec3 a = frame_lin_ca(i + 0.5), b = frame_lin_ca(i + vec2(1.5, 0.5));
    vec3 c = frame_lin_ca(i + vec2(0.5, 1.5)), d = frame_lin_ca(i + 1.5);
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// What a prism shows at p: the image displaced by `shift`, the defocus of the
// surface it looks through to (depth z). Light through a prism beside an edge
// comes from what is behind it there, so a sample landing on something much
// nearer (a focused antenna, for a background pixel) is not its light: it
// keeps its own place instead.
vec3 prism_sample(vec2 p, vec2 shift, float z) {
    vec2 q = p + shift;
    float zq = frame_z(clamp_px(ivec2(q)));
    // Eased, not switched: a hard either/or carved sharp edges into soft blur.
    float keep = smoothstep(z * 0.7, z * 0.9, zq);
    return mix(frame_lin_smooth(p), frame_lin_smooth(q), keep);
}
