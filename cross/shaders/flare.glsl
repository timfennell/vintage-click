// Lens flare (lens_flare and flare_faces in Shaders.swift, line for line),
// from each light that shines into the lens (Flare.swift): ghosts (the
// aperture's shape, reflected between elements, strung along the line from
// the light through the optical axis; round wide open, the blades' polygon
// stopped down; tinted by the coating), veiling glare, the starburst of
// diffraction at the blades, and a faint ring. In frame light, before
// exposure; `uv` 0...1 over the frame, `size` its pixels.
//   FL[0] = (lights, blades, blade rotation, openness)  FL[1] = (single-coated, seed, obstruction, squeeze)
//   FL[2] = (axis uv, dispersion, field softness)  FL[3] = the filter: (glass on the lens, star points, star strength, spectral)
//   then per light (uv, face radius / diagonal, visible), (flare rgb, own blur / diagonal),
//   (face half-extent vectors px), (face brightness rgb, 1 flare on + 2 round face + 4 gel)
//   FL[36 + li / 4][li % 4]: the lights' distances.
// The kernel declares FL[38] and includes vc.glsl first.
#include "spectra.glsl"

// The same for a lamp through gel g whose light has colour I: its own spectrum (3200 K
// tungsten times the gel's curve) spread out. The hue comes from the spectrum, the
// brightness from the light.
vec3 grating_lamp(float u, int g, vec3 I) {
    vec3 c = vec3(0.0);
    for (int m = 1; m <= 4; m++) {
        float span = 730.0 / (float(m) * GRATING_U1);
        float lam = u * span;
        if (lam < 380.0 || lam > 730.0) continue;
        float f = (lam - 380.0) / 10.0;
        int i = min(int(f), SPEC_N - 2);
        float t = f - float(i);
        vec3 d = mix(SPEC_TUNGSTEN[i] * SPEC_GEL[g][i], SPEC_TUNGSTEN[i + 1] * SPEC_GEL[g][i + 1], t);
        c += GRATING_ETA[m - 1] * d * span / 10.0;
    }
    vec3 luma = vec3(0.2126, 0.7152, 0.0722);
    return max(c, 0.0) * (GRATING_K * dot(I, luma) / max(dot(SPEC_GEL_RGB[g], luma), 1e-6));
}
// Dispersion's sign and size for a band: + toward the blue, - toward the red.
float band_bend(int b) { return (550.0 - SPEC_BAND_NM[b]) / 90.0; }

float flare_hash(float s, float k) { return fract(sin(s * 12.9898 + k * 78.233) * 43758.5453); }
// Inside the aperture's shape (radius 1): 1 inside, soft edge; blades, or round.
float aperture_mask(vec2 d, float soft) {
    float r = length(d);
    int nb = int(FL[0].y);
    float open = FL[0].w;
    float edge = 1.0;
    if (nb >= 3 && open < 0.98) {
        float seg = 2.0 * M_PI_F / float(nb);
        float th = atan(d.y, d.x) - FL[0].z;
        float a = fmod_t(fmod_t(th, seg) + seg, seg) - seg / 2.0;
        // Wide open the blades are drawn back (round); stopped down, a polygon.
        float poly = r * cos(a) / cos(M_PI_F / float(nb));
        edge = mix(poly, r, smoothstep(0.75, 0.98, open));
    } else {
        edge = r;
    }
    float m = 1.0 - smoothstep(1.0 - soft, 1.0 + soft, edge);
    if (FL[1].z > 0.0) m *= smoothstep(FL[1].z - soft, FL[1].z + soft, r);      // a mirror lens: a ring
    return m;
}
// The glass's own flaws as a ghost shows them: dust and seed bubbles cast small
// shadows, cleaning marks catch the light as fine arcs, scratches as hairlines,
// fungus as a dark lace; the polish is never quite even.
bool fungus(float seed, float dust) { return dust >= 2.0 && flare_hash(seed, 1300.0) < 0.55; }
float glass_flaws(vec2 d, float seed, float k, float dust, bool bubbles) {
    if (dust <= 0.0 && !bubbles) return 1.0;
    float m = 1.0;
    int specks = int(dust * 4.0);
    for (int i = 0; i < 12; i++) {
        if (i >= specks) break;
        float h = k * 37.0 + float(i) * 3.0 + 200.0;
        float a = flare_hash(seed, h) * 6.2831853, r = sqrt(flare_hash(seed, h + 1.0)) * 0.92;
        float sz = mix(0.022, 0.07, flare_hash(seed, h + 2.0));
        float q = length(d - r * vec2(cos(a), sin(a))) / sz;
        m *= 1.0 - 0.55 * (1.0 - smoothstep(0.7, 1.0, q)) + 0.18 * exp(-pow((q - 1.15) / 0.18, 2.0));
    }
    if (bubbles) {
        for (int i = 0; i < 3; i++) {
            float h = k * 37.0 + float(i) * 3.0 + 500.0;
            float a = flare_hash(seed, h) * 6.2831853, r = sqrt(flare_hash(seed, h + 1.0)) * 0.85;
            float sz = mix(0.035, 0.10, flare_hash(seed, h + 2.0));
            float q = length(d - r * vec2(cos(a), sin(a))) / sz;
            m *= 1.0 - 0.35 * (1.0 - smoothstep(0.6, 0.95, q)) + 0.45 * exp(-pow((q - 1.0) / 0.12, 2.0));
        }
    }
    float marks = 0.0;
    for (int j = 0; j < 4; j++) {
        float h = k * 37.0 + float(j) * 4.0 + 800.0;
        float a = flare_hash(seed, h) * 6.2831853;
        vec2 c = 1.4 * vec2(cos(a), sin(a));                 // swirls round a centre off the glass
        float R = length(c) + mix(-0.8, 0.6, flare_hash(seed, h + 1.0));
        float arc = abs(length(d - c) - R);
        float along = atan(d.y - c.y, d.x - c.x) - (a + M_PI_F);
        float span = 0.25 + 0.5 * flare_hash(seed, h + 2.0);
        marks += exp(-pow(arc / 0.006, 2.0)) * (1.0 - smoothstep(span * 0.7, span, abs(fmod_t(along + 3.0 * M_PI_F, 2.0 * M_PI_F) - M_PI_F)));
    }
    // Fine scratches in the coating: straight hairlines that catch the light.
    float scratches = 0.0;
    int ns = int(dust * 2.0);
    for (int j = 0; j < 6; j++) {
        if (j >= ns) break;
        float h = k * 37.0 + float(j) * 5.0 + 1100.0;
        float a = flare_hash(seed, h) * M_PI_F;
        vec2 dir = vec2(cos(a), sin(a)), nrm = vec2(-dir.y, dir.x);
        vec2 o = (vec2(flare_hash(seed, h + 1.0), flare_hash(seed, h + 2.0)) - 0.5) * 1.6;
        float along = dot(d - o, dir), off = dot(d - o, nrm);
        float len = 0.15 + 0.6 * flare_hash(seed, h + 3.0);
        scratches += exp(-pow(off / 0.004, 2.0)) * (1.0 - smoothstep(len * 0.8, len, abs(along)));
    }
    // Fungus (some of the old lenses): a colony's branching threads.
    float lace = 0.0;
    if (fungus(seed, dust)) {
        for (int c = 0; c < 2; c++) {
            float h = k * 37.0 + float(c) * 9.0 + 1400.0;
            float a = flare_hash(seed, h) * 6.2831853, r = sqrt(flare_hash(seed, h + 1.0)) * 0.8;
            vec2 q = d - r * vec2(cos(a), sin(a));
            float size = mix(0.12, 0.3, flare_hash(seed, h + 2.0));
            float rr = length(q) / size;
            if (rr >= 1.0) continue;
            float th = atan(q.y, q.x);
            float best = 1e3;
            for (int b = 0; b < 7; b++) {
                float tb = float(b) / 7.0 * 6.2831853 + flare_hash(seed, h + 3.0 + float(b));
                float wob = tb + 0.25 * sin(rr * 9.0 + float(b) * 2.1) + 0.12 * sin(rr * 23.0 + float(b));
                float dth = abs(fmod_t(th - wob + 3.0 * M_PI_F, 2.0 * M_PI_F) - M_PI_F);
                best = min(best, dth * rr * size);
                float tb2 = wob + 0.6 * (flare_hash(seed, h + 20.0 + float(b)) - 0.5) * 2.0;
                float dth2 = abs(fmod_t(th - tb2 - 0.4 * sin(rr * 13.0) + 3.0 * M_PI_F, 2.0 * M_PI_F) - M_PI_F);
                if (rr > 0.35) best = min(best, dth2 * rr * size * 1.4);
            }
            float strand = exp(-pow(best / 0.006, 2.0)) * (1.0 - smoothstep(0.6, 1.0, rr));
            lace += strand + 0.6 * (1.0 - smoothstep(0.0, 0.08, rr));
        }
    }
    float polish = 0.05 * sin(d.x * 6.1 + seed) * sin(d.y * 4.7 + seed * 1.7);
    return max(m * (1.0 + polish) * (1.0 - 0.6 * min(lace, 1.0)) + marks * 0.1 * dust + scratches * 0.3
               + 0.15 * min(lace, 1.0) * (1.0 - min(lace, 1.0)) * 4.0, 0.0);
}

// Each lamp's own lit face at pixel `p` (px), as far as this pixel sees it:
// hidden where the scan has a surface nearer than the lamp (T its
// transmittance, z the ray depth there).
vec3 flare_faces(vec2 p, vec2 size, float T, float z) {
    int nl = int(FL[0].x);
    float diag = length(size);
    vec3 add = vec3(0.0);
    for (int li = 0; li < nl; li++) {
        vec4 a = FL[4 + 4 * li], b = FL[5 + 4 * li], fa = FL[6 + 4 * li], fb = FL[7 + 4 * li];
        if (!any(greaterThan(fb.rgb, vec3(0.0)))) continue;
        float dist = FL[36 + li / 4][li % 4];
        float seen = (dist > 0.0 && z > 0.0 && z < dist * 0.97) ? T : 1.0;
        if (seen <= 0.001) continue;
        vec2 s = a.xy * size;
        vec2 A = fa.xy, B = fa.zw;
        float det = A.x * B.y - A.y * B.x;
        float rf = sqrt(max(abs(det), 0.25));                // its size, px
        float blurPx = b.w * diag;
        float grow = (rf + blurPx) / rf;
        vec2 d = p - s;
        if (dot(d, d) > (rf * grow + 4.0) * (rf * grow + 4.0) * 4.0) continue;
        vec2 ab = abs(det) > 1e-6 ? vec2(d.x * B.y - d.y * B.x, A.x * d.y - A.y * d.x) / det : d / rf;
        bool round = mod(fb.w, 4.0) >= 2.0;
        float rho = (round ? length(ab) : max(abs(ab.x), abs(ab.y))) / grow;
        float soft = (0.7 + blurPx) / (rf * grow) + 0.02;
        float face = 1.0 - smoothstep(1.0 - soft, 1.0 + soft, rho);
        add += fb.rgb * seen * face / (grow * grow);
    }
    return add;
}

vec3 lens_flare(vec2 uv, vec2 size) {
    int nl = int(FL[0].x);
    if (nl <= 0) return vec3(0.0);
    float diag = length(size);
    float npx = size.x * size.y;
    bool single = FL[1].x > 0.5;
    // FL[1].y: the lens's seed, + 10000 x its dust grade, + 40000 if its glass has bubbles
    float seed = mod(FL[1].y, 10000.0);
    float dust = floor(mod(FL[1].y, 40000.0) / 10000.0);
    bool bubbles = FL[1].y >= 40000.0;
    vec2 axis = FL[2].xy * size;
    vec2 p = uv * size;
    vec3 add = vec3(0.0);
    const vec3 lum = vec3(0.2126, 0.7152, 0.0722);
    for (int li = 0; li < nl; li++) {
        vec4 a = FL[4 + 4 * li], b = FL[5 + 4 * li], fa = FL[6 + 4 * li], fb = FL[7 + 4 * li];
        float vis = a.w;
        if (vis <= 0.001) continue;
        vec3 I = b.rgb * vis;                      // the frame's brightness were all its light spread evenly
        vec2 s = a.xy * size;
        vec2 v = s - axis;
        // The bloom the lens scatters round a lamp's bright face.
        if (any(greaterThan(fb.rgb, vec3(0.0)))) {
            vec2 A = fa.xy, B = fa.zw;
            float det = A.x * B.y - A.y * B.x;
            float rf = sqrt(max(abs(det), 0.25));
            float blurPx = b.w * diag;
            vec2 d = p - s;
            float flux = dot(fb.rgb, lum) * vis * M_PI_F * rf * rf;
            float r0 = 4.0 + 0.6 * rf + blurPx;
            float dd = length(d);
            float bloom = (single ? 0.05 : 0.025) / (M_PI_F * r0 * r0) / pow(1.0 + (dd / r0) * (dd / r0), 2.0);
            add += fb.rgb / max(dot(fb.rgb, lum), 1e-6) * flux * bloom;
        }
        // The flare's parts only for a light with flare on.
        if (mod(fb.w, 2.0) < 1.0) continue;
        int gel = clamp(int(fb.w / 4.0), 0, SPEC_GELS - 1);      // its gel: the light's spectrum
        // Veiling glare: a broad haze, strongest near the light.
        float rg = diag * 0.35;
        float dg = length(p - s);
        float wear = 1.0 + 0.35 * dust + (fungus(seed, dust) ? 0.8 : 0.0);
        float glare = (single ? 0.006 : 0.0025) * wear / (1.0 + (dg / rg) * (dg / rg));
        add += I * glare * npx / (M_PI_F * rg * rg * 3.0);
        // Ghosts along the line through the axis, each the aperture's shape.
        int ng = single ? 7 : 6;
        for (int k = 0; k < ng; k++) {
            float t = mix(-1.6, 1.5, flare_hash(seed, float(k)));
            float rad = diag * mix(0.015, 0.11, flare_hash(seed, float(k) + 20.0)) * mix(0.55, 1.0, FL[0].w);
            float g = (single ? 2e-4 : 2e-5) * mix(0.4, 1.6, flare_hash(seed, float(k) + 40.0));
            float hue = flare_hash(seed, float(k) + 60.0);
            vec3 tint = single ? mix(vec3(1.0, 0.55, 0.2), vec3(0.3, 0.9, 0.5), hue)
                               : mix(vec3(0.45, 0.85, 0.55), vec3(0.85, 0.45, 0.9), hue);
            tint = mix(tint, vec3(1.0), 0.25);
            vec2 cg = axis + v * t;
            float field = length(cg - axis) / diag;
            float focusGhost = b.w * diag / rad * mix(0.15, 1.2, flare_hash(seed, float(k) + 90.0));
            float soft = 0.05 + 0.08 * flare_hash(seed, float(k) + 80.0) + FL[2].w * field + focusGhost;
            float bendK = FL[2].z * (single ? 2.0 : 1.0) * (1.0 + 2.0 * abs(t));
            float reach = 1.0 + length(v * t) / rad;
            float far = length(p - cg) / (rad * max(FL[1].w, 1.0));
            if (far > (1.0 + 1.6 * abs(bendK)) * (1.0 + soft + 0.6 * abs(bendK) * reach) + 1.6 * abs(bendK) * reach) continue;
            vec3 m3 = vec3(0.0);
            for (int bd = 0; bd < SPEC_BANDS; bd++) {
                float sc = 1.0 + bendK * band_bend(bd);
                vec2 d = (p - (axis + v * t * sc)) / (rad * sc);
                d.x /= max(FL[1].w, 0.5);
                float sb = soft + 0.5 * abs(bendK) * SPEC_BAND_WIDTH[bd] * reach;
                m3 += SPEC_BAND_SHARE[gel][bd] * aperture_mask(d, sb);
            }
            if (max(m3.r, max(m3.g, m3.b)) > 0.0) {
                vec2 dq = (p - cg) / rad;
                dq.x /= max(FL[1].w, 0.5);
                m3 *= glass_flaws(dq, seed, float(k), dust, bubbles);
            }
            if (max(m3.r, max(m3.g, m3.b)) <= 0.0) continue;
            float rim = 0.8 + 0.4 * smoothstep(0.6, 1.0, length((p - cg) / rad));
            add += I * tint * m3 * (g * rim * npx / (M_PI_F * rad * rad));
        }
        // Scratches in the front coating: each throws a faint streak through the light.
        for (int j = 0; j < 3; j++) {
            if (float(j) >= dust) break;
            float an = flare_hash(seed, 1600.0 + float(j)) * M_PI_F;
            vec2 dir = vec2(cos(an), sin(an));
            float along = abs(dot(p - s, dir)), across = abs(dot(p - s, vec2(-dir.y, dir.x)));
            float Ls = diag * mix(0.012, 0.035, flare_hash(seed, 1610.0 + float(j)));
            float wS = max(1.5, diag * 0.0012);
            float streak = exp(-0.5 * pow(across / wS, 2.0)) * exp(-pow(along / Ls, 1.5));
            add += I * (1e-5 * streak * npx / (Ls * 2.0 * wS * 2.5));
        }
        // A faint ring round the light (a reflection off the film and back).
        float rr = diag * 0.18, w = diag * 0.012;
        vec3 ring = vec3(0.0);
        float ringW = w * (1.0 + FL[2].w * 4.0);
        if (abs(dg - rr) < 5.0 * ringW + rr * abs(FL[2].z) * 3.0 * 1.6)
            for (int bd = 0; bd < SPEC_BANDS; bd++) {
                float rc = rr * (1.0 + FL[2].z * 3.0 * band_bend(bd));
                ring += SPEC_BAND_SHARE[gel][bd] * exp(-0.5 * pow((dg - rc) / (w * (1.0 + FL[2].w * 4.0)), 2.0));
            }
        add += I * ring * ((single ? 1e-4 : 2e-5) * npx / (2.0 * M_PI_F * rr * w * 2.5));
        // A filter on the lens: its flat glass reflects a small sharp ghost mirrored through the axis.
        if (FL[3].x > 0.5) {
            vec2 cm = 2.0 * axis - s;
            float rm = max(a.z * diag * 1.3, 2.5);
            float dm = length(p - cm);
            float mg = exp(-0.5 * (dm / rm) * (dm / rm));
            add += I * (8e-4 * mg * npx / (2.0 * M_PI_F * rm * rm));
        }
        // A cross screen or diffraction grating: the filter's own spikes.
        int sp = int(FL[3].y);
        if (sp > 0 && dg > 0.5) {
            int lines = max(1, sp / 2);
            float L = diag * (FL[3].w > 0.5 ? 0.22 : 0.16);
            vec3 star = vec3(0.0);
            for (int j = 0; j < lines; j++) {
                float ang = 0.35 + float(j) * M_PI_F / float(lines);
                vec2 dir = vec2(cos(ang), sin(ang));
                float along = abs(dot(p - s, dir)), across = abs(dot(p - s, vec2(-dir.y, dir.x)));
                float spk = exp(-0.5 * (across / 1.4) * (across / 1.4)) * exp(-3.2 * along / L);
                if (spk < 1e-5) continue;
                vec3 c = I;
                if (FL[3].w > 0.5) c = mix(I, grating_lamp(along / L, gel, I) / 1.3, smoothstep(0.02, 0.10, along / L));
                star += c * spk;
            }
            add += star * (FL[3].z * 0.01 * npx / (float(lines) * L * 2.0 * 1.4 * 2.5));
        }
        // Starburst: diffraction at the corners of the iris, stopped down; only a
        // light in focus is sharp enough to show it.
        int nb = int(FL[0].y);
        float corners = 1.0 - smoothstep(0.75, 0.98, FL[0].w);
        float sharp = exp(-b.w * diag / 3.0);
        if (nb >= 3 && dg > 0.5 && corners * sharp > 0.001) {
            int rays = (nb % 2 == 0) ? nb : 2 * nb;
            float th = atan(p.y - s.y, p.x - s.x) - FL[0].z;
            float seg = 2.0 * M_PI_F / float(rays);
            float off = fmod_t(fmod_t(th, seg) + seg, seg) - seg / 2.0;
            float wpx = 1.1 + 0.5 * exp(-dg / 40.0);
            float spike = exp(-0.5 * pow(off * dg / wpx, 2.0));
            float len = diag * min(0.3, 0.025 / max(FL[0].w, 0.05));
            float fade = pow(len / (len + dg), 2.0) * exp(-dg / (len * 3.0));
            add += I * (6e-5 * corners * sharp * spike * fade * npx / (float(rays) * len * 2.0 * wpx * 2.5 + 1.0));
        }
    }
    return add;
}
