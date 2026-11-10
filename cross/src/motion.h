// The movie camera (MotionTake.swift, MovieDeveloper.swift): a take is keys on a
// timeline, eased through; the darkroom exposes it frame by frame into a movie.
#pragma once
#include "scene.h"
#include <algorithm>
#include <cmath>
#include <memory>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

/// One key on the movie camera's timeline: where the camera stood and how it
/// was set at that moment of the take.
struct MotionKey {
    double time = 0;                // seconds from the start of the take
    FlyCamera camera;
    float focusM = 1, fNumber = 2, shutterAngle = 180;
};

/// A shot for the movie camera: keys on a timeline. Saved as take.txt beside its
/// clips (and as the scan's working take between launches).
struct MotionTake {
    std::string scene;
    std::vector<MotionKey> keys;
    double duration = 10;
    float frameRate = 24;
    int takeNumber = 0;
    /// The camera body it was shot with (the app's own line: lens, film, filter, the scene's light).
    std::string bodyLine;

    static const std::vector<double>& lengths() { static const std::vector<double> l = {5, 10, 20, 30}; return l; }
    int frameCount() const { return std::max(1, int(std::lround(duration * frameRate))); }
    double frameTime() const { return 1.0 / frameRate; }

    /// The camera and its settings at `t`: a smooth curve through the keys
    /// (time-spaced Hermite, still at the first and last key, so a move eases
    /// in and out), held before the first and after the last. Focus eases in
    /// dioptres, as a focus ring turns; the iris in stops.
    bool sample(double t, MotionKey& out) const {
        if (keys.empty()) return false;
        const MotionKey &first = keys.front(), &last = keys.back();
        if (keys.size() == 1 || t <= first.time) { out = first; out.time = t; return true; }
        if (t >= last.time) { out = last; out.time = t; return true; }
        size_t i = 0;
        for (size_t j = 0; j < keys.size(); j++) if (keys[j].time <= t) i = j;
        const MotionKey& a = keys[i];
        double h = keys[i + 1].time - a.time;
        float u = float((t - a.time) / std::max(h, 1e-9));
        // Each key's yaw, turned by whole turns to be nearest the one before (a pan
        // from 350° to 10° goes 20°, not the long way round).
        std::vector<float> yaws;
        for (auto& k : keys) {
            float y = k.camera.yaw;
            if (!yaws.empty()) y -= 2 * float(M_PI) * std::round((y - yaws.back()) / (2 * float(M_PI)));
            yaws.push_back(y);
        }
        // Hermite through each value, with tangents (per second) from the
        // neighbouring keys, zero at the ends of the take.
        auto curve = [&](auto value) {
            auto v = [&](size_t j) { return value(j); };
            using T = decltype(value(size_t(0)));
            auto slope = [&](size_t j) -> T {
                if (j == 0 || j + 1 >= keys.size()) return v(j) * 0.f;
                return (v(j + 1) - v(j - 1)) * (1.f / std::max(float(keys[j + 1].time - keys[j - 1].time), 1e-6f));
            };
            T m0 = slope(i) * float(h), m1 = slope(i + 1) * float(h);
            float u2 = u * u, u3 = u2 * u;
            return v(i) * (2 * u3 - 3 * u2 + 1) + m0 * (u3 - 2 * u2 + u) + v(i + 1) * (-2 * u3 + 3 * u2) + m1 * (u3 - u2);
        };
        V3 pos = curve([&](size_t j) { return keys[j].camera.position; });
        V3 ang = curve([&](size_t j) { return V3{yaws[j], keys[j].camera.pitch, 0}; });
        V3 set = curve([&](size_t j) {
            return V3{1 / std::max(keys[j].focusM, 0.01f), std::log2(keys[j].fNumber), keys[j].shutterAngle};
        });
        out = a;
        out.time = t;
        out.camera.position = pos;
        out.camera.yaw = ang.x;
        out.camera.pitch = std::clamp(ang.y, -1.5f, 1.5f);
        out.focusM = 1 / std::max(set.x, 0.005f);
        out.fNumber = std::exp2(set.y);
        out.shutterAngle = std::clamp(set.z, 1.f, 360.f);
        return true;
    }

    /// Adds a key at `key.time`, replacing one within half a frame of it.
    void setKey(const MotionKey& key) {
        double half = frameTime() / 2;
        std::vector<MotionKey> kept;
        for (auto& k : keys) if (std::fabs(k.time - key.time) >= half) kept.push_back(k);
        kept.push_back(key);
        std::sort(kept.begin(), kept.end(), [](const MotionKey& a, const MotionKey& b) { return a.time < b.time; });
        keys = kept;
    }
    /// Removes the key within half a frame of `t`; false when there is none.
    bool deleteKey(double t) {
        size_t n = keys.size();
        double half = frameTime() / 2;
        keys.erase(std::remove_if(keys.begin(), keys.end(), [&](const MotionKey& k) { return std::fabs(k.time - t) < half; }), keys.end());
        return keys.size() != n;
    }
    /// The key at `t` (within half a frame): its number from 1, or 0.
    int keyNumber(double t) const {
        for (size_t i = 0; i < keys.size(); i++) if (std::fabs(keys[i].time - t) < frameTime() / 2) return int(i) + 1;
        return 0;
    }

    /// "00:00:04:12": hours, minutes, seconds and frames.
    static std::string timecode(double t, float fps) {
        int f = int(std::lround(t * fps)), r = std::max(1, int(std::lround(fps))), s = f / r;
        char b[32];
        snprintf(b, sizeof b, "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, f % r);
        return b;
    }

    // ---- on disk: a line per value, a line per key
    void save(const fs::path& p) const {
        std::error_code ec;
        fs::create_directories(p.parent_path(), ec);
        std::ofstream o(p, std::ios::binary);
        o << "vintage-click-take 1\nscene " << scene << "\nduration " << duration << "\nfps " << frameRate << "\ntake " << takeNumber << "\n";
        if (!bodyLine.empty()) o << "body " << bodyLine << "\n";
        o.precision(9);
        for (auto& k : keys)
            o << "key " << k.time << " " << k.camera.position.x << " " << k.camera.position.y << " " << k.camera.position.z << " "
              << k.camera.up.x << " " << k.camera.up.y << " " << k.camera.up.z << " " << k.camera.yaw << " " << k.camera.pitch << " "
              << k.camera.focalMM << " " << k.focusM << " " << k.fNumber << " " << k.shutterAngle << "\n";
    }
    static bool load(const fs::path& p, MotionTake& t) {
        std::ifstream in(p, std::ios::binary);
        std::string line;
        if (!in || !std::getline(in, line) || line.rfind("vintage-click-take", 0) != 0) return false;
        t = MotionTake{};
        while (std::getline(in, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            std::istringstream s(line);
            std::string what;
            s >> what;
            if (what == "scene") t.scene = line.size() > 6 ? line.substr(6) : "";
            else if (what == "duration") s >> t.duration;
            else if (what == "fps") s >> t.frameRate;
            else if (what == "take") s >> t.takeNumber;
            else if (what == "body") t.bodyLine = line.size() > 5 ? line.substr(5) : "";
            else if (what == "key") {
                MotionKey k;
                s >> k.time >> k.camera.position.x >> k.camera.position.y >> k.camera.position.z >> k.camera.up.x >> k.camera.up.y >>
                    k.camera.up.z >> k.camera.yaw >> k.camera.pitch >> k.camera.focalMM >> k.focusM >> k.fNumber >> k.shutterAngle;
                if (s) t.keys.push_back(k);
            }
        }
        return true;
    }
    /// A short stable name for a scan's working take.
    static std::string digest(const std::string& s) {
        uint64_t h = 1469598103934665603ull;
        for (unsigned char c : s) { h ^= c; h *= 1099511628211ull; }
        char b[20];
        snprintf(b, sizeof b, "%016llx", (unsigned long long)h);
        return b;
    }
};

// ---------------------------------------------------------------------------
// The movie file: Media Foundation's sink writer (H.264 or HEVC in an .mp4),
// the frames handed in as 8-bit RGBA prints (movie.cpp).
class MovieWriter {
public:
    MovieWriter();
    ~MovieWriter();
    /// Opens `path` for `w` x `h` frames at `fps`; `hevc` asks for HEVC (false: H.264); `tenBit`
    /// for HEVC Main 10, fed P010 (the frames then come as floats, through writeFloat).
    bool open(const fs::path& path, int w, int h, float fps, bool hevc, unsigned bitrate, std::string& err, bool tenBit = false);
    /// Appends a frame: RGBA bytes (R first), top row first.
    bool write(const uint32_t* rgba, int frame);
    /// Appends a frame of display-referred RGB floats (0...1), for a 10-bit file.
    bool writeFloat(const float* rgb, int frame);
    bool tenBit = false;
    /// Closes the file; true when it was written whole.
    bool finish();
    int W = 0, H = 0;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
