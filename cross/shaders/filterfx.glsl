// Lens filters' effects (filter_fx in Shaders.swift, line for line).
//   O[9] = (the filter's transmission rgb, -), O[10] = (star points, star
//   strength, 1 = diffraction grating, angle), O[11] = (glow, soften, veil,
//   highlight threshold). A filter is in front of the lens: the finder, the
//   meter and the film all see through it.
// The kernel defines `vec3 fx_src(vec2 q)` (the light at q, already through
// the filter: the finder's frame or the photo's exposure) and includes
// vc.glsl and spectra.glsl first. (Metal templates the source; GLSL has none.)
vec3 fx_src(vec2 q);

// Light brighter than `thr`, keeping its colour (a cut per channel would tint it).
vec3 above(vec3 v, float thr) {
    float lum = dot(v, vec3(0.2126, 0.7152, 0.0722));
    return v * (max(lum - thr, 0.0) / max(lum, 1e-4));
}

// A grating's colour along its spike (u: distance over the spike's length) for a scene
// highlight of colour v: the smooth spectrum behind v, each order spreading it further out.
vec3 grating_scene(float u, vec3 v) {
    float x = clamp(u, 0.0, 1.0) * 64.0 - 0.5;
    int i = clamp(int(floor(x)), 0, 62);
    float t = clamp(x - float(i), 0.0, 1.0);
    vec3 c = vec3(dot(mix(GRATING_M[i][0], GRATING_M[i + 1][0], t), v),
                  dot(mix(GRATING_M[i][1], GRATING_M[i + 1][1], t), v),
                  dot(mix(GRATING_M[i][2], GRATING_M[i + 1][2], t), v));
    return max(c, 0.0);
}

// The light an effect filter adds at p (or takes, for soften and veil) to
// `base`, the light already there. `steps`: samples along each star ray.
vec3 filter_fx(vec2 p, vec3 base, int steps) {
    vec3 add = vec3(0.0);
    float thr = O[11].w, H = O[0].y;
    int points = int(O[10].x);
    // Each pixel's samples start at its own offset, so their spacing never shows.
    float jitter = hash(uvec2(p), 57u);
    if (points > 0) {
        bool spectral = O[10].z > 0.5;
        float L = H * (spectral ? 0.20 : 0.15);
        // Rays both ways along each line: a 4-point star is two lines.
        int lines = max(1, points / 2);
        int n = spectral ? steps * 2 : steps;
        vec3 star = vec3(0.0);
        for (int j = 0; j < lines; j++) {
            float a = O[10].w + float(j) * M_PI_F / float(lines);
            vec2 dir = vec2(cos(a), sin(a));
            for (int s = 0; s < n; s++) {
                float t = (float(s) + jitter) / float(n);
                float d = L * t * t;
                float w = exp(-3.2 * t) * (2.0 * t / float(n)) * 3.0;
                for (int side = -1; side <= 1; side += 2) {
                    vec3 v = above(fx_src(p - dir * d * float(side)), thr);
                    if (max(v.r, max(v.g, v.b)) <= 0.0) continue;       // not bright enough to spike
                    if (spectral) {
                        // A grating sends each order's spectrum further out, violet nearest.
                        float tc = (float(s) + 0.5) / float(n);
                        vec3 c = mix(v * 1.3, grating_scene(tc * tc, v), smoothstep(0.02, 0.10, tc));
                        star += c * w;
                    } else {
                        star += v * w;
                    }
                }
            }
        }
        add += star * O[10].y;
    }
    if (O[11].x > 0.0 || O[11].y > 0.0 || O[11].z > 0.0) {
        // Discs of samples, spread evenly by area and turned at random per pixel.
        float rot = jitter * 6.2831853;
        // Soft-focus filters scatter from everything bright, not only clipped highlights.
        float gthr = thr * 0.45;
        vec3 near = vec3(0.0), far = vec3(0.0), nearHi = vec3(0.0), farHi = vec3(0.0);
        // Samples crowd toward the middle (radius ~ t^2): a halo bright near the light.
        for (uint k = 0u; k < 20u; k++) {
            float t = (float(k) + 0.5) / 20.0, a = float(k) * 2.39996323 + rot;
            vec3 v = fx_src(p + vec2(cos(a), sin(a)) * t * t * H * 0.02);
            near += v; nearHi += above(v, gthr);
        }
        for (uint k = 0u; k < 28u; k++) {
            float t = (float(k) + 0.5) / 28.0, a = float(k) * 2.39996323 + rot;
            vec3 v = fx_src(p + vec2(cos(a), sin(a)) * t * t * H * 0.09);
            far += v; farHi += above(v, gthr);
        }
        near /= 20.0; far /= 28.0; nearHi /= 20.0; farHi /= 28.0;
        add += O[11].x * (nearHi * 1.2 + farHi * 1.6);
        add += O[11].y * (near - base);
        add += O[11].z * ((far - base) * 0.6 + far * 0.12);
    }
    return add;
}
