// The finder's blur, in image space (dof_spread in Shaders.swift).
//
// The finder renders sharp; this blurs it as the lens would, like a print
// (which averages sharp views through the lens): each pixel spreads its light
// as a Gaussian with the pupil's spread at its place in the field (the pupil
// table: shift, radial and tangential variance, light), sized by its own
// defocus (tilt and field curvature included) and capped as the renderer caps
// it; gathered from smaller copies of the frame so large blurs stay smooth.
// Light from in front spreads over what is behind; what is behind is limited
// to the blur of what it is behind, so a sharp subject keeps its edge.
//   D[0] = (W, H, fx, cap px)  D[1] = (cx, cy, metres per unit, rows in L)
//   D[2] = (table rows, mip levels, -, -)  D[3..] the lens rows (as sr_set_lens)
struct DofSpread { vec2 sr; vec2 shift; float light; };     // (radial, tangential) sigma px, shift px

DofSpread dof_spread(vec2 pc, float zr) {
    int nT = int(D[2].x);
    vec2 q = (pc - D[1].xy) / D[0].z;
    float zc = max(zr / sqrt(1.0 + dot(q, q)), 1e-4);        // along the axis
    float k = D[3].y - 1.0 / zc, a = D[3].z;
    vec2 centre = D[3 + nT + 4].xy;
    vec2 qv = (pc - centre) / D[3 + nT + 4].z;
    float ql = length(qv);
    vec2 qd = ql > 1e-4 ? qv / ql : vec2(1.0, 0.0);
    float tt = clamp(ql / 1.25, 0.0, 1.0) * float(nT - 1);
    int i0 = min(int(tt), nT - 2);
    vec4 m = mix(D[3 + 2 + i0], D[3 + 3 + i0], tt - float(i0));
    vec4 tilt = D[3 + nT + 2];
    float dk = tilt.x * qv.x + tilt.y * qv.y;
    float kr = k + dk + tilt.z * ql * ql, kt = k + dk + tilt.w * ql * ql;
    float fx = D[0].z;
    DofSpread o;
    o.sr = vec2(abs(kr) * sqrt(max(m.y, 0.0)) * a, abs(kt) * sqrt(max(m.z, 0.0)) * a) * fx;
    float tr = dot(o.sr, o.sr), cap = 2.0 * D[0].w * D[0].w;
    if (tr > cap) o.sr *= sqrt(cap / tr);
    o.sr = max(o.sr, vec2(0.5));
    o.shift = qd * (kr * m.x * a * fx);
    o.light = m.w;
    return o;
}
