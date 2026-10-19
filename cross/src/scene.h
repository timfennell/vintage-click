// Vintage Click, cross-platform: the renderer's C interface, the scan (PLY)
// loader and the hand-held camera. Ported from PLYLoader.swift and FlyCamera.swift.
#pragma once
#include "kit.h"
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <thread>
#include <type_traits>

#include <SDL3/SDL_loadso.h>

// The renderer's C interface (src/blender/SplatRenderC.cpp in Spirula Studio),
// loaded at run time from the library next to the program, so a missing GPU
// driver is a message rather than a refusal to start.
namespace sr {
inline const char* (*last_error)(void);
inline int (*set_splats)(int64_t, int, const float*, const float*, const float*, const float*, const float*, const float*);
inline int (*render_ex)(const float*, float, float, float, float, int, int, const char*, float*, float*, float*, float*);
inline int (*set_lens)(const float*, int);
inline int (*set_camera_model)(const char*);
inline void (*shutdown)(void);

/// Load from `dir`; "" on success, otherwise why not.
inline std::string load(const std::string& dir) {
#if defined(_WIN32)
    const char* name = "spirula_render.dll";
#elif defined(__APPLE__)
    const char* name = "libspirula_render.dylib";
#else
    const char* name = "libspirula_render.so";
#endif
    SDL_SharedObject* so = SDL_LoadObject((dir + name).c_str());
    if (!so) so = SDL_LoadObject(name);
    if (!so) return std::string("cannot load ") + name + ": " + SDL_GetError();
    auto get = [&](auto& fn, const char* sym) {
        fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(SDL_LoadFunction(so, sym));
        return fn != nullptr;
    };
    if (!get(last_error, "sr_last_error") || !get(set_splats, "sr_set_splats") || !get(render_ex, "sr_render_ex") ||
        !get(set_lens, "sr_set_lens") || !get(set_camera_model, "sr_set_camera_model") || !get(shutdown, "sr_shutdown"))
        return std::string(name) + " is missing a function (an older renderer?)";
    return "";
}
}

struct Scan {
    int64_t count = 0;
    int shDegree = 0;
    std::vector<float> means, quats, scales, opacities, dc, sh;
    V3 center;
    float radius = 1;
};

/// A trained 3DGS PLY (binary little-endian float properties).
inline Scan loadPLY(const std::string& path) {
    std::ifstream in(std::filesystem::u8path(path), std::ios::binary);
    if (!in) throw std::runtime_error("cannot open " + path);
    std::string line;
    std::vector<std::string> props;
    int64_t count = 0;
    bool inVertex = false;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line == "end_header") break;
        if (line.rfind("format", 0) == 0 && line.find("binary_little_endian") == std::string::npos)
            throw std::runtime_error("only binary little-endian PLY files are supported");
        if (line.rfind("element", 0) == 0) {
            inVertex = line.find("element vertex") == 0;
            if (inVertex) count = std::stoll(line.substr(15));
        } else if (line.rfind("property", 0) == 0 && inVertex) {
            auto sp = line.rfind(' ');
            if (line.find("property float ") != 0) throw std::runtime_error("PLY property is not a float: " + line);
            props.push_back(line.substr(sp + 1));
        }
    }
    auto idx = [&](const std::string& n) {
        for (size_t i = 0; i < props.size(); i++) if (props[i] == n) return int(i);
        throw std::runtime_error("PLY has no " + n);
    };
    int ix = idx("x"), iy = idx("y"), iz = idx("z"), iop = idx("opacity");
    int irot[4], isc[3], idc[3];
    for (int j = 0; j < 4; j++) irot[j] = idx("rot_" + std::to_string(j));
    for (int j = 0; j < 3; j++) { isc[j] = idx("scale_" + std::to_string(j)); idc[j] = idx("f_dc_" + std::to_string(j)); }
    int nrest = 0;
    while (std::find(props.begin(), props.end(), "f_rest_" + std::to_string(nrest)) != props.end()) nrest++;
    int K = nrest / 3, degree = 0;
    while ((degree + 1) * (degree + 1) - 1 < K) degree++;
    std::vector<int> irest(nrest);
    for (int j = 0; j < nrest; j++) irest[j] = idx("f_rest_" + std::to_string(j));

    size_t np = props.size();
    std::vector<float> raw(size_t(count) * np);
    in.read(reinterpret_cast<char*>(raw.data()), std::streamsize(raw.size() * 4));
    if (!in) throw std::runtime_error("PLY is truncated");

    Scan s;
    s.count = count; s.shDegree = degree;
    s.means.resize(count * 3); s.quats.resize(count * 4); s.scales.resize(count * 3);
    s.opacities.resize(count); s.dc.resize(count * 3); s.sh.resize(size_t(count) * K * 3);
    unsigned nt = std::max(1u, std::thread::hardware_concurrency());
    std::vector<std::thread> ts;
    for (unsigned t = 0; t < nt; t++) ts.emplace_back([&, t] {
        for (int64_t i = count * t / nt; i < count * (t + 1) / nt; i++) {
            const float* v = &raw[i * np];
            s.means[3 * i] = v[ix]; s.means[3 * i + 1] = v[iy]; s.means[3 * i + 2] = v[iz];
            for (int j = 0; j < 4; j++) s.quats[4 * i + j] = v[irot[j]];
            for (int j = 0; j < 3; j++) { s.scales[3 * i + j] = v[isc[j]]; s.dc[3 * i + j] = v[idc[j]]; }
            s.opacities[i] = v[iop];
            for (int k = 0; k < K; k++)
                for (int c = 0; c < 3; c++) s.sh[(i * K + k) * 3 + c] = v[irest[c * K + k]];
        }
    });
    for (auto& t : ts) t.join();

    // Robust centre and radius: medians, 90th-percentile distance.
    int64_t stride = std::max<int64_t>(1, count / 20000);
    std::vector<float> xs, ys, zs;
    for (int64_t i = 0; i < count; i += stride) {
        xs.push_back(s.means[3 * i]); ys.push_back(s.means[3 * i + 1]); zs.push_back(s.means[3 * i + 2]);
    }
    auto med = [](std::vector<float> v) { std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end()); return v[v.size() / 2]; };
    s.center = {med(xs), med(ys), med(zs)};
    std::vector<float> d;
    for (size_t i = 0; i < xs.size(); i++) d.push_back(len(V3{xs[i], ys[i], zs[i]} - s.center));
    std::nth_element(d.begin(), d.begin() + d.size() * 9 / 10, d.end());
    s.radius = std::max(1e-6f, d[d.size() * 9 / 10]);
    return s;
}

/// The scan's middle tone as linear luminance (see PLYLoader.swift, middleTone).
inline float middleTone(const Scan& s) {
    if (s.count == 0) return 0.18f;
    int64_t stride = std::max<int64_t>(1, s.count / 400000);
    std::vector<float> area;
    for (int64_t i = 0; i < s.count; i += stride)
        area.push_back(std::exp((s.scales[3 * i] + s.scales[3 * i + 1] + s.scales[3 * i + 2]) * (2.f / 3.f)));
    std::vector<float> sorted = area;
    std::nth_element(sorted.begin(), sorted.begin() + sorted.size() * 95 / 100, sorted.end());
    float cap = sorted[std::min(sorted.size() - 1, sorted.size() * 95 / 100)];
    auto lin = [](float v) { return v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f); };
    const float c0 = 0.28209479f;
    double sw = 0, sl = 0; size_t k = 0;
    for (int64_t i = 0; i < s.count; i += stride, k++) {
        float o = 1 / (1 + std::exp(-s.opacities[i]));
        double w = o * std::min(area[k], cap);
        float r = lin(std::clamp(0.5f + c0 * s.dc[3 * i], 0.f, 1.f));
        float g = lin(std::clamp(0.5f + c0 * s.dc[3 * i + 1], 0.f, 1.f));
        float b = lin(std::clamp(0.5f + c0 * s.dc[3 * i + 2], 0.f, 1.f));
        sw += w; sl += w * std::max(0.002f, 0.2126f * r + 0.7152f * g + 0.0722f * b);
    }
    return sw > 0 ? float(sl / sw) : 0.18f;
}

/// A hand-held camera: yaw and pitch about a world up axis, eased velocities.
struct FlyCamera {
    V3 position, up{0, -1, 0};
    float yaw = 0, pitch = 0, moveSpeed = 1, lookSpeed = 1.6f, focalMM = 50;
    V3 velocity;
    V2 lookRate;

    void horizon(V3& a, V3& b) const {
        V3 seed = std::fabs(up.x) < 0.9f ? V3{1, 0, 0} : V3{0, 0, 1};
        a = norm(seed - up * dot(seed, up));
        b = cross(up, a);
    }
    V3 forward() const {
        V3 a, b; horizon(a, b);
        return (a * std::cos(yaw) + b * std::sin(yaw)) * std::cos(pitch) + up * std::sin(pitch);
    }
    V3 right() const { return norm(cross(forward(), up)); }
    V3 down() const { return cross(forward(), right()); }
    void lookAt(V3 target, V3 eye) {
        position = eye;
        V3 d = norm(target - eye), a, b; horizon(a, b);
        pitch = std::asin(std::clamp(dot(d, up), -1.f, 1.f));
        yaw = std::atan2(dot(d, b), dot(d, a));
    }
    void turn(V2 d) {
        float k = 0.0022f * std::min(1.f, 50 / focalMM);
        yaw -= d.x * k;
        pitch = std::clamp(pitch + d.y * k, -1.5f, 1.5f);
    }
    void update(V2 move, V2 look, float rise, float dt) {
        float ease = 1 - std::exp(-dt / 0.12f);
        V2 want = look * (lookSpeed * (focalMM < 50 ? 1 : 50 / focalMM));
        lookRate = lookRate + (want - lookRate) * ease;
        yaw -= lookRate.x * dt;
        pitch = std::clamp(pitch + lookRate.y * dt, -1.5f, 1.5f);
        V3 f = forward(), r = right();
        V3 flat = norm(f - up * dot(f, up));
        V3 w = (flat * move.y + r * move.x + up * rise) * moveSpeed;
        velocity = velocity + (w - velocity) * ease;
        position = position + velocity * dt;
    }
    std::vector<float> viewMatrix() const {
        V3 r = right(), d = down(), f = forward(), p = position;
        return {r.x, r.y, r.z, -dot(r, p), d.x, d.y, d.z, -dot(d, p), f.x, f.y, f.z, -dot(f, p), 0, 0, 0, 1};
    }
};

/// Somewhere to stand in a scanned place: near the middle, at eye height above
/// the ground there, nothing within arm's reach and a clear view a few metres
/// ahead (see Viewer.swift, findOpenSpot). False when nowhere qualifies.
inline bool findOpenSpot(const Scan& m, float metresPerUnit, V3 up, V3& position, float& yaw) {
    float unit = 1 / metresPerUnit;
    int64_t stride = std::max<int64_t>(1, m.count / 400000);
    std::vector<V3> pts;
    for (int64_t i = 0; i < m.count; i += stride) pts.push_back({m.means[3 * i], m.means[3 * i + 1], m.means[3 * i + 2]});
    FlyCamera cam; cam.up = up;
    V3 a = cam.forward(), b = cross(up, a);
    struct Best { float score = 1e30f; V3 pos; float yaw = 0; bool ok = false; };
    std::vector<Best> best(49);
    std::vector<std::thread> ts;
    for (int g = 0; g < 49; g++) ts.emplace_back([&, g] {
        int gx = g / 7 - 3, gy = g % 7 - 3;
        V3 foot = m.center + (a * float(gx) + b * float(gy)) * (m.radius * 0.12f);
        std::vector<float> heights;
        for (const V3& p : pts) {
            V3 d = p - foot;
            float h = dot(d, up);
            V3 side = d - up * h;
            if (dot(side, side) < unit * unit) heights.push_back(h);
        }
        if (heights.size() <= 30) return;
        std::sort(heights.begin(), heights.end());
        float ground = heights[heights.size() / 20];
        V3 eye = foot + up * (ground + 1.6f * unit);
        int near = 0;
        for (const V3& p : pts) { V3 d = p - eye; if (dot(d, d) < unit * unit) near++; }
        for (int k = 0; k < 8; k++) {
            float y = k * float(M_PI) / 4;
            V3 f = a * std::cos(y) + b * std::sin(y);
            int blocked = 0, seen = 0;
            for (const V3& p : pts) {
                V3 d = p - eye;
                float along = dot(d, f);
                if (along <= 0.3f * unit) continue;
                float off = len(d - f * along);
                if (along < 4 * unit && off < 0.6f * unit) blocked++;
                if (along < 25 * unit && off < along * 0.4f) seen++;
            }
            float score = float(near * 20 + blocked * 5) - float(std::min(seen, 5000)) * 0.05f;
            if (score < best[g].score) best[g] = {score, eye, y, true};
        }
    });
    for (auto& t : ts) t.join();
    const Best* w = nullptr;
    for (auto& c : best) if (c.ok && (!w || c.score < w->score)) w = &c;
    if (!w) return false;
    position = w->pos; yaw = w->yaw;
    return true;
}

/// How flat the scan is: smallest over largest variance along its principal
/// axes, far tail trimmed. A place (dominated by its ground) is under 0.15.
inline float flatness(const Scan& s) {
    int64_t step = std::max<int64_t>(1, s.count / 20000);
    std::vector<V3> pts;
    for (int64_t i = 0; i < s.count; i += step) pts.push_back({s.means[3 * i], s.means[3 * i + 1], s.means[3 * i + 2]});
    if (pts.size() < 100) return 1;
    V3 c{};
    for (auto& p : pts) c = c + p;
    c = c * (1.f / pts.size());
    std::vector<float> d;
    for (auto& p : pts) d.push_back(len(p - c));
    std::vector<float> sorted = d;
    std::sort(sorted.begin(), sorted.end());
    float cut = sorted[size_t((sorted.size() - 1) * 0.9f)];
    double a[3][3] = {};
    int m = 0;
    for (size_t i = 0; i < pts.size(); i++) {
        if (d[i] > cut) continue;
        V3 q = pts[i] - c;
        float v[3] = {q.x, q.y, q.z};
        for (int r = 0; r < 3; r++) for (int k = 0; k < 3; k++) a[r][k] += v[r] * v[k];
        m++;
    }
    for (auto& r : a) for (auto& x : r) x /= std::max(m, 1);
    // Eigenvalues of a symmetric 3x3 (Jacobi sweeps).
    for (int sweep = 0; sweep < 12; sweep++)
        for (auto [p, q] : {std::pair{0, 1}, std::pair{0, 2}, std::pair{1, 2}}) {
            if (std::fabs(a[p][q]) < 1e-12) continue;
            double theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
            double t = (theta >= 0 ? 1 : -1) / (std::fabs(theta) + std::sqrt(theta * theta + 1));
            double cs = 1 / std::sqrt(t * t + 1), sn = t * cs;
            double r[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
            r[p][p] = cs; r[q][q] = cs; r[p][q] = sn; r[q][p] = -sn;
            double tmp[3][3] = {}, out[3][3] = {};
            for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) for (int k = 0; k < 3; k++) tmp[i][j] += a[i][k] * r[k][j];
            for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) for (int k = 0; k < 3; k++) out[i][j] += r[k][i] * tmp[k][j];
            std::memcpy(a, out, sizeof a);
        }
    double ev[3] = {a[0][0], a[1][1], a[2][2]};
    std::sort(ev, ev + 3);
    return ev[2] > 0 ? float(ev[0] / ev[2]) : 1;
}
