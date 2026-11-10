// Vintage Click, cross-platform (Windows, Linux, macOS): a 1970s 35 mm SLR in
// a 3D Gaussian splat scan. SDL3 for the window, input and sound; Spirula
// Studio's renderer (libspirula_render) for the scene and the lens; the
// focusing screen, film and light table on the CPU. Behaviour follows the
// Swift app (Sources/SplatCamera), which remains the Mac release.
//
//   VintageClick [scan.ply] [--shoot out.png] [--res 1440x960] ...
#include "scene.h"
#include "image.h"
#include "draw.h"
#include "gpu.h"
#include "lights.h"
#include "flare.h"
#include "motion.h"
#include "bundle.h"
#include "soundscape.h"
#include "exif.h"
#include <SDL3/SDL.h>
#include <array>
#include <SDL3/SDL_main.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <ctime>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <sstream>

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBIW_WINDOWS_UTF8
#include "stb_image_write.h"
#define STB_IMAGE_IMPLEMENTATION
#define STBI_WINDOWS_UTF8
#define STBI_ONLY_PNG
#define STBI_ONLY_HDR
#include "stb_image.h"

namespace fs = std::filesystem;
static std::vector<std::string> g_args;
static std::string option(const std::string& name) {
    for (size_t i = 0; i + 1 < g_args.size(); i++) if (g_args[i] == name) return g_args[i + 1];
    return "";
}
static bool flag(const std::string& name) { return std::find(g_args.begin(), g_args.end(), name) != g_args.end(); }

static std::string basePath() { const char* b = SDL_GetBasePath(); return b ? b : ""; }

// ---------------------------------------------------------------------------
// Settings kept between runs (the Mac app's UserDefaults): one "key<TAB>value"
// per line in the user's app-data folder (on Windows %APPDATA%\Vintage Click).

struct Prefs {
    std::map<std::string, std::string> kv;
    fs::path file;
    void load() {
        char* dir = SDL_GetPrefPath("", "Vintage Click");
        if (!dir) return;
        file = fs::u8path(dir) / "settings.txt";
        SDL_free(dir);
        std::ifstream in(file, std::ios::binary);
        std::string line;
        while (std::getline(in, line)) {
            size_t t = line.find('\t');
            if (t != std::string::npos) kv[line.substr(0, t)] = line.substr(t + 1);
        }
    }
    void save() const {
        if (file.empty()) return;
        std::ofstream out(file, std::ios::binary | std::ios::trunc);
        for (auto& [k, v] : kv) out << k << '\t' << v << '\n';
    }
    std::string get(const std::string& k, const std::string& d = "") const { auto i = kv.find(k); return i == kv.end() ? d : i->second; }
    bool getBool(const std::string& k, bool d) const { auto v = get(k); return v.empty() ? d : v == "1"; }
    int getInt(const std::string& k, int d) const { auto v = get(k); return v.empty() ? d : std::atoi(v.c_str()); }
    void set(const std::string& k, const std::string& v) { kv[k] = v; save(); }
    void setBool(const std::string& k, bool v) { set(k, v ? "1" : "0"); }
    void setInt(const std::string& k, int v) { set(k, std::to_string(v)); }
};
static Prefs g_prefs;

/// How a scan was made, remembered per file (as SceneKind in main.swift): a
/// place to stand in or an object on the rig, its light, and a measured scale.
struct SceneKind {
    bool place = false;
    float ev = 12;
    float scale = 0;   // metres per unit once measured, else 0
    static bool remembered(const std::string& path, SceneKind& k) {
        std::string v = g_prefs.get("scene:" + path);
        if (v.empty()) return false;
        int p = 0; float ev = 12, s = 0;
        if (sscanf(v.c_str(), "%d %f %f", &p, &ev, &s) < 2) return false;
        k.place = p != 0; k.ev = ev; k.scale = s;
        return true;
    }
    void remember(const std::string& path) const {
        char b[64]; snprintf(b, sizeof b, "%d %g %g", place ? 1 : 0, ev, scale);
        g_prefs.set("scene:" + path, b);
    }
};

// ---------------------------------------------------------------------------
// Where rolls are kept: <Pictures>/Vintage Click/<day>/<HH.MM scene>/<Roll NN - stock>/frame-NN.png

static fs::path rollsRoot() {
    if (const char* env = SDL_getenv("VINTAGE_CLICK_ROLLS")) return fs::u8path(env);
    // Chosen in Menu > Photos > Where rolls are kept (remembered).
    std::string chosen = g_prefs.get("rollsFolder");
    if (!chosen.empty()) return fs::u8path(chosen);
    const char* pics = SDL_GetUserFolder(SDL_FOLDER_PICTURES);
    fs::path base = pics ? fs::u8path(pics) : fs::current_path();
    return base / "Vintage Click";
}

static std::string stamp(const char* fmt) {
    std::time_t t = std::time(nullptr);
    char b[64]; std::strftime(b, sizeof b, fmt, std::localtime(&t));
    return b;
}

// ---------------------------------------------------------------------------
// Sounds: the camera's own recordings (assets/Sounds), mixed by SDL.

struct Sounds {
    SDL_AudioDeviceID dev = 0;
    struct Take { SDL_AudioSpec spec; std::vector<uint8_t> data; };
    std::map<std::string, std::vector<Take>> takes;
    std::map<float, std::vector<Take>> shutterAt;
    std::vector<SDL_AudioStream*> playing;
    bool enabled = true;

    void load(const fs::path& dir) {
        dev = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, nullptr);
        if (!dev || !fs::exists(dir)) return;
        for (auto& e : fs::directory_iterator(dir)) {
            if (e.path().extension() != ".wav") continue;
            std::string stem = e.path().stem().string();
            SDL_AudioSpec spec; Uint8* buf = nullptr; Uint32 n = 0;
            if (!SDL_LoadWAV(e.path().u8string().c_str(), &spec, &buf, &n)) continue;
            Take t{spec, std::vector<uint8_t>(buf, buf + n)};
            SDL_free(buf);
            // "shutter-125" is at 1/125, "shutter-0.5" half a second.
            if (stem.rfind("shutter-", 0) == 0 && stem.rfind("shutter-change", 0) != 0) {
                std::string tok = stem.substr(8);
                tok = tok.substr(0, tok.find('-'));
                float v = std::strtof(tok.c_str(), nullptr);
                if (v > 0) { shutterAt[tok.find('.') != std::string::npos || v <= 1 ? v : 1 / v].push_back(std::move(t)); continue; }
            }
            std::string event = stem;
            for (const char* name : {"film-advance", "film-change", "lens-change", "shutter-change", "iris-click"})
                if (stem.rfind(name, 0) == 0) event = name;
            takes[event].push_back(std::move(t));
        }
    }
    void tidy() {
        for (size_t i = 0; i < playing.size();)
            if (SDL_GetAudioStreamQueued(playing[i]) <= 0) { SDL_DestroyAudioStream(playing[i]); playing.erase(playing.begin() + i); }
            else i++;
    }
    void play(const Take& t, float volume = 1) {
        if (!enabled || !dev) return;
        SDL_AudioStream* s = SDL_CreateAudioStream(&t.spec, nullptr);
        if (!s) return;
        SDL_BindAudioStream(dev, s);
        SDL_SetAudioStreamGain(s, volume * (0.88f + 0.12f * float(rand()) / RAND_MAX));
        SDL_PutAudioStreamData(s, t.data.data(), int(t.data.size()));
        SDL_FlushAudioStream(s);
        playing.push_back(s);
    }
    void play(const std::string& event, float volume = 1) {
        auto it = takes.find(event);
        if (it == takes.end() || it->second.empty()) return;
        play(it->second[size_t(rand()) % it->second.size()], volume);
    }
    void shutter(float seconds) {
        if (shutterAt.empty()) return;
        auto best = shutterAt.begin();
        for (auto it = shutterAt.begin(); it != shutterAt.end(); ++it)
            if (std::fabs(std::log2(it->first / seconds)) < std::fabs(std::log2(best->first / seconds))) best = it;
        play(best->second[size_t(rand()) % best->second.size()]);
    }
};

// ---------------------------------------------------------------------------
// The render thread: the only one that talks to the renderer. It renders the
// finder's next frame and, between them, the next sub-pupil of a photo.

/// A sky for scans whose own sky was cut away (SkySetting in Sky.swift): an
/// equirectangular .hdr shown wherever the scan leaves the view empty, turned
/// and brightened to suit. Remembered with each scan.
struct SkySetting {
    std::string path;          // empty: the scan's own
    float yawDegrees = 0, stops = 0;
    std::string name() const { return fs::u8path(path).filename().u8string(); }
};

struct FinderJob {
    std::vector<float> view;
    float fx = 1; V2 axis;
    int W = 0, H = 0;
    std::vector<V4> lens;           // empty: pinhole
    bool fisheye = false;
    bool smooth = true;             // render sharp, blur in image space (dof_* kernels)
    float metresPerUnit = 1;
    LightingPlot plot;              // the lights, for the relight
    int fromLight = -1;             // seen from this light (-1: from the camera)
    SkySetting sky;
    V3 position;                    // the camera, for the relight's view
    CameraBody body;
    Optics optics;
    bool shells = false;            // far splats may come from the baked shells (a place, Menu > Settings)
    float shellRadius = 0;          // the near region's radius, scene units
};

struct Exposure {
    CameraBody body;
    FlyCamera camera;
    int W = 0, H = 0, tileW = 0, tileH = 0;
    std::vector<V2> cells;
    size_t next = 0;
    std::vector<V4> acc;            // accumulated light and weight per pixel (CPU path)
    SDL_GPUBuffer* gacc = nullptr;  // the same on the GPU (W*H float4)
    LightingPlot plot;              // the lights it was taken under
    std::vector<V4> flare;          // the flare rows at the shutter (empty: none)
    float filterThreshold = 1;      // how bright a point must be for the filter's spikes or halo
    SkySetting sky;
    int frameNumber = 0;
    fs::path out;
    bool done = false;
    std::time_t shotAt = std::time(nullptr);
    bool proof = false;             // a proof at the shutter: the finder's size, few lens samples
    bool wantsNegative = false;     // keep a digital negative (DNG) beside the print
    /// A movie frame: where the camera is through the shutter's opening (0 open ...
    /// 1 closed). Each sub-pupil is also a moment, so the frame blurs with the move.
    std::function<FlyCamera(float)> cameraAt;
    /// A movie frame's print (RGBA), handed over on the render thread instead of a
    /// file; an empty one when it couldn't be developed.
    std::function<void(std::vector<uint32_t>&)> sink;
    /// The same print as display-referred floats (develop16), for a 10-bit movie; empty when it failed.
    std::function<void(std::vector<float>&)> sinkFloat;
    /// The moment through the shutter's opening sub-pupil `k` stands for: spread
    /// evenly over it, in an order unrelated to the lens rings.
    float shutterTime(size_t k) const { float v = float(k) * 0.618034f + 0.5f / float(cells.size()); return v - std::floor(v); }
    FlyCamera cameraFor(size_t k) const { return cameraAt ? cameraAt(shutterTime(k)) : camera; }
};

struct Renderer {
    std::mutex m;
    std::condition_variable cv;
    std::thread thread;
    bool quit = false;
    std::unique_ptr<FinderJob> request;
    std::shared_ptr<Frame> latest;          // the newest finder frame
    std::shared_ptr<FinderJob> latestJob;
    std::deque<std::shared_ptr<Exposure>> darkroom;
    std::atomic<int> developedCount{0};
    std::string error;

    void start() { thread = std::thread([this] { loop(); }); }
    void stop() {
        { std::lock_guard<std::mutex> l(m); quit = true; }
        cv.notify_all();
        if (thread.joinable()) thread.join();
    }
    void ask(FinderJob j) {
        { std::lock_guard<std::mutex> l(m); request = std::make_unique<FinderJob>(std::move(j)); }
        cv.notify_all();
    }
    void expose(std::shared_ptr<Exposure> e) {
        { std::lock_guard<std::mutex> l(m); darkroom.push_back(std::move(e)); }
        cv.notify_all();
    }
    int pending() { std::lock_guard<std::mutex> l(m); return int(darkroom.size()); }

    static bool render(Frame& f, const std::vector<float>& view, float fx, float cx, float cy, int W, int H) {
        f.w = W; f.h = H;
        f.rgb.resize(size_t(W) * H * 3); f.T.resize(size_t(W) * H); f.z.resize(size_t(W) * H);
        std::vector<float> alpha(size_t(W) * H), depth(size_t(W) * H);
        if (sr::render_ex(view.data(), fx, fx, cx, cy, W, H, "3dgs", f.rgb.data(), alpha.data(), depth.data(), f.z.data()) != 0) return false;
        for (size_t i = 0; i < alpha.size(); i++) f.T[i] = 1 - alpha[i];
        return true;
    }
    static void setLens(const std::vector<V4>& p) {
        if (p.empty()) sr::set_lens(nullptr, 0);
        else sr::set_lens(reinterpret_cast<const float*>(p.data()), int(p.size()));
    }

    void loop() {
        for (;;) {
            std::unique_ptr<FinderJob> job;
            std::shared_ptr<Exposure> ex;
            {
                std::unique_lock<std::mutex> l(m);
                cv.wait(l, [&] { return quit || request || !darkroom.empty(); });
                if (quit) return;
                job = std::move(request);
                if (!darkroom.empty()) ex = darkroom.front();
            }
            if (job) {
                if (gpu) setSky(job->sky);
                relight(job->plot, job->position, job->body, 0);
                // Smooth (renderFinder in RenderLoop.swift): rendered sharp, blurred afterwards in image space.
                bool dof = gpu && job->smooth && !job->fisheye && !job->lens.empty();
                setLens(dof ? std::vector<V4>{} : job->lens);
                sr::set_camera_model(job->fisheye ? "FISHEYE" : "PINHOLE");
                // Distant shells: while the view moves (turning, focusing) only the near splats are
                // drawn live and the far ones come from the bake; held still, everything is drawn.
                bool still = noteStillness(*job);
                bool useShells = gpu && sr::set_region && !still && shellsUsable(*job);
                if (useShells) sr::set_region(shellCentre.x, shellCentre.y, shellCentre.z, shellRadiusBaked);
                auto f = std::make_shared<Frame>();
                Uint64 tr0 = SDL_GetTicksNS();
                bool ok = render(*f, job->view, job->fx, job->axis.x, job->axis.y, job->W, job->H);
                if (std::getenv("VC_TIMING")) fprintf(stderr, "  render %.1f ms%s\n", (SDL_GetTicksNS() - tr0) / 1e6, useShells ? " (shells)" : "");
                if (useShells) sr::set_region(0, 0, 0, 0);
                sr::set_camera_model("PINHOLE");
                int slot = -1;
                if (ok && gpu) {
                    slot = (latestSlot + 1) % 3;
                    // The finder shows the sky at infinity as blurred as the lens would:
                    // a smaller copy, by the blur circle's size in the sky's texels.
                    const Lens& l = job->body.lens();
                    float fm = l.focalMM / 1000, s = std::max(job->body.focusM, fm * 1.01f);
                    float texels = fm * float(skyWidth) / (2 * float(M_PI) * job->body.viewingAperture() * (s - fm));
                    std::array<V4, 44> fogRows;
                    bool fog = !job->plot.fog.empty();
                    if (fog) fogRows = job->plot.fog.rows(job->position, job->plot.up, job->metresPerUnit, job->plot.fogLight());
                    bool ready = uploadFinder(slot, *f) &&
                                 (job->fromLight >= 0 || encodeBackground(gfinder[slot], job->W, job->H, job->view, job->fx, job->axis.x,
                                                                          job->axis.y, job->fisheye, job->plot.up,
                                                                          dof ? 0.f : std::log2(std::max(1.f, texels)), fog ? &fogRows : nullptr, 0,
                                                                          useShells ? job.get() : nullptr, dof)) &&
                                 (!dof || blurFinder(slot, *job));
                    if (!ready) slot = -1;
                }
                // Held still with no usable bake: bake the shells now, for the next move.
                if (ok && gpu && sr::set_region && still && job->shells && job->fromLight < 0 && !job->fisheye && !shellsUsable(*job)) bakeShells(*job);
                std::lock_guard<std::mutex> l(m);
                if (ok) { latest = f; latestJob = std::shared_ptr<FinderJob>(std::move(job)); latestSlot = slot; }
                else error = sr::last_error();
            }
            if (ex) {
                step(*ex);
                if (ex->done) {
                    std::lock_guard<std::mutex> l(m);
                    darkroom.pop_front();
                    developedCount++;
                }
            }
        }
    }

    // ---- the GPU finder (renderFinder and encodeDOF in RenderLoop.swift) ----
    // Three frames: the render thread fills the one after the latest, so the
    // one on show (at most one behind) is never written while it is read.
    SDL_GPUBuffer* gfinder[3] = {};
    int finderSize[2] = {0, 0};
    int latestSlot = -1;                       // the latest frame's GPU copy (-1: none)
    SDL_GPUTexture* dofCol = nullptr;
    SDL_GPUTexture* dofDep = nullptr;
    SDL_GPUBuffer* dofTiles = nullptr;
    int dofLevels = 1;

    bool uploadFinder(int slot, const Frame& f) {
        size_t np = size_t(f.w) * f.h;
        if (finderSize[0] != f.w || finderSize[1] != f.h) {
            for (auto& b : gfinder) gpu->release(b);
            gpu->release(dofCol); gpu->release(dofDep); gpu->release(dofTiles);
            finderSize[0] = f.w; finderSize[1] = f.h;
        }
        if (!gfinder[slot] && !(gfinder[slot] = gpu->buffer(np * 5 * sizeof(float)))) return false;
        std::vector<float> packed(np * 5);
        std::memcpy(packed.data(), f.rgb.data(), np * 3 * sizeof(float));
        std::memcpy(packed.data() + 3 * np, f.T.data(), np * sizeof(float));
        std::memcpy(packed.data() + 4 * np, f.z.data(), np * sizeof(float));
        return gpu->upload(gfinder[slot], packed.data(), packed.size() * sizeof(float));
    }
    /// 48 equal-area points over the unit disc (RenderLoop.dofSamples).
    static const std::array<V4, 48>& dofSamples() {
        static std::array<V4, 48> s = [] {
            std::array<V4, 48> a{};
            for (int j = 0; j < 48; j++) { V2 v = vogel(j, 48); a[j] = {v.x, v.y, 0, 0}; }
            return a;
        }();
        return s;
    }
    /// Blurs the sharp finder frame as the lens (job.lens) would.
    bool blurFinder(int slot, const FinderJob& job) {
        int W = job.W, H = job.H;
        if (!dofCol) {
            dofLevels = 1;
            for (int s = std::max(W, H); s > 1; s /= 2) dofLevels++;
            dofCol = gpu->texture(W, H, SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT, dofLevels);
            dofDep = gpu->texture(W, H, SDL_GPU_TEXTUREFORMAT_R32_FLOAT, 1);
            dofTiles = gpu->buffer(size_t((W + 15) / 16) * ((H + 15) / 16) * 4);
        }
        if (!dofCol || !dofDep || !dofTiles) return false;
        std::array<V4, 48> D{};
        D[0] = {float(W), float(H), job.fx, job.fx * 0.25f};
        D[1] = {job.axis.x, job.axis.y, job.metresPerUnit, float(job.lens.size())};
        D[2] = {float(CameraBody::tableSize), float(dofLevels), 0, 0};
        for (size_t i = 0; i < job.lens.size() && i + 3 < D.size(); i++) D[3 + i] = job.lens[i];
        const auto& G = dofSamples();
        Gpu::Uniform d{D.data(), sizeof D};
        return gpu->run(kernels.dofPack, {gfinder[slot]}, {}, {d}, W, H, {}, {dofCol, dofDep}) &&
               gpu->mipmaps(dofCol) &&
               gpu->run(kernels.dofTiles, {}, {dofTiles}, {d}, (W + 15) / 16, (H + 15) / 16, {dofDep}) &&
               gpu->run(kernels.dofBlur, {dofTiles}, {gfinder[slot]}, {d, {G.data(), sizeof G}}, W, H, {dofCol, dofDep});
    }

    // ---- what lies behind the scan (encodeBackground / SkyTexture in the Swift app) ----
    static inline SkySetting sky;                  // the sky loaded (path empty: none)
    static inline SDL_GPUTexture* skyTex = nullptr;
    static inline float skyLevel = 1;              // puts the sky's middle brightness where a scan's sky sits
    static inline int skyWidth = 1;
    static inline SDL_GPUTexture* blankTex = nullptr;

    /// Loads (or clears) the sky; a no-op when it is already this one.
    static void setSky(const SkySetting& s) {
        if (s.path != sky.path) {
            gpu->release(skyTex);
            sky.path.clear();
            if (!s.path.empty() && loadSky(s.path)) sky.path = s.path;
        }
        sky.yawDegrees = s.yawDegrees; sky.stops = s.stops;
    }
    static bool loadSky(const std::string& path) {
        int iw, ih, n;
        float* src = stbi_loadf(path.c_str(), &iw, &ih, &n, 3);
        if (!src) return false;
        int w = std::min(iw, 4096), h = std::max(1, w / 2);
        // Resampled to w x h (an equirectangular 2:1), bilinear.
        std::vector<float> px(size_t(w) * h * 3);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                float sx = (x + 0.5f) * iw / w - 0.5f, sy = (y + 0.5f) * ih / h - 0.5f;
                int x0 = std::clamp(int(std::floor(sx)), 0, iw - 1), y0 = std::clamp(int(std::floor(sy)), 0, ih - 1);
                int x1 = std::min(x0 + 1, iw - 1), y1 = std::min(y0 + 1, ih - 1);
                float fx = std::clamp(sx - x0, 0.f, 1.f), fy = std::clamp(sy - y0, 0.f, 1.f);
                for (int c = 0; c < 3; c++) {
                    float a = src[(size_t(y0) * iw + x0) * 3 + c], b = src[(size_t(y0) * iw + x1) * 3 + c];
                    float cc = src[(size_t(y1) * iw + x0) * 3 + c], d = src[(size_t(y1) * iw + x1) * 3 + c];
                    px[(size_t(y) * w + x) * 3 + c] = (a + (b - a) * fx) * (1 - fy) + (cc + (d - cc) * fx) * fy;
                }
            }
        stbi_image_free(src);
        // The upper half's median brightness.
        std::vector<float> lums;
        for (int y = 0; y < h / 2; y += 4)
            for (int x = 0; x < w; x += 4) {
                size_t i = (size_t(y) * w + x) * 3;
                lums.push_back(0.2126f * px[i] + 0.7152f * px[i + 1] + 0.0722f * px[i + 2]);
            }
        std::sort(lums.begin(), lums.end());
        float median = lums.empty() ? 1 : std::max(lums[lums.size() / 2], 1e-4f);
        std::vector<uint16_t> half(size_t(w) * h * 4);
        for (size_t i = 0; i < size_t(w) * h; i++) {
            half[4 * i] = toHalf(std::max(px[3 * i], 0.f)); half[4 * i + 1] = toHalf(std::max(px[3 * i + 1], 0.f));
            half[4 * i + 2] = toHalf(std::max(px[3 * i + 2], 0.f)); half[4 * i + 3] = toHalf(1);
        }
        int levels = 1;
        for (int s = std::max(w, h); s > 1; s /= 2) levels++;
        skyTex = gpu->texture(w, h, SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT, levels);
        if (!skyTex || !gpu->uploadTexture(skyTex, half.data(), w, h, 8) || !gpu->mipmaps(skyTex)) { gpu->release(skyTex); return false; }
        skyLevel = 0.75f / median;
        skyWidth = w;
        return true;
    }
    /// 32 equal-area points over +-2.5 sigma, weighted by a unit Gaussian (RenderLoop.gaussSamples).
    static const std::array<V4, 32>& gaussSamples() {
        static std::array<V4, 32> s = [] {
            std::array<V4, 32> a{};
            for (int j = 0; j < 32; j++) { V2 v = vogel(j, 32) * 2.5f; a[j] = {v.x, v.y, std::exp(-0.5f * (v.x * v.x + v.y * v.y)), 0}; }
            return a;
        }();
        return s;
    }
    /// Fills the empty part of a rendered frame with the sky or the background
    /// (and, to come, the distant shells and the fog), as encodeBackground does.
    static bool encodeBackground(SDL_GPUBuffer* frame, int w, int h, const std::vector<float>& V, float fx, float cx, float cy,
                                 bool fisheye, V3 up, float mip, const std::array<V4, 44>* fog = nullptr, float fogSeed = 0,
                                 const FinderJob* shells = nullptr, bool sharpShells = true) {
        // Nothing to fill with and no fog: frame_rgb and accumulate add the background.
        if (!skyTex && !fog && !shells) return true;
        if (!blankTex) {
            blankTex = gpu->texture(1, 1, SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT, 1);
            uint16_t z[4] = {0, 0, 0, 0};
            if (blankTex) gpu->uploadTexture(blankTex, z, 1, 1, 8);
        }
        std::array<V4, 100> K{};
        K[0] = {float(w), float(h), fx, fx};
        K[1] = {cx, cy, fisheye ? 1.f : 0.f, mip};
        K[2] = {V[0], V[1], V[2], 0}; K[3] = {V[4], V[5], V[6], 0}; K[4] = {V[8], V[9], V[10], 0};
        K[5] = {up.x, up.y, up.z, sky.yawDegrees * float(M_PI) / 180};
        K[6] = {skyLevel * std::exp2(sky.stops), sceneIsPlace ? 1.f : 0.f, skyTex ? 1.f : 0.f, 0};
        K[7] = {0.08f, 0.08f, 0.09f, 0};
        K[28] = {0, 0, float(CameraBody::tableSize), 0};
        for (int j = 0; j < 32; j++) K[29 + j] = gaussSamples()[j];
        if (shells) {
            // The shells: where the camera stands from the bake, the lens's blur, the window baked.
            const FinderJob& j = *shells;
            V3 rel = j.position - shellCentre;
            K[6].w = 1;
            K[8] = {rel.x, rel.y, rel.z, shellRadiusBaked};
            K[9] = {j.body.lens().focalMM / 1000 / j.body.viewingAperture(), j.body.focusM, j.metresPerUnit, 0};
            K[10] = {shellWin.r.x, shellWin.r.y, shellWin.r.z, shellWin.fx / shellWin.w};
            K[11] = {shellWin.d.x, shellWin.d.y, shellWin.d.z, shellWin.fx / shellWin.h};
            K[12] = {shellWin.f.x, shellWin.f.y, shellWin.f.z, 0};
            K[13] = {shellWin.cx / shellWin.w, shellWin.cy / shellWin.h, 0, 0};
            // Filled sharp when the finder blurs afterwards (smooth); else blurred here, as the lens would.
            size_t rows = sharpShells ? 0 : std::min<size_t>(j.lens.size(), K.size() - 61);
            K[28] = {j.fx * 0.25f, float(rows), float(CameraBody::tableSize), 0};
            for (size_t r = 0; r < rows; r++) K[61 + r] = j.lens[r];
        }
        static const std::array<V4, 44> noFog{};
        const std::array<V4, 44>& G = fog ? *fog : noFog;
        // The lamps it scatters (the last relight's rows and beam tables, the finder's
        // shadow maps and their views): beams and shafts in the fog, cut by what stands in the light.
        if (!blankBuf) blankBuf = gpu->buffer(16);
        if (!blankArray) {
            SDL_GPUTextureCreateInfo ci{};
            ci.type = SDL_GPU_TEXTURETYPE_2D_ARRAY; ci.format = SDL_GPU_TEXTUREFORMAT_R8_UNORM;
            ci.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
            ci.width = ci.height = 1; ci.layer_count_or_depth = 1; ci.num_levels = 1;
            blankArray = SDL_CreateGPUTexture(gpu->dev, &ci);
        }
        int nl = fog && gFogBeams ? fogLampCount : 0;
        std::array<V4, 41> SV{};
        SDL_GPUBuffer* maps = nl > 0 && fogLampShadows ? shaftMaps(nl) : nullptr;
        if (maps) {
            auto& slots = shadowSlots[0];
            for (int k = 0; k < nl && k < int(slots.size()); k++)
                if (slots[k].map) for (int r = 0; r < 5; r++) SV[5 * k + r] = slots[k].view[r];
        }
        SV[40] = {float(nl), maps ? 1.f : 0.f, 0.55f, fogSeed};
        return gpu->run(kernels.backgroundFill, {nl > 0 ? gFogBeams : blankBuf, maps ? maps : blankBuf}, {frame},
                        {{K.data(), sizeof K}, {G.data(), sizeof G}, {fogLamps.data(), sizeof fogLamps}, {SV.data(), sizeof SV}}, w, h,
                        {skyTex ? skyTex : blankTex, shells ? shellCol : blankTex, shells ? shellDep : blankTex, gPatterns ? gPatterns : blankArray}, {},
                        {gpu->skySampler(), nullptr, nullptr, nullptr});
    }
    // ---- distant shells (RenderLoop.swift) ----
    // In a place, the splats beyond the near radius are baked (once the view is still) into a
    // window: the view widened by a margin, colour and distance, at the finder's pixel density.
    // While the camera stays put and looks within it, the finder draws only the near splats live
    // and fills the rest from it; a step, a wider turn or a lighting change draws everything until
    // the view is still again. Prints never use it.
    static constexpr float shellMargin = 1.5f, shellSettle = 0.35f;
    struct ShellWindow { V3 r, d, f; float fx = 1, cx = 0, cy = 0; int w = 1, h = 1; };
    static inline SDL_GPUTexture *shellCol = nullptr, *shellDep = nullptr;
    static inline SDL_GPUBuffer* shellFrame = nullptr;
    static inline bool shellBaked = false;
    static inline V3 shellCentre;
    static inline float shellRadiusBaked = 0;
    static inline std::vector<V4> shellLightKey;
    static inline ShellWindow shellWin;
    static inline std::vector<float> stillKey;
    static inline double lastChange = 0;
    /// The relight's key without the eye: the lights themselves.
    static std::vector<V4> lightKey() {
        std::vector<V4> k = lastRelight;
        if (!k.empty()) { k[0].x = k[0].y = k[0].z = 0; }
        return k;
    }
    /// Whether the view (where it looks, focus, aperture) has held still a moment.
    static bool noteStillness(const FinderJob& j) {
        std::vector<float> key(j.view.begin(), j.view.end());
        key.insert(key.end(), {j.fx, j.body.focusM, j.body.viewingAperture(), float(j.body.lensIndex), float(j.fromLight)});
        double now = SDL_GetTicks() / 1000.0;
        if (key != stillKey) { stillKey = key; lastChange = now; }
        return now - lastChange >= shellSettle;
    }
    /// Whether this view can use the shells as baked: near where they were baked (a step of d
    /// moves something at the near radius by fx d / R pixels), the lights unchanged, the frame inside.
    static bool shellsUsable(const FinderJob& j) {
        if (!shellBaked || !j.shells || j.fisheye || j.fromLight >= 0 || j.shellRadius != shellRadiusBaked) return false;
        if (len(j.position - shellCentre) > 1.5f * shellRadiusBaked / std::max(j.fx, 1.f)) return false;
        std::vector<V4> k = lightKey();
        if (k.size() != shellLightKey.size() || (!k.empty() && std::memcmp(k.data(), shellLightKey.data(), k.size() * sizeof(V4)) != 0)) return false;
        const auto& V = j.view;
        float hw = j.W / 2.f / j.fx * 1.05f, hh = j.H / 2.f / j.fx * 1.05f;
        V3 r{V[0], V[1], V[2]}, d{V[4], V[5], V[6]}, f{V[8], V[9], V[10]};
        for (float sx : {-hw, hw})
            for (float sy : {-hh, hh}) {
                V3 u = norm(f + r * sx + d * sy);
                float z = dot(u, shellWin.f);
                if (z <= 0) return false;
                float x = dot(u, shellWin.r) / z * shellWin.fx + shellWin.cx, y = dot(u, shellWin.d) / z * shellWin.fx + shellWin.cy;
                if (x < 0 || y < 0 || x > shellWin.w || y > shellWin.h) return false;
            }
        return true;
    }
    /// The far splats, drawn from here into the shells' window (colour and distance, with mips for the blur).
    static void bakeShells(const FinderJob& j) {
        int W = int(j.W * shellMargin), H = int(j.H * shellMargin);
        if (!shellCol) {
            int levels = 1;
            for (int s2 = std::max(W, H); s2 > 1; s2 /= 2) levels++;
            shellCol = gpu->texture(W, H, SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT, levels);
            shellDep = gpu->texture(W, H, SDL_GPU_TEXTUREFORMAT_R32_FLOAT, 1);
            shellFrame = gpu->buffer(size_t(W) * H * 5 * sizeof(float));
        }
        if (!shellCol || !shellDep || !shellFrame) return;
        Uint64 t0 = SDL_GetTicksNS();
        setLens({});
        sr::set_camera_model("PINHOLE");
        sr::set_region(j.position.x, j.position.y, j.position.z, -j.shellRadius);
        Frame f;
        float cx = W / 2.f, cy = H / 2.f;
        bool ok = render(f, j.view, j.fx, cx, cy, W, H);
        sr::set_region(0, 0, 0, 0);
        if (!ok) return;
        size_t np = size_t(W) * H;
        std::vector<float> packed(np * 5);
        std::memcpy(packed.data(), f.rgb.data(), np * 12);
        std::memcpy(packed.data() + 3 * np, f.T.data(), np * 4);
        std::memcpy(packed.data() + 4 * np, f.z.data(), np * 4);
        std::array<V4, 2> B = {V4{float(W), float(H), j.fx, sceneIsPlace ? 1.f : 0.f}, V4{cx, cy, 0, 0}};
        if (!gpu->upload(shellFrame, packed.data(), packed.size() * 4) ||
            !gpu->run(kernels.shellStore, {shellFrame}, {}, {{B.data(), sizeof B}}, W, H, {}, {shellCol, shellDep}) || !gpu->mipmaps(shellCol))
            return;
        const auto& V = j.view;
        shellWin = {V3{V[0], V[1], V[2]}, V3{V[4], V[5], V[6]}, V3{V[8], V[9], V[10]}, j.fx, cx, cy, W, H};
        shellCentre = j.position;
        shellRadiusBaked = j.shellRadius;
        shellLightKey = lightKey();
        shellBaked = true;
        if (std::getenv("VC_TIMING"))
            fprintf(stderr, "Distant shells baked in %.0f ms (near radius %.1f m)\n", (SDL_GetTicksNS() - t0) / 1e6, j.shellRadius * j.metresPerUnit);
    }

    // The lamps as the last relight packed them, for the fog to scatter (lampRows in RenderLoop.swift).
    static inline std::array<V4, 48> fogLamps{};
    static inline int fogLampCount = 0;
    static inline bool fogLampShadows = false;
    static inline SDL_GPUBuffer* gFogBeams = nullptr;
    static inline size_t fogBeamBytes = 0;
    static inline SDL_GPUBuffer* blankBuf = nullptr;
    static inline SDL_GPUTexture* blankArray = nullptr;
    // The finder's shadow maps side by side (the kernel takes one buffer of them), copied when they change.
    static inline SDL_GPUBuffer* gShaftMaps = nullptr;
    static inline size_t shaftBytes = 0;
    static inline int shaftVersion = -1, shaftCount = 0;
    static SDL_GPUBuffer* shaftMaps(int nl) {
        auto& slots = shadowSlots[0];
        if (slots.empty()) return nullptr;
        size_t per = size_t(512) * 512 * 5 * 4, need = per * size_t(nl);
        if (gShaftMaps && shaftVersion == shadowVersion && shaftCount == nl) return gShaftMaps;
        if (!gShaftMaps || shaftBytes < need) {
            gpu->release(gShaftMaps);
            gShaftMaps = gpu->buffer(need);
            shaftBytes = gShaftMaps ? need : 0;
            if (!gShaftMaps) return nullptr;
        }
        for (int k = 0; k < nl && k < int(slots.size()); k++)
            if (slots[k].map && !gpu->copy(slots[k].map, 0, gShaftMaps, Uint32(per * k), Uint32(per))) return nullptr;
        shaftVersion = shadowVersion;
        shaftCount = nl;
        return gShaftMaps;
    }

    // ---- lighting: relight and shadows (relight / prepareShadows in RenderLoop.swift) ----
    static constexpr int maxLights = 8;
    static inline const Scan* scan = nullptr;      // the open scan (its own colours, for the relight)
    static inline bool shadowsOn = true;
    static inline bool daylightScan = false;       // a place: scanned in its own light, not from the camera
    static inline SDL_GPUBuffer *gMeans = nullptr, *gDc0 = nullptr, *gSh0 = nullptr, *gOutDc = nullptr, *gVis = nullptr;
    static inline SDL_GPUTexture* gPatterns = nullptr;
    static inline std::vector<V4> lastRelight;
    static inline bool relit = false;              // the renderer holds relit colours (drawn at degree 0)
    static inline std::vector<float> relitDc;
    struct ShadowSlot { SDL_GPUBuffer* map = nullptr; std::vector<V4> key; std::array<V4, 5> view{}; };
    static inline std::vector<ShadowSlot> shadowSlots[2];   // finder (512), photo (1536)
    static inline int shadowVersion = 0;

    /// Forget the scan's GPU copies (a new scan is loading; the render thread is stopped).
    static void dropScan() {
        shellBaked = false;
        if (gpu) {
            gpu->release(gMeans); gpu->release(gDc0); gpu->release(gSh0); gpu->release(gOutDc); gpu->release(gVis);
            for (auto& q : shadowSlots) for (auto& s : q) gpu->release(s.map);
        }
        for (auto& q : shadowSlots) q.clear();
        lastRelight.clear();
        if (relit) sr::set_render_degree(-1);
        relit = false;
    }
    static uint16_t toHalf(float f) {
        uint32_t x; std::memcpy(&x, &f, 4);
        uint32_t sign = (x >> 16) & 0x8000, e = (x >> 23) & 0xff, m = x & 0x7fffff;
        if (e == 255) return uint16_t(sign | 0x7c00 | (m ? 0x200 : 0));
        int ee = int(e) - 127 + 15;
        if (ee >= 31) return uint16_t(sign | 0x7c00);
        if (ee <= 0) {
            if (ee < -10) return uint16_t(sign);
            m |= 0x800000;
            uint32_t sh = uint32_t(14 - ee);
            uint32_t hm = m >> sh;
            if ((m >> (sh - 1)) & 1) hm++;
            return uint16_t(sign | hm);
        }
        uint32_t h = sign | (uint32_t(ee) << 10) | (m >> 13);
        if (m & 0x1000) h++;
        return uint16_t(h);
    }
    /// The scan's own colours and positions on the GPU, made the first time a relight needs them.
    static bool scanOnGpu() {
        if (gMeans) return true;
        size_t N = size_t(scan->count), K = size_t((scan->shDegree + 1) * (scan->shDegree + 1) - 1);
        gMeans = gpu->buffer(N * 3 * 4); gDc0 = gpu->buffer(N * 3 * 4); gOutDc = gpu->buffer(N * 3 * 4);
        gVis = gpu->buffer(N * 2 * 4);
        std::vector<uint16_t> half(std::max<size_t>(N * K * 3, 2) + 1, 0);
        for (size_t i = 0; i < N * K * 3 && i < scan->sh.size(); i++) half[i] = toHalf(scan->sh[i]);
        if (half.size() % 2) half.push_back(0);
        gSh0 = gpu->buffer(half.size() * 2);
        if (!gMeans || !gDc0 || !gOutDc || !gVis || !gSh0) return false;
        std::vector<uint32_t> ones(N * 2, 0xffffffffu);
        bool ok = gpu->upload(gMeans, scan->means.data(), N * 12) && gpu->upload(gDc0, scan->dc.data(), N * 12) &&
                  gpu->upload(gSh0, half.data(), half.size() * 2) && gpu->upload(gVis, ones.data(), ones.size() * 4);
        if (ok && !gPatterns) {
            auto px = pattern_art::make();
            int levels = 9;
            SDL_GPUTextureCreateInfo ci{};
            ci.type = SDL_GPU_TEXTURETYPE_2D_ARRAY; ci.format = SDL_GPU_TEXTUREFORMAT_R8_UNORM;
            ci.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER | SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
            ci.width = ci.height = pattern_art::size; ci.layer_count_or_depth = 8; ci.num_levels = Uint32(levels);
            gPatterns = SDL_CreateGPUTexture(gpu->dev, &ci);
            if (gPatterns) {
                std::lock_guard<std::recursive_mutex> l(gpu->m);
                SDL_GPUTransferBuffer* t = gpu->staging(true, px.size());
                void* p = SDL_MapGPUTransferBuffer(gpu->dev, t, false);
                std::memcpy(p, px.data(), px.size());
                SDL_UnmapGPUTransferBuffer(gpu->dev, t);
                SDL_GPUCommandBuffer* cb = SDL_AcquireGPUCommandBuffer(gpu->dev);
                SDL_GPUCopyPass* cp = SDL_BeginGPUCopyPass(cb);
                size_t layer = size_t(pattern_art::size) * pattern_art::size;
                for (Uint32 k = 0; k < 8; k++) {
                    SDL_GPUTextureTransferInfo src{t, Uint32(k * layer), Uint32(pattern_art::size), Uint32(pattern_art::size)};
                    SDL_GPUTextureRegion dst{};
                    dst.texture = gPatterns; dst.layer = k; dst.w = dst.h = pattern_art::size; dst.d = 1;
                    SDL_UploadToGPUTexture(cp, &src, &dst, false);
                }
                SDL_EndGPUCopyPass(cp);
                SDL_GenerateMipmapsForGPUTexture(cb, gPatterns);
                gpu->finish(cb);
            }
        }
        return ok && gPatterns;
    }

    /// Brings each light's shadow map and the splats' visibility up to date
    /// for this lighting (only lights that moved, turned or changed beam).
    static bool prepareShadows(const LightingPlot& plot, const CameraBody& body, int q) {
        int res = q == 0 ? 512 : 1536;
        V3 taps = q == 0 ? V3{8, 12, 10} : V3{24, 48, 48};
        auto& slots = shadowSlots[q];
        for (int slot = 0; slot < int(plot.lights.size()) && slot < maxLights; slot++) {
            const PlacedLight& light = plot.lights[slot];
            std::vector<V4> key = {{light.position.x, light.position.y, light.position.z, light.spot},
                                   {light.aim.x, light.aim.y, light.aim.z, float(light.head)},
                                   {plot.up.x, plot.up.y, plot.up.z, body.metresPerUnit}};
            while (int(slots.size()) <= slot) slots.push_back({});
            ShadowSlot& s = slots[slot];
            if (s.key.size() == key.size() && std::memcmp(s.key.data(), key.data(), key.size() * sizeof(V4)) == 0) continue;
            if (!s.map && !(s.map = gpu->buffer(size_t(res) * res * 5 * 4))) return false;
            // The view from the head, wide enough for the beam's field.
            FlyCamera cam;
            cam.up = plot.up;
            cam.lookAt(light.position + light.aim, light.position);
            float field = std::min(light.beam().angle(0.1f) * 1.15f, 120.f) * float(M_PI) / 360;
            float fx = float(res) / 2 / std::tan(field);
            setLens({});
            sr::set_camera_model("PINHOLE");
            Frame f;
            std::vector<float> V = cam.viewMatrix();
            if (!render(f, V, fx, res / 2.f, res / 2.f, res, res)) return false;
            size_t np = size_t(res) * res;
            std::vector<float> packed(np * 5);
            std::memcpy(packed.data(), f.rgb.data(), np * 12);
            std::memcpy(packed.data() + 3 * np, f.T.data(), np * 4);
            std::memcpy(packed.data() + 4 * np, f.z.data(), np * 4);
            if (!gpu->upload(s.map, packed.data(), packed.size() * 4)) return false;
            const LightHead& kit = light.kit();
            float lensR = kit.kind == LightHead::Kind::Softlight ? 0.27f : kit.kind == LightHead::Kind::Ellipsoidal ? 0.06f
                                                                                                            : photometry::optics(kit).lensR;
            float source = lensR / body.metresPerUnit;
            s.view = {V4{V[0], V[1], V[2], V[3]}, V4{V[4], V[5], V[6], V[7]}, V4{V[8], V[9], V[10], V[11]},
                      V4{fx, float(res), body.metresPerUnit, source}, V4{taps.x, taps.y, taps.z, float(slot)}};
            uint32_t n[4] = {uint32_t(scan->count), 0, 0, 0};
            if (!gpu->run(kernels.shadowVis, {gMeans, s.map}, {gVis}, {{s.view.data(), sizeof s.view}, {n, sizeof n}}, Uint32(scan->count)))
                return false;
            s.key = key;
            shadowVersion++;
        }
        return true;
    }

    /// The relit colours for this lighting, seen from `eye`, into the renderer
    /// (skipped when nothing changed). Without lights in full house light the
    /// relight is the scan's own colour: the renderer then draws it as loaded.
    static void relight(const LightingPlot& plot, V3 eye, const CameraBody& body, int quality) {
        if (!gpu || !scan || !scan->count) return;
        bool neutral = plot.lights.empty() && plot.ambient == 1 && plot.ambientTint.x == 1 && plot.ambientTint.y == 1 &&
                       plot.ambientTint.z == 1;
        if (neutral) {
            fogLampCount = 0;
            if (relit) { sr::set_colors(scan->dc.data(), nullptr); sr::set_render_degree(-1); relit = false; lastRelight.clear(); }
            return;
        }
        if (!scanOnGpu()) return;
        bool vis = !plot.lights.empty() && shadowsOn && prepareShadows(plot, body, quality);
        int K = (scan->shDegree + 1) * (scan->shDegree + 1) - 1;
        int nl = std::min(int(plot.lights.size()), maxLights);
        std::array<V4, 4> g = {V4{eye.x, eye.y, eye.z, plot.ambient},
                               V4{float(nl), float(scan->count), float(K), 0.25f},
                               V4{plot.ambientTint.x, plot.ambientTint.y, plot.ambientTint.z, vis ? 1.f : 0.f},
                               V4{float(quality), float(shadowVersion), daylightScan ? 1.f : 0.f, 0}};
        std::vector<V4> lt, tables;
        float spots = 0;
        for (int k = 0; k < nl; k++) { plot.lights[k].packed(body.metresPerUnit, body.sceneEV, plot.up, lt, tables); spots += plot.lights[k].spot; }
        std::vector<V4> key(g.begin(), g.end());
        key.insert(key.end(), lt.begin(), lt.end());
        key.push_back({spots, 0, 0, 0});
        auto same = [](const std::vector<V4>& a, const std::vector<V4>& b) {
            return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(V4)) == 0;
        };
        if (relit && same(key, lastRelight)) return;
        lastRelight = key;
        std::array<V4, 48> lamps{};
        for (size_t i = 0; i < lt.size() && i < lamps.size(); i++) lamps[i] = lt[i];
        if (tables.empty()) tables.assign(1, V4{});
        // The same lamps for the fog's shafts (its shadows from the finder's maps).
        fogLamps = lamps;
        fogLampCount = nl;
        fogLampShadows = vis && !shadowSlots[0].empty();
        if (!gFogBeams || fogBeamBytes < tables.size() * sizeof(V4)) {
            gpu->release(gFogBeams);
            fogBeamBytes = tables.size() * sizeof(V4);
            gFogBeams = gpu->buffer(fogBeamBytes);
        }
        if (gFogBeams) gpu->upload(gFogBeams, tables.data(), tables.size() * sizeof(V4));
        SDL_GPUBuffer* beams = gpu->buffer(tables.size() * sizeof(V4));
        if (!beams) return;
        gpu->upload(beams, tables.data(), tables.size() * sizeof(V4));
        size_t N = size_t(scan->count);
        bool ok = gpu->run(kernels.relight, {gMeans, gDc0, gSh0, beams, gVis}, {gOutDc},
                           {{g.data(), sizeof g}, {lamps.data(), sizeof lamps}}, Uint32(N), 1, {gPatterns});
        gpu->release(beams);
        if (!ok) return;
        relitDc.resize(N * 3);
        if (!gpu->download(gOutDc, relitDc.data(), N * 12)) return;
        sr::set_colors(relitDc.data(), nullptr);
        // Relit colours are view-dependent already: the renderer evaluates base colour only.
        sr::set_render_degree(0);
        relit = true;
    }

    // ---- the GPU photo path (RenderLoop.step in the Swift app) ----
    static inline Gpu* gpu = nullptr;          // null: the CPU path below
    static inline PhotoKernels kernels;
    static inline SDL_GPUBuffer* gframe = nullptr;   // one rendered tile: rgb, T, median depth
    static inline size_t gframeBytes = 0;

    /// The optics rows for a photo (photoOptics in RenderLoop.swift; the
    /// layout is Shaders.swift's header): 9 rows, then the filter's 3.
    static std::array<V4, 12> photoOptics(const Exposure& e, float fx) {
        const CameraBody& b = e.body;
        const Lens& l = b.lens();
        float n = b.takingAperture();
        std::array<V4, 12> o{};
        o[0] = {float(e.W), float(e.H), fx, fx};
        V2 ax = V2{e.W / 2.f, e.H / 2.f} + b.axisOffset(e.W);
        o[1] = {ax.x, ax.y, b.metresPerUnit, b.focusM};
        o[2] = {l.focalMM / 1000, n, l.maxAperture, float(l.blades)};
        o[3] = {l.catsEye, l.soapBubble, l.bladeRotation, l.vignette};
        o[4] = {0.08f, 0.08f, 0.09f, sceneIsPlace ? 2.f : 1.f};
        o[5] = {0, 1, float(b.rollNumber * 100 + e.frameNumber), b.filmStops()};
        o[6] = {l.lateralCA, l.axialCA, l.projection == Projection::CircularFisheye ? e.H / 2.f : 0, l.obstruction};
        o[7] = {0, 0, 0, 0};
        o[8] = {l.squeeze, 0, 0, 0};
        // The filter on the lens; its threshold as the finder's, in exposed light.
        b.filter().optics(e.filterThreshold * std::exp2(b.filmStops()), &o[9]);
        return o;
    }
    /// FilmStock.packed (FilmStock.swift).
    static std::array<V4, 8> packedFilm(const FilmStock& s) {
        return {V4{s.crosstalk[0].x, s.crosstalk[0].y, s.crosstalk[0].z, 0},
                V4{s.crosstalk[1].x, s.crosstalk[1].y, s.crosstalk[1].z, 0},
                V4{s.crosstalk[2].x, s.crosstalk[2].y, s.crosstalk[2].z, 0},
                V4{s.balance.x, s.balance.y, s.balance.z, s.blackAndWhite ? 1.f : 0.f},
                V4{s.bwMix.x, s.bwMix.y, s.bwMix.z, s.saturation},
                V4{s.contrast, s.blackLift, s.shoulder, s.grain * std::sqrt(s.iso / 100)},
                V4{s.halation, s.halationTint.x, s.halationTint.y, s.halationTint.z},
                V4{s.iso, s.grainSize, s.toe, s.falseColourIR ? 1.f : 0.f}};
    }

    static bool stepGPU(Exposure& e) {
        const CameraBody& b = e.body;
        const Lens& L = b.lens();
        float n = b.takingAperture();
        float fx = b.focalPixels(e.W, e.H);
        float radiusUnits = L.focalMM / 1000 / n / 2 / b.metresPerUnit;
        relight(e.plot, e.cameraFor(e.next).position, b, 1);
        setSky(e.sky);
        int channel = b.splitsColour(int(e.cells.size())) ? int(e.next % 3) : -1;
        V2 c = e.cells[e.next];
        // Axial colour and spherical aberration move this sub-pupil's focus.
        CameraBody body = b;
        float dioptres = 1 / b.focusM;
        if (channel >= 0) dioptres += L.axialCA * float(1 - channel);
        float open = L.maxAperture / n;
        dioptres += L.sphericalAberration * (c.x * c.x + c.y * c.y) * open * open;
        body.focusM = 1 / dioptres;
        float invFocus = body.metresPerUnit / body.focusM;
        sr::set_camera_model(L.isFisheye() ? "FISHEYE" : "PINHOLE");
        V2 d{c.x * L.squeeze * radiusUnits, c.y * radiusUnits};
        std::vector<float> vm = e.cameraFor(e.next).viewMatrix();
        vm[3] -= d.x; vm[7] -= d.y;
        V2 axis = V2{e.W / 2.f, e.H / 2.f} + b.axisOffset(e.W);
        auto o = photoOptics(e, fx);
        float share = std::sqrt(float(channel < 0 ? 1 : 3) / float(e.cells.size()));
        V4 mask = channel < 0 ? V4{1, 1, 1, 1} : channel == 0 ? V4{1, 0, 0, 1} : channel == 1 ? V4{0, 1, 0, 1} : V4{0, 0, 1, 1};
        static const std::array<V4, 38> noFlare{};
        float fieldR = std::sqrt(float(e.W * e.W + e.H * e.H)) / 2.f;
        if (!e.gacc) e.gacc = gpu->buffer(size_t(e.W) * e.H * sizeof(V4));
        size_t tileBytes = size_t(e.tileW) * e.tileH * 5 * sizeof(float);
        if (gframeBytes < tileBytes) { gpu->release(gframe); gframe = gpu->buffer(tileBytes); gframeBytes = tileBytes; }
        if (!e.gacc || !gframe) return false;
        Frame tile;
        std::vector<float> packed(size_t(e.tileW) * e.tileH * 5);
        // The fog, seen from this sub-pupil's moment.
        std::array<V4, 44> fogRows;
        bool fog = !e.plot.fog.empty();
        if (fog) fogRows = e.plot.fog.rows(e.cameraFor(e.next).position, e.plot.up, b.metresPerUnit, e.plot.fogLight());
        // The photo in finder-sized tiles: each a render with the principal
        // point moved so it sees its part of the frame.
        for (int y0 = 0; y0 < e.H; y0 += e.tileH)
            for (int x0 = 0; x0 < e.W; x0 += e.tileW) {
                setLens(L.isFisheye() ? std::vector<V4>{}
                                      : body.lensParams(n, fx, int(channel < 0 ? e.cells.size() : e.cells.size() / 3), nullptr,
                                                        {axis.x - x0, axis.y - y0}, fieldR, d, share));
                if (!render(tile, vm, fx, axis.x + fx * d.x * invFocus - x0, axis.y + fx * d.y * invFocus - y0, e.tileW, e.tileH))
                    continue;
                // Spirula's frame layout: rgb, then transmittance, then median depth.
                size_t np = size_t(e.tileW) * e.tileH;
                std::memcpy(packed.data(), tile.rgb.data(), np * 3 * sizeof(float));
                std::memcpy(packed.data() + 3 * np, tile.T.data(), np * sizeof(float));
                std::memcpy(packed.data() + 4 * np, tile.z.data(), np * sizeof(float));
                gpu->upload(gframe, packed.data(), packed.size() * sizeof(float));
                encodeBackground(gframe, e.tileW, e.tileH, vm, fx, axis.x + fx * d.x * invFocus - x0, axis.y + fx * d.y * invFocus - y0,
                                 L.isFisheye(), e.plot.up, 0, fog ? &fogRows : nullptr, float(e.next) * 0.618034f);
                float first = e.next == 0 ? 1.f : 0.f;
                V4 l[3] = {{c.x, c.y, 1, first}, mask, {float(x0), float(y0), float(e.tileW), float(e.tileH)}};
                gpu->run(kernels.accumulate, {gframe}, {e.gacc},
                         {{o.data(), sizeof o}, {l, sizeof l}, {e.flare.size() == noFlare.size() ? e.flare.data() : noFlare.data(), sizeof noFlare}},
                         e.tileW, e.tileH);
            }
        sr::set_camera_model("PINHOLE");
        e.next++;
        if (e.next == e.cells.size()) { developGPU(e, o); e.done = true; }
        return true;
    }

    static void developGPU(Exposure& e, const std::array<V4, 12>& o) {
        const CameraBody& b = e.body;
        const Lens& L = b.lens();
        float n = b.takingAperture();
        int W = e.W, H = e.H;
        // Light through the unclipped centre of the frame sets the scale, per channel.
        V3 full{};
        int split = b.splitsColour(int(e.cells.size()));
        for (size_t k = 0; k < e.cells.size(); k++) {
            float w = pupilWeight(e.cells[k], {0, 0}, L, n);
            if (!split) full = full + V3{w, w, w};
            else if (k % 3 == 0) full.x += w; else if (k % 3 == 1) full.y += w; else full.z += w;
        }
        V4 dv{1 / std::max(full.x, 1e-6f), 1 / std::max(full.y, 1e-6f), 1 / std::max(full.z, 1e-6f), 0};
        // A wire across the stop: its horizontal diffraction streaks, from the whole exposure.
        SDL_GPUBuffer* streaks = nullptr;
        if (L.streak > 0 && (streaks = gpu->buffer(size_t(W) * H * sizeof(V4)))) {
            dv.w = 1;
            V4 z{W * 0.004f, L.streak, 0, 0};
            gpu->run(kernels.streak, {e.gacc}, {streaks}, {{o.data(), sizeof o}, {&dv, sizeof dv}, {&z, sizeof z}}, H);
        }
        // An effect filter (stars, glow, mist): what it scatters, from the whole exposure.
        SDL_GPUBuffer* fxBuf = nullptr;
        if (b.filter().hasEffect() && (fxBuf = gpu->buffer(size_t(W) * H * sizeof(V4))))
            gpu->run(kernels.lensFx, {e.gacc}, {fxBuf}, {{o.data(), sizeof o}, {&dv, sizeof dv}}, W, H);
        auto f = packedFilm(b.developed());
        static const std::array<V4, 38> noFlare{};
        if (e.sinkFloat) {
            // A frame for a 10-bit movie: the print kept in floats (develop16).
            SDL_GPUBuffer* print16 = gpu->buffer(size_t(W) * H * 3 * sizeof(float));
            std::vector<float> rgbf(size_t(W) * H * 3);
            bool ok16 = print16 && gpu->run(kernels.develop16, {e.gacc, streaks ? streaks : e.gacc, fxBuf ? fxBuf : e.gacc}, {print16},
                                            {{o.data(), sizeof o}, {f.data(), sizeof f}, {&dv, sizeof dv},
                                             {e.flare.size() == noFlare.size() ? e.flare.data() : noFlare.data(), sizeof noFlare}}, W, H)
                        && gpu->download(print16, rgbf.data(), rgbf.size() * sizeof(float));
            gpu->release(print16); gpu->release(streaks); gpu->release(fxBuf); gpu->release(e.gacc);
            if (!ok16) rgbf.clear();
            e.sinkFloat(rgbf);
            return;
        }
        SDL_GPUBuffer* print = gpu->buffer(size_t(W) * H * 4);
        std::vector<uint32_t> rgba(size_t(W) * H);
        bool ok = print && gpu->run(kernels.develop, {e.gacc, streaks ? streaks : e.gacc, fxBuf ? fxBuf : e.gacc}, {print},
                                    {{o.data(), sizeof o}, {f.data(), sizeof f}, {&dv, sizeof dv},
                                     {e.flare.size() == noFlare.size() ? e.flare.data() : noFlare.data(), sizeof noFlare}}, W, H)
                  && gpu->download(print, rgba.data(), rgba.size() * 4);
        // The digital negative: the same light before any film, unclipped, as half floats in a DNG.
        if (ok && e.wantsNegative && !e.sink) {
            SDL_GPUBuffer* neg = gpu->buffer(size_t(W) * H * 3 * sizeof(float));
            std::vector<float> lin(size_t(W) * H * 3);
            if (neg && gpu->run(kernels.negative, {e.gacc, streaks ? streaks : e.gacc, fxBuf ? fxBuf : e.gacc}, {neg},
                                {{o.data(), sizeof o}, {&dv, sizeof dv},
                                 {e.flare.size() == noFlare.size() ? e.flare.data() : noFlare.data(), sizeof noFlare}}, W, H) &&
                gpu->download(neg, lin.data(), lin.size() * sizeof(float))) {
                std::vector<uint16_t> half(lin.size());
                for (size_t i = 0; i < lin.size(); i++) half[i] = toHalf(lin[i]);
                std::error_code ec2;
                if (e.out.has_parent_path()) fs::create_directories(e.out.parent_path(), ec2);
                dng::write(fs::path(e.out).replace_extension(".dng").u8string(), half, W, H,
                           e.body.rollName() + ", frame " + std::to_string(e.frameNumber) + ": linear light before the film", e.body, e.shotAt,
                           "Vintage Click for Windows");
            }
            gpu->release(neg);
        }
        gpu->release(print); gpu->release(streaks); gpu->release(fxBuf); gpu->release(e.gacc);
        if (!ok) {
            fprintf(stderr, "GPU develop failed: %s\n", gpu->error.c_str());
            if (e.sink) { std::vector<uint32_t> none; e.sink(none); }
            return;
        }
        if (e.sink) { e.sink(rgba); return; }
        std::error_code ec;
        if (e.out.has_parent_path()) fs::create_directories(e.out.parent_path(), ec);
        std::vector<uint8_t> rgb(size_t(W) * H * 3);
        for (size_t i = 0; i < rgba.size(); i++) {
            rgb[3 * i] = uint8_t(rgba[i]); rgb[3 * i + 1] = uint8_t(rgba[i] >> 8); rgb[3 * i + 2] = uint8_t(rgba[i] >> 16);
        }
        writePrint(e, rgb.data(), W, H);
        writeShotRecord(e);
    }

    /// One sub-pupil: render the view sheared to that lens point (focus plane
    /// fixed), add it to the film; develop after the last.
    static void step(Exposure& e) {
        if (gpu && stepGPU(e)) return;
        const CameraBody& b = e.body;
        const Lens& L = b.lens();
        float n = b.takingAperture();
        float fx = b.focalPixels(e.W, e.H);
        float radiusUnits = L.focalMM / 1000 / n / 2 / b.metresPerUnit;
        int channel = b.splitsColour(int(e.cells.size())) ? int(e.next % 3) : -1;
        V2 c = e.cells[e.next];
        CameraBody body = b;
        float dioptres = 1 / b.focusM;
        if (channel >= 0) dioptres += L.axialCA * float(1 - channel);
        float open = L.maxAperture / n;
        dioptres += L.sphericalAberration * (c.x * c.x + c.y * c.y) * open * open;
        body.focusM = 1 / dioptres;
        float invFocus = body.metresPerUnit / body.focusM;
        sr::set_camera_model(L.isFisheye() ? "FISHEYE" : "PINHOLE");
        V2 d{c.x * L.squeeze * radiusUnits, c.y * radiusUnits};
        std::vector<float> vm = e.cameraFor(e.next).viewMatrix();
        vm[3] -= d.x; vm[7] -= d.y;
        V2 axis = V2{e.W / 2.f, e.H / 2.f} + b.axisOffset(e.W);
        float share = std::sqrt(float(channel < 0 ? 1 : 3) / float(e.cells.size()));
        float fieldR = std::sqrt(e.W * e.W + e.H * e.H) / 2.f;
        if (e.next == 0) e.acc.assign(size_t(e.W) * e.H, V4{});
        Frame tile;
        for (int y0 = 0; y0 < e.H; y0 += e.tileH)
            for (int x0 = 0; x0 < e.W; x0 += e.tileW) {
                setLens(L.isFisheye() ? std::vector<V4>{}
                                      : body.lensParams(n, fx, int(channel < 0 ? e.cells.size() : e.cells.size() / 3), nullptr,
                                                        {axis.x - x0, axis.y - y0}, fieldR, d, share));
                if (!render(tile, vm, fx, axis.x + fx * d.x * invFocus - x0, axis.y + fx * d.y * invFocus - y0, e.tileW, e.tileH))
                    continue;
                Optics o; o.place = e.camera.up.y != 0 && false;
                float r0 = std::sqrt(c.x * c.x + c.y * c.y);
                float soap = L.soapBubble;
                float w = (r0 < L.obstruction) ? 0 : (1 + soap * std::pow(r0, 6.f)) / (1 + soap * 0.25f);
                for (int y = 0; y < e.tileH && y0 + y < e.H; y++)
                    for (int x = 0; x < e.tileW && x0 + x < e.W; x++) {
                        size_t ti = size_t(y) * e.tileW + x;
                        V3 col{tile.rgb[3 * ti], tile.rgb[3 * ti + 1], tile.rgb[3 * ti + 2]};
                        float t = tile.T[ti];
                        V3 bg{0.08f, 0.08f, 0.09f};
                        V3 lit = col + bg * t;
                        if (e.body.metresPerUnit > 0 && sceneIsPlace) {
                            float keep = smoothstepf(0.85f, 0.97f, t);
                            lit = col * (1 / std::max(1 - t, 0.03f)) * (1 - keep) + lit * keep;
                        }
                        V3 lin = toLin(lit);
                        V4& a = e.acc[size_t(y0 + y) * e.W + x0 + x];
                        float mr = channel < 0 || channel == 0 ? 1.f : 0.f, mg = channel < 0 || channel == 1 ? 1.f : 0.f,
                              mb = channel < 0 || channel == 2 ? 1.f : 0.f;
                        a.x += lin.x * mr * w; a.y += lin.y * mg * w; a.z += lin.z * mb * w; a.w += w;
                    }
            }
        sr::set_camera_model("PINHOLE");
        e.next++;
        if (e.next == e.cells.size()) { develop(e); e.done = true; }
    }

    static inline bool sceneIsPlace = false;

    static void develop(Exposure& e) {
        const CameraBody& b = e.body;
        const Lens& L = b.lens();
        float n = b.takingAperture();
        V3 full{};
        int channelSplit = b.splitsColour(int(e.cells.size()));
        for (size_t k = 0; k < e.cells.size(); k++) {
            float w = pupilWeight(e.cells[k], {0, 0}, L, n);
            if (!channelSplit) full = full + V3{w, w, w};
            else if (k % 3 == 0) full.x += w; else if (k % 3 == 1) full.y += w; else full.z += w;
        }
        V3 D{1 / std::max(full.x, 1e-6f), 1 / std::max(full.y, 1e-6f), 1 / std::max(full.z, 1e-6f)};
        float expo = std::exp2(b.filmStops());
        FilmStock F = b.developed();
        int W = e.W, H = e.H;
        std::vector<uint8_t> out(size_t(W) * H * 3);
        auto acc = [&](float x, float y) {
            int ix = std::clamp(int(x), 0, W - 1), iy = std::clamp(int(y), 0, H - 1);
            return e.acc[size_t(iy) * W + ix];
        };
        float k = L.lateralCA;
        V2 cc{W / 2.f, H / 2.f};
        float diag = std::sqrt(W * W * 0.25f + H * H * 0.25f);
        uint32_t seed = uint32_t(b.rollNumber * 100 + e.frameNumber);
        parallelRows(H, [&](int y0, int y1) {
            for (int y = y0; y < y1; y++)
                for (int x = 0; x < W; x++) {
                    V2 pc{x + 0.5f, y + 0.5f};
                    V2 q{(pc.x - cc.x) / diag, (pc.y - cc.y) / diag};
                    float vig = 1 - L.vignette * std::pow(sat(L.maxAperture / n), 1.5f) * (q.x * q.x + q.y * q.y);
                    V2 pr = cc + (pc - cc) * (1 - k), pb = cc + (pc - cc) * (1 + k);
                    V3 lin{acc(pr.x, pr.y).x, acc(pc.x, pc.y).y, acc(pb.x, pb.y).z};
                    lin = lin * D * (expo * vig);
                    V3 halo{};
                    if (F.halation > 0) {
                        float rad = H * 0.012f;
                        for (int j = 0; j < 16; j++) {
                            V2 o = vogel(j, 16) * rad;
                            V4 s = acc(pc.x + o.x, pc.y + o.y);
                            halo = halo + V3{std::max(s.x * D.x * expo - 0.9f, 0.f), std::max(s.y * D.y * expo - 0.9f, 0.f),
                                             std::max(s.z * D.z * expo - 0.9f, 0.f)};
                        }
                        halo = halo * (1 / 16.f);
                    }
                    if (L.projection == Projection::CircularFisheye)
                        lin = lin * (1 - smoothstepf(H / 2.f - 2, H / 2.f, len(pc - cc)));
                    V3 col = filmLook(lin, halo, pc.x, pc.y, seed, float(H), F);
                    size_t i = (size_t(y) * W + x) * 3;
                    out[i] = uint8_t(col.x * 255 + 0.5f); out[i + 1] = uint8_t(col.y * 255 + 0.5f); out[i + 2] = uint8_t(col.z * 255 + 0.5f);
                }
        });
        e.acc.clear(); e.acc.shrink_to_fit();
        if (e.sinkFloat) {
            std::vector<float> rgbf(out.size());
            for (size_t i = 0; i < out.size(); i++) rgbf[i] = out[i] / 255.f;
            e.sinkFloat(rgbf);
            return;
        }
        if (e.sink) {
            std::vector<uint32_t> rgba(size_t(W) * H);
            for (size_t i = 0; i < rgba.size(); i++) rgba[i] = 0xff000000u | out[3 * i] | out[3 * i + 1] << 8 | out[3 * i + 2] << 16;
            e.sink(rgba);
            return;
        }
        std::error_code ec;
        if (e.out.has_parent_path()) fs::create_directories(e.out.parent_path(), ec);
        writePrint(e, out.data(), W, H);
        writeShotRecord(e);
    }
    /// The print as a PNG carrying the EXIF a camera of the day would have written (Exif.swift).
    static void writePrint(const Exposure& e, const uint8_t* rgb, int W, int H) {
        int len = 0;
        unsigned char* png = stbi_write_png_to_mem(rgb, W * 3, W, H, 3, &len);
        if (!png) return;
        const CameraBody& b = e.body;
        auto tiff = exif::forPrint(b, e.shotAt, b.rollName() + ", frame " + std::to_string(e.frameNumber), "Vintage Click for Windows");
        auto bytes = exif::withExif(png, size_t(len), tiff);
        free(png);
        std::ofstream o(e.out, std::ios::binary);
        o.write(reinterpret_cast<const char*>(bytes.data()), std::streamsize(bytes.size()));
    }
    /// The frame's settings beside it (frame-NN.json).
    static void writeShotRecord(const Exposure& e) {
        const CameraBody& b = e.body;
        std::ofstream j(fs::path(e.out).replace_extension(".json"));
        j << "{\n  \"camera\": \"" << b.model().fullName() << "\",\n  \"camera_serial\": \"" << b.model().serial
          << "\",\n  \"camera_year\": " << b.model().year << ",\n  \"shot_at\": \"" << exif::date(e.shotAt)
          << "\",\n  \"filter\": \"" << b.filter().name << "\",\n  \"proof\": " << (e.proof ? "true" : "false")
          << ",\n  \"negative\": \"" << (e.wantsNegative ? fs::path(e.out).replace_extension(".dng").filename().u8string() : std::string())
          << "\",\n  \"lens\": \"" << b.lens().name << "\",\n  \"film\": \"" << b.stock().name << "\",\n  \"aperture\": " << b.takingAperture()
          << ",\n  \"shutter\": \"1/" << b.shutter().label << "\",\n  \"iso\": " << b.stock().iso << ",\n  \"rated_ei\": "
          << b.ratedEI() << ",\n  \"push\": " << b.push << ",\n  \"focus_m\": " << b.focusM << ",\n  \"scene_ev\": "
          << b.sceneEV << ",\n  \"exposure_stops\": " << b.exposureStops() << ",\n  \"magnification\": "
          << b.magnification() << ",\n  \"sub_pupils\": " << e.cells.size() << ",\n  \"width\": " << e.W
          << ",\n  \"height\": " << e.H << "\n}\n";
    }
};

// ---------------------------------------------------------------------------
// The game.

enum class Mode { Camera, Menu, Bag, Film, Sheet, Lighting, List, Wall };

struct Roll { int number; std::string stock, session; fs::path dir; std::vector<fs::path> frames; bool take = false; };

struct App {
    SDL_Window* window = nullptr;
    SDL_Renderer* sdl = nullptr;
    SDL_Texture* tex = nullptr;
    SDL_Gamepad* pad = nullptr;
    Canvas cv;
    Font font;
    Sounds sounds;
    Renderer renderer;
    Scan scan;
    std::string scanPath, sceneName;
    bool place = false;
    bool hasSpot = false;
    int meterSettle = 0;
    V3 spot; float spotYaw = 0;
    CameraBody body;
    FlyCamera camera, home;
    LightingPlot lighting;
    SkySetting sky;                         // remembered with each scan
    std::string pendingSky;                 // chosen in the file dialog, picked up next frame
    int finderW = 1620, finderH = 1080;     // the Mac's default (--res 1620x1080)
    int photoW = 3240, photoH = 2160;
    int cells = 32;
    Mode mode = Mode::Camera;
    int menuSel = 0, shelf = 0, lensSel = 0, filmSel = 0, filmPush = 0;
    float meterLum = 0.18f, finderGain = 1, needle = 7, needleSpeed = 0;
    double mirrorUpUntil = 0;
    std::string flash; double flashUntil = 0;
    std::string session;
    bool mouseCaptured = false;
    // The light table.
    std::vector<Roll> rolls;
    std::vector<std::vector<int>> sessions;
    int sessionIndex = 0, sheetSel = 0;
    V2 loupe{-1, -1};
    float loupePower = 4;
    std::map<std::string, std::vector<uint8_t>> thumbs;   // path -> RGB at thumbW x thumbH
    std::map<std::string, std::pair<int, int>> thumbSize;
    bool quit = false;
    Uint64 lastTicks = 0;

    void say(const std::string& s) { flash = s; flashUntil = SDL_GetTicks() / 1000.0 + 2.5; }

    // ---- the scan ----
    bool open(const std::string& path) {
        // A scene from the Scene Builder: unpacked (once), then its scan.
        SceneBundle bundle;
        bool isBundle = SceneBundle::isBundle(path);
        std::string ply = path;
        if (isBundle) {
            std::string err;
            if (!SceneBundle::open(path, bundle, err)) { say("CAN'T OPEN THE SCENE: " + upper(err)); return false; }
            ply = bundle.plyPath();
        }
        try {
            scan = loadPLY(ply);
        } catch (std::exception& ex) {
            say(std::string("COULD NOT OPEN THE SCAN: ") + ex.what());
            return false;
        }
        scanPath = path;
        sceneName = fs::u8path(path).parent_path().filename().u8string();
        if (sceneName.empty()) sceneName = fs::u8path(path).stem().u8string();
        if (isBundle) sceneName = bundle.name();
        // What the last scene brought goes with it.
        soundscape.reset();
        bounds = MovementBounds{};
        lighting.fog = SceneFog{};
        hasStart = false;
        V3 bundleUp;
        if (isBundle && bundle.up(bundleUp)) worldUp = bundleUp;
        // Remembered for this file, else a guess: a place is dominated by its
        // ground (flat); an object on the rig is a rounder blob. A scene says what it is.
        SceneKind k;
        if (!SceneKind::remembered(path, k)) {
            if (isBundle) { k.place = bundle.place(); k.ev = bundle.ev(); }
            else { k.place = flatness(scan) < 0.15f; k.ev = k.place ? 13.f : 12.f; }
        }
        if (isBundle && k.scale <= 0 && bundle.metresPerUnit() > 0) k.scale = bundle.metresPerUnit();
        if (flag("--inside")) k.place = true; else if (flag("--object")) k.place = false;
        if (!option("--ev").empty()) k.ev = std::stof(option("--ev"));
        if (!option("--scale").empty()) k.scale = std::stof(option("--scale"));
        body.calibration = std::clamp(std::log2(0.18f / middleTone(scan)), -4.f, 4.f);
        // The renderer wants some higher SH bands: give a flat-colour scan one
        // band of zeros (the same picture).
        if (scan.shDegree == 0) { scan.shDegree = 1; scan.sh.assign(size_t(scan.count) * 3 * 3, 0.f); }
        Renderer::dropScan();
        Renderer::scan = &scan;
        int rc = sr::set_splats(scan.count, scan.shDegree, scan.means.data(), scan.quats.data(), scan.scales.data(),
                               scan.opacities.data(), scan.dc.data(), scan.shDegree > 0 ? scan.sh.data() : nullptr);
        if (rc != 0) { say(std::string("THE RENDERER REFUSED THE SCAN: ") + sr::last_error()); return false; }
        applyKind(k);
        sky = rememberedSky(path);
        if (isBundle) applyBundle(bundle);
        if (!option("--sky").empty()) sky = SkySetting{option("--sky")};
        session = stamp("%Y-%m-%d") + "/" + stamp("%H.%M") + " " + sceneName;
        if (window) SDL_SetWindowTitle(window, ("Vintage Click — " + sceneName).c_str());
        return true;
    }
    /// A scene composed in Blender: where to stand, its lights, house lights, sky,
    /// bounds, fog and sounds (Viewer.apply in the Swift app).
    void applyBundle(const SceneBundle& b) {
        const Json& st = b.file["start"];
        V3 pos, fwd;
        if (SceneBundle::vec(st["position"], pos) && SceneBundle::vec(st["forward"], fwd) && len(fwd) > 1e-6f) {
            if (st.has("focalMM")) {
                // The lens in the bag nearest the start camera's (not a fisheye unless asked for).
                float f = float(st["focalMM"].num());
                int best = -1;
                for (int i = 0; i < int(lensBag().size()); i++) {
                    const Lens& L = lensBag()[i];
                    if (!body.fits(L) || (f >= 12 && L.isFisheye())) continue;
                    if (best < 0 || std::fabs(L.focalMM - f) < std::fabs(lensBag()[best].focalMM - f)) best = i;
                }
                if (best >= 0) body.chooseLens(best);
            }
            camera = FlyCamera();
            camera.up = worldUp;
            camera.focalMM = body.lens().focalMM;
            camera.lookAt(pos + norm(fwd), pos);
            startCam = camera;
            hasStart = true;
        }
        if (b.file.has("houseLights")) lighting.setHouseLights(b.file["houseLights"].str());
        // The lights, matched to the kit by name (an unknown name: the first, logged).
        auto index = [](const Json& j, const auto& names, const char* what) {
            if (j.kind != Json::String) return 0;
            for (int i = 0; i < int(names.size()); i++) if (names[i].name == j.s) return i;
            fprintf(stderr, "Scene: no %s called \"%s\": using %s\n", what, j.s.c_str(), names.empty() ? "?" : names[0].name.c_str());
            return 0;
        };
        std::vector<PlacedLight> lights;
        for (auto& l : b.file["lights"].a) {
            V3 lp, aim;
            if (!SceneBundle::vec(l["position"], lp) || !SceneBundle::vec(l["aim"], aim) || len(aim) <= 1e-6f) continue;
            PlacedLight p;
            p.head = index(l["head"], lightKit(), "light head");
            p.position = lp;
            p.aim = norm(aim);
            if (l.has("spot")) p.spot = std::clamp(float(l["spot"].num()), 0.f, 1.f);
            if (l.has("dimmerStops")) p.dimmerStops = float(l["dimmerStops"].num());
            p.gel = index(l["gel"], gels(), "gel");
            p.modifier = index(l["modifier"], lightModifiers(), "light modifier");
            if (!p.fits(lightModifiers()[p.modifier])) p.modifier = 0;
            if (l.has("patternFocus")) p.patternFocus = std::clamp(float(l["patternFocus"].num()), 0.f, 1.f);
            p.flare = l.has("flare") ? (l["flare"].boolean() ? 1 : 0) : (newLightsFlare ? 1 : 0);
            lights.push_back(p);
        }
        if (!lights.empty()) { lighting.lights = lights; lighting.selected = 0; }
        bounds = b.bounds();
        lighting.fog = b.fog();
        // The scene's own sky, as it was composed.
        const Json& sk = b.file["sky"];
        if (sk.kind == Json::Object && !sk["file"].str().empty() && fs::exists(fs::u8path(b.path(sk["file"].str()))))
            sky = SkySetting{b.path(sk["file"].str()), float(sk["yawDegrees"].num(0)), float(sk["stops"].num(0))};
        // Its sounds: placed ones, and beds heard everywhere.
        std::vector<Soundscape::Emitter> em;
        for (auto& snd : b.file["sounds"].a) {
            Soundscape::Emitter e;
            if (!SceneBundle::vec(snd["position"], e.position)) continue;
            e.file = b.path(snd["file"].str());
            e.volume = float(snd["volume"].num(1));
            e.fullWithinM = std::max(0.05f, float(snd["fullWithinM"].num(1)));
            e.silentBeyondM = float(snd["silentBeyondM"].num(50));
            em.push_back(e);
        }
        std::vector<Soundscape::Bed> bedList;
        for (auto& bd : b.file["ambience"].a) {
            Soundscape::Bed bed;
            bed.file = b.path(bd["file"].str());
            bed.volume = float(bd["volume"].num(1));
            bedList.push_back(bed);
        }
        size_t nSounds = em.size(), nBeds = bedList.size();
        if (nSounds + nBeds > 0) {
            soundscape = std::make_unique<Soundscape>();
            soundscape->start(std::move(em), std::move(bedList));
            if (soundscape->empty()) soundscape.reset();
        }
        fprintf(stderr, "Scene: %s: %d lights, %d sounds, %d beds, %d bounds, %d fog patches%s, sky %s\n", b.name().c_str(), int(lights.size()),
                int(nSounds), int(nBeds), int(bounds.volumes.size()), int(lighting.fog.patches.size()),
                lighting.fog.visibilityM > 0 ? " and haze" : "", sky.path.empty() ? "none" : sky.name().c_str());
    }
    std::unique_ptr<Soundscape> soundscape;
    MovementBounds bounds;               // where the camera may go (a .vcscene's)
    bool hasStart = false;               // a .vcscene's start view
    FlyCamera startCam;
    /// The scene's own sounds: on, and how loud (Menu > Settings).
    bool sceneSoundOn() const { return g_prefs.getBool("soundscape", true); }
    float sceneSoundLevel() const {
        float v = 0.8f;
        sscanf(g_prefs.get("soundscapeLevel", "0.8").c_str(), "%f", &v);
        return std::clamp(v, 0.f, 1.f);
    }
    static SkySetting rememberedSky(const std::string& scene) {
        SkySetting s;
        std::string v = g_prefs.get("sky:" + scene);
        float yaw = 0, stops = 0; int at = 0;
        if (!v.empty() && sscanf(v.c_str(), "%f %f %n", &yaw, &stops, &at) >= 2 && at > 0) { s.path = v.substr(at); s.yawDegrees = yaw; s.stops = stops; }
        return s;
    }
    void setSky(const SkySetting& s) {
        sky = s;
        if (s.path.empty()) g_prefs.kv.erase("sky:" + scanPath), g_prefs.save();
        else { char b[64]; snprintf(b, sizeof b, "%g %g ", s.yawDegrees, s.stops); g_prefs.set("sky:" + scanPath, b + s.path); }
    }
    void chooseSky() {
        static const SDL_DialogFileFilter filters[] = {{"Equirectangular sky (.hdr)", "hdr"}};
        SDL_ShowOpenFileDialog([](void* ud, const char* const* list, int) {
            if (list && list[0]) static_cast<App*>(ud)->pendingSky = list[0];
        }, this, window, filters, 1, nullptr, false);
    }
    /// Read the open scan as a place or an object: its size, light, walking pace and start.
    void applyKind(const SceneKind& k) {
        place = k.place;
        Renderer::sceneIsPlace = place;
        // Places are scanned in their own light; objects on the rig are lit from the camera.
        Renderer::daylightScan = place || flag("--daylight-scan");
        lighting.up = worldUp;
        float scale = k.scale > 0 ? k.scale : (place ? 15.f : 0.3f) / scan.radius;
        body.metresPerUnit = scale;
        body.sceneEV = k.ev;
        pickGait();
        meterSettle = 12;
        hasSpot = place && findOpenSpot(scan, scale, worldUp, spot, spotYaw);
        resetView();
    }
    /// A ready lighting plot (demoLights in Viewer.swift): in a place a night set,
    /// two hard Fresnels crossing and a softlight fill; for an object a key and a fill.
    void demoLights() {
        V3 subject = camera.position + camera.forward() * (body.focusM / body.metresPerUnit);
        V3 up = camera.up, f = camera.forward(), r = camera.right();
        if (place) {
            // In a place, light the ground where the camera looks, not the air.
            V3 flat = norm(f - up * dot(f, up));
            subject = camera.position + flat * (5 / body.metresPerUnit) - up * (1.6f / body.metresPerUnit);
        }
        auto placeLight = [&](int head, float side, float upAmt, float metres, float spot) {
            V3 toCam = norm(camera.position - subject);
            V3 dir = norm(toCam * std::cos(side) + r * std::sin(side) + up * upAmt);
            PlacedLight l;
            l.head = head;
            l.position = subject + dir * (metres / body.metresPerUnit);
            l.aim = norm(subject - l.position);
            l.spot = spot;
            return l;
        };
        if (place) {
            lighting.lights = {placeLight(2, -0.9f, 0.55f, 6, 0.5f), placeLight(2, 2.4f, 0.5f, 6, 0.7f), placeLight(3, 0.6f, 0.6f, 4, 0)};
            lighting.setHouseLights("city night");
            return;
        }
        lighting.lights = {placeLight(2, -0.8f, 0.7f, 2.0f, 0.6f), placeLight(3, 0.9f, 0.2f, 2.2f, 0)};
        lighting.ambient = 0.1f;
    }
    /// The test options (main.swift): --demo-lights, --house, --gel / --head /
    /// --modifier / --pattern-focus (on every light), --no-shadows.
    void applyTestLighting() {
        if (flag("--demo-lights")) demoLights();
        if (flag("--flare-light")) {
            // A Fresnel ahead and a little to the side, aimed back at the lens (flareTestLight in Viewer.swift).
            float m = 1 / body.metresPerUnit;
            PlacedLight l;
            l.head = 2;
            l.position = camera.position + camera.forward() * (7 * m) + camera.right() * (1.2f * m) - camera.down() * (0.4f * m);
            l.aim = norm(camera.position - l.position);
            l.flare = 1;
            lighting.lights.push_back(l);
        }
        if (!option("--house").empty()) lighting.setHouseLights(option("--house"));
        for (auto& l : lighting.lights) {
            if (!option("--gel").empty()) l.gel = std::clamp(std::stoi(option("--gel")), 0, int(gels().size()) - 1);
            if (!option("--head").empty()) l.head = std::clamp(std::stoi(option("--head")), 0, int(lightKit().size()) - 1);
            if (!option("--modifier").empty()) l.modifier = std::clamp(std::stoi(option("--modifier")), 0, int(lightModifiers().size()) - 1);
            if (!option("--pattern-focus").empty()) l.patternFocus = std::stof(option("--pattern-focus"));
        }
        if (flag("--no-shadows")) Renderer::shadowsOn = false;
        if (flag("--flare")) for (auto& l : lighting.lights) l.flare = 1;
        std::string flyOpt = !option("--fly").empty() ? option("--fly") : option("--fly-light");
        if (flag("--lighting-mode") || !flyOpt.empty()) playMode = mode = Mode::Lighting;
        if (!flyOpt.empty()) fly(std::stoi(flyOpt) - 1);
        // The screens, opened straight away (the Mac's flags, for screenshots and tests).
        if (flag("--menu")) openMenu();
        if (!option("--menu-page").empty()) {
            static const std::map<std::string, Page> pages = {{"main", Page::Main}, {"bag", Page::Bag}, {"scene", Page::Scene},
                {"photos", Page::Photos}, {"settings", Page::Settings}, {"finder", Page::Finder}, {"lights", Page::Lights}};
            auto it = pages.find(option("--menu-page"));
            if (it != pages.end()) go(it->second);
        }
        if (flag("--controls")) { openMenu(); showingHelp = true; }
        if (flag("--film-menu")) { filmSel = body.stockIndex; filmPush = body.push; mode = Mode::Film; }
        if (flag("--lens-menu")) openBag();
        if (flag("--filter-menu")) openBag(true);
        if (flag("--sheet")) openSheet();
    }
    SceneKind currentKind() const {
        SceneKind k;
        if (!SceneKind::remembered(scanPath, k)) { k.place = place; k.ev = body.sceneEV; }
        return k;
    }
    /// "Treat this scan as a place / an object": remember the other reading for this file.
    void switchKind() {
        SceneKind k = currentKind();
        k.place = !place;
        k.scale = 0;                 // a measured size belonged to the other reading
        k.ev = k.place ? 13.f : 12.f;
        k.remember(scanPath);
        applyKind(k);
        say(place ? "A PLACE TO STAND IN" : "AN OBJECT ON THE RIG");
    }
    V3 worldUp{0, -1, 0};           // which way is up in the scan (U cycles it)
    /// U: the scan stored on its side or upside down: the next axis as up, and a fresh view (cycleUp in Viewer.swift).
    void cycleUp() {
        static const V3 axes[] = {{0, -1, 0}, {0, 0, 1}, {0, 1, 0}, {0, 0, -1}, {1, 0, 0}, {-1, 0, 0}};
        int i = 0;
        for (int k = 0; k < 6; k++) if (axes[k].x == worldUp.x && axes[k].y == worldUp.y && axes[k].z == worldUp.z) i = k;
        worldUp = axes[(i + 1) % 6];
        lighting.up = worldUp;
        resetView();
    }
    /// A lens from the mounted lens's collection (the number keys).
    void mountFromCollection(int d) {
        for (int s0 = 0, k = 0; s0 < int(lensShelves().size()); k += lensShelves()[s0].count, s0++) {
            if (lensShelves()[s0].name != body.lens().collection) continue;
            if (d > lensShelves()[s0].count) return;
            int i = k + d - 1;
            if (i == body.lensIndex || !body.fits(lensBag()[i])) return;
            body.chooseLens(i);
            camera.focalMM = body.lens().focalMM;
            playFelt("lens-change");
            say(mountedLabel());
            return;
        }
    }
    void resetView() {
        // A scene's own start view.
        if (hasStart) {
            camera = startCam;
            camera.focalMM = body.lens().focalMM;
            return;
        }
        camera = FlyCamera();
        camera.up = worldUp;
        camera.focalMM = body.lens().focalMM;
        if (place) {
            camera.position = scan.center + camera.up * (1.6f / body.metresPerUnit);
            if (hasSpot) { camera.position = spot; camera.yaw = spotYaw; }
            body.focusM = std::max(body.lens().minFocusM, 5.f);
        } else {
            float dist = std::max(scan.radius * 1.2f * camera.focalMM / 36 + scan.radius,
                                  body.lens().minFocusM * 1.15f / body.metresPerUnit);
            FlyCamera c;
            c.up = worldUp;
            V3 eye = scan.center - c.forward() * dist + camera.up * (scan.radius * 0.35f);
            camera.lookAt(scan.center, eye);
            body.focusM = std::max(body.lens().minFocusM, len(eye - scan.center) * body.metresPerUnit);
        }
        home = camera;
    }

    // ---- optics for the screen ----
    Optics finderOptics(const FinderJob& j) const {
        Optics o;
        o.W = j.W; o.H = j.H; o.fx = j.fx; o.axis = j.axis;
        o.metresPerUnit = body.metresPerUnit; o.focusM = body.focusM;
        o.focalM = body.lens().focalMM / 1000; o.N = body.viewingAperture(); o.Nopen = body.lens().maxAperture;
        o.vignette = body.lens().vignette; o.lateralCA = body.lens().lateralCA;
        o.circleR = body.lens().projection == Projection::CircularFisheye ? j.H / 2.f : 0;
        o.place = place;
        o.prismR = j.H * 0.065f;
        o.brightness = std::pow(body.lens().maxAperture / body.viewingAperture(), 2.f) * std::exp2(-body.closeFocusLoss());
        return o;
    }
    FinderJob finderJob() const {
        FinderJob j;
        j.W = finderW; j.H = finderH;
        j.view = camera.viewMatrix();
        j.fx = body.focalPixels(finderW, finderH);
        // A shifted lens moves the optical axis.
        j.axis = V2{finderW / 2.f, finderH / 2.f} + body.axisOffset(finderW);
        j.fisheye = body.lens().isFisheye();
        j.smooth = !g_prefs.getBool("classicBlur", false);
        j.metresPerUnit = body.metresPerUnit;
        // Distant shells: in a place, with lenses up to a short tele (Viewer.swift). VC_SHELL_M sets the near radius.
        const char* sm = std::getenv("VC_SHELL_M");
        j.shells = g_prefs.getBool("distantShells", true) && std::getenv("VC_SHELLS") == nullptr && place && body.lens().focalMM <= 85;
        if (const char* off = std::getenv("VC_SHELLS")) j.shells = std::string(off) != "0" && place && body.lens().focalMM <= 85;
        j.shellRadius = (sm ? std::strtof(sm, nullptr) : 4.f) / body.metresPerUnit;
        j.plot = lighting;
        j.position = camera.position;
        j.body = body;
        j.sky = sky;
        if (pov >= 0 && pov < int(lighting.lights.size())) {
            // From the light being flown: a plain wide view down its beam, no lens to speak of.
            j.view = lightCam.viewMatrix();
            j.position = lightCam.position;
            j.fx = lightCam.focalMM / 36 * finderW;
            j.axis = {finderW / 2.f, finderH / 2.f};
            j.fisheye = false;
            j.fromLight = pov;
            return j;
        }
        if (body.model().rangefinder()) {
            // The rangefinder's window (or shoe finder): its own view, clear glass, no lens blur.
            float fx; V3 off; bool ext;
            rangefinderFinder(fx, off, ext);
            FlyCamera c = camera;
            c.position = c.position + off;
            j.view = c.viewMatrix();
            j.position = c.position;
            j.fx = fx;
            j.axis = {finderW / 2.f, finderH / 2.f};
            j.fisheye = ext && body.lens().isFisheye();
            return j;
        }
        if (!j.fisheye) {
            float n = body.viewingAperture();
            static std::map<std::pair<int, float>, std::vector<V4>> tables;
            auto key = std::make_pair(body.lensIndex, n);
            if (!tables.count(key)) tables[key] = CameraBody::pupilTable(body.lens(), n);
            j.lens = body.lensParams(n, j.fx, 1, &tables[key], j.axis, std::sqrt(finderW * finderW + finderH * finderH) / 2.f);
        }
        return j;
    }

    // ---- the shutter ----
    void release() {
        // The movie camera's button rolls the take (from the top when it is not rolling).
        if (body.model().isMotion()) { roll(!rolling); return; }
        double now = SDL_GetTicks() / 1000.0;
        if (now < mirrorUpUntil) return;
        if (body.framesLeft() <= 0) { say("END OF ROLL: LOAD FILM (R)"); return; }
        mirrorUpUntil = now + 0.07 + body.shutter().seconds;
        shutterFelt(body.shutter().seconds);
        auto e = std::make_shared<Exposure>();
        e->body = body; e->camera = camera; e->plot = lighting;
        e->flare = photoFlare();
        e->filterThreshold = filterThreshold();
        e->sky = sky;
        bool scripted = !option("--shoot").empty();
        e->proof = proofsAtShutter() && !scripted;
        e->wantsNegative = keepNegative() && !e->proof;
        e->W = e->proof ? finderW : photoW; e->H = e->proof ? finderH : photoH; e->tileW = finderW; e->tileH = finderH;
        e->cells = body.lens().isFisheye() ? std::vector<V2>{{0, 0}} : body.cellCentres(e->proof ? std::min(8, cells) : cells);
        body.framesShot++;
        e->frameNumber = body.framesShot;
        char roll[256];
        snprintf(roll, sizeof roll, "Roll %02d - %s", body.rollNumber, body.rollName().c_str());
        char frame[32]; snprintf(frame, sizeof frame, "frame-%02d.png", e->frameNumber);
        e->out = rollsRoot() / fs::u8path(session) / fs::u8path(roll) / frame;
        if (scripted && option("--shoot") != "-") e->out = fs::u8path(option("--shoot"));
        // Everything the enlarger needs to make it again, beside the proof.
        if (e->proof) writeShotRecordFile(*e, cells, photoW, photoH, keepNegative());
        renderer.expose(e);
        // The advance lever, once the shutter has closed.
        advanceAt = now + body.shutter().seconds + 0.4;
    }
    double advanceAt = 0;

    // ---- proofs and the enlarger (ShotRecord.swift, Viewer.swift's enlarger) ----
    /// Proofs at the shutter (the finder's size, few lens samples), full prints from the enlarger.
    bool proofsAtShutter() const { return g_prefs.getBool("proofsAtShutter", true); }
    /// A digital negative (DNG) beside every full print.
    bool keepNegative() const { return flag("--dng") || g_prefs.getBool("keepNegative", false); }   // --dng: for this run (main.swift)

    static std::string jsonEscape(const std::string& s) {
        std::string o;
        for (unsigned char c : s) {
            if (c == '"' || c == '\\') { o += '\\'; o += char(c); }
            else if (c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); o += b; }
            else o += char(c);
        }
        return o;
    }
    static fs::path shotRecordPath(const fs::path& print) { fs::path p = print; return p.replace_extension(".shot.json"); }

    /// Everything about a shot the enlarger needs to make it again (frame-NN.shot.json): the
    /// camera where it stood, its settings, the lights, the scan, the sky and the print's size.
    void writeShotRecordFile(const Exposure& e, int printCells, int W, int H, bool negative) {
        std::error_code ec;
        fs::create_directories(e.out.parent_path(), ec);
        std::ofstream o(shotRecordPath(e.out), std::ios::binary);
        o.precision(9);
        auto v3 = [&](V3 v) { o << "[" << v.x << ", " << v.y << ", " << v.z << "]"; };
        const CameraBody& b = e.body;
        const FlyCamera& c = e.camera;
        o << "{\n  \"format\": \"vintage-click-shot\",\n  \"scene\": \"" << jsonEscape(scanPath) << "\",\n  \"frame\": " << e.frameNumber
          << ",\n  \"cells\": " << printCells << ",\n  \"width\": " << W << ",\n  \"height\": " << H << ",\n  \"negative\": " << (negative ? "true" : "false")
          << ",\n  \"filterThreshold\": " << e.filterThreshold << ",\n  \"camera\": {\"position\": ";
        v3(c.position); o << ", \"up\": "; v3(c.up);
        o << ", \"yaw\": " << c.yaw << ", \"pitch\": " << c.pitch << ", \"focalMM\": " << c.focalMM << "},\n  \"body\": {\"model\": " << b.modelIndex
          << ", \"lens\": \"" << jsonEscape(b.lens().name) << "\", \"lensIndex\": " << b.lensIndex << ", \"apertureIndex\": " << b.apertureIndex
          << ", \"shutterIndex\": " << b.shutterIndex << ", \"focusM\": " << b.focusM << ", \"stockIndex\": " << b.stockIndex << ", \"push\": " << b.push
          << ", \"rollNumber\": " << b.rollNumber << ", \"framesShot\": " << b.framesShot << ", \"metresPerUnit\": " << b.metresPerUnit
          << ", \"sceneEV\": " << b.sceneEV << ", \"calibration\": " << b.calibration << ", \"tilt\": [" << b.tilt.x << ", " << b.tilt.y
          << "], \"shift\": [" << b.shift.x << ", " << b.shift.y << "], \"filterIndex\": " << b.filterIndex << ", \"autoExposure\": " << b.autoExposure
          << "},\n  \"lighting\": {\"ambient\": " << e.plot.ambient << ", \"ambientTint\": ";
        v3(e.plot.ambientTint);
        o << ", \"ambientName\": \"" << jsonEscape(e.plot.ambientName) << "\", \"up\": ";
        v3(e.plot.up);
        o << ", \"lights\": [";
        for (size_t k = 0; k < e.plot.lights.size(); k++) {
            const PlacedLight& l = e.plot.lights[k];
            o << (k ? ", " : "") << "\n    {\"head\": " << l.head << ", \"position\": ";
            v3(l.position); o << ", \"aim\": "; v3(l.aim);
            o << ", \"spot\": " << l.spot << ", \"dimmerStops\": " << l.dimmerStops << ", \"gel\": " << l.gel << ", \"modifier\": " << l.modifier
              << ", \"patternFocus\": " << l.patternFocus << ", \"flare\": " << l.flare << "}";
        }
        o << "]},\n  \"sky\": {\"path\": \"" << jsonEscape(e.sky.path) << "\", \"yawDegrees\": " << e.sky.yawDegrees << ", \"stops\": " << e.sky.stops
          << "},\n  \"flare\": [";
        for (size_t k = 0; k < e.flare.size(); k++)
            o << (k ? ", " : "") << "[" << e.flare[k].x << ", " << e.flare[k].y << ", " << e.flare[k].z << ", " << e.flare[k].w << "]";
        o << "]\n}\n";
    }
    /// A shot again, from its record (the enlarger): the print's size and lens samples.
    bool readShotRecordFile(const fs::path& print, Exposure& e, std::string& scene, int& printCells, bool& negative) {
        std::ifstream in(shotRecordPath(print), std::ios::binary);
        std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        Json j; std::string err;
        if (text.empty() || !Json::parse(text, j, err) || j["format"].str() != "vintage-click-shot") return false;
        auto v3 = [](const Json& a, V3 d) { auto f = a.floats(); return f.size() == 3 ? V3{f[0], f[1], f[2]} : d; };
        scene = j["scene"].str();
        printCells = int(j["cells"].num(32));
        negative = j["negative"].boolean();
        e.frameNumber = int(j["frame"].num(1));
        e.W = int(j["width"].num(photoW)); e.H = int(j["height"].num(photoH));
        e.filterThreshold = float(j["filterThreshold"].num(1));
        const Json& c = j["camera"];
        e.camera = FlyCamera();
        e.camera.position = v3(c["position"], {});
        e.camera.up = v3(c["up"], {0, -1, 0});
        e.camera.yaw = float(c["yaw"].num()); e.camera.pitch = float(c["pitch"].num()); e.camera.focalMM = float(c["focalMM"].num(50));
        const Json& b = j["body"];
        CameraBody body = this->body;
        body.chooseBody(int(b["model"].num(0)));
        // Lenses are numbered by their place in the bag, which grows: find it by name.
        int li = int(b["lensIndex"].num(body.lensIndex));
        for (int i = 0; i < int(lensBag().size()); i++) if (lensBag()[i].name == b["lens"].str()) li = i;
        body.lensIndex = std::clamp(li, 0, int(lensBag().size()) - 1);
        body.apertureIndex = std::clamp(int(b["apertureIndex"].num()), 0, int(body.lens().apertureStops().size()) - 1);
        body.shutterIndex = std::clamp(int(b["shutterIndex"].num(7)), 0, int(shutterSpeeds().size()) - 1);
        body.focusM = float(b["focusM"].num(body.focusM));
        body.stockIndex = std::clamp(int(b["stockIndex"].num(body.stockIndex)), 0, int(filmStocks().size()) - 1);
        body.push = int(b["push"].num(0));
        body.rollNumber = int(b["rollNumber"].num(body.rollNumber));
        body.framesShot = int(b["framesShot"].num(0));
        body.metresPerUnit = float(b["metresPerUnit"].num(body.metresPerUnit));
        body.sceneEV = float(b["sceneEV"].num(body.sceneEV));
        body.calibration = float(b["calibration"].num(body.calibration));
        auto tl = b["tilt"].floats(), sh = b["shift"].floats();
        body.tilt = tl.size() == 2 ? V2{tl[0], tl[1]} : V2{};
        body.shift = sh.size() == 2 ? V2{sh[0], sh[1]} : V2{};
        body.filterIndex = std::clamp(int(b["filterIndex"].num(0)), 0, int(lensFilters().size()) - 1);
        body.autoExposure = int(b["autoExposure"].num(-1));
        body.dofPreview = false;
        body.stopBetween = 0;
        e.body = body;
        const Json& L = j["lighting"];
        LightingPlot plot = lighting;      // the scene's fog stays (it is the scan's, not the shot's)
        plot.ambient = float(L["ambient"].num(1));
        plot.ambientTint = v3(L["ambientTint"], {1, 1, 1});
        plot.ambientName = L["ambientName"].str("day");
        plot.up = v3(L["up"], {0, -1, 0});
        plot.lights.clear();
        for (auto& l : L["lights"].a) {
            PlacedLight p;
            p.head = std::clamp(int(l["head"].num(1)), 0, int(lightKit().size()) - 1);
            p.position = v3(l["position"], {});
            p.aim = v3(l["aim"], {0, 0, 1});
            p.spot = float(l["spot"].num(0.5));
            p.dimmerStops = float(l["dimmerStops"].num(0));
            p.gel = std::clamp(int(l["gel"].num(0)), 0, int(gels().size()) - 1);
            p.modifier = std::clamp(int(l["modifier"].num(0)), 0, int(lightModifiers().size()) - 1);
            p.patternFocus = float(l["patternFocus"].num(0.25));
            p.flare = int(l["flare"].num(-1));
            plot.lights.push_back(p);
        }
        e.plot = plot;
        const Json& sk = j["sky"];
        e.sky = SkySetting{sk["path"].str(), float(sk["yawDegrees"].num(0)), float(sk["stops"].num(0))};
        e.flare.clear();
        for (auto& r : j["flare"].a) { auto f = r.floats(); if (f.size() == 4) e.flare.push_back({f[0], f[1], f[2], f[3]}); }
        return true;
    }
    /// A frame's settings say it is still a proof.
    static bool isProof(const fs::path& f) {
        std::ifstream in(fs::path(f).replace_extension(".json"), std::ios::binary);
        std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        Json j; std::string err;
        return !text.empty() && Json::parse(text, j, err) && j["proof"].boolean(false);
    }
    bool anyMarked() const {
        if (sessions.empty()) return false;
        for (int r : sessions[sessionIndex]) {
            auto it = marks.find(rolls[r].dir.u8string());
            if (it != marks.end() && !it->second.empty() && !rolls[r].take) return true;
        }
        return false;
    }
    /// The marked frames of the session on the table, or all of them if none is marked.
    std::vector<fs::path> enlargeCandidates() const {
        std::vector<fs::path> out;
        if (sessions.empty()) return out;
        bool marked = anyMarked();
        for (int r : sessions[sessionIndex]) {
            if (rolls[r].take) continue;
            auto it = marks.find(rolls[r].dir.u8string());
            for (int f = 0; f < int(rolls[r].frames.size()); f++)
                if (!marked || (it != marks.end() && it->second.count(f))) out.push_back(rolls[r].frames[f]);
        }
        return out;
    }
    std::deque<fs::path> enlargeQueue;
    int enlargeTotal = 0, enlargeDone = 0;
    fs::path enlarging;                 // the frame on the easel now
    /// Queues proofs for full prints, from their records (only this scan's: the stage holds one at a time).
    void enlarge(const std::vector<fs::path>& frames) {
        int queued = 0, elsewhere = 0;
        for (auto& u : frames) {
            if (std::find(enlargeQueue.begin(), enlargeQueue.end(), u) != enlargeQueue.end() || u == enlarging || !isProof(u)) continue;
            Exposure probe;
            std::string scene; int c; bool neg;
            if (!readShotRecordFile(u, probe, scene, c, neg)) continue;
            if (scene != scanPath) { elsewhere++; continue; }
            enlargeQueue.push_back(u);
            queued++;
            enlargeTotal++;
        }
        std::string msg = queued == 0 ? "NOTHING TO ENLARGE" : "ENLARGING " + std::to_string(queued) + (queued == 1 ? " FRAME" : " FRAMES");
        if (elsewhere > 0) msg += " · " + std::to_string(elsewhere) + " FROM ANOTHER SCAN: OPEN IT TO ENLARGE THEM";
        say(msg);
    }
    /// One print at a time: each needs a big accumulator.
    void feedEnlarger() {
        if (renderer.pending() > 0) return;
        if (!enlarging.empty()) {
            // The print is on the table now: forget the proof's picture.
            std::string k = enlarging.u8string();
            thumbs.erase(k); thumbSize.erase(k);
            if (bigKey == k) bigKey.clear();
            enlarging.clear();
            if (enlargeQueue.empty()) { say("ENLARGED " + std::to_string(enlargeDone) + (enlargeDone == 1 ? " PRINT" : " PRINTS")); enlargeTotal = enlargeDone = 0; }
        }
        if (enlargeQueue.empty()) return;
        fs::path u = enlargeQueue.front();
        enlargeQueue.pop_front();
        enlargeDone++;
        auto e = std::make_shared<Exposure>();
        std::string scene; int printCells; bool neg;
        if (!readShotRecordFile(u, *e, scene, printCells, neg)) return;
        e->tileW = finderW; e->tileH = finderH;
        e->cells = e->body.lens().isFisheye() ? std::vector<V2>{{0, 0}} : e->body.cellCentres(printCells);
        e->wantsNegative = neg;
        e->out = u;
        e->proof = false;
        enlarging = u;
        renderer.expose(e);
    }
    std::string enlargerStatus() const {
        if (movie) return "";
        return enlargeTotal > 0 ? " · ENLARGING " + std::to_string(enlargeDone) + " OF " + std::to_string(enlargeTotal) : "";
    }

    struct Inset { float x, y, s, corner; };
    // ---- the movie camera (Viewer.swift's "the movie camera") ----
    MotionTake take;                    // the working take (this scan's), kept on disk
    std::string takeFor = "\x01";       // the scan it was loaded for
    double playhead = 0;
    bool rolling = false, pullingFocus = false;
    double rollStart = 0, rollFrom = 0;
    float focusSeen = 0;
    static double nowSeconds() { return SDL_GetTicksNS() / 1e9; }
    static fs::path takesDir() { return g_prefs.file.parent_path() / "takes"; }
    MotionTake& workingTake() {
        if (takeFor != scanPath) {
            takeFor = scanPath;
            MotionTake t;
            if (!MotionTake::load(takesDir() / (MotionTake::digest(scanPath) + ".txt"), t) || t.scene != scanPath) {
                t = MotionTake{};
                t.scene = scanPath;
                t.frameRate = body.frameRate;
            }
            take = t;
            playhead = 0;
        }
        return take;
    }
    void saveTake() { take.save(takesDir() / (MotionTake::digest(take.scene) + ".txt")); }

    /// Puts the camera where the take has it at `t`, set as it is there.
    void pose(double t) {
        MotionTake& tk = workingTake();
        playhead = std::clamp(t, 0.0, tk.duration);
        MotionKey k;
        if (!tk.sample(playhead, k)) return;
        camera.position = k.camera.position;
        camera.yaw = k.camera.yaw;
        camera.pitch = k.camera.pitch;
        camera.velocity = {};
        camera.lookRate = {};
        if (!(rolling && pullingFocus)) body.focusM = std::max(k.focusM, body.lens().minFocusM);
        body.shutterAngle = k.shutterAngle;
        auto stops = body.lens().apertureStops();
        int best = 0;
        for (int i = 0; i < int(stops.size()); i++) if (std::fabs(stops[i] - k.fNumber) < std::fabs(stops[best] - k.fNumber)) best = i;
        body.apertureIndex = best;
        body.stopBetween = std::fabs(stops[best] - k.fNumber) < 0.01f ? 0 : k.fNumber;
        focusSeen = body.focusM;
    }
    /// The timeline's keys (motionInput in Viewer.swift).
    void motionKey(const std::string& what, bool shift) {
        MotionTake& t = workingTake();
        double step = shift ? 1 : t.frameTime();
        if (what == "setKey") {
            if (shift) say(t.deleteKey(playhead) ? "KEY DELETED" : "NO KEY HERE");
            else {
                MotionKey k;
                k.time = playhead; k.camera = camera; k.focusM = body.focusM; k.fNumber = body.takingAperture(); k.shutterAngle = body.shutterAngle;
                t.setKey(k);
                char b[96];
                snprintf(b, sizeof b, "KEY %d OF %d AT %s", t.keyNumber(playhead), int(t.keys.size()), MotionTake::timecode(playhead, t.frameRate).c_str());
                say(b);
                playFelt("shutter-change", 0.5f);
            }
            saveTake();
        }
        if (what == "prevKey")
            for (auto it = t.keys.rbegin(); it != t.keys.rend(); ++it) if (it->time < playhead - t.frameTime() / 2) { pose(it->time); break; }
        if (what == "nextKey")
            for (auto& k : t.keys) if (k.time > playhead + t.frameTime() / 2) { pose(k.time); break; }
        if (what == "stepBack") pose(playhead - step);
        if (what == "stepForward") pose(playhead + step);
        if (what == "roll") roll(false);
        if (what == "develop") developTake(!shift);
    }
    /// Plays the move in the finder in real time (again: stops it).
    void roll(bool fromTop) {
        if (rolling) { rolling = false; say("CUT"); return; }
        MotionTake& t = workingTake();
        if (t.keys.empty()) { say("NO KEYS: SET ONE WITH K (Y ON A PAD), MOVE ON WITH X, SET ANOTHER"); return; }
        double from = fromTop || playhead >= t.duration - t.frameTime() ? 0 : playhead;
        rolling = true; rollStart = nowSeconds(); rollFrom = from; pullingFocus = false;
        pose(from);
        playFelt("film-advance", 0.4f);
    }
    /// Scripted checks (developScripted in Viewer.swift): a slow pan and dolly across
    /// the view with a focus pull, as three keys over `seconds`.
    void demoTake(double seconds, const std::string& develop) {
        body.chooseBody(CameraModel::wilmont);
        body.meterAperture(meterLum);
        MotionTake& t = workingTake();
        t.keys.clear();
        t.duration = seconds;
        t.frameRate = body.frameRate;
        float step = 0.4f / body.metresPerUnit;
        for (int k = 0; k < 3; k++) {
            MotionKey key;
            key.time = seconds * k / 2;
            key.camera = camera;
            key.camera.position = camera.position + camera.right() * (step * (k - 1));
            key.camera.yaw = camera.yaw + 0.12f * (1 - k);
            key.focusM = body.focusM * (k == 0 ? 1.4f : 1.f);
            key.fNumber = body.takingAperture();
            key.shutterAngle = body.shutterAngle;
            t.setKey(key);
        }
        saveTake();
        pose(0);
        if (develop == "preview" || develop == "final") developTake(develop == "preview");
    }
    void advanceRoll() {
        if (!rolling) return;
        double t = rollFrom + nowSeconds() - rollStart;
        pose(t);
        if (t >= take.duration) { rolling = false; say("CUT"); }
    }

    // A take in the darkroom: its frames go to the renderer two at a time, come
    // back as prints on the render thread and go into the movie file, in order.
    struct Movie {
        MotionTake take;
        CameraBody body;
        LightingPlot plot;
        SkySetting sky;
        bool preview = true, postersKept = false;
        int W = 0, H = 0;
        fs::path folder, file;
        std::string kindName;
        MovieWriter writer;
        int next = 0;                               // the next frame to expose (main thread)
        std::atomic<int> written{0}, inFlight{0};
        std::atomic<bool> failed{false}, cancelled{false};
        double started = 0;
        std::mutex m;                               // the monitor's picture
        std::vector<uint32_t> thumb;
        int tw = 0, th = 0, thumbFrame = -1;
        int total() const { return take.frameCount(); }
    };
    std::shared_ptr<Movie> movie, lastMovie;
    std::string movieNote;
    double movieNoteUntil = 0;
    bool finalHevc() const { return flag("--hevc") || g_prefs.getBool("movieHevc", false); }   // --hevc: for this run
    std::string finalName() const { return finalHevc() ? "HEVC 10-bit" : "H.264"; }
    /// The final's size: 8-perf's 1.5:1 (the larger is the most the encoders take).
    std::pair<int, int> finalSize() const { return g_prefs.getInt("movieSize", 0) == 1 ? std::make_pair(1920, 1280) : std::make_pair(3072, 2048); }

    /// A line in the darkroom's notes: Vintage Click.log beside the settings.
    static void movieLog(const std::string& line) {
        fprintf(stderr, "Movie: %s\n", line.c_str());
        std::ofstream o(g_prefs.file.parent_path() / "Vintage Click.log", std::ios::app);
        o << stamp("%Y-%m-%d %H:%M:%S") << "  " << line << "\n";
    }
    /// The camera body a take was shot with, as a line in its take.txt.
    static std::string bodyLine(const CameraBody& b) {
        std::ostringstream o;
        o.precision(9);
        o << b.lensIndex << " " << b.stockIndex << " " << b.push << " " << b.filterIndex << " " << b.sceneEV << " " << b.calibration << " "
          << b.metresPerUnit << " " << b.rollNumber << " " << b.tilt.x << " " << b.tilt.y << " " << b.shift.x << " " << b.shift.y;
        return o.str();
    }
    static bool parseBody(const std::string& line, CameraBody& b) {
        std::istringstream s(line);
        CameraBody x = b;
        s >> x.lensIndex >> x.stockIndex >> x.push >> x.filterIndex >> x.sceneEV >> x.calibration >> x.metresPerUnit >> x.rollNumber >>
            x.tilt.x >> x.tilt.y >> x.shift.x >> x.shift.y;
        if (!s || x.lensIndex < 0 || x.lensIndex >= int(lensBag().size()) || x.stockIndex < 0 || x.stockIndex >= int(filmStocks().size()) ||
            x.filterIndex < 0 || x.filterIndex >= int(lensFilters().size()))
            return false;
        b = x;
        return true;
    }

    /// The working take to the darkroom: a preview (the finder's size, onto the
    /// light table) or straight to the final (posters too, so it lies there as well).
    void developTake(bool preview) {
        MotionTake t = workingTake();
        if (t.keys.empty()) { say("NO KEYS TO DEVELOP"); return; }
        if (movie) { say("A TAKE IS ALREADY IN THE DARKROOM"); return; }
        fs::path dir = rollsRoot() / fs::u8path(session);
        int n = 0;
        std::error_code ec;
        if (fs::exists(dir, ec))
            for (auto& d : fs::directory_iterator(dir, ec)) {
                std::string nm = d.path().filename().u8string();
                if (nm.rfind("Take ", 0) == 0) n = std::max(n, std::atoi(nm.c_str() + 5));
            }
        n++;
        char name[256];
        snprintf(name, sizeof name, "Take %02d - %s", n, body.rollName().c_str());
        t.frameRate = body.frameRate;
        t.takeNumber = n;
        t.bodyLine = bodyLine(body);
        auto sz = finalSize();
        startMovie(t, dir / fs::u8path(name), preview, preview ? finderW : sz.first, preview ? finderH : sz.second, body);
    }
    /// A take's final from its take.txt (R at the light table), under the lights as they are now.
    void developFinal(const fs::path& dir) {
        if (movie && movie->folder == dir) { movie->cancelled = true; say("STOPPED"); return; }
        if (movie) { say("A TAKE IS ALREADY IN THE DARKROOM"); return; }
        MotionTake t;
        if (!MotionTake::load(dir / "take.txt", t)) { say("NO TAKE RECORD BESIDE THESE POSTERS"); return; }
        if (t.scene != scanPath) { say("THAT TAKE IS FROM ANOTHER SCAN: OPEN IT TO DEVELOP IT"); return; }
        CameraBody b = body;
        parseBody(t.bodyLine, b);
        b.frameRate = t.frameRate;
        auto sz = finalSize();
        startMovie(t, dir, false, sz.first, sz.second, b);
    }
    /// Plays a take's movie in the system's player: the final if there is one, else the preview.
    void playTake(const fs::path& dir) {
        for (const char* f : {"final-hevc.mp4", "final-h264.mp4", "preview.mp4"})
            if (fs::exists(dir / f)) { SDL_OpenURL(("file:///" + (dir / f).generic_u8string()).c_str()); return; }
        say("NO MOVIE IN THIS TAKE YET");
    }

    void startMovie(MotionTake t, const fs::path& folder, bool preview, int W, int H, const CameraBody& b) {
        auto mv = std::make_shared<Movie>();
        mv->body = b;
        mv->body.modelIndex = CameraModel::wilmont;
        mv->plot = lighting;
        mv->sky = sky;
        mv->preview = preview;
        // Codecs want even sizes.
        mv->W = W & ~1; mv->H = H & ~1;
        mv->folder = folder;
        std::error_code ec;
        fs::create_directories(folder, ec);
        mv->postersKept = fs::exists(folder / "poster-0000.png");
        bool hevc = !preview && finalHevc();
        double pixels = double(mv->W) * mv->H * t.frameRate;
        auto open = [&](bool h, std::string& err, bool ten = false) {
            mv->file = folder / (preview ? "preview.mp4" : h ? "final-hevc.mp4" : "final-h264.mp4");
            unsigned rate = unsigned(std::min(200e6, pixels * (preview ? 0.2 : h ? (ten ? 0.5 : 0.4) : 0.6)));
            return mv->writer.open(mv->file, mv->W, mv->H, t.frameRate, h, rate, err, ten);
        };
        std::string err;
        bool ok = hevc && open(true, err, true);
        if (hevc && !ok) {
            movieLog("HEVC 10-bit: " + err + "; 8-bit instead");
            err.clear();
            ok = open(true, err);
        }
        if (!hevc) ok = open(false, err);
        if (!ok && hevc) {
            movieLog("HEVC: " + err + "; H.264 instead");
            err.clear();
            hevc = false;
            ok = open(false, err);
            if (ok) say("NO HEVC ENCODER: H.264 INSTEAD");
        }
        if (!ok) { say("CAN'T DEVELOP: " + upper(err)); movieLog("can't develop: " + err); return; }
        mv->kindName = preview ? "PREVIEW" : hevc ? (mv->writer.tenBit ? "HEVC 10-BIT FINAL" : "HEVC FINAL") : "H.264 FINAL";
        if (!fs::exists(folder / "take.txt")) t.save(folder / "take.txt");
        mv->take = t;
        mv->started = nowSeconds();
        rolling = false;
        movie = mv;
        char b2[256];
        snprintf(b2, sizeof b2, "take %d: %d frames at %.0f fps, %s, %dx%d, %d lens samples, %d lamps -> ", t.takeNumber, t.frameCount(),
                 t.frameRate, mv->kindName.c_str(), mv->W, mv->H, preview ? std::min(8, cells) : cells, int(lighting.lights.size()));
        movieLog(b2 + folder.u8string());
    }

    /// Keeps two frames of the take in the darkroom, and closes the file once the last is in.
    void feedMovie() {
        auto mv = movie;
        if (!mv) return;
        if (mv->failed) mv->cancelled = true;
        while (!mv->cancelled && mv->inFlight < 2 && mv->next < mv->total()) {
            int f = mv->next++;
            mv->inFlight++;
            renderer.expose(movieJob(mv, f));
        }
        if (mv->written >= mv->total() || (mv->cancelled && mv->inFlight == 0)) endMovie(mv);
    }
    std::shared_ptr<Exposure> movieJob(const std::shared_ptr<Movie>& mv, int f) {
        const MotionTake& t = mv->take;
        double t0 = f / double(t.frameRate);
        MotionKey k;
        t.sample(t0, k);
        CameraBody b = mv->body;
        b.focusM = std::max(k.focusM, b.lens().minFocusM);
        b.stopBetween = k.fNumber;
        b.shutterAngle = k.shutterAngle;
        b.frameRate = t.frameRate;
        auto e = std::make_shared<Exposure>();
        e->body = b; e->camera = k.camera; e->plot = mv->plot; e->sky = mv->sky;
        e->flare = photoFlareFor(b, k.camera, mv->plot);
        e->filterThreshold = filterThreshold();
        e->W = mv->W; e->H = mv->H; e->tileW = finderW; e->tileH = finderH;
        int n = mv->preview ? std::min(8, cells) : cells;
        e->cells = b.lens().isFisheye() ? std::vector<V2>{{0, 0}} : b.cellCentres(n);
        e->frameNumber = f + 1;
        e->out = mv->folder / "frame.png";
        // The shutter is open for its angle of the frame: the camera moves on meanwhile.
        float open = b.shutter().seconds;
        MotionTake tk = t;
        FlyCamera at = k.camera;
        e->cameraAt = [tk, t0, open, at](float u) { MotionKey s; return tk.sample(t0 + double(u) * open, s) ? s.camera : at; };
        std::weak_ptr<Movie> wm = mv;
        if (mv->writer.tenBit) {
            e->sinkFloat = [wm, f](std::vector<float>& rgbf) {
                auto mv = wm.lock();
                if (!mv) return;
                // The 8-bit copy for the posters and the monitor; the floats go into the file.
                std::vector<uint32_t> rgba(rgbf.size() / 3);
                for (size_t i = 0; i < rgba.size(); i++)
                    rgba[i] = 0xff000000u | uint32_t(std::lround(rgbf[3 * i] * 255)) | uint32_t(std::lround(rgbf[3 * i + 1] * 255)) << 8 |
                              uint32_t(std::lround(rgbf[3 * i + 2] * 255)) << 16;
                deliverFrame(mv, f, rgba, &rgbf);
            };
            return e;
        }
        e->sink = [wm, f](std::vector<uint32_t>& rgba) {
            if (auto mv = wm.lock()) deliverFrame(mv, f, rgba, nullptr);
        };
        return e;
    }
    /// A developed frame into the movie (floats for a 10-bit file), a poster now and then, the monitor.
    static void deliverFrame(const std::shared_ptr<Movie>& mv, int f, std::vector<uint32_t>& rgba, const std::vector<float>* rgbf) {
        {
            int W = mv->W, H = mv->H;
            if (rgba.size() != size_t(W) * H) {
                movieLog("frame " + std::to_string(f + 1) + " failed in the darkroom");
                mv->failed = true;
            } else if (!mv->cancelled && !mv->failed) {
                if (!(rgbf ? mv->writer.writeFloat(rgbf->data(), f) : mv->writer.write(rgba.data(), f))) {
                    movieLog("frame " + std::to_string(f + 1) + " didn't go into the movie");
                    mv->failed = true;
                } else {
                    // Posters for the light table (a final made straight from the camera
                    // lays its own, when there is no preview's to keep).
                    if (f % 12 == 0 && (mv->preview || !mv->postersKept)) {
                        std::vector<uint8_t> rgb(size_t(W) * H * 3);
                        for (size_t i = 0; i < rgba.size(); i++) {
                            rgb[3 * i] = uint8_t(rgba[i]); rgb[3 * i + 1] = uint8_t(rgba[i] >> 8); rgb[3 * i + 2] = uint8_t(rgba[i] >> 16);
                        }
                        char nm[32]; snprintf(nm, sizeof nm, "poster-%04d.png", f);
                        stbi_write_png((mv->folder / nm).u8string().c_str(), W, H, 3, rgb.data(), W * 3);
                    }
                    // The darkroom's monitor: this frame, small.
                    int tw = std::min(W, 480), th = H * tw / W;
                    std::vector<uint32_t> small(size_t(tw) * th);
                    for (int y = 0; y < th; y++)
                        for (int x = 0; x < tw; x++) small[size_t(y) * tw + x] = rgba[size_t(y * H / th) * W + x * W / tw] | 0xff000000u;
                    std::lock_guard<std::mutex> l(mv->m);
                    mv->thumb = std::move(small); mv->tw = tw; mv->th = th; mv->thumbFrame = f;
                }
                mv->written++;
            }
            mv->inFlight--;
        }
    }
    void endMovie(const std::shared_ptr<Movie>& mv) {
        movie.reset();
        bool ok = mv->writer.finish();
        int w = mv->written;
        char msg[160];
        if (w == 0) snprintf(msg, sizeof msg, "TAKE %d %s STOPPED BEFORE ITS FIRST FRAME", mv->take.takeNumber, mv->kindName.c_str());
        else if (mv->failed || !ok) snprintf(msg, sizeof msg, "TAKE %d %s FAILED", mv->take.takeNumber, mv->kindName.c_str());
        else if (mv->cancelled) snprintf(msg, sizeof msg, "TAKE %d %s STOPPED AT %d OF %d FRAMES", mv->take.takeNumber, mv->kindName.c_str(), w, mv->total());
        else snprintf(msg, sizeof msg, "TAKE %d %s DEVELOPED · ON THE LIGHT TABLE", mv->take.takeNumber, mv->kindName.c_str());
        std::error_code ec;
        // An empty clip is no use to anyone.
        if (w == 0) fs::remove(mv->file, ec);
        char b[64]; snprintf(b, sizeof b, " after %.1f min -> ", (nowSeconds() - mv->started) / 60);
        movieLog(std::string(msg) + b + mv->file.u8string());
        movieNote = msg;
        movieNoteUntil = nowSeconds() + 20;
        lastMovie = mv;     // its last frame stays on the monitor with the note
        say(msg);
        if (mode == Mode::Sheet) scanRolls();
    }

    /// How far the take in the darkroom is, and how long it has to go.
    std::string movieProgress(float& done) {
        auto mv = movie;
        float partial = 0;
        {
            std::lock_guard<std::mutex> l(renderer.m);
            // The frame being exposed now: the first not yet through all its sub-pupils.
            for (auto& e : renderer.darkroom)
                if (e->sink && e->next < e->cells.size()) { partial = float(e->next) / float(std::max<size_t>(1, e->cells.size())); break; }
        }
        partial = std::min(partial, 1.f);
        done = (mv->written + partial) / float(std::max(1, mv->total()));
        double elapsed = nowSeconds() - mv->started;
        char left[64] = "TIMING THE FIRST FRAME";
        if (done > 0.002f && elapsed > 5) {
            double sLeft = elapsed * (1 - done) / done;
            if (sLeft < 90) snprintf(left, sizeof left, "ABOUT %.0f S LEFT", sLeft);
            else if (sLeft < 5400) snprintf(left, sizeof left, "ABOUT %.0f MIN LEFT", sLeft / 60);
            else snprintf(left, sizeof left, "ABOUT %.1f H LEFT", sLeft / 3600);
        }
        char b[256];
        snprintf(b, sizeof b, "DEVELOPING TAKE %d %s · FRAME %d OF %d (%.0f%%) · %s", mv->take.takeNumber, mv->kindName.c_str(),
                 std::min(mv->total(), int(mv->written) + 1), mv->total(), partial * 100, left);
        return b;
    }

    /// The darkroom's monitor: the frame developed last, small in the upper right
    /// while the rest develop (DarkroomMonitor.swift).
    void drawMonitor() {
        auto mv = movie ? movie : (nowSeconds() < movieNoteUntil ? lastMovie : nullptr);
        if (!mv) return;
        std::vector<uint32_t> pic;
        int tw, th, frame;
        {
            std::lock_guard<std::mutex> l(mv->m);
            if (mv->thumb.empty()) return;
            pic = mv->thumb; tw = mv->tw; th = mv->th; frame = mv->thumbFrame;
        }
        float w = std::round(cv.w * 0.3f), h = std::round(w * th / tw), cap = 22;
        float x0 = cv.w - w - 24, y0 = 24;
        cv.rect(x0, y0, x0 + w, y0 + h + cap, {0, 0, 0, 0.75f});
        for (int y = std::max(0, int(y0)); y < std::min(cv.h, int(y0 + h)); y++)
            for (int x = std::max(0, int(x0)); x < std::min(cv.w, int(x0 + w)); x++) {
                int sx = std::clamp(int((x - x0) / w * tw), 0, tw - 1), sy = std::clamp(int((y - y0) / h * th), 0, th - 1);
                cv.px[size_t(y) * cv.w + x] = pic[size_t(sy) * tw + sx];
            }
        RGBA edge{1, 1, 1, 0.35f};
        cv.line({x0, y0}, {x0 + w, y0}, 1, edge); cv.line({x0 + w, y0}, {x0 + w, y0 + h}, 1, edge);
        cv.line({x0 + w, y0 + h}, {x0, y0 + h}, 1, edge); cv.line({x0, y0 + h}, {x0, y0}, 1, edge);
        char c[96]; snprintf(c, sizeof c, "LAST DEVELOPED: FRAME %d OF %d", frame + 1, mv->total());
        font.draw(cv, c, x0 + 6, y0 + h + 4, 12, {1, 0.92f, 0.8f, 0.85f}, 0);
    }

    /// The ground glass's markings (the 1.85 extraction inside the 8-perf frame),
    /// and the timeline along the bottom of the image: projected light (ViewfinderHUD.drawMotion).
    void drawMotion(const Inset& in, float u) {
        float imgW = finderW * in.s, imgH = finderH * in.s;
        float ix0 = in.x, iy0 = in.y, ix1 = in.x + imgW, iy1 = in.y + imgH, mx = (ix0 + ix1) / 2, my = (iy0 + iy1) / 2;
        RGBA lit{0.93f, 0.96f, 1.0f, 0.5f}, warmC{1, 0.9f, 0.78f, 0.85f}, red{0.95f, 0.15f, 0.08f, 0.95f};
        float glow = 0.35f * u;
        // 1.85:1 inside 1.5:1: corner marks top and bottom, and a centre cross.
        float h85 = imgW / 1.85f, rx0 = ix0 + 0.6f * u, rx1 = ix1 - 0.6f * u, ry0 = my - h85 / 2, ry1 = my + h85 / 2, k = 2.2f * u;
        float lw = std::max(1.f, 0.12f * u);
        for (auto [x, y, dx, dy] : {std::array<float, 4>{rx0, ry0, 1, 1}, {rx1, ry0, -1, 1}, {rx0, ry1, 1, -1}, {rx1, ry1, -1, -1}}) {
            cv.line({x + dx * k, y}, {x, y}, lw, lit, glow, true);
            cv.line({x, y}, {x, y + dy * k}, lw, lit, glow, true);
        }
        cv.line({mx - 0.8f * u, my}, {mx + 0.8f * u, my}, lw, lit, glow, true);
        cv.line({mx, my - 0.8f * u}, {mx, my + 0.8f * u}, lw, lit, glow, true);
        font.draw(cv, "1.85", rx0 + 0.4f * u, ry0 + 0.3f * u, int(0.7f * u), lit, 0.45f);

        MotionTake& t = workingTake();
        float x0 = ix0 + 4 * u, x1 = ix1 - 4 * u, y = iy1 - 2.6f * u;
        RGBA rule{warmC.r, warmC.g, warmC.b, 0.6f};
        float rw = std::max(1.f, 0.1f * u);
        cv.line({x0, y}, {x1, y}, rw, rule, 0, true);
        for (int i = 0; i <= 10; i++) {
            float x = x0 + (x1 - x0) * i / 10;
            cv.line({x, y - 0.25f * u}, {x, y + 0.25f * u}, rw, rule, 0, true);
        }
        float progress = 0;
        std::string developing;
        if (movie) developing = movieProgress(progress);
        else if (nowSeconds() < movieNoteUntil) developing = movieNote;
        if (progress > 0) cv.rect(x0, y - 0.15f * u, x0 + (x1 - x0) * std::min(1.f, progress), y + 0.15f * u, {warmC.r, warmC.g, warmC.b, 0.7f});
        int current = t.keyNumber(playhead) - 1;
        for (size_t i = 0; i < t.keys.size(); i++) {
            float f = float(t.keys[i].time / t.duration);
            V2 c{x0 + (x1 - x0) * std::clamp(f, 0.f, 1.f), y};
            float sz = 0.45f * u;
            if (int(i) == current)
                for (float yy = -sz; yy <= sz; yy += 0.5f) { float half = sz - std::fabs(yy); cv.line({c.x - half, c.y + yy}, {c.x + half, c.y + yy}, 1, warmC); }
            V2 pts[4] = {{c.x, c.y - sz}, {c.x + sz, c.y}, {c.x, c.y + sz}, {c.x - sz, c.y}};
            for (int j = 0; j < 4; j++) cv.line(pts[j], pts[(j + 1) % 4], rw, warmC, 0, true);
        }
        float px = x0 + (x1 - x0) * float(std::clamp(playhead / t.duration, 0.0, 1.0));
        cv.line({px, y - 0.9f * u}, {px, y + 0.9f * u}, std::max(1.f, 0.16f * u), rolling ? red : warmC, 0, true);
        font.draw(cv, MotionTake::timecode(playhead, t.frameRate), x0, y - 2.0f * u, int(0.9f * u), warmC, 0.45f);
        char rate[96];
        snprintf(rate, sizeof rate, "%.0f FPS · %s  ·  %.0f S", body.frameRate, body.shutter().label.c_str(), t.duration);
        std::string right = developing.empty() ? std::string(rate) : developing;
        float wr = font.width(right, int(0.9f * u));
        font.draw(cv, right, x1 - wr, y - 2.0f * u, int(0.9f * u), warmC, 0.45f);
        // The controls, faint under the rule.
        if (!rolling) {
            std::string hint = movie ? (pad ? "B or Start: stop developing (the frames so far are kept)" : "Esc: stop developing (the frames so far are kept)")
                             : pad ? "L2 / R2 focus  ·  Y set key  ·  hold B: ◀ ▶ keys, L1 / R1 step a second, ▼ delete key, ▲ develop preview  ·  A roll  ·  final: Menu › Camera bag › Motion"
                                   : "scroll or F / C focus  ·  K set key (focus too)  ·  Shift-K delete  ·  I / O previous / next key  ·  Z / X step (Shift: a second)  ·  P roll  ·  G preview  ·  Shift-G final";
            int hs = int(0.68f * u);
            float hw = font.width(hint, hs);
            font.draw(cv, hint, mx - hw / 2, y + 0.8f * u, hs, {warmC.r, warmC.g, warmC.b, 0.45f}, 0.45f);
        }
        // Rolling: the tally.
        if (rolling) {
            cv.circle({ix0 + 2.55f * u, iy0 + 2.55f * u}, 0.28f * u, 0.55f * u, red);
            font.draw(cv, "REC", ix0 + 3.5f * u, iy0 + 1.85f * u, int(0.9f * u), red, 0.45f);
        }
    }

    // ---- the light table ----
    void scanRolls() {
        rolls.clear(); sessions.clear();
        fs::path root = rollsRoot();
        if (!fs::exists(root)) return;
        std::vector<fs::path> days;
        for (auto& d : fs::directory_iterator(root)) if (d.is_directory()) days.push_back(d.path());
        std::sort(days.begin(), days.end());
        for (auto& day : days) {
            std::vector<fs::path> sits;
            for (auto& s : fs::directory_iterator(day)) if (s.is_directory()) sits.push_back(s.path());
            std::sort(sits.begin(), sits.end());
            for (auto& sit : sits) {
                std::vector<fs::path> rs;
                for (auto& r : fs::directory_iterator(sit)) if (r.is_directory()) rs.push_back(r.path());
                std::sort(rs.begin(), rs.end());
                std::vector<int> group;
                for (auto& r : rs) {
                    std::string nm = r.filename().u8string();
                    bool isTake = nm.rfind("Take ", 0) == 0;
                    if (nm.rfind("Roll ", 0) != 0 && !isTake) continue;
                    Roll roll{std::atoi(nm.c_str() + 5), nm.find(" - ") != std::string::npos ? nm.substr(nm.find(" - ") + 3) : "",
                              day.filename().u8string() + " · " + sit.filename().u8string(), r, {}, isTake};
                    if (isTake) roll.stock = "Take " + nm.substr(5, 2) + "  ·  " + roll.stock;
                    for (auto& f : fs::directory_iterator(r))
                        if (f.path().extension() == ".png" && f.path().filename().u8string().rfind(isTake ? "poster-" : "frame-", 0) == 0)
                            roll.frames.push_back(f.path());
                    if (roll.frames.empty() && isTake) continue;
                    std::sort(roll.frames.begin(), roll.frames.end());
                    group.push_back(int(rolls.size()));
                    rolls.push_back(roll);
                }
                if (!group.empty()) sessions.push_back(group);
            }
        }
        sessionIndex = std::max(0, int(sessions.size()) - 1);
        loadMarks();
    }
    const std::vector<uint8_t>* thumb(const fs::path& p, int& w, int& h) {
        std::string k = p.u8string();
        auto it = thumbs.find(k);
        if (it == thumbs.end()) {
            int iw, ih, n;
            unsigned char* d = stbi_load(k.c_str(), &iw, &ih, &n, 3);
            if (!d) return nullptr;
            // Keep a 960-wide copy: enough for the loupe at a few times.
            int tw = std::min(960, iw), th = ih * tw / iw;
            std::vector<uint8_t> t(size_t(tw) * th * 3);
            for (int y = 0; y < th; y++)
                for (int x = 0; x < tw; x++)
                    for (int c = 0; c < 3; c++) t[(size_t(y) * tw + x) * 3 + c] = d[(size_t(y * ih / th) * iw + x * iw / tw) * 3 + c];
            stbi_image_free(d);
            thumbSize[k] = {tw, th};
            it = thumbs.emplace(k, std::move(t)).first;
        }
        w = thumbSize[k].first; h = thumbSize[k].second;
        return &it->second;
    }

    // ---- drawing ----
    /// Where the finder's image sits in the window (Viewer.finderImage / finderInset):
    /// a 3:2 window inset in the black surround, room below for the LED readouts.
    Inset inset() const {
        return {cv.w * 0.09f, cv.h * 0.045f, 0.82f * cv.w / finderW, cv.h * 0.025f};
    }

    // ---- the finder on the GPU (Viewer.draw in the Swift app) ----
    Uint64 displayFrame = 0;
    SDL_GPUBuffer* gOut = nullptr;      // the window's pixels
    SDL_GPUBuffer* gMeter = nullptr;    // the meter's 48 x 32 samples
    SDL_GPUBuffer* gPlate = nullptr;    // the meter's drawn scale
    SDL_GPUBuffer* gFlareVis = nullptr; // how much of each flaring light the camera sees
    std::vector<float> flareVis;        // the same, eased

    /// The flare rows for a photo (photoFlare in Viewer.swift): the lights as the
    /// finder sees them, with the finder's visibility.
    std::vector<V4> photoFlare() const {
        float fx = body.focalPixels(finderW, finderH);
        V2 axis = V2{finderW / 2.f, finderH / 2.f} + body.axisOffset(finderW);
        auto s = flare::sources(lighting, camera.viewMatrix(), camera.position, fx, axis, finderW, finderH, body.lens().isFisheye(), body,
                                body.takingAperture());
        if (s.empty()) return {};
        auto rows = flare::uniforms(s, flareVis.size() == s.size() ? flareVis : std::vector<float>(s.size(), 1.f), body.lens(),
                                    body.takingAperture(), {axis.x / finderW, axis.y / finderH}, &body.filter());
        return std::vector<V4>(rows.begin(), rows.end());
    }
    /// The flare for a movie frame: the lights as that frame's camera sees them.
    std::vector<V4> photoFlareFor(const CameraBody& b, const FlyCamera& cam, const LightingPlot& plot) const {
        float fx = b.focalPixels(finderW, finderH);
        V2 axis = V2{finderW / 2.f, finderH / 2.f} + b.axisOffset(finderW);
        auto s = flare::sources(plot, cam.viewMatrix(), cam.position, fx, axis, finderW, finderH, b.lens().isFisheye(), b, b.takingAperture());
        if (s.empty()) return {};
        auto rows = flare::uniforms(s, std::vector<float>(s.size(), 1.f), b.lens(), b.takingAperture(), {axis.x / finderW, axis.y / finderH}, &b.filter());
        return std::vector<V4>(rows.begin(), rows.end());
    }
    std::vector<uint32_t> plateText;
    int plateW = 0, plateH = 0, plateKey = -1;
    float plateRect[4] = {0, 0, 0, 0};

    /// How bright a point must be for a filter's spikes or halo (Viewer.filterThreshold).
    float filterThreshold() const { return std::min(0.95f, std::max(0.35f, meterLum * 5)); }

    /// Optics for the focusing screen (finderOptics in Viewer.swift; layout in Shaders.swift).
    std::array<V4, 14> screenOptics(const FinderJob& j, bool mirrorUp) const {
        const Lens& l = body.lens();
        std::array<V4, 14> o{};
        o[0] = {float(j.W), float(j.H), j.fx, j.fx};
        o[1] = {j.axis.x, j.axis.y, body.metresPerUnit, body.focusM};
        o[2] = {l.focalMM / 1000, body.viewingAperture(), l.maxAperture, float(l.blades)};
        o[3] = {l.catsEye, l.soapBubble, l.bladeRotation, l.vignette};
        o[4] = {0.08f, 0.08f, 0.09f, place ? 2.f : 1.f};
        // Stopping down for the depth-of-field preview darkens the screen.
        o[5] = {j.H * 0.065f, std::pow(l.maxAperture / body.viewingAperture(), 2.f) * std::exp2(-body.closeFocusLoss()) * finderGain,
                float(displayFrame), body.exposureStops()};
        o[6] = {l.lateralCA, l.axialCA, l.projection == Projection::CircularFisheye ? j.H / 2.f : 0, l.obstruction};
        o[7] = {cv.w * 0.09f, cv.h * 0.045f, 0.82f, cv.h * 0.025f};
        o[8] = {l.squeeze, mirrorUp ? 1.f : 0.f, 0, 0};
        body.filter().optics(filterThreshold(), &o[9]);
        // The rangefinder (O[12], O[13]): a clear window and its focusing patch, whose
        // second image (from the rangefinder's window, 69 mm along) moves by fx B (1/z - 1/s);
        // a shoe finder has no patch. O[13].z: the Kwanon's screen, the split alone.
        bool rf = body.model().rangefinder() && j.fromLight < 0;
        bool ext = rf && (l.focalMM < 27 || l.isFisheye());
        o[12] = {rf && !ext ? 1.f : 0.f, j.W * 0.055f, j.H * 0.045f, 0.069f * j.fx};
        o[13] = {1 / std::max(body.focusM, 0.05f), rf ? 1.f : 0.f, body.model().shutterPriority() ? 1.f : 0.f, 0};
        // The movie camera's finder: a plain ground glass, no focusing aids.
        if (body.model().isMotion()) o[5].x = 0;
        if (j.fromLight >= 0) {
            // A light's view: no filter, no focusing aids, no lens colour or fall-off.
            lensFilters()[0].optics(1, &o[9]);
            o[5].x = 0; o[6].x = 0; o[3].w = 0; o[2].y = l.maxAperture;
        }
        return o;
    }

    /// The meter's centre-weighted reading from its 48 x 32 samples (Viewer.centreWeighted).
    static float centreWeighted(const float* v) {
        float sum = 0, wsum = 0;
        for (int y = 0; y < 32; y++)
            for (int x = 0; x < 48; x++) {
                float u = (x + 0.5f) / 48 - 0.5f, w2 = (y + 0.5f) / 32 - 0.5f;
                float w = 0.25f + std::exp(-(u * u + w2 * w2) / 0.03f);
                sum += w * v[y * 48 + x];
                wsum += w;
            }
        return sum / wsum;
    }

    /// The meter's scale, drawn as light on black (its plate), again only when it changes.
    void makePlate(const Inset& in) {
        MeterSpec m = meterSpec(in);
        float u = m.u;
        int key = ((m.set * 8 + body.modelIndex) * 64 + body.lensIndex) * 100000 + cv.w;
        if (key == plateKey && gPlate) return;
        plateKey = key;
        // The plate covers the card and the set-speed tab beside it.
        float x0 = std::floor((m.right ? m.x0 - 2 * u : m.x0) - 0.6f * u), y0 = std::floor(m.y0 - 0.6f * u);
        float x1 = std::ceil((m.right ? m.x0 + m.w : m.x0 + m.w + 2 * u) + 0.6f * u), y1 = std::ceil(m.y0 + m.h + 0.6f * u);
        Canvas saved = std::move(cv);
        cv.resize(saved.w, saved.h);                       // black: the plate's light only
        drawMeterScale(in);
        plateW = int(x1 - x0); plateH = int(y1 - y0);
        plateText.assign(size_t(plateW) * plateH, 0);
        for (int y = 0; y < plateH; y++)
            for (int x = 0; x < plateW; x++) {
                int sx = int(x0) + x, sy = int(y0) + y;
                if (sx >= 0 && sy >= 0 && sx < cv.w && sy < cv.h) plateText[size_t(y) * plateW + x] = cv.px[size_t(sy) * cv.w + sx];
            }
        cv = std::move(saved);
        plateRect[0] = x0; plateRect[1] = y0; plateRect[2] = float(plateW); plateRect[3] = float(plateH);
        Renderer::gpu->release(gPlate);
        gPlate = Renderer::gpu->buffer(plateText.size() * 4);
        if (gPlate) Renderer::gpu->upload(gPlate, plateText.data(), plateText.size() * 4);
    }

    /// The camera on its tripod, for seeing where it is from a light (cameraWireframe in Viewer.swift).
    std::vector<std::pair<V3, V3>> cameraWireframe(float scale) const {
        float s = 1 / scale;
        V3 p = camera.position, f = camera.forward(), r = camera.right(), u = camera.down() * -1;
        float w = 0.14f * s, h = 0.09f * s, d = 0.07f * s;
        std::vector<std::pair<V3, V3>> segs;
        const float c[8][3] = {{-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1}, {-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1}};
        V3 v[8];
        for (int i = 0; i < 8; i++) v[i] = p + r * (c[i][0] * w / 2) + u * (c[i][1] * h / 2) + f * (c[i][2] * d / 2);
        const int e[12][2] = {{0, 1}, {1, 2}, {2, 3}, {3, 0}, {4, 5}, {5, 6}, {6, 7}, {7, 4}, {0, 4}, {1, 5}, {2, 6}, {3, 7}};
        for (auto& ab : e) segs.push_back({v[ab[0]], v[ab[1]]});
        V3 lc = p + f * (d / 2);
        for (int k = 0; k < 12; k++) {
            float a0 = float(k) / 12 * 2 * float(M_PI), a1 = float(k + 1) / 12 * 2 * float(M_PI);
            segs.push_back({lc + (r * std::cos(a0) + u * std::sin(a0)) * (h * 0.4f), lc + (r * std::cos(a1) + u * std::sin(a1)) * (h * 0.4f)});
        }
        segs.push_back({lc, lc + f * (body.focusM / scale)});
        for (float a : {0.0f, 2.1f, 4.2f}) {
            V3 top = p - u * (h / 2);
            V3 spread = (r * std::cos(a) + f * std::sin(a)) * (0.35f * s);
            segs.push_back({top, p - u * (1.5f * s) + spread});
        }
        return segs;
    }

    /// The light heads as wireframes on the screen, over the frame they belong to
    /// (drawWireframes, wire_vertex and wire_fragment in the Swift app): each
    /// segment a soft band of light, a faint wide glow and a fine core, added on,
    /// dimmed where the scene stands in front.
    void drawWireframes(const Frame& fr, const FinderJob& j) {
        const LightingPlot& plot = j.plot;
        float scale = j.body.metresPerUnit;
        struct Shape { std::vector<std::pair<V3, V3>> segs; bool chosen; };
        std::vector<Shape> shapes;
        float focusUnits = j.body.focusM / scale;
        for (int i = 0; i < int(plot.lights.size()); i++) {
            if (i == j.fromLight) continue;
            bool chosen = mode == Mode::Lighting && i == plot.selected && j.fromLight < 0;
            float target = len(plot.lights[i].position - (camera.position + camera.forward() * focusUnits));
            shapes.push_back({plot.lights[i].wireframe(camera.up, scale, chosen ? target : 0), chosen});
        }
        if (j.fromLight >= 0) shapes.push_back({cameraWireframe(scale), true});
        if (shapes.empty()) return;
        auto o = screenOptics(j, false);
        const std::vector<float>& V = j.view;
        auto cam = [&](V3 p) {
            return V3{V[0] * p.x + V[1] * p.y + V[2] * p.z + V[3], V[4] * p.x + V[5] * p.y + V[6] * p.z + V[7],
                      V[8] * p.x + V[9] * p.y + V[10] * p.z + V[11]};
        };
        float nearZ = 0.02f / scale;
        bool fisheye = j.fisheye && j.fromLight < 0;
        V2 centre = j.axis;
        auto onScreen = [&](V3 q) {
            if (fisheye) {
                float r = std::sqrt(q.x * q.x + q.y * q.y), th = std::atan2(r, q.z);
                return r > 1e-9f ? centre + V2{q.x / r, q.y / r} * (j.fx * th) : centre;
            }
            return centre + V2{q.x / q.z, q.y / q.z} * j.fx;
        };
        // Eyepiece pincushion (eyepiece / eyepiece_forward in Shaders.swift).
        V2 c0{o[0].x * 0.5f, o[0].y * 0.5f};
        auto eyepiece = [&](V2 pos, float k) { V2 d = pos - c0; return c0 + d * (1 - k * (d.x * d.x + d.y * d.y) / (c0.x * c0.x + c0.y * c0.y)); };
        auto eyeFwd = [&](V2 pos, float k) { V2 d = pos - c0; return c0 + d * (1 + k * (d.x * d.x + d.y * d.y) / (c0.x * c0.x + c0.y * c0.y)); };
        auto frameZ = [&](V2 p) {
            int x = std::clamp(int(p.x), 0, fr.w - 1), y = std::clamp(int(p.y), 0, fr.h - 1);
            size_t i = size_t(y) * fr.w + x;
            float T = fr.T[i], d = fr.z[i];
            if (T > 0.97f || !(d > 0)) return 1e5f;
            V2 uv{(x + 0.5f - o[1].x) / o[0].z, (y + 0.5f - o[1].y) / o[0].w};
            return d / std::sqrt(1 + uv.x * uv.x + uv.y * uv.y) * o[1].z;
        };
        for (auto& sh : shapes) {
            // Segments in image pixels, with metres along the axis.
            std::vector<std::array<float, 6>> segs;   // ax, ay, az, bx, by, bz
            for (auto& ab : sh.segs) {
                V3 pa = cam(ab.first), pb = cam(ab.second);
                if (fisheye) {
                    const int n = 12;
                    bool have = false; V3 prev{};
                    for (int i = 0; i <= n; i++) {
                        V3 q = pa + (pb - pa) * (float(i) / n);
                        bool ok = std::atan2(std::sqrt(q.x * q.x + q.y * q.y), q.z) < 1.65f && len(q) > nearZ;
                        if (ok && have) {
                            V2 s0 = onScreen(prev), s1 = onScreen(q);
                            segs.push_back({s0.x, s0.y, std::max(prev.z, nearZ) * scale, s1.x, s1.y, std::max(q.z, nearZ) * scale});
                        }
                        have = ok; prev = q;
                    }
                    continue;
                }
                if (pa.z < nearZ && pb.z < nearZ) continue;
                if (pa.z < nearZ) pa = pb + (pa - pb) * ((pb.z - nearZ) / (pb.z - pa.z));
                if (pb.z < nearZ) pb = pa + (pb - pa) * ((pa.z - nearZ) / (pa.z - pb.z));
                V2 s0 = onScreen(pa), s1 = onScreen(pb);
                segs.push_back({s0.x, s0.y, pa.z * scale, s1.x, s1.y, pb.z * scale});
            }
            // Warm cream light, as framelines are; the light being placed a little brighter, warmer.
            V4 colour = sh.chosen ? V4{1.0f, 0.80f, 0.55f, 0.75f} : V4{1.0f, 0.92f, 0.80f, 0.42f};
            for (auto [half, gain] : {std::pair<float, float>{9, 0.16f}, {2.4f, 1}}) {
                float hw = half * float(cv.h) / 1080;
                for (auto& s : segs) {
                    V2 a = eyeFwd(V2{o[7].x + s[0] * o[7].z, o[7].y + s[1] * o[7].z}, 0.018f);
                    V2 b = eyeFwd(V2{o[7].x + s[3] * o[7].z, o[7].y + s[4] * o[7].z}, 0.018f);
                    V2 d = b - a;
                    float L = std::max(len(d), 1e-3f);
                    d = d * (1 / L);
                    V2 nrm{-d.y, d.x};
                    int x0 = std::max(0, int(std::floor(std::min(a.x, b.x) - hw - 1))), x1 = std::min(cv.w - 1, int(std::ceil(std::max(a.x, b.x) + hw + 1)));
                    int y0 = std::max(0, int(std::floor(std::min(a.y, b.y) - hw - 1))), y1 = std::min(cv.h - 1, int(std::ceil(std::max(a.y, b.y) + hw + 1)));
                    if (x1 - x0 > 4000 || y1 - y0 > 4000) continue;
                    for (int y = y0; y <= y1; y++)
                        for (int x = x0; x <= x1; x++) {
                            V2 pos{x + 0.5f, y + 0.5f}, w = pos - a;
                            float t = w.x * d.x + w.y * d.y, across = (w.x * nrm.x + w.y * nrm.y) / hw;
                            if (t < -hw || t > L + hw || std::fabs(across) >= 1) continue;
                            // Where the eye sees this: the lines stop at the window's rounded edge.
                            V2 halfSize{o[0].x * 0.5f, o[0].y * 0.5f};
                            V2 pe = (eyepiece(pos, 0.018f) - V2{o[7].x, o[7].y}) * (1 / o[7].z);
                            float qx = std::fabs(pe.x - halfSize.x) - (halfSize.x - o[7].w), qy = std::fabs(pe.y - halfSize.y) - (halfSize.y - o[7].w);
                            float edge = std::sqrt(std::max(qx, 0.f) * std::max(qx, 0.f) + std::max(qy, 0.f) * std::max(qy, 0.f)) +
                                         std::min(std::max(qx, qy), 0.f) - o[7].w;
                            float inside = 1 - smoothstepf(-2, 0, edge);
                            if (inside <= 0) continue;
                            float z = s[2] + (s[5] - s[2]) * std::clamp(t / L, 0.f, 1.f);
                            float behind = z > frameZ(pe) * 1.01f ? 0.3f : 1.0f;
                            float xa = std::fabs(across);
                            float profile = std::exp(-xa * xa * 3.2f) * (1 - smoothstepf(0.85f, 1.0f, xa));
                            float al = behind * profile * colour.w * gain * inside;
                            uint32_t& px = cv.px[size_t(y) * cv.w + x];
                            float rr = float(px & 255) + colour.x * al * 255, gg = float((px >> 8) & 255) + colour.y * al * 255,
                                  bb = float((px >> 16) & 255) + colour.z * al * 255;
                            px = 0xff000000u | uint32_t(std::min(rr, 255.f)) | uint32_t(std::min(gg, 255.f)) << 8 | uint32_t(std::min(bb, 255.f)) << 16;
                        }
                }
            }
        }
    }

    /// The finder drawn on the GPU into the window's pixels; false: fall back to the CPU.
    bool drawFinderGPU(int slot, const FinderJob& j, bool mirrorUp, float dt) {
        Gpu& g = *Renderer::gpu;
        SDL_GPUBuffer* frame = renderer.gfinder[slot];
        if (!frame || j.W != cv.w || j.H != cv.h) return false;
        displayFrame++;
        // Eyes adapt, but not all the way: night stays night in the finder,
        // and a dim interior looks dimmer than a sunlit street.
        float light = std::pow(2.f, (body.sceneEV + body.calibration - 13) * 0.35f);
        float want = std::clamp(0.06f / std::max(meterLum, 1e-6f), 1.f, 24.f) * std::clamp(light, 0.2f, 1.6f);
        finderGain *= std::pow(want / finderGain, std::min(1.f, dt * 0.8f));
        auto o = screenOptics(j, mirrorUp);
        if (!gMeter) gMeter = g.buffer(48 * 32 * 4);
        if (!gOut) gOut = g.buffer(size_t(cv.w) * cv.h * 4);
        if (!gMeter || !gOut) return false;
        // The meter: 48 x 32 samples of the frame, centre-weighted.
        float samples[48 * 32];
        if (!g.run(Renderer::kernels.meter, {frame}, {gMeter}, {{o.data(), sizeof o}}, 48, 32) ||
            !g.download(gMeter, samples, sizeof samples)) return false;
        meterLum = centreWeighted(samples);
        // Shutter-priority: the camera sets the aperture from the meter.
        if (body.autoOn()) body.meterAperture(meterLum);
        Inset in = inset();
        makePlate(in);
        V2 pivot, tip;
        float u = needleGeometry(in, pivot, tip);
        // A rangefinder has no meter card (its needle is across the top); a light's view none.
        bool meterOn = gPlate && !body.model().rangefinder() && j.fromLight < 0;
        std::array<V4, 4> M{V4{plateRect[0], plateRect[1], plateRect[2], plateRect[3]}, V4{pivot.x, pivot.y, tip.x, tip.y},
                            V4{meterOn ? 1.f : 0.f, u, apertureScale() ? 1.f : 0.f, 0}, V4{float(plateW), float(plateH), 0, 0}};
        // Lens flare: which lights shine into the lens, and how much of each the camera sees.
        flare::Rows fl{};
        V2 fAxis = j.axis;
        std::vector<flare::Source> src;
        if (j.fromLight < 0)
            src = flare::sources(j.plot, j.view, j.position, j.fx, fAxis, j.W, j.H, j.fisheye, j.body, j.body.viewingAperture());
        if (!src.empty()) {
            auto probes = flare::probes(src, std::sqrt(float(j.W * j.W + j.H * j.H)));
            struct { V4 o0; uint32_t c[4]; } pc{{float(j.W), float(j.H), j.fx, j.fx}, {uint32_t(src.size()), 0, 0, 0}};
            if (!gFlareVis) gFlareVis = g.buffer(flare::maxLights * 4);
            float seen[flare::maxLights] = {};
            if (gFlareVis && g.run(Renderer::kernels.flareProbe, {frame}, {gFlareVis}, {{&pc, sizeof pc}, {probes.data(), sizeof probes}},
                                   uint32_t(src.size())) && g.download(gFlareVis, seen, sizeof seen)) {
                if (flareVis.size() != src.size()) flareVis.assign(src.size(), 1.f);
                for (size_t k = 0; k < src.size(); k++) flareVis[k] += (seen[k] - flareVis[k]) * 0.5f;
            }
            std::vector<float> seenNow = mirrorUp ? std::vector<float>(src.size(), 0.f) : flareVis;
            fl = flare::uniforms(src, seenNow, j.body.lens(), j.body.viewingAperture(), {fAxis.x / j.W, fAxis.y / j.H}, &j.body.filter());
        }
        if (!g.run(Renderer::kernels.viewfinder, {frame, gPlate ? gPlate : frame}, {gOut},
                   {{o.data(), sizeof o}, {M.data(), sizeof M}, {fl.data(), sizeof fl}}, cv.w, cv.h) ||
            !g.download(gOut, cv.px.data(), cv.px.size() * 4)) return false;
        drawReadouts(in);
        return true;
    }

    void drawFinder(const Frame& f, const FinderJob& j, bool mirrorUp) {
        Optics o = finderOptics(j);
        // Eyes adapt, but not all the way (see Viewer.swift).
        float light = std::pow(2.f, (body.sceneEV + body.calibration - 13) * 0.35f);
        float want = std::clamp(0.06f / std::max(meterLum, 1e-6f), 1.f, 24.f) * std::clamp(light, 0.2f, 1.6f);
        finderGain *= std::pow(want / finderGain, 0.15f);
        o.brightness *= finderGain;
        Inset in = inset();
        int W = cv.w, H = cv.h;
        // The surround: a faintly textured black.
        parallelRows(H, [&](int y0, int y1) {
            for (int y = y0; y < y1; y++)
                for (int x = 0; x < W; x++) {
                    float px = (x + 0.5f - in.x) / in.s, py = (y + 0.5f - in.y) / in.s;
                    float qx = std::fabs(px - finderW / 2.f) - (finderW / 2.f - in.corner / in.s);
                    float qy = std::fabs(py - finderH / 2.f) - (finderH / 2.f - in.corner / in.s);
                    float edge = std::sqrt(std::max(qx, 0.f) * std::max(qx, 0.f) + std::max(qy, 0.f) * std::max(qy, 0.f)) +
                                 std::min(std::max(qx, qy), 0.f) - in.corner / in.s;
                    float g = 0.022f + 0.01f * valueNoise(x / 3.f, y / 3.f, 31);
                    V3 sur{g, g, g * 1.05f};
                    V3 col = sur;
                    if (edge < 1 && !mirrorUp) {
                        V3 lin = groundGlass(f, {px, py}, o);
                        lin = lin * (smoothstepf(0, in.corner / in.s * 0.9f, -edge) * 0.25f + 0.75f);
                        V3 s = toSrgb(lin);
                        float k = sat(edge + 0.5f);
                        col = s + (sur - s) * k;
                    } else if (edge < 1) {
                        col = {0.02f, 0.02f, 0.02f};
                    }
                    cv.px[size_t(y) * W + x] = 0xff000000u | uint32_t(sat(col.x) * 255) | uint32_t(sat(col.y) * 255) << 8 |
                                               uint32_t(sat(col.z) * 255) << 16;
                }
        });
        drawMeter(in);
        drawReadouts(in);
    }

    void drawMeter(const Inset& in) {
        drawMeterScale(in);
        V2 pivot, tip;
        float u = needleGeometry(in, pivot, tip);
        V2 start = pivot + (tip - pivot) * ((in.x - pivot.x) / (tip.x - pivot.x));
        cv.line(start, tip, std::max(1.2f, 0.11f * u), {0.9f, 0.08f, 0.05f, 0.85f}, 0.15f * u, true);
    }
    /// The meter as this body has it (ViewfinderHUD's MeterShape): the Ohi Kor's
    /// shutter speeds at the left; the Kwanon EF's f-numbers at the right, the
    /// camera's aperture marked. Highest at the top.
    struct MeterSpec {
        std::vector<std::string> labels;   // empty: the shutter speeds
        int set = 0, n = 0;
        bool right = false;
        float u = 0, cap = 0, step = 0;
        float x0 = 0, y0 = 0, w = 0, h = 0;  // the card
        float yAt(float idx) const { return y0 + cap + (n - 1 - idx + 0.5f) * step; }
    };
    MeterSpec meterSpec(const Inset& in) const {
        MeterSpec m;
        if (apertureScale()) {
            for (float a : body.lens().apertureStops()) { char b[16]; snprintf(b, sizeof b, a < 10 ? "%.1f" : "%.0f", a); m.labels.push_back(b); }
            m.set = body.apertureIndex;
            m.right = true;
        } else {
            m.set = body.shutterIndex;
        }
        m.n = m.labels.empty() ? int(shutterSpeeds().size()) : int(m.labels.size());
        float imgH = finderH * in.s, imgW = finderW * in.s;
        m.u = imgH / 50;
        m.w = 3.6f * m.u; m.h = imgH * 0.66f;
        // Inside the frame, just in from its edge (the needle swings in from outside).
        m.x0 = m.right ? in.x + imgW - 1.0f * m.u - m.w : in.x + 1.0f * m.u;
        m.y0 = in.y + imgH / 2 - m.h / 2;
        m.cap = 2 * m.u;
        m.step = (m.h - 2 * m.cap) / m.n;
        return m;
    }
    /// The needle: it has mass, and aims through the reading's tick. Returns the HUD unit.
    float needleGeometry(const Inset& in, V2& pivot, V2& tip) {
        MeterSpec m = meterSpec(in);
        float u = m.u;
        pivot = {m.right ? m.x0 + m.w + 9 * u : m.x0 - 9 * u, m.y0 + m.h / 2};
        float meterStops = body.exposureStops() + std::log2(std::max(meterLum, 1e-4f) / 0.18f);
        float wantN = std::clamp(float(m.set) + meterStops, -1.5f, float(m.n) + 0.5f);
        float dt = 1 / 30.f;
        needleSpeed += (60 * (wantN - needle) - 11 * needleSpeed) * dt;
        needle += needleSpeed * dt;
        V2 aim{m.right ? m.x0 + m.w - 0.1f * u : m.x0 + 0.1f * u, m.yAt(needle)};
        float reach = ((m.right ? m.x0 + m.w - 1.15f * u : m.x0 + 1.15f * u) - pivot.x) / (aim.x - pivot.x);
        tip = pivot + (aim - pivot) * reach;
        return u;
    }
    /// The scale as projected light (drawPlate / drawApertureScale in ViewfinderHUD.swift).
    void drawMeterScale(const Inset& in) {
        MeterSpec m = meterSpec(in);
        float u = m.u, cx0 = m.x0, cy0 = m.y0, cardW = m.w, cardH = m.h, step = m.step, cap = m.cap;
        if (!m.labels.empty()) {
            // The Kwanon's: a dark strip with cool white f-numbers, red over and under
            // marks beyond its ends, an orange index at the aperture the camera chose.
            float sx0 = cx0 + cardW * 0.12f, sx1 = cx0 + cardW * 0.88f;
            cv.rect(sx0, cy0, sx1, cy0 + cardH, {0.02f, 0.02f, 0.02f, 0.5f});
            RGBA white{0.86f, 0.92f, 1.0f, 1}, red{1.0f, 0.22f, 0.16f, 0.85f};
            float st = (cardH - 4.0f * u) / m.n;
            float mid = (sx0 + sx1) / 2;
            for (int k = 0; k < 2; k++) {
                float y = k == 0 ? cy0 + 0.9f * u : cy0 + cardH - 0.9f * u, hh = 0.7f * u * (k == 0 ? -1 : 1);
                for (float t = 0; t <= 1; t += 0.1f) {
                    float hw = 0.6f * u * (1 - t);
                    float yy = y - hh / 2 + hh * t;
                    cv.line({mid - hw, yy}, {mid + hw, yy}, std::max(1.f, std::fabs(hh) * 0.12f), red, 0, true);
                }
            }
            for (int i = 0; i < m.n; i++) {
                float y = m.yAt(float(i));
                int size = int(std::min(st * 0.62f, (sx1 - sx0) * 0.32f));
                float w = font.width(m.labels[i], size);
                font.draw(cv, m.labels[i], mid - w / 2 - 0.3f * u, y - size * 0.6f, size, white, 0.3f);
                float xe = sx1;
                cv.line({xe, y}, {xe - 0.5f * u, y}, std::max(1.f, 0.1f * u), {white.r, white.g, white.b, 0.7f}, 0, true);
            }
            float ty = m.yAt(float(m.set));
            cv.roundRect(sx0 - 0.9f * u, ty - 0.18f * u, sx0 - 0.2f * u, ty + 0.18f * u, 0.1f * u, {1.0f, 0.58f, 0.12f, 0.9f}, true);
            return;
        }
        RGBA cream{1.0f, 0.90f, 0.78f, 1}, red{1.0f, 0.40f, 0.28f, 1};
        auto& sp = shutterSpeeds();
        int n = m.n;
        cv.roundRect(cx0, cy0, cx0 + cardW, cy0 + cardH, 0.5f * u, {cream.r, cream.g, cream.b, 0.10f}, true);
        cv.roundRect(cx0, cy0, cx0 + cardW, cy0 + cap * 0.8f, 0.4f * u, {red.r, red.g, red.b, 0.5f}, true);
        cv.roundRect(cx0, cy0 + cardH - cap * 0.8f, cx0 + cardW, cy0 + cardH, 0.4f * u, {red.r, red.g, red.b, 0.5f}, true);
        // The manual mark, dark on the cap (less light there).
        int mSize = int(1.0f * u);
        font.draw(cv, "M", cx0 + cardW / 2 - font.width("M", mSize) / 2, cy0 + cardH - cap * 0.8f + (cap * 0.8f - mSize) / 2 - 0.1f * u,
                  mSize, {0, 0, 0, 0.55f}, 0);
        V2 pivot{cx0 - 9 * u, cy0 + cardH / 2};
        for (int i = 0; i < n; i++) {
            bool slow = sp[i].seconds >= 1 / 30.f;
            RGBA c = slow ? red : cream;
            float y = m.yAt(float(i));
            int size = int(std::min(step * 0.58f, cardW * 0.25f));
            float w = font.width(sp[i].label, size);
            font.draw(cv, sp[i].label, cx0 + cardW - w - 0.35f * u, y - size * 0.6f, size, {c.r, c.g, c.b, 0.85f}, 0.4f);
            V2 p0{cx0 + 0.1f * u, y};
            V2 d = p0 - pivot; float L = len(d);
            cv.line(p0, p0 + d * (0.9f * u / L), 0.13f * u, {c.r, c.g, c.b, 0.8f}, 0, true);
        }
        // The set speed's green tab.
        float ty = m.yAt(float(m.set));
        for (float k = -0.4f; k <= 0.4f; k += 0.05f)
            cv.line({cx0 + cardW - 0.2f * u, ty + k * step}, {cx0 + cardW + 1.4f * u, ty + k * step * 0.55f}, 1.5f,
                    {0.45f, 0.95f, 0.70f, 0.85f}, 0, false);
    }

    // ---- pace (gaits in Viewer.swift): from a macro focusing rail to a run, real metres per second ----
    struct Gait { const char* name; float metres; };
    static const std::vector<Gait>& gaits() {
        static const std::vector<Gait> g = {{"rail", 0.005f}, {"creep", 0.02f}, {"inch", 0.08f}, {"step", 0.3f},
                                            {"stroll", 0.8f}, {"walk", 1.4f}, {"jog", 3}, {"run", 6}};
        return g;
    }
    int gait = 5;
    /// The pace that suits the scene's real size: walking in a place; for an object about half its size a second.
    void pickGait() {
        if (place) { gait = 5; return; }
        float want = scan.radius * body.metresPerUnit * 0.5f;
        int best = 5; float err = 1e9f;
        for (int i = 0; i < int(gaits().size()); i++) {
            float e = std::fabs(std::log(gaits()[i].metres / std::max(want, 1e-6f)));
            if (e < err) { err = e; best = i; }
        }
        gait = best;
    }
    void changeGait(int d) {
        gait = std::clamp(gait + d, 0, int(gaits().size()) - 1);
        const Gait& g = gaits()[gait];
        char b[48];
        if (g.metres < 0.1f) snprintf(b, sizeof b, "%s %.0f MM/S", upper(g.name).c_str(), g.metres * 1000);
        else snprintf(b, sizeof b, "%s %.1f M/S", upper(g.name).c_str(), g.metres);
        say(b);
    }
    std::string gaitLabel() const {
        const Gait& g = gaits()[gait];
        char b[48];
        if (g.metres < 0.1f) snprintf(b, sizeof b, "%s %.0f mm/s", g.name, g.metres * 1000);
        else snprintf(b, sizeof b, "%s %.1f m/s", g.name, g.metres);
        return b;
    }

    // ---- the rangefinder (rangefinderFinder / rangefinderFrame in Viewer.swift) ----
    /// The Lahntal's finder: a window 35 mm left of and 15 mm above the lens, at
    /// 0.72x; for 21 mm and wider (and the fisheyes) a finder on the hot shoe,
    /// 60 mm above the lens, at the lens's own field.
    void rangefinderFinder(float& fx, V3& offset, bool& external) const {
        float m = 1 / body.metresPerUnit;
        V3 up = camera.down() * -1;
        if (body.lens().focalMM < 27 || body.lens().isFisheye()) {
            fx = body.focalPixels(finderW, finderH) * 0.9f; offset = up * (0.06f * m); external = true;
            return;
        }
        fx = 28.f / 36 * finderW * 0.94f;
        offset = camera.right() * (-0.035f * m) + up * (0.015f * m);
        external = false;
    }
    /// The bright frame for the mounted lens (fractions of the image), moved by parallax for the distance.
    void rangefinderFrame(float& x0, float& y0, float& s) const {
        float fx; V3 off; bool ext;
        rangefinderFinder(fx, off, ext);
        float lensFx = body.focalPixels(finderW, finderH);
        s = fx / lensFx;
        float cx = 0.5f, cy = 0.5f;
        float d = std::max(body.focusM, 0.5f);
        if (!ext) { cx += fx * 0.035f / d / finderW; cy += fx * 0.015f / d / finderH; }
        else cy -= fx * 0.06f / d / finderH;
        x0 = cx - s / 2; y0 = cy - s / 2;
    }

    /// Everything the finder shows around the image (ViewfinderHUD.swift's drawContent).
    void drawReadouts(const Inset& in) {
        float imgH = finderH * in.s, imgW = finderW * in.s, u = imgH / 50;
        bool mirrorUp = SDL_GetTicks() / 1000.0 < mirrorUpUntil;
        bool rf = body.model().rangefinder() && pov < 0;
        if (pov >= 0 && pov < int(lighting.lights.size())) {
            if (!mirrorUp) drawBeam(in, u);
        } else if (rf) {
            drawRangefinder(in, u);
        }
        // The lighting plot, over the top of the image.
        if (playMode == Mode::Lighting && !mirrorUp) {
            auto lines = lightingLines();
            for (size_t k = 0; k < lines.size(); k++) {
                RGBA c = k + 3 < lines.size() ? RGBA{1, 0.82f, 0.55f, 0.9f} : RGBA{1, 0.93f, 0.84f, 0.75f};
                font.draw(cv, lines[k], in.x + 3.5f * u, in.y + 1.2f * u + k * 1.4f * u, int(0.95f * u), c, 0.3f);
            }
        }
        if (body.model().isMotion() && pov < 0 && !mirrorUp) drawMotion(in, u);
        if (measure != Measure::None && pov < 0) drawMeasure(in, u);
        // Above the frame: what is mounted, how fast you go, what is loaded.
        std::string lensName = body.lens().name + (body.filterIndex ? "  +  " + body.filter().name : "") + "  ·  " + gaitLabel();
        font.draw(cv, lensName + "  ·  " + body.rollName(), in.x + 0.5f * u, std::max(2.f, in.y - 2.15f * u), int(0.95f * u),
                  {1.0f, 0.90f, 0.76f, 0.9f}, 0.3f);
        if (rf) drawRangefinderReadouts(in, u);
        else if (apertureScale()) drawWindow(in, u);
        else drawLEDs(in, u);
    }
    std::string apertureText() const { char b[16]; float N = body.takingAperture(); snprintf(b, sizeof b, N < 10 ? "%.1f" : "%.0f", N); return b; }
    std::string focusText() const { char b[16]; snprintf(b, sizeof b, "%.2f m", body.focusM); return body.focusM >= 100 ? "∞" : b; }
    std::string counterText() const {
        if (body.model().isMotion()) return MotionTake::timecode(playhead, take.frameRate);
        return body.framesLeft() > 0 ? std::to_string(body.framesShot + 1) : "E";
    }
    /// The needle on an aperture scale: the Kwanon's, and the movie camera's (it holds its speed).
    bool apertureScale() const { return body.model().shutterPriority() || body.model().isMotion(); }
    /// The small notes under the readouts: messages and modes.
    std::vector<std::string> notes() {
        std::vector<std::string> n;
        if (SDL_GetTicks() / 1000.0 < flashUntil) n.push_back(flash);
        if (body.dofPreview) n.push_back("DOF PREVIEW");
        if (playMode == Mode::Lighting) n.push_back("LIGHTING");
        if (renderer.pending() > 0 && !movie) n.push_back("DEVELOPING " + std::to_string(renderer.pending()));
        return n;
    }
    static std::string joined(const std::vector<std::string>& v) {
        std::string s;
        for (size_t i = 0; i < v.size(); i++) s += (i ? "   ·   " : "") + v[i];
        return s;
    }
    void drawLEDs(const Inset& in, float u) {
        float imgH = finderH * in.s, imgW = finderW * in.s;
        float h = 2 * u, y = in.y + imgH + (cv.h - in.y - imgH - h) * 0.4f;
        RGBA ledRed{0.92f, 0.29f, 0.19f, 1};
        // Fixed displays: aperture (an F, then three places), speed (four), film speed (five), distance (four), frame (two).
        float ax = in.x + imgW * 0.07f;
        drawLED(cv, "F", ax, y, h, 1);
        drawLED(cv, apertureText(), ax + h * 0.52f * 1.45f, y, h, 3);
        bool seconds = body.shutter().seconds >= 1;
        float sEnd = drawLED(cv, body.shutter().label, in.x + imgW * 0.25f, y, h, 4);
        if (seconds) font.draw(cv, "s", sEnd + 0.1f * u, y + h * 0.1f, int(h * 0.75f), ledRed, 0);
        float isoX = in.x + imgW * 0.45f;
        bool rated = body.push != 0;
        font.draw(cv, rated ? "EI" : "ISO", isoX - h * 1.15f, y + h * 0.1f, int(h * 0.5f), ledRed, 0);
        drawLED(cv, std::to_string(int(std::lround(body.ratedEI()))), isoX, y, h, 5);
        float fx = in.x + imgW * 0.66f;
        if (body.focusM >= 100) {
            float end = drawLED(cv, "", fx, y, h, 4);
            font.draw(cv, "∞", end - h * 1.6f, y - 0.45f * h, int(h * 1.3f), ledRed, 0);
            font.draw(cv, "m", end + 0.2f * u, y + h * 0.1f, int(h * 0.75f), ledRed, 0);
        } else {
            char fm[16]; snprintf(fm, sizeof fm, "%.2f", body.focusM);
            float end = drawLED(cv, fm, fx, y, h, 4);
            font.draw(cv, "m", end + 0.2f * u, y + h * 0.1f, int(h * 0.75f), ledRed, 0);
        }
        drawLED(cv, counterText(), in.x + imgW * 0.87f, y, h, 2);
        auto n = notes();
        if (rated) n.push_back(body.push > 0 ? "PUSHED" : "PULLED");
        std::string s = joined(n);
        float nw = font.width(s, int(0.75f * u));
        font.draw(cv, s, in.x + imgW / 2 - nw / 2, y + h * 1.3f, int(0.75f * u), {0.92f, 0.29f, 0.19f, 0.85f}, 0);
    }
    /// The Kwanon EF's readout: no LEDs in 1973, the set speed lit in a small window
    /// under the image, an A while the camera sets the aperture; distance and frame beside it.
    void drawWindow(const Inset& in, float u) {
        float imgH = finderH * in.s, imgW = finderW * in.s;
        float h = 2 * u, y = in.y + imgH + (cv.h - in.y - imgH - h) * 0.4f;
        RGBA cream{1.0f, 0.92f, 0.80f, 0.95f};
        std::string speed = body.shutter().seconds >= 1 ? std::string(body.shutter().label) + " s" : body.shutter().label;
        float mx = in.x + imgW / 2;
        float wx0 = mx - 5 * u, wy0 = y - 0.3f * u, wx1 = mx + 5 * u, wy1 = y + h + 0.3f * u;
        cv.roundRect(wx0, wy0, wx1, wy1, 0.3f * u, {0.02f, 0.02f, 0.02f, 0.9f}, true);
        cv.roundRect(wx0, wy0, wx1, wy1, 0.3f * u, {0.35f, 0.35f, 0.35f, 0.6f}, false);
        int size = int(h * 0.95f);
        float sw = font.width(speed, size);
        font.draw(cv, speed, mx - (body.autoOn() ? 1.2f * u : 0) - sw / 2, y - 0.05f * u, size, cream, 0.4f);
        if (body.autoOn()) font.draw(cv, "A", wx1 - 2.0f * u, y + 0.15f * u, int(h * 0.7f), {0.45f, 0.95f, 0.70f, 0.95f}, 0.4f);
        RGBA dim2{cream.r, cream.g, cream.b, 0.6f};
        font.draw(cv, focusText(), in.x + imgW * 0.18f, y + 0.2f * u, int(h * 0.6f), dim2, 0.3f);
        std::string right = counterText() + "  ·  " + std::to_string(int(std::lround(body.ratedEI())));
        float rw = font.width(right, int(h * 0.6f));
        font.draw(cv, right, in.x + imgW * 0.82f - rw, y + 0.2f * u, int(h * 0.6f), dim2, 0.3f);
        std::string s = joined(notes());
        float nw = font.width(s, int(0.75f * u));
        if (!s.empty()) font.draw(cv, s, mx - nw / 2, y + h * 1.4f, int(0.75f * u), {cream.r, cream.g, cream.b, 0.8f}, 0.2f);
    }
    /// The Lahntal's finder: the mounted lens's bright frame, lit (cool white, a soft
    /// glow), corners heavier, moved by parallax as you focus; and the meter's needle
    /// across the top, centred when the exposure is right.
    void drawRangefinder(const Inset& in, float u) {
        float imgH = finderH * in.s, imgW = finderW * in.s;
        float fx0, fy0, s;
        rangefinderFrame(fx0, fy0, s);
        float rx0 = in.x + fx0 * imgW, ry0 = in.y + fy0 * imgH, rx1 = rx0 + s * imgW, ry1 = ry0 + s * imgH;
        RGBA lit{0.93f, 0.96f, 1.0f, 0.5f};
        auto clipLine = [&](V2 a, V2 b, float w, RGBA c) {
            a.x = std::clamp(a.x, in.x, in.x + imgW); b.x = std::clamp(b.x, in.x, in.x + imgW);
            a.y = std::clamp(a.y, in.y, in.y + imgH); b.y = std::clamp(b.y, in.y, in.y + imgH);
            cv.line(a, b, w, c, 0.35f * u, false);
        };
        V2 c00{rx0, ry0}, c10{rx1, ry0}, c01{rx0, ry1}, c11{rx1, ry1};
        for (auto [a, b] : {std::pair<V2, V2>{c00, c10}, {c10, c11}, {c11, c01}, {c01, c00}}) {
            clipLine(a, b, std::max(1.f, 0.12f * u), lit);
        }
        float k = std::min(rx1 - rx0, ry1 - ry0) * 0.08f;
        for (auto [x, y, dx, dy] : {std::array<float, 4>{rx0, ry0, 1, 1}, {rx1, ry0, -1, 1}, {rx0, ry1, 1, -1}, {rx1, ry1, -1, -1}}) {
            clipLine({x + dx * k, y}, {x, y}, std::max(1.f, 0.24f * u), lit);
            clipLine({x, y}, {x, y + dy * k}, std::max(1.f, 0.24f * u), lit);
        }
        // The meter: a needle swinging across a short scale at the top of the window.
        float cx = in.x + imgW / 2, top = in.y + 1.6f * u, span = 5.0f * u;
        RGBA cream{1, 0.9f, 0.78f, 0.8f};
        for (int kk = -2; kk <= 2; kk++) {
            float x = cx + kk * span / 2;
            cv.line({x, top}, {x, top + (kk == 0 ? 1.0f : 0.6f) * u}, std::max(1.f, 0.12f * u), cream, 0, true);
        }
        font.draw(cv, "-", cx - span * 1.25f, top - 0.25f * u, int(1.0f * u), cream, 0.3f);
        font.draw(cv, "+", cx + span * 1.12f, top - 0.25f * u, int(1.0f * u), cream, 0.3f);
        float stops = std::clamp(body.exposureStops() + std::log2(std::max(meterLum, 1e-4f) / 0.18f), -2.4f, 2.4f);
        float nx = cx + stops * span / 2;
        cv.line({nx, top - 0.6f * u}, {nx, top + 1.6f * u}, std::max(1.f, 0.16f * u), {0.95f, 0.15f, 0.08f, 0.95f}, 0, true);
        float ffx; V3 off; bool ext;
        rangefinderFinder(ffx, off, ext);
        if (ext) {
            char b[64]; snprintf(b, sizeof b, "%.0f mm finder on the shoe", body.lens().focalMM);
            float w = font.width(b, int(0.9f * u));
            font.draw(cv, b, cx - w / 2, in.y + imgH - 2.4f * u, int(0.9f * u), {1, 0.9f, 0.78f, 0.75f}, 0.3f);
        }
    }
    /// Under the window: what is set, plainly lit (no LEDs in 1971).
    void drawRangefinderReadouts(const Inset& in, float u) {
        float imgH = finderH * in.s, imgW = finderW * in.s;
        float h = 2 * u, y = in.y + imgH + (cv.h - in.y - imgH - h) * 0.45f;
        RGBA cream{1.0f, 0.92f, 0.80f, 0.9f};
        std::string speed = body.shutter().seconds >= 1 ? std::string(body.shutter().label) + " s" : "1/" + std::string(body.shutter().label);
        std::string line = "f/" + apertureText() + "     " + speed + "     " + focusText() + "     " + counterText() + "     ISO " +
                           std::to_string(int(std::lround(body.ratedEI())));
        float w = font.width(line, int(h * 0.62f));
        font.draw(cv, line, in.x + imgW / 2 - w / 2, y, int(h * 0.62f), cream, 0.3f);
        std::string s = joined(notes());
        float nw = font.width(s, int(0.75f * u));
        if (!s.empty()) font.draw(cv, s, in.x + imgW / 2 - nw / 2, y + h * 1.1f, int(0.75f * u), {cream.r, cream.g, cream.b, 0.8f}, 0.2f);
    }
    /// The lighting plot shown while placing lights (Viewer.updateHUD's lines).
    std::vector<std::string> lightingLines() const {
        std::vector<std::string> lines;
        for (int k = 0; k < int(lighting.lights.size()); k++) {
            const auto& l = lighting.lights[k];
            char b[256], dim[24];
            if (l.dimmerStops == 0) snprintf(dim, sizeof dim, "full"); else snprintf(dim, sizeof dim, "%+.1f stop", l.dimmerStops);
            std::string extra = (l.gel ? "  · " + gels()[l.gel].name : "") + (l.modifier ? "  · " + lightModifiers()[l.modifier].name : "") +
                                (l.flareOn() ? "  · flare" : "");
            snprintf(b, sizeof b, "%s %d %s  beam %.0f°  %s%s", k == pov ? "◉" : " ", k + 1, l.kit().name.c_str(), l.beamAngle(), dim, extra.c_str());
            lines.push_back(b);
        }
        char h[160];
        snprintf(h, sizeof h, "House lights: %s (%.2f%%)   ·   next light: %s", lighting.ambientName.c_str(), lighting.ambient * 100,
                 lightKit()[lighting.kitChoice].name.c_str());
        lines.push_back(h);
        if (pov >= 0) {
            lines.push_back("Flying the light: WASD / sticks move it, mouse / right stick aims it · wheel or L2/R2 flood/spot · - = or ▲▼ dimmer · T / Y head · P / Select lens flare");
            lines.push_back("Backspace (or the menu) removes it · 0 or B back to the camera · 1-9 or ◀▶ another light · F / X add one · G / L3 house lights · L / R3 done");
        } else {
            lines.push_back("1-9 or ◀▶ fly a light from its own view · F / X add one at your view · G / L3 house lights · P / Select lens flare");
            lines.push_back("L / R3 back to the camera controls");
        }
        return lines;
    }
    /// Seen from a light: its beam's hot centre, edge and falloff as rings, and its name.
    void drawBeam(const Inset& in, float u) {
        float imgH = finderH * in.s, imgW = finderW * in.s;
        const auto& l = lighting.lights[pov];
        BeamTable beam = l.beam();
        auto r = [&](float a) { return std::tan(std::min(a, 1.4f)) / (18.f / 28) * 0.5f; };
        const float toRad = float(M_PI) / 360;
        float rings[3] = {r(beam.angle(0.9f) * toRad), r(beam.angle(0.5f) * toRad), r(beam.angle(0.1f) * toRad)};
        float alphas[3] = {0.45f, 0.75f, 0.5f};
        float cx = in.x + imgW / 2, cy = in.y + imgH / 2;
        for (int k = 0; k < 3; k++) {
            float rad = rings[k] * imgW;
            int segs = 96;
            for (int i = 0; i < segs; i++) {
                if (k == 2 && (i % 4) >= 2) continue;   // the falloff dashed
                float a0 = i * 2 * float(M_PI) / segs, a1 = (i + 1) * 2 * float(M_PI) / segs;
                V2 p0{cx + rad * std::cos(a0), cy + rad * std::sin(a0)}, p1{cx + rad * std::cos(a1), cy + rad * std::sin(a1)};
                if (p0.x < in.x || p0.x > in.x + imgW || p0.y < in.y || p0.y > in.y + imgH) continue;
                cv.line(p0, p1, std::max(1.f, 0.22f * u), {1.0f, 0.90f, 0.76f, alphas[k]}, 0.5f * u, true);
            }
        }
        cv.line({cx - 0.6f * u, cy}, {cx + 0.6f * u, cy}, std::max(1.f, 0.18f * u), {1.0f, 0.90f, 0.76f, 0.7f}, 0, true);
        cv.line({cx, cy - 0.6f * u}, {cx, cy + 0.6f * u}, std::max(1.f, 0.18f * u), {1.0f, 0.90f, 0.76f, 0.7f}, 0, true);
        std::string title = "LIGHT " + std::to_string(pov + 1) + " · " + l.kit().name;
        float w = font.width(title, int(1.5f * u));
        font.draw(cv, title, cx - w / 2, in.y + imgH - 4 * u, int(1.5f * u), {1.0f, 0.90f, 0.76f, 0.9f}, 0.4f);
    }

    // ---- the menus' look (MenuOverlay.swift) ----
    // Light, as the finder's meter scale is: warm cream (greys become dimmer cream,
    // amber stays warm), Futura-like, a soft glow; the scene dimmed behind.
    static constexpr RGBA amber{1.0f, 0.78f, 0.42f, 1};
    static RGBA grey(float w) { return {w, w, w, 1}; }
    static RGBA warm(RGBA c) {
        float mx = std::max(c.r, std::max(c.g, c.b)), mn = std::min(c.r, std::min(c.g, c.b));
        if (mx - mn < 0.05f) { float w = std::min(1.f, mx * 1.15f + 0.08f); return {w, w * 0.92f, w * 0.80f, c.a}; }
        return c;
    }
    /// MenuOverlay's text: size x 1.05, the glow a shadow blurred to 0.14 x the size at 0.3; bold drawn twice.
    void mtext(const std::string& str, float x, float y, float size, RGBA c, bool bold = false) {
        RGBA k = warm(c);
        int sz = int(size * 1.05f + 0.5f);
        font.draw(cv, str, x, y, sz, k, 0.14f, 0.3f);
        if (bold) font.draw(cv, str, x + std::max(1.f, size * 0.045f), y, sz, k, 0);
    }
    float mwidth(const std::string& str, float size) { return font.width(str, int(size * 1.05f + 0.5f)); }
    void dimScene() {
        for (auto& px : cv.px) {
            uint32_t r = px & 255, g = (px >> 8) & 255, b = (px >> 16) & 255;
            px = 0xff000000u | uint32_t(r * 0.28f) | uint32_t(g * 0.28f) << 8 | uint32_t(b * 0.28f) << 16;
        }
    }
    void panel(float x0, float y0, float x1, float y1, float u, bool border = false) {
        cv.roundRect(x0, y0, x1, y1, u, {0.08f, 0.08f, 0.08f, 0.95f});
        if (!border) return;
        // A thin warm rim.
        for (int y = std::max(0, int(y0) - 1); y < std::min(cv.h, int(y1) + 2); y++)
            for (int x = std::max(0, int(x0) - 1); x < std::min(cv.w, int(x1) + 2); x++) {
                float px_ = x + 0.5f, py_ = y + 0.5f;
                float qx = std::fabs(px_ - (x0 + x1) / 2) - ((x1 - x0) / 2 - u), qy = std::fabs(py_ - (y0 + y1) / 2) - ((y1 - y0) / 2 - u);
                float d = std::sqrt(std::max(qx, 0.f) * std::max(qx, 0.f) + std::max(qy, 0.f) * std::max(qy, 0.f)) + std::min(std::max(qx, qy), 0.f) - u;
                cv.blend(x, y, {amber.r, amber.g, amber.b, 0.5f}, std::clamp(1.f - std::fabs(d), 0.f, 1.f));
            }
    }
    void selRow(float x0, float y0, float x1, float y1, float u) { cv.roundRect(x0, y0, x1, y1, 0.5f * u, {amber.r, amber.g, amber.b, 0.18f}); }
    std::string modeName() const {
        if (playMode == Mode::Lighting) return pov >= 0 ? "lighting · flying light " + std::to_string(pov + 1) : "lighting";
        return "camera";
    }
    bool showingHelp = false;
    enum class HitKind { Item, ListRow, Shelf, BagRow, FilmRow, Rating };
    struct Hit { float x0, y0, x1, y1; HitKind kind; int index; };
    std::vector<Hit> hits;
    void hit(float x0, float y0, float x1, float y1, HitKind k, int i) { hits.push_back({x0, y0, x1, y1, k, i}); }
    const Hit* hitAt(V2 p) const {
        for (auto& h : hits) if (p.x >= h.x0 && p.x < h.x1 && p.y >= h.y0 && p.y < h.y1) return &h;
        return nullptr;
    }

    void drawMenu() {
        dimScene();
        hits.clear();
        if (showingHelp) { drawHelp(); return; }
        std::vector<MenuItem> items = menuItems();
        float u = cv.h / 70.f;
        // The whole list fits the window, however many items there are.
        u = std::min(u, cv.h * 0.92f / (items.size() * 2.9f + 9));
        float w = std::min(cv.w * 0.5f, 40 * u * 1.4f), rowH = 2.9f * u;
        float h = items.size() * rowH + 9 * u, x0 = cv.w / 2 - w / 2, y0 = cv.h / 2 - h / 2;
        panel(x0, y0, x0 + w, y0 + h, u, true);
        mtext("VINTAGE CLICK", x0 + 2 * u, y0 + 1.6f * u, 1.5f * u, amber, true);
        mtext("now: " + modeName(), x0 + w - 16 * u, y0 + 1.9f * u, 1.0f * u, grey(0.6f));
        for (size_t i = 0; i < items.size(); i++) {
            float ry = y0 + 5 * u + i * rowH, rx = x0 + u;
            bool sel = int(i) == menuSel;
            hit(rx, ry, rx + w - 2 * u, ry + rowH, HitKind::Item, int(i));
            if (sel) selRow(rx, ry, rx + w - 2 * u, ry + rowH - 0.4f * u, u);
            mtext((sel ? "▶ " : "  ") + items[i].title, rx + u, ry + 0.35f * u, 1.15f * u, sel ? amber : grey(1));
            mtext(items[i].detail, rx + 3 * u, ry + 1.7f * u, 0.8f * u, grey(0.55f));
        }
        mtext("▲▼ choose   A / Enter / click select   B / Esc back", x0 + 2 * u, y0 + h - 2.6f * u, 0.9f * u, grey(0.6f));
    }

    /// The controls guide: every mode, pad and keyboard side by side (MenuOverlay.guide).
    void drawHelp() {
        struct Row { const char* what; const char* pad; const char* keys; };
        struct Section { const char* title; std::vector<Row> rows; };
        static const std::vector<Section> guide = {
            {"CAMERA", {{"walk / look", "sticks", "WASD · mouse"},
                        {"pace: rail ... run (real m/s)", "L3 (steps up)", ",  .  (slower / faster)"},
                        {"burst of speed (x3)", "", "hold Shift"},
                        {"rise / sink", "R1 / L1", "Space / Ctrl"},
                        {"focus ring", "R2 far · L2 near", "mouse wheel"},
                        {"aperture", "d-pad ◀ ▶", "[  ]"},
                        {"shutter speed", "d-pad ▲ ▼", "-  ="},
                        {"fire the shutter", "bottom (A)", "left click"},
                        {"depth-of-field preview", "hold right (B)", "hold right click"},
                        {"camera bag (change lens)", "left (X)", "B, or 1 - 9 in the collection"},
                        {"lens filter (the bag's Filters shelf)", "menu", "V"},
                        {"load film (stock, push / pull)", "tap top (Y)", "R"},
                        {"tilt / shift the lens", "hold Y + right stick", "hold M + arrows"},
                        {"square the lens up again", "hold Y + click R3", "N"}}},
            {"LIGHTING", {{"lighting mode on / off", "R3", "L"},
                          {"fly a light (its own view)", "d-pad ◀ ▶", "1 - 9"},
                          {"back to the camera's view", "right (B)", "0  or  `"},
                          {"add a light (you fly it)", "left (X)", "F"},
                          {"change the head", "top (Y)", "T"},
                          {"gel on the light", "menu", "C"},
                          {"modifier: doors, flag, cookie, gobo", "menu", "M"},
                          {"gobo focus / cookie distance", "menu", "K"},
                          {"flood / spot", "L2 / R2", "mouse wheel"},
                          {"dimmer (half stops)", "d-pad ▲ ▼", "-  ="},
                          {"remove the light you fly", "via the menu", "Backspace"},
                          {"house lights: day ... night", "L3", "G"}}},
            {"LIGHT TABLE", {{"open / close", "View (−)", "Tab"},
                             {"move the loupe", "either stick", "the mouse"},
                             {"loupe power", "L2 / R2", "mouse wheel"},
                             {"choose a frame", "d-pad", "arrows"},
                             {"mark a keeper", "bottom (A)", "click / Enter"},
                             {"another session", "L1 / R1", "Q / E"}}},
            {"ANYWHERE", {{"this menu", "Menu (+)", "Esc or H"},
                          {"take / free the mouse", "", "click / Esc"},
                          {"which way is up", "", "U"}}},
        };
        float u = cv.h / 70.f;
        float px0 = cv.w * 0.06f, py0 = cv.h * 0.05f, px1 = cv.w * 0.94f, py1 = cv.h * 0.95f;
        cv.roundRect(px0, py0, px1, py1, u, {0.08f, 0.08f, 0.08f, 0.96f});
        mtext("CONTROLS", px0 + 2 * u, py0 + 1.5f * u, 1.5f * u, amber, true);
        mtext("pad buttons by position: Xbox, PlayStation and Switch Pro alike", px0 + 16 * u, py0 + 1.9f * u, 0.9f * u, grey(0.6f));
        float colW = (px1 - px0) / 2 - 3 * u;
        float x = px0 + 2 * u, y = py0 + 5 * u, line = 1.55f * u;
        for (size_t k = 0; k < guide.size(); k++) {
            const Section& sec = guide[k];
            float need = (sec.rows.size() + 2) * line;
            if (k > 0 && y + need > py1 - 3 * u) { x += colW + 2 * u; y = py0 + 5 * u; }
            mtext(sec.title, x, y, 1.1f * u, amber, true);
            mtext("pad", x + colW * 0.46f, y + 0.15f * u, 0.8f * u, grey(0.5f));
            mtext("keys / mouse", x + colW * 0.72f, y + 0.15f * u, 0.8f * u, grey(0.5f));
            y += line * 1.2f;
            for (const Row& r : sec.rows) {
                mtext(r.what, x, y, 0.85f * u, grey(1));
                mtext(r.pad, x + colW * 0.46f, y, 0.85f * u, grey(0.8f));
                mtext(r.keys, x + colW * 0.72f, y, 0.85f * u, grey(0.8f));
                y += line;
            }
            y += line * 0.8f;
        }
        mtext("B / Esc / click: back", px0 + 2 * u, py1 - 2.4f * u, 0.9f * u, grey(0.6f));
    }

    /// The chooser page (the gel book, the modifiers): drawList in MenuOverlay.swift.
    void drawList() {
        dimScene();
        hits.clear();
        float u = cv.h / 70.f, rowH = 3.0f * u;
        int shown = std::min(int(listRows.size()), 12);
        int first = std::max(0, std::min(int(listRows.size()) - shown, listChoice - shown / 2));
        float w = std::min(cv.w * 0.7f, 70 * u), h = shown * rowH + 12 * u;
        float x0 = cv.w / 2 - w / 2, y0 = cv.h / 2 - h / 2;
        cv.roundRect(x0, y0, x0 + w, y0 + h, u, {0.08f, 0.08f, 0.08f, 0.96f});
        mtext(listTitle, x0 + 2 * u, y0 + 1.5f * u, 1.5f * u, amber, true);
        mtext(listAbout, x0 + 2 * u, y0 + 4.0f * u, 0.9f * u, grey(0.55f));
        for (int k = 0; k < shown; k++) {
            int i = first + k;
            float rx = x0 + u, ry = y0 + 6.2f * u + k * rowH;
            bool sel = i == listChoice;
            hit(rx, ry, rx + w - 2 * u, ry + rowH, HitKind::ListRow, i);
            if (sel) selRow(rx, ry, rx + w - 2 * u, ry + rowH - 0.4f * u, u);
            mtext((sel ? "▶ " : "  ") + listRows[i].first + (i == listMarked ? "  ●" : ""), rx + u, ry + 0.3f * u, 1.15f * u, sel ? amber : grey(1));
            mtext(listRows[i].second, rx + 3 * u, ry + 1.7f * u, 0.8f * u, grey(0.5f));
        }
        if (first > 0) mtext("▲ more", x0 + w - 9 * u, y0 + 4.0f * u, 0.8f * u, grey(0.5f));
        if (first + shown < int(listRows.size())) mtext("▼ more", x0 + w - 9 * u, y0 + h - 2.6f * u, 0.8f * u, grey(0.5f));
        mtext("▲▼ choose   A / Enter / click again: put it on   B / Esc back      ● on now", x0 + 2 * u, y0 + h - 2.6f * u, 0.9f * u, grey(0.6f));
    }

    // The game menu, page by page, as in Viewer.swift (menuItems): the modes and
    // headings on the main page, the settings under them.
    enum class Page { Main, Bag, Scene, Photos, Settings, Controls, Finder, Lights, Motion };
    struct MenuItem { std::string title, detail; std::function<void()> action; };
    Page menuPage = Page::Main;
    void go(Page p) { menuPage = p; menuSel = p == Page::Main ? 0 : 1; mode = Mode::Menu; }
    void openMenu() { menuPage = Page::Main; menuSel = 0; mode = Mode::Menu; showingHelp = false; }

    std::vector<MenuItem> menuItems() {
        auto back = [this](Page to, const char* name = "Back to the menu") {
            return MenuItem{name, "", [this, to] { go(to); }};
        };
        auto fmt = [](const char* f, auto... a) { char b[256]; snprintf(b, sizeof b, f, a...); return std::string(b); };
        switch (menuPage) {
        case Page::Main:
            return {
                {playMode == Mode::Lighting ? "Back to the lights" : "Back to the camera", "carry on where you were",
                 [this] { mode = playMode; }},
                {"Camera", "frame, focus and expose", [this] { pov = -1; playMode = mode = Mode::Camera; }},
                {"Lighting", "place and fly the lights, set the house lights", [this] { pov = -1; playMode = mode = Mode::Lighting; }},
                {"Light table", "your rolls, through a loupe", [this] { openSheet(); }},
                {"Camera bag…", "lens and film: " + body.lens().name + " · " + body.rollName(), [this] { go(Page::Bag); }},
                {"Scene…", "its light and size; reset the view; open another scan", [this] { go(Page::Scene); }},
                {"Photos…", "size, quality, where rolls are kept", [this] { go(Page::Photos); }},
                {"Lights…", lighting.lights.empty() ? "add a light first (lighting mode)"
                                                      : "light " + std::to_string(chosenLight() + 1) + ": gel, modifier, lens flare",
                 [this] { go(Page::Lights); }},
                {"Settings…", "camera sounds, controls", [this] { go(Page::Settings); }},
                {"Quit", "", [this] { quit = true; }},
            };
        case Page::Bag: {
            std::vector<MenuItem> items = {
                back(Page::Main),
                {"Camera body: " + body.model().fullName(), body.model().about() + " (select to change)", [this] {
                     body.chooseBody(body.model().isMotion() ? 0 : (body.modelIndex + 1) % int(CameraModel::all().size()));
                     playFelt("lens-change");
                 }},
            };
            if (body.model().shutterPriority())
                items.push_back({std::string("Exposure: ") + (body.autoOn() ? "shutter-priority auto" : "manual"),
                                 "auto: set the speed, the camera sets the aperture; turning the aperture yourself is manual",
                                 [this] { body.autoExposure = body.autoOn() ? 0 : 1; }});
            if (body.model().isMotion())
                items.push_back({"Motion…", fmt("%.0f fps, %s shutter, a %.0f s take: keys, rolling, developing", body.frameRate,
                                                  body.shutter().label.c_str(), workingTake().duration),
                                 [this] { go(Page::Motion); }});
            items.push_back({"Change lens…", "now: " + body.lens().name + " (" + body.lens().collection + ")", [this] { openBag(); }});
            items.push_back({"Lens filter: " + body.filter().name, "ND, colour, star, soft and mist (V)", [this] { openBag(true); }});
            items.push_back({"Load film…", fmt("now: %s, frame %d of %d", body.rollName().c_str(), body.framesShot + 1, body.stock().exposures),
                             [this] { filmSel = body.stockIndex; filmPush = body.push; mode = Mode::Film; }});
            return items;
        }
        case Page::Scene:
            return {
                back(Page::Main),
                {"Set the scale (measure)…", fmt("now %.3g m per unit: aim at two ends of something you know the size of, then say how long it is", body.metresPerUnit),
                 [this] { startMeasure(); }},
                {fmt("Scene light: EV %.0f", body.sceneEV),
                 fmt("the light on the scene's middle tone (calibrated %+.1f stops) · select to change (9 to 15)", body.calibration),
                 [this] {
                     body.sceneEV = body.sceneEV >= 15 ? 9 : body.sceneEV + 1;
                     SceneKind k = currentKind(); k.ev = body.sceneEV; k.remember(scanPath);
                 }},
                {sky.path.empty() ? "Sky: the scan's own" : "Sky: " + sky.name(),
                 sky.path.empty() ? "choose an equirectangular .hdr to fill where the scan is empty" : "select to remove it",
                 [this] { if (sky.path.empty()) chooseSky(); else setSky({}); }},
                {fmt("Sky turn: %.0f°  ·  brightness %+.0f stops", sky.yawDegrees, sky.stops),
                 "select to turn the sky 30° (Shift-select: brightness)",
                 [this] {
                     if (sky.path.empty()) return;
                     SkySetting s = sky;
                     if (SDL_GetModState() & SDL_KMOD_SHIFT) s.stops = s.stops >= 2 ? -2 : s.stops + 1;
                     else s.yawDegrees = std::fmod(s.yawDegrees + 30, 360.f);
                     setSky(s);
                 }},
                {place ? "Treat this scan as an object" : "Treat this scan as a place",
                 place ? "now: a place to stand in, about 30 m across — wrong size? switch"
                       : "now: an object about 60 cm across — wrong size? switch",
                 [this] { switchKind(); mode = Mode::Camera; }},
                {"Reset the view", "back to where you started", [this] { camera = home; mode = Mode::Camera; }},
                {"Open another scene…", "a .ply scan, or a .vcscene from the Scene Builder", [this] { chooseScene(); }},
            };
        case Page::Photos:
            return {
                back(Page::Main),
                {fmt("Photo size: %d × %d", photoW, photoH),
                 fmt("%d× the finder · bigger takes longer to develop (select to change)", photoW / finderW),
                 [this] {
                     int s = photoW / finderW; s = s >= 4 ? 2 : s + 1;
                     photoW = finderW * s; photoH = finderH * s; g_prefs.setInt("photoScale", s);
                 }},
                {std::string("Shutter makes: ") + (proofsAtShutter() ? "proofs (enlarge at the light table)" : "full prints"),
                 "proofs keep the finder fast; at the light table Y / P sends the marked frames (or all) to the enlarger",
                 [this] { g_prefs.setBool("proofsAtShutter", !proofsAtShutter()); }},
                {std::string("Digital negative (DNG): ") + (keepNegative() ? "on" : "off"),
                 "a high-dynamic-range raw beside each full print, for a raw developer (select to change)",
                 [this] { g_prefs.setBool("keepNegative", !keepNegative()); }},
                {fmt("Exposure quality: %d lens samples", cells),
                 "more: truer bokeh, smoother blur, slower; 64+ adds coloured bokeh fringes (select to change)",
                 [this] { cells = cells >= 128 ? 32 : cells * 2; g_prefs.setInt("cells", cells); }},
                {"Where rolls are kept: " + rollsRoot().u8string(), "select to choose another folder (new rolls go there; the light table reads it)",
                 [this] { chooseRollsFolder(); }},
                {"Open the rolls folder", "in Explorer",
                 [] {
                     std::error_code ec; fs::create_directories(rollsRoot(), ec);
                     std::string url = "file:///" + rollsRoot().generic_u8string();
                     SDL_OpenURL(url.c_str());
                 }},
            };
        case Page::Settings:
            return {
                back(Page::Main),
                {"Viewfinder graphics…", "how the finder draws: blur", [this] { go(Page::Finder); }},
                {std::string("Haptics: ") + (hapticsOn() ? "on" : "off"),
                 std::string("shutter, film advance and lens felt through the controller (select to turn ") + (hapticsOn() ? "off" : "on") + ")",
                 [this] { g_prefs.setBool("haptics", !hapticsOn()); }},
                {std::string("Distant shells: ") + (g_prefs.getBool("distantShells", true) ? "on" : "off"),
                 "in a place, far splats drawn from a baked panorama while you turn and focus: a faster finder (prints always draw everything)",
                 [this] { g_prefs.setBool("distantShells", !g_prefs.getBool("distantShells", true)); }},
                {std::string("Camera sounds: ") + (sounds.enabled ? "on" : "off"),
                 std::string("shutter, film advance, lens and dial: a real Nikon (select to turn ") + (sounds.enabled ? "off" : "on") + ")",
                 [this] { sounds.enabled = !sounds.enabled; g_prefs.setBool("sounds", sounds.enabled); }},
                {"Scene sound: " + (sceneSoundOn() ? fmt("%.0f%%", sceneSoundLevel() * 100) : std::string("off")),
                 soundscape ? "the scene's own sounds: select to step the level (off, 25, 50, 75, 100%)"
                            : "this scene has no sounds of its own (a .vcscene can bring some)",
                 [this] {
                     // off -> 25 -> 50 -> 75 -> 100 -> off
                     if (!sceneSoundOn()) { g_prefs.setBool("soundscape", true); g_prefs.set("soundscapeLevel", "0.25"); }
                     else if (sceneSoundLevel() >= 0.99f) g_prefs.setBool("soundscape", false);
                     else {
                         char b[16]; snprintf(b, sizeof b, "%g", std::min(1.f, std::floor(sceneSoundLevel() * 4) / 4 + 0.25f));
                         g_prefs.set("soundscapeLevel", b);
                     }
                 }},
                {"Controls", "every button, pad and keyboard", [this] { showingHelp = true; }},
            };
        case Page::Motion: {
            MotionTake& t = workingTake();
            auto sz = finalSize();
            return {
                back(Page::Bag, "Back to the camera bag"),
                {fmt("Frame rate: %.0f fps", body.frameRate), "frames a second, on film and on the screen (select to change)", [this] {
                     auto& r = CameraBody::frameRates();
                     size_t i = std::find(r.begin(), r.end(), body.frameRate) - r.begin();
                     body.frameRate = r[(i + 1) % r.size()];
                     workingTake().frameRate = body.frameRate;
                     saveTake();
                 }},
                {"Shutter angle: " + body.shutter().label + fmt(" (1/%.0f s)", 1 / body.shutter().seconds),
                 "how long each frame is open, and how much a move blurs (- = in the camera)", [this] {
                     body.setShutterAngleIndex((body.shutterAngleIndex() + 1) % int(CameraBody::shutterAngles().size()));
                 }},
                {fmt("Take length: %.0f s", t.duration),
                 fmt("%d key%s · K sets one, I / O between them, Z / X a frame (Shift: a second), P or the button rolls", int(t.keys.size()),
                     t.keys.size() == 1 ? "" : "s"),
                 [this] {
                     auto& l = MotionTake::lengths();
                     size_t i = std::find(l.begin(), l.end(), workingTake().duration) - l.begin();
                     workingTake().duration = l[(i + 1) % l.size()];
                     saveTake();
                 }},
                {"Develop a preview", "the take at the finder's size, quickly, onto the light table (G)", [this] { mode = playMode; developTake(true); }},
                {"Develop the final", fmt("%s at %d × %d: slow, full quality (Shift-G)", finalName().c_str(), sz.first, sz.second),
                 [this] { mode = playMode; developTake(false); }},
                {"Final: " + finalName(), "what Shift-G, and R on a take at the light table, develop (select to change)", [this] {
                     g_prefs.setBool("movieHevc", !finalHevc());
                 }},
                {fmt("Final size: %d × %d", sz.first, sz.second), "8-perf's 1.5:1 (select to change)", [this] {
                     g_prefs.setInt("movieSize", (g_prefs.getInt("movieSize", 0) + 1) % 2);
                 }},
                {"Clear all keys", "start the take again", [this] {
                     workingTake().keys.clear();
                     saveTake();
                     playhead = 0;
                     say("KEYS CLEARED");
                 }},
            };
        }
        case Page::Lights: {
            std::vector<MenuItem> items = {back(Page::Main)};
            MenuItem newFlare{std::string("Lens flare on new lights: ") + (newLightsFlare ? "on" : "off"),
                              "whether a light you add flares when it shines into the lens (each light can still be switched)",
                              [this] { newLightsFlare = !newLightsFlare; }};
            if (lighting.lights.empty()) {
                items.push_back({"No lights yet", "add one in lighting mode (F)", [this] { pov = -1; playMode = mode = Mode::Lighting; }});
                items.push_back(newFlare);
                return items;
            }
            int k = chosenLight();
            const PlacedLight& l = lighting.lights[k];
            std::string n = std::to_string(k + 1);
            items.push_back({"Gel on light " + n + ": " + gels()[l.gel].name, "colour correction and effect colours for the light (C in lighting)",
                             [this] { openGels(); }});
            items.push_back({"Modifier on light " + n + ": " + lightModifiers()[l.modifier].name,
                             "barn doors, flags, cookies; gobos in an ellipsoidal (M in lighting, K focus)", [this] { openModifiers(); }});
            items.push_back({"Lens flare from light " + n + ": " + (l.flareOn() ? "on" : "off"),
                             "ghosts, glare and a starburst when it shines into the lens (P in lighting)",
                             [this, k] { lighting.lights[k].flare = lighting.lights[k].flareOn() ? 0 : 1; }});
            items.push_back(newFlare);
            if (playMode == Mode::Lighting && pov >= 0)
                items.push_back({"Remove light " + std::to_string(pov + 1), "the one you are flying", [this] {
                    lighting.lights.erase(lighting.lights.begin() + pov);
                    lighting.selected = std::max(0, pov - 1);
                    pov = -1;
                    mode = playMode;
                }});
            return items;
        }
        case Page::Finder:
            return {
                back(Page::Settings, "Back to settings"),
                {std::string("Finder blur: ") + (g_prefs.getBool("classicBlur", false) ? "classic" : "smooth"),
                 "smooth: rendered sharp, blurred like a print; classic: each splat blurred by the renderer",
                 [] { g_prefs.setBool("classicBlur", !g_prefs.getBool("classicBlur", false)); }},
                {std::string("Finder focus (classic): ") + (g_prefs.getBool("fastFocus", false) ? "fast" : "smooth"),
                 "fast draws strong blur from fewer splats: quicker far out of focus, a little coarser",
                 [] {
                     g_prefs.setBool("fastFocus", !g_prefs.getBool("fastFocus", false));
                     CameraBody::finderThinning = g_prefs.getBool("fastFocus", false) ? 0.1f : 0.05f;
                 }},
            };
        case Page::Controls: {
            std::vector<MenuItem> rows = {back(Page::Settings, "Back to settings")};
            static const char* guide[][2] = {
                {"Walk / look", "W A S D and the mouse (or arrows) · sticks (click the window to take the mouse; Esc frees it)"},
                {"Rise / sink", "Space or E / Ctrl or Q · RB / LB (Shift runs)"},
                {"Pace", ", slower · . faster · click the left stick"},
                {"Focus", "mouse wheel, or hold F far / C near · RT far, LT near"},
                {"Aperture", "[ ] · d-pad left / right"},
                {"Shutter speed", "- = · d-pad up / down"},
                {"Take the picture", "left click · A"},
                {"Depth-of-field preview", "hold the right button · hold B"},
                {"Tilt / shift the lens", "hold M + arrows · hold Y + right stick (N or Y + R3 squares it)"},
                {"Camera bag (lenses)", "B · X (1-9: that lens of the collection)"},
                {"Lens filter", "V"},
                {"Lighting mode", "L · R3 (and back to the camera)"},
                {"In lighting", "F add a light · 1-9 fly one (0 back) · [ ] next · = - dimmer · wheel spot/flood · T head · C gel · M modifier · K focus · P flare · G house lights · Backspace remove"},
                {"Load film", "R · Y"},
                {"Light table", "Tab · View"},
                {"Menu", "Esc or H · Menu"},
                {"Which way is up", "U (a scan stored on its side)"},
                {"On the light table", "drag the loupe; wheel or triggers for its power; arrows for the frame; Q / E another session"},
            };
            for (auto& g : guide) rows.push_back({g[0], g[1], [] {}});
            return rows;
        }
        }
        return {};
    }
    void chooseMenu() {
        auto items = menuItems();
        if (menuSel >= 0 && menuSel < int(items.size())) items[menuSel].action();
    }
    void openBag(bool filters = false) {
        shelf = 0;
        for (int s = 0, k = 0; s < int(lensShelves().size()); k += lensShelves()[s].count, s++)
            if (body.lensIndex >= k && body.lensIndex < k + lensShelves()[s].count) { shelf = s; lensSel = body.lensIndex - k; }
        if (filters) { shelf = int(lensShelves().size()); lensSel = body.filterIndex; }
        mode = Mode::Bag;
    }
    int shelfStart(int s) const { int k = 0; for (int i = 0; i < s; i++) k += lensShelves()[i].count; return k; }
    /// The camera bag: collections across the top, their lenses below (drawLenses in MenuOverlay.swift).
    void drawBag() {
        dimScene();
        hits.clear();
        int filterShelf = int(lensShelves().size());
        bool onFilters = shelf == filterShelf;
        float u = cv.h / 70.f, rowH = 3.3f * u;
        float w = std::min(cv.w * 0.86f, 84 * u);
        int rowsShown = onFilters ? 9 : std::max(lensShelves()[shelf].count, 8);
        float h = rowsShown * rowH + 15 * u, x0 = cv.w / 2 - w / 2, y0 = cv.h / 2 - h / 2;
        cv.roundRect(x0, y0, x0 + w, y0 + h, u, {0.08f, 0.08f, 0.08f, 0.96f});
        mtext("CAMERA BAG", x0 + 2 * u, y0 + 1.5f * u, 1.5f * u, amber, true);
        // The shelves: the tabs shrink to fit the panel.
        auto tabWidth = [&](const std::string& name, float size) { return mwidth(name, size) + 2 * size / 1.05f; };
        float x = x0 + 17 * u, room = x0 + w - 1.5f * u - x, natural = 0;
        std::vector<std::string> names;
        for (auto& sh : lensShelves()) names.push_back(sh.name);
        names.push_back("Filters");
        for (auto& n : names) natural += tabWidth(n, 1.05f * u) + 0.6f * u;
        float fit = std::min(1.f, room / natural), ts = 1.05f * u * fit;
        for (int i = 0; i < int(names.size()); i++) {
            float tw = tabWidth(names[i], ts);
            hit(x, y0 + 1.2f * u, x + tw, y0 + 3.4f * u, HitKind::Shelf, i);
            if (i == shelf) cv.roundRect(x, y0 + 1.2f * u, x + tw, y0 + 3.4f * u, 0.4f * u, {amber.r, amber.g, amber.b, 0.25f});
            bool fits = i >= filterShelf;
            if (!fits) for (int k = 0; k < lensShelves()[i].count; k++) if (body.fits(lensBag()[shelfStart(i) + k])) fits = true;
            mtext(names[i], x + ts / 1.05f, y0 + 1.2f * u + 0.35f * u + (1.05f * u - ts) / 2, ts, i == shelf ? amber : grey(fits ? 0.7f : 0.3f));
            x += tw + 0.6f * u * fit;
        }
        if (onFilters) {
            int n = int(lensFilters().size()), shown = rowsShown;
            int first = std::max(0, std::min(n - shown, lensSel - shown / 2));
            bool rearOnly = body.lens().rearFilter;
            mtext(rearOnly ? "this lens takes filters at the back: colour and ND only, no effect filters"
                           : "on the front of the lens: the finder, the meter and the film all see through it",
                  x0 + 2 * u, y0 + 4.0f * u, 0.9f * u, grey(0.55f));
            for (int k = 0; k < std::min(shown, n); k++) {
                int i = first + k;
                const LensFilter& f = lensFilters()[i];
                bool fits = body.fits(f), sel = i == lensSel;
                float rx = x0 + u, ry = y0 + 6.2f * u + k * rowH;
                hit(rx, ry, rx + w - 2 * u, ry + rowH, HitKind::BagRow, i);
                if (sel) selRow(rx, ry, rx + w - 2 * u, ry + rowH - 0.4f * u, u);
                RGBA dim = grey(0.4f);
                mtext((sel ? "▶ " : "  ") + f.name + (i == body.filterIndex ? "  ●" : ""), rx + u, ry + 0.4f * u, 1.2f * u,
                      !fits ? dim : sel ? amber : grey(1));
                char loss[32];
                if (f.stops() < 0.05f) snprintf(loss, sizeof loss, "no light lost"); else snprintf(loss, sizeof loss, "%.1f stops", f.stops());
                mtext(fits ? f.group + " · " + loss : f.group + " · not on this lens", rx + w * 0.5f, ry + 0.55f * u, 0.95f * u,
                      fits ? grey(0.72f) : dim);
                mtext(f.about, rx + 3 * u, ry + 1.95f * u, 0.8f * u, grey(0.5f));
            }
            if (first > 0) mtext("▲ more", x0 + w - 9 * u, y0 + 4.0f * u, 0.8f * u, grey(0.5f));
            if (first + shown < n) mtext("▼ more", x0 + w - 9 * u, y0 + h - 4.2f * u, 0.8f * u, grey(0.5f));
            mtext("◀▶ shelf   ▲▼ filter   A / Enter / click again: put it on   B / Esc back      ● on the lens",
                  x0 + 2 * u, y0 + h - 2.6f * u, 0.9f * u, grey(0.6f));
            return;
        }
        const LensShelf& sh = lensShelves()[shelf];
        mtext(sh.about, x0 + 2 * u, y0 + 4.0f * u, 0.9f * u, grey(0.55f));
        for (int i = 0; i < sh.count; i++) {
            const Lens& L = lensBag()[shelfStart(shelf) + i];
            float rx = x0 + u, ry = y0 + 6.2f * u + i * rowH;
            bool sel = i == lensSel;
            hit(rx, ry, rx + w - 2 * u, ry + rowH, HitKind::BagRow, i);
            if (sel) selRow(rx, ry, rx + w - 2 * u, ry + rowH - 0.4f * u, u);
            bool mounted = shelfStart(shelf) + i == body.lensIndex;
            mtext((sel ? "▶ " : "  ") + L.name + (mounted ? "  ●" : ""), rx + u, ry + 0.4f * u, 1.2f * u, sel ? amber : grey(1));
            std::string kind = L.projection == Projection::CircularFisheye ? "circular fisheye" : L.projection == Projection::Fisheye ? "fisheye"
                             : (L.blades == 0 ? std::string("round") : std::to_string(L.blades) + "-blade") + " iris";
            char close[32];
            if (L.minFocusM < 1) snprintf(close, sizeof close, "%.0f cm", L.minFocusM * 100); else snprintf(close, sizeof close, "%.1f m", L.minFocusM);
            char mv[48] = "";
            if (L.movement == Movement::Tilt) snprintf(mv, sizeof mv, " · tilts %.0f°", L.movementAmount);
            if (L.movement == Movement::Shift) snprintf(mv, sizeof mv, " · shifts %.0f mm", L.movementAmount);
            mtext(kind + mv + " · close " + close, rx + w * 0.5f, ry + 0.55f * u, 0.95f * u, grey(0.72f));
            mtext(L.inspiredBy, rx + 3 * u, ry + 1.95f * u, 0.8f * u, grey(0.5f));
        }
        mtext("◀▶ collection   ▲▼ lens   A / Enter / click again: mount   B / Esc back      ● on the camera",
              x0 + 2 * u, y0 + h - 2.6f * u, 0.9f * u, grey(0.6f));
        if (lensSel < sh.count) {
            const Lens& L = lensBag()[shelfStart(shelf) + lensSel];
            const char* how = L.movement == Movement::Tilt ? "tilt it on the camera: hold Y + right stick, or hold M + arrows · Y + R3 or N squares it"
                            : L.movement == Movement::Shift ? "shift it on the camera: hold Y + right stick, or hold M + arrows · Y + R3 or N centres it"
                                                             : nullptr;
            if (how) mtext(how, x0 + 2 * u, y0 + h - 4.2f * u, 0.9f * u, amber);
        }
    }
    /// Loading a roll: the stocks in the bag, and how to rate the roll (drawFilm in MenuOverlay.swift).
    void drawFilm() {
        dimScene();
        hits.clear();
        float u = cv.h / 70.f, rowH = 3.3f * u;
        int n = int(filmStocks().size()), shown = std::min(n, 9);
        int first = std::max(0, std::min(n - shown, filmSel - shown / 2));
        float w = std::min(cv.w * 0.7f, 70 * u), h = shown * rowH + 15 * u, x0 = cv.w / 2 - w / 2, y0 = cv.h / 2 - h / 2;
        cv.roundRect(x0, y0, x0 + w, y0 + h, u, {0.08f, 0.08f, 0.08f, 0.96f});
        mtext("LOAD FILM", x0 + 2 * u, y0 + 1.5f * u, 1.5f * u, amber, true);
        mtext("the roll in the camera is rewound and put away", x0 + 15 * u, y0 + 1.9f * u, 0.9f * u, grey(0.55f));
        if (first > 0) mtext("▲ more", x0 + w - 9 * u, y0 + 3.6f * u, 0.8f * u, grey(0.5f));
        if (first + shown < n) mtext("▼ more", x0 + w - 9 * u, y0 + 5 * u + shown * rowH, 0.8f * u, grey(0.5f));
        for (int k = 0; k < shown; k++) {
            int i = first + k;
            const FilmStock& st = filmStocks()[i];
            float rx = x0 + u, ry = y0 + 5 * u + k * rowH;
            bool sel = i == filmSel;
            hit(rx, ry, rx + w - 2 * u, ry + rowH, HitKind::FilmRow, i);
            if (sel) selRow(rx, ry, rx + w - 2 * u, ry + rowH - 0.4f * u, u);
            const char* kind = st.blackAndWhite ? "B&W" : (st.contrast > 1.3f ? "slide" : "colour neg");
            mtext((sel ? "▶ " : "  ") + st.name, rx + u, ry + 0.4f * u, 1.25f * u, sel ? amber : grey(1));
            char d[96]; snprintf(d, sizeof d, "ISO %.0f · %s · %d exp", st.iso, kind, st.exposures);
            mtext(d, rx + w * 0.42f, ry + 0.55f * u, 1.0f * u, grey(0.75f));
            mtext(st.inspiredBy, rx + 3 * u, ry + 1.95f * u, 0.8f * u, grey(0.5f));
        }
        // The rating: push / pull.
        float ei = filmStocks()[filmSel].iso * std::exp2(float(filmPush));
        std::string rating = filmPush == 0 ? "box speed" : filmPush > 0 ? "push +" + std::to_string(filmPush) : "pull " + std::to_string(filmPush);
        float y = y0 + h - 8.5f * u;
        char r[96]; snprintf(r, sizeof r, "◀  rate at EI %.0f  (%s)  ▶", ei, rating.c_str());
        mtext(r, x0 + 2 * u, y, 1.3f * u, amber);
        hit(x0 + 2 * u, y - 0.3f * u, x0 + 2 * u + mwidth(r, 1.3f * u), y + 1.8f * u, HitKind::Rating, 0);
        const char* effect = filmPush > 0 ? "more contrast and grain, deeper shadows, a little fog: for low light"
                           : filmPush < 0 ? "softer contrast, finer grain: for harsh light" : "as the maker intended";
        mtext(effect, x0 + 2 * u, y + 1.9f * u, 0.9f * u, grey(0.6f));
        mtext("▲▼ stock   ◀▶ push / pull   A / Enter load   B / Esc back", x0 + 2 * u, y0 + h - 2.6f * u, 0.9f * u, grey(0.6f));
    }
    void openSheet() { scanRolls(); sheetSel = 0; loupe = {-1, -1}; mode = Mode::Sheet; }
    // ---- setting the scale: measure two points (Viewer.swift's measure) ----
    enum class Measure { None, First, Second, Entry };
    Measure measure = Measure::None;
    V3 measureA, measureB;
    bool hasHit = false;                 // what is under the crosshair (the finder's centre depth)
    V3 crosshairHit;
    std::string entryText;
    float entryValue = 1;
    int entryUnit = 2;
    struct Unit { const char* name; float metres; };
    static const std::vector<Unit>& units() {
        static const std::vector<Unit> u = {{"mm", 0.001f}, {"cm", 0.01f}, {"m", 1}, {"in", 0.0254f}, {"ft", 0.3048f}};
        return u;
    }
    static std::string metresText(float d) {
        char b[32];
        if (d < 0.1f) snprintf(b, sizeof b, "%.1f mm", d * 1000);
        else if (d < 1) snprintf(b, sizeof b, "%.1f cm", d * 100);
        else snprintf(b, sizeof b, "%.2f m", d);
        return b;
    }
    /// Measure two points on the scan and say how far apart they really are.
    void startMeasure() {
        mode = Mode::Camera;
        playMode = Mode::Camera;
        measure = Measure::First;
    }
    void endMeasure() {
        measure = Measure::None;
        if (window) SDL_StopTextInput(window);
    }
    /// A, a click or Enter while measuring: the first point, the second, then the real length.
    void measurePress() {
        if (measure == Measure::First || measure == Measure::Second) {
            if (!hasHit) { say("NOTHING UNDER THE CROSSHAIR"); return; }
            if (measure == Measure::First) { measureA = crosshairHit; measure = Measure::Second; return; }
            float metres = len(crosshairHit - measureA) * body.metresPerUnit;
            if (metres <= 0) return;
            measureB = crosshairHit;
            measure = Measure::Entry;
            // Start the dial on the length it measures now, in a sensible unit.
            entryUnit = metres < 0.1f ? 0 : metres < 1 ? 1 : 2;
            entryValue = metres / units()[entryUnit].metres;
            entryText.clear();
            if (window) SDL_StartTextInput(window);
            return;
        }
        if (measure == Measure::Entry) {
            float real = entryValue * units()[entryUnit].metres, now = len(measureB - measureA) * body.metresPerUnit;
            if (real <= 0 || now <= 0) return;
            applyScale(body.metresPerUnit * real / now);
            endMeasure();
        }
    }
    /// B, the right button or Esc while measuring: back a step, or out.
    void measureBack() {
        if (measure == Measure::Entry) { measure = Measure::Second; if (window) SDL_StopTextInput(window); }
        else endMeasure();
    }
    /// Typing the real length: digits and a unit (2.5 m, 30cm, 6 ft).
    void measureType(const std::string& typed, int erase) {
        if (erase > 0 && !entryText.empty()) entryText.pop_back();
        for (char c : typed) entryText += c == ',' ? '.' : c;
        std::string letters, digits;
        for (char c : entryText) {
            if (std::isalpha((unsigned char)c)) letters += char(std::tolower((unsigned char)c));
            if (std::isdigit((unsigned char)c) || c == '.') digits += c;
        }
        for (int u = 0; u < int(units().size()); u++) if (letters == units()[u].name) entryUnit = u;
        if (!digits.empty()) entryValue = std::strtof(digits.c_str(), nullptr);
    }
    void measureDial(const std::string& what) {
        if (what == "up") { entryValue *= 1.1f; entryText.clear(); }
        if (what == "down") { entryValue /= 1.1f; entryText.clear(); }
        if (what == "left" || what == "right") {
            float metres = entryValue * units()[entryUnit].metres;
            int n = int(units().size());
            entryUnit = (entryUnit + (what == "right" ? 1 : n - 1)) % n;
            entryValue = metres / units()[entryUnit].metres;
            entryText.clear();
        }
    }
    /// The scan's new size: metres per scene unit. Distances in metres pinned to the
    /// scene (where you focus) keep their place; paces follow. Remembered for the file.
    void applyScale(float scale) {
        float ratio = scale / body.metresPerUnit;
        body.metresPerUnit = scale;
        body.focusM = std::max(body.lens().minFocusM, body.focusM * ratio);
        pickGait();
        SceneKind k = currentKind();
        k.scale = scale;
        k.remember(scanPath);
        char b[64]; snprintf(b, sizeof b, "SCALE SET: %.3g M PER UNIT", scale);
        say(b);
    }
    /// The crosshair's hit from the finder frame: its centre's ray depth.
    void updateCrosshair(const Frame& f, const FinderJob& j) {
        hasHit = false;
        if (j.fromLight >= 0 || f.w <= 0) return;
        int x = std::clamp(int(j.axis.x), 0, f.w - 1), y = std::clamp(int(j.axis.y), 0, f.h - 1);
        size_t i = size_t(y) * f.w + x;
        if (i >= f.z.size() || f.T[i] > 0.5f || !(f.z[i] > 0)) return;
        V3 fwd{j.view[8], j.view[9], j.view[10]};
        crosshairHit = j.position + norm(fwd) * f.z[i];
        hasHit = true;
    }
    /// The measuring overlay: crosshair, the line, the question (ViewfinderHUD.drawMeasure).
    void drawMeasure(const Inset& in, float u) {
        float imgW = finderW * in.s, imgH = finderH * in.s;
        RGBA yellow{1, 0.85f, 0.2f, 1};
        float fx = body.focalPixels(finderW, finderH);
        auto project = [&](V3 p, V2& out) {
            std::vector<float> V = camera.viewMatrix();
            float cx = V[0] * p.x + V[1] * p.y + V[2] * p.z + V[3], cy = V[4] * p.x + V[5] * p.y + V[6] * p.z + V[7],
                  cz = V[8] * p.x + V[9] * p.y + V[10] * p.z + V[11];
            if (cz <= 0) return false;
            out = {in.x + (fx * cx / cz + finderW / 2.f) * in.s, in.y + (fx * cy / cz + finderH / 2.f) * in.s};
            return true;
        };
        auto shadowed = [&](V2 a, V2 b, float w) { cv.line(a, b, w + 2, {0, 0, 0, 0.6f}, 1.5f); cv.line(a, b, w, yellow); };
        V2 c{in.x + imgW / 2, in.y + imgH / 2};
        if (measure != Measure::Entry)
            for (V2 d : {V2{1, 0}, V2{-1, 0}, V2{0, 1}, V2{0, -1}}) shadowed(c + d * (0.6f * u), c + d * (2.2f * u), 1.5f);
        std::string prompt, label;
        V2 pa, pb;
        bool hasA = false, hasB = false;
        if (measure == Measure::First) {
            prompt = "SET THE SCALE · aim at one end of something you know the size of · A / click · B / right button cancels";
        } else {
            hasA = project(measureA, pa);
            V3 b = measure == Measure::Entry ? measureB : crosshairHit;
            if (measure == Measure::Entry || hasHit) {
                hasB = project(b, pb);
                label = "now " + metresText(len(b - measureA) * body.metresPerUnit);
            }
            prompt = measure == Measure::Second ? "aim at the other end · A / click · B back"
                                                : "How long is it really?  type it (2.5 m, 30 cm, 6 ft) · or ▲▼ / L2 R2 dial, ◀▶ unit · Enter / A set · B re-aim";
        }
        if (hasA) {
            fillEllipse(cv, pa.x, pa.y, 0.45f * u, 0.45f * u, yellow);
            if (hasB) {
                shadowed(pa, pb, 2);
                fillEllipse(cv, pb.x, pb.y, 0.45f * u, 0.45f * u, yellow);
                font.draw(cv, label, (pa.x + pb.x) / 2 + u, (pa.y + pb.y) / 2 - 2 * u, int(1.2f * u), yellow, 0.3f);
            }
        }
        if (measure == Measure::Entry) {
            float w = 34 * u, h = 7 * u, x0 = in.x + imgW / 2 - w / 2, y0 = in.y + imgH - h - 3 * u;
            cv.roundRect(x0, y0, x0 + w, y0 + h, 0.8f * u, {0.06f, 0.06f, 0.06f, 0.92f});
            font.draw(cv, "really:", x0 + 1.5f * u, y0 + 2.6f * u, int(1.2f * u), {0.7f, 0.7f, 0.7f, 1}, 0);
            std::string shown;
            if (entryText.empty()) { char b[32]; snprintf(b, sizeof b, "%.3g", entryValue); shown = b; }
            else for (char ch : entryText) if (std::isdigit((unsigned char)ch) || ch == '.') shown += ch;
            bool blink = (SDL_GetTicks() / 500) % 2 == 0;
            font.draw(cv, shown + " " + units()[entryUnit].name + (blink ? "▏" : " "), x0 + 9 * u, y0 + 1.9f * u, int(2.2f * u), yellow, 0.3f);
        }
        float pw = font.width(prompt, int(0.95f * u));
        font.draw(cv, prompt, in.x + imgW / 2 - pw / 2, in.y + imgH - 2.2f * u, int(0.95f * u), yellow, 0.3f);
    }

    // ---- haptics (Haptics.swift): the camera felt through the controller ----
    bool hapticsOn() const { return g_prefs.getBool("haptics", true); }
    void rumble(float low, float high, int ms) {
        if (pad && hapticsOn()) SDL_RumbleGamepad(pad, Uint16(std::clamp(low, 0.f, 1.f) * 65535), Uint16(std::clamp(high, 0.f, 1.f) * 65535), Uint32(ms));
    }
    /// A camera sound, and the same moment felt in the hands.
    void playFelt(const std::string& event, float volume = 1) {
        sounds.play(event, volume);
        if (event == "film-advance") rumble(0.35f, 0.15f, 140);
        else if (event == "lens-change") rumble(0.45f, 0.25f, 90);
        else if (event == "film-change") rumble(0.3f, 0.3f, 160);
        else if (event == "shutter-change") rumble(0.0f, 0.25f * volume, 25);
        else if (event == "iris-click") rumble(0.0f, 0.18f * volume, 20);
    }
    void shutterFelt(float seconds) {
        sounds.shutter(seconds);
        // The mirror slap and the curtain: a hard knock, longer for slow speeds.
        rumble(0.7f, 0.9f, int(std::clamp(60 + seconds * 1000, 60.f, 400.f)));
    }

    // ---- the light table (ContactSheet.swift, LoupeArt.swift) ----
    /// A small repeatable random stream (each strip's and print's flaws stay put).
    struct Grit {
        uint64_t s;
        explicit Grit(uint64_t seed) : s(seed * 0x9E3779B97F4A7C15ull + 0x632BE59BD9B4E019ull) {}
        uint64_t next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
        float unit() { return float(next() % 1000000) / 1000000.f; }
        float sgn() { return unit() * 2 - 1; }
        int below(int n) { return int(next() % uint64_t(std::max(1, n))); }
    };
    static void fillEllipse(Canvas& c, float cx, float cy, float rx, float ry, RGBA col) {
        for (int y = std::max(0, int(cy - ry - 1)); y < std::min(c.h, int(cy + ry + 2)); y++)
            for (int x = std::max(0, int(cx - rx - 1)); x < std::min(c.w, int(cx + rx + 2)); x++) {
                float dx = (x + 0.5f - cx) / std::max(rx, 0.01f), dy = (y + 0.5f - cy) / std::max(ry, 0.01f);
                float d = (std::sqrt(dx * dx + dy * dy) - 1) * std::min(rx, ry);
                c.blend(x, y, col, std::clamp(0.5f - d, 0.f, 1.f));
            }
    }
    /// A curve from a to b through the controls (a cubic), drawn as short lines.
    static void curve(Canvas& c, V2 a, V2 c1, V2 c2, V2 b, float width, RGBA col) {
        V2 prev = a;
        for (int k = 1; k <= 16; k++) {
            float t = k / 16.f, u = 1 - t;
            V2 p = a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
            c.line(prev, p, width, col);
            prev = p;
        }
    }
    static void hair(Canvas& c, V2 p, float length, float width, RGBA col, Grit& g) {
        float a = g.unit() * 2 * float(M_PI);
        V2 end{p.x + std::cos(a) * length, p.y + std::sin(a) * length};
        curve(c, p, {p.x + g.sgn() * length, p.y + g.sgn() * length}, {end.x + g.sgn() * length * 0.6f, end.y + g.sgn() * length * 0.6f}, end, width, col);
    }

    /// The light table's glow: fluorescent tubes behind a diffuser (bands), warmer and
    /// cooler patches, darker corners, then dust, lint and fine scratches on the glass.
    std::vector<uint32_t> tablePx;
    int tablePxW = 0, tablePxH = 0;
    const std::vector<uint32_t>& tableImage() {
        int w = cv.w, h = cv.h;
        if (tablePxW == w && tablePxH == h) return tablePx;
        Grit g(2024);
        const int gw = 9, gh = 7;
        float grid[gw * gh];
        for (float& v : grid) v = g.sgn();
        auto mottle = [&](float x, float y) {
            float fx = x * (gw - 1), fy = y * (gh - 1);
            int ix = std::min(gw - 2, int(fx)), iy = std::min(gh - 2, int(fy));
            float tx = fx - ix, ty = fy - iy, sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty);
            float a = grid[iy * gw + ix], b = grid[iy * gw + ix + 1], c = grid[(iy + 1) * gw + ix], d = grid[(iy + 1) * gw + ix + 1];
            float top = a + (b - a) * sx, low = c + (d - c) * sx;
            return top + (low - top) * sy;
        };
        Canvas t;
        t.resize(w, h);
        for (int y = 0; y < h; y++) {
            float v = float(y) / h;
            for (int x = 0; x < w; x++) {
                float u = float(x) / w, dx = u - 0.5f, dy = v - 0.5f;
                float lum = 0.93f + 0.035f * std::cos(u * 2 * float(M_PI) * 3.5f + 0.7f) + 0.03f * mottle(u, v);
                lum *= 1 - 0.32f * (dx * dx + dy * dy) * 2;
                lum += float(g.next() % 1000) / 1000 * 0.012f - 0.006f;
                float warm = 0.012f * mottle(1 - v, u);
                t.px[size_t(y) * w + x] = 0xff000000u | uint32_t(sat(lum + warm) * 255) | uint32_t(sat(lum + 0.004f) * 255) << 8 |
                                          uint32_t(sat(lum - warm + 0.03f) * 255) << 16;
            }
        }
        for (int k = 0; k < 260; k++) {
            float r = 0.4f + 1.6f * g.unit() * g.unit();
            fillEllipse(t, g.unit() * w, g.unit() * h, r, r * (0.6f + 0.4f * g.unit()), {0.25f, 0.25f, 0.25f, 0.12f + 0.35f * g.unit()});
        }
        for (int k = 0; k < 7; k++) hair(t, {g.unit() * w, g.unit() * h}, 10 + 30 * g.unit(), 0.6f, {0.3f, 0.3f, 0.3f, 0.3f}, g);
        for (int k = 0; k < 10; k++) {
            V2 p{g.unit() * w, g.unit() * h};
            float a = g.unit() * float(M_PI), l = 40 + 200 * g.unit();
            float wv = g.unit() < 0.5f ? 1.f : 0.4f;
            t.line(p, {p.x + std::cos(a) * l, p.y + std::sin(a) * l}, 0.5f, {wv, wv, wv, 0.12f});
        }
        tablePx = std::move(t.px);
        tablePxW = w; tablePxH = h;
        return tablePx;
    }

    /// Keepers, per roll (frame indices from 0), as marks.json beside its frames.
    std::map<std::string, std::set<int>> marks;
    void loadMarks() {
        marks.clear();
        for (auto& r : rolls) {
            std::ifstream in(r.dir / "marks.json", std::ios::binary);
            if (!in) continue;
            std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
            Json j; std::string err;
            if (!Json::parse(text, j, err)) continue;
            for (float f : j.floats()) marks[r.dir.u8string()].insert(int(f) - 1);
        }
    }
    /// Red grease pencil round the chosen frame: a keeper (or not any more).
    void toggleMark() {
        if (sheetSel < 0 || sheetSel >= int(sheetCellList.size())) return;
        auto [r, f] = sheetCellList[sheetSel];
        if (rolls[r].take) return;
        auto& m = marks[rolls[r].dir.u8string()];
        if (m.count(f)) m.erase(f); else m.insert(f);
        std::ofstream o(rolls[r].dir / "marks.json", std::ios::binary);
        o << "[";
        bool first = true;
        for (int i : m) { o << (first ? "" : ", ") << i + 1; first = false; }
        o << "]";
    }
    std::vector<std::pair<int, int>> sheetCellList;   // each cell's roll and frame

    /// Edge print: small, a little soft (a latent image, not ink), in the margin.
    void filmPrint(const std::string& s, float x, float y, float mm, RGBA c) {
        font.draw(cv, s, x, y, std::max(6, int(1.6f * mm)), c, 0.35f, 0.6f);
    }
    /// A keeper, ringed in red china marker: wobbly, waxy, gone over twice.
    void greasePencil(float x0, float y0, float x1, float y1, uint64_t seed, float mm) {
        Grit g(seed * 7919 + 3);
        x0 -= 1.6f * mm; y0 -= 1.6f * mm; x1 += 1.6f * mm; y1 += 1.6f * mm;
        for (int pass = 0; pass < 2; pass++) {
            V2 corners[4] = {{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}};
            auto jitter = [&](V2 p) { return V2{p.x + g.sgn() * 1.2f * mm, p.y + g.sgn() * 1.2f * mm}; };
            V2 start = jitter(corners[0]), at = start;
            RGBA red{0.80f, 0.08f, 0.07f, pass == 0 ? 0.72f : 0.5f};
            for (int k = 1; k <= 4; k++) {
                V2 a = corners[(k - 1) % 4], b = corners[k % 4];
                V2 mid{(a.x + b.x) / 2 + g.sgn() * 0.8f * mm, (a.y + b.y) / 2 + g.sgn() * 0.8f * mm};
                V2 to = k == 4 ? V2{start.x + 2 * mm, start.y + g.sgn() * mm} : jitter(b);
                curve(cv, at, mid, mid, to, (pass == 0 ? 0.9f : 0.6f) * mm, red);
                at = to;
            }
        }
    }

    /// The zoom knob's place round the barrel for a power (radians, y down): lower
    /// left at 2x, lower right at 10x, the needle inside geared to it.
    static float tabAngle(float power) {
        float t = std::clamp((std::log(power) - std::log(2.f)) / (std::log(10.f) - std::log(2.f)), 0.f, 1.f);
        float a0 = float(M_PI) / 2 + 0.62f, a1 = float(M_PI) / 2 - 0.62f;
        return a0 + (a1 - a0) * t;
    }

    void drawSheet() {
        int W = cv.w, H = cv.h;
        const auto& table = tableImage();
        std::copy(table.begin(), table.end(), cv.px.begin());
        RGBA cream{1.0f, 0.92f, 0.80f, 0.92f};
        sheetRolls.clear();
        sheetCellList.clear();
        auto rail = [&](const std::string& s) {
            cv.rect(0, H - 34, W, H, {0.06f, 0.06f, 0.06f, 0.92f});
            int size = 13;
            float hw = font.width(s, size);
            while (hw > W - 20 && size > 9) hw = font.width(s, --size);
            font.draw(cv, s, std::max(10.f, W / 2 - hw / 2), H - 25, size, cream, 0.2f);
        };
        if (sessions.empty()) {
            rail("No rolls developed yet: shoot a roll, and it comes here from the darkroom");
            sheetCells = 0;
            drawMonitor();
            return;
        }
        // The session's rolls, each cut into strips of six as a lab would, laid in
        // rows, in columns if there are many, as large as the table allows.
        struct Cut { int roll, first, count; };
        std::vector<Cut> cuts;
        for (int r : sessions[sessionIndex])
            for (int f = 0; f < int(rolls[r].frames.size()); f += 6) cuts.push_back({r, f, std::min(6, int(rolls[r].frames.size()) - f)});
        float areaW = W * 0.92f, areaH = (H - 34) * 0.88f;
        auto fit = [&](int cols) {
            int rows = (int(cuts.size()) + cols - 1) / cols;
            float byW = (areaW / cols * 0.96f) / (6 * 38 + 6), byH = areaH / (rows * 35.f + (rows - 1) * 6.f);
            return std::min(byW, byH);
        };
        int cols = 1;
        for (int c = 2; c <= 4; c++) if (fit(c) > fit(cols)) cols = c;
        float mm = fit(cols);
        int rows = (int(cuts.size()) + cols - 1) / cols;
        float colW = (6 * 38 + 6) * mm, gapX = (areaW - cols * colW) / std::max(1, cols);
        float blockH = rows * 35 * mm + (rows - 1) * 6 * mm;
        float bx0 = W / 2.f - (cols * colW + (cols - 1) * gapX) / 2, by0 = std::max(H * 0.03f, ((H - 34) * 0.95f - blockH) / 2);
        struct Cell { float x, y, w, h; int roll, frame; };
        std::vector<Cell> cells;
        for (size_t k = 0; k < cuts.size(); k++) {
            const Cut& cut = cuts[k];
            const Roll& roll = rolls[cut.roll];
            int col = int(k) / rows, row = int(k) % rows;
            Grit g(uint64_t(roll.number * 131 + cut.first * 17 + int(k) + 5));
            // Laid down by hand: never quite in line.
            float x = bx0 + col * (colW + gapX) + g.sgn() * 1.5f, y = by0 + row * 41 * mm + g.sgn() * 1.2f;
            float w = (cut.count * 38 + 6) * mm, h = 35 * mm;
            // The base, punched: the table shows through the sprocket holes.
            cv.rect(x, y, x + w, y + h, {0.05f, 0.05f, 0.05f, 1});
            for (float hx = x + 1.2f * mm; hx < x + w - 2 * mm; hx += 4.75f * mm)
                for (float hy : {y + 2.0f * mm, y + h - 4.8f * mm}) {
                    int sx = std::clamp(int(hx), 0, W - 1), sy = std::clamp(int(hy), 0, H - 1);
                    uint32_t p = table[size_t(sy) * W + sx];
                    RGBA under{(p & 255) / 255.f, ((p >> 8) & 255) / 255.f, ((p >> 16) & 255) / 255.f, 1};
                    cv.roundRect(hx, hy, hx + 1.98f * mm, hy + 2.79f * mm, 0.5f * mm, under);
                }
            // Edge print, exposed into the film at the factory: warm through a colour
            // film's mask, grey on black-and-white.
            bool bw = false;
            for (auto& s : filmStocks()) if (roll.stock.find(s.name) != std::string::npos) bw = s.blackAndWhite;
            RGBA edge = bw ? RGBA{0.80f, 0.80f, 0.80f, 0.85f} : RGBA{1.0f, 0.70f, 0.30f, 0.85f};
            std::string stockName = upper(roll.stock);
            float top = y + 0.2f * mm, bottom = y + h - 1.95f * mm;
            float nx = x + 3 * mm;
            do {
                filmPrint(roll.take ? stockName + "  8-PERF" : stockName + "  SAFETY FILM", nx, top, mm, edge);
                nx += 115 * mm;
            } while (nx < x + w - 50 * mm);
            for (int j = 0; j < cut.count; j++) {
                Cell c{x + (4 + j * 38) * mm, y + 5.5f * mm, 36 * mm, 24 * mm, cut.roll, cut.first + j};
                // A take's posters stand for every 12th frame of the clip.
                int n = roll.take ? (cut.first + j) * 12 + 1 : cut.first + j + 1;
                filmPrint(std::to_string(n), c.x + 2 * mm, bottom, mm, edge);
                filmPrint("▸ " + std::to_string(n) + "A", c.x + c.w / 2 + 1 * mm, bottom, mm, edge);
                if (!bw) {
                    // The bar code: thin and thick dashes, the same for the whole roll.
                    float bxx = c.x + 8 * mm;
                    for (int b = 0; b < 12; b++) {
                        int sum = b;
                        for (unsigned char ch : stockName) sum += ch;
                        float bw2 = (sum % 3 == 0 ? 0.7f : 0.35f) * mm;
                        cv.rect(bxx, bottom + 0.35f * mm, bxx + bw2, bottom + 1.45f * mm, {edge.r, edge.g, edge.b, 0.6f});
                        bxx += 0.9f * mm;
                    }
                }
                cells.push_back(c);
                sheetRolls.push_back(cut.roll);
                sheetCellList.push_back({cut.roll, cut.first + j});
            }
            // The pictures.
            for (int j = 0; j < cut.count; j++) {
                const Cell& c = cells[cells.size() - cut.count + j];
                int tw, th;
                const std::vector<uint8_t>* tp = thumb(roll.frames[c.frame], tw, th);
                if (!tp) continue;
                for (int yy = std::max(0, int(c.y)); yy < std::min(H, int(c.y + c.h)); yy++)
                    for (int xx = std::max(0, int(c.x)); xx < std::min(W, int(c.x + c.w)); xx++) {
                        int sx = std::clamp(int((xx - c.x) / c.w * tw), 0, tw - 1), sy = std::clamp(int((yy - c.y) / c.h * th), 0, th - 1);
                        const uint8_t* p = &(*tp)[(size_t(sy) * tw + sx) * 3];
                        cv.px[size_t(yy) * W + xx] = 0xff000000u | p[0] | p[1] << 8 | p[2] << 16;
                    }
            }
            // Dust printed in with the pictures: white specks, now and then a hair.
            for (int d = 0, n = 2 + g.below(3) + cut.count * 2; d < n; d++) {
                float r = (0.08f + 0.25f * g.unit() * g.unit()) * mm;
                fillEllipse(cv, x + g.unit() * w, y + g.unit() * h, r, r * (0.6f + 0.4f * g.unit()), {0.92f, 0.92f, 0.92f, 0.7f});
            }
            if (g.unit() < 0.4f) hair(cv, {x + g.unit() * w, y + g.unit() * h}, (3 + 6 * g.unit()) * mm, std::max(0.6f, 0.07f * mm), {0.9f, 0.9f, 0.9f, 0.55f}, g);
            // Keepers, ringed in red.
            auto it = marks.find(roll.dir.u8string());
            for (int j = 0; j < cut.count; j++) {
                const Cell& c = cells[cells.size() - cut.count + j];
                if (it != marks.end() && it->second.count(c.frame)) greasePencil(c.x, c.y, c.x + c.w, c.y + c.h, uint64_t(roll.number * 100 + c.frame), mm);
            }
        }
        if (sheetSel >= int(cells.size())) sheetSel = int(cells.size()) - 1;
        if (sheetSel >= 0) {
            // The chosen frame: a dashed line round it.
            const Cell& c = cells[sheetSel];
            float x0 = c.x - 3, y0 = c.y - 3, x1 = c.x + c.w + 3, y1 = c.y + c.h + 3;
            RGBA dash{0.1f, 0.1f, 0.1f, 0.8f};
            for (float t = x0; t < x1; t += 10) { cv.line({t, y0}, {std::min(t + 6, x1), y0}, 1.5f, dash); cv.line({t, y1}, {std::min(t + 6, x1), y1}, 1.5f, dash); }
            for (float t = y0; t < y1; t += 10) { cv.line({x0, t}, {x0, std::min(t + 6, y1)}, 1.5f, dash); cv.line({x1, t}, {x1, std::min(t + 6, y1)}, 1.5f, dash); }
            if (loupe.x < 0) loupe = {c.x + c.w / 2, c.y + c.h / 2};
        }
        sheetCells = int(cells.size());

        // The rail: the session, how many films, the chosen frame, the keys.
        std::string chosen;
        if (sheetSel >= 0 && sheetSel < int(sheetCellList.size())) {
            const Roll& r = rolls[sheetCellList[sheetSel].first];
            bool hasFinal = fs::exists(r.dir / "final-h264.mp4") || fs::exists(r.dir / "final-hevc.mp4");
            chosen = r.take ? " · take " + std::to_string(r.number) + (hasFinal ? " (Return / A: play the final · P / Y: develop it again)"
                                                                                 : " (Return / A: play the preview · P / Y: develop the final)")
                            : " · roll " + std::to_string(r.number) + " frame " + std::to_string(sheetCellList[sheetSel].second + 1);
        }
        char hint[512];
        int nRolls = int(sessions[sessionIndex].size());
        snprintf(hint, sizeof hint, "%s · %d %s (session %d of %d)%s · loupe %.0f×     sticks / mouse: loupe  L2/R2 / wheel: power  d-pad / arrows: frame  A / Return: mark  Y / P: enlarge %s%s  X / G: print wall  Q / E (L1 / R1): session  Esc (B): back",
                 rolls[sessions[sessionIndex][0]].session.c_str(), nRolls, nRolls == 1 ? "roll" : "rolls", sessionIndex + 1, int(sessions.size()),
                 chosen.c_str(), loupePower, anyMarked() ? "marked" : "all", enlargerStatus().c_str());
        rail(hint);

        // The loupe: the table under it, magnified (the pictures from their larger copies).
        float R = H * 0.2f;
        if (loupe.x >= 0) {
            std::vector<uint32_t> under = cv.px;
            auto sample = [&](float sx, float sy) {
                int x0 = std::clamp(int(sx - 0.5f), 0, W - 2), y0 = std::clamp(int(sy - 0.5f), 0, H - 2);
                float fx = std::clamp(sx - 0.5f - x0, 0.f, 1.f), fy = std::clamp(sy - 0.5f - y0, 0.f, 1.f);
                uint32_t q[4] = {under[size_t(y0) * W + x0], under[size_t(y0) * W + x0 + 1], under[size_t(y0 + 1) * W + x0], under[size_t(y0 + 1) * W + x0 + 1]};
                uint32_t out = 0xff000000u;
                for (int ch = 0; ch < 3; ch++) {
                    float a = ((q[0] >> (8 * ch)) & 255) * (1 - fx) + ((q[1] >> (8 * ch)) & 255) * fx;
                    float b = ((q[2] >> (8 * ch)) & 255) * (1 - fx) + ((q[3] >> (8 * ch)) & 255) * fx;
                    out |= uint32_t(a * (1 - fy) + b * fy) << (8 * ch);
                }
                return out;
            };
            for (int y = std::max(0, int(loupe.y - R)); y < std::min(H, int(loupe.y + R) + 1); y++)
                for (int x = std::max(0, int(loupe.x - R)); x < std::min(W, int(loupe.x + R) + 1); x++)
                    if (len(V2{x + 0.5f, y + 0.5f} - loupe) <= R)
                        cv.px[size_t(y) * W + x] = sample(loupe.x + (x + 0.5f - loupe.x) / loupePower, loupe.y + (y + 0.5f - loupe.y) / loupePower);
            // The pictures under it from their 960-wide copies, sharper than the table's.
            for (auto& c : cells) {
                float dx0 = loupe.x + (c.x - loupe.x) * loupePower, dy0 = loupe.y + (c.y - loupe.y) * loupePower;
                float dw = c.w * loupePower, dh = c.h * loupePower;
                if (dx0 > loupe.x + R || dx0 + dw < loupe.x - R || dy0 > loupe.y + R || dy0 + dh < loupe.y - R) continue;
                int tw, th;
                const std::vector<uint8_t>* tp = thumb(rolls[c.roll].frames[c.frame], tw, th);
                if (!tp) continue;
                for (int y = std::max(0, int(dy0)); y < std::min(H, int(dy0 + dh)); y++)
                    for (int x = std::max(0, int(dx0)); x < std::min(W, int(dx0 + dw)); x++) {
                        if (len(V2{x + 0.5f, y + 0.5f} - loupe) > R) continue;
                        int sx = std::clamp(int((x - dx0) / dw * tw), 0, tw - 1), sy = std::clamp(int((y - dy0) / dh * th), 0, th - 1);
                        const uint8_t* p = &(*tp)[(size_t(sy) * tw + sx) * 3];
                        cv.px[size_t(y) * W + x] = 0xff000000u | p[0] | p[1] << 8 | p[2] << 16;
                    }
            }
            // Fall-off toward the rim; specks on the loupe's own glass, its flare off the rim.
            for (int y = std::max(0, int(loupe.y - R)); y < std::min(H, int(loupe.y + R) + 1); y++)
                for (int x = std::max(0, int(loupe.x - R)); x < std::min(W, int(loupe.x + R) + 1); x++) {
                    float d = len(V2{x + 0.5f, y + 0.5f} - loupe) / R;
                    if (d > 1) continue;
                    float t = 0.62f * d, c2 = 1 / (1 + t * t);
                    cv.blend(x, y, {0, 0, 0, 1}, 1 - c2 * c2);
                    float fl = len(V2{x + 0.5f - (loupe.x - R * 0.45f), y + 0.5f - (loupe.y - R * 0.5f)}) / (R * 0.5f);
                    if (fl < 1) cv.blend(x, y, {1, 1, 1, 1}, 0.10f * (1 - fl));
                }
            Grit lr(77);
            for (int k = 0; k < 7; k++) {
                float a = lr.unit() * 2 * float(M_PI), d = R * (0.2f + 0.75f * lr.unit()), r = R * (0.006f + 0.012f * lr.unit());
                fillEllipse(cv, loupe.x + std::cos(a) * d, loupe.y + std::sin(a) * d, r, r, {0.2f, 0.2f, 0.2f, 0.18f});
            }
            drawLoupeBody(loupe, R);
        }
        drawMonitor();
    }

    /// The loupe's body (LoupeArt.swift, simplified): the power scale inside the glass
    /// with its pointer, a bright brass lip, the blackened barrel lit from the room's
    /// window high to the upper left, its knurled grip, and the zoom knob on its neck.
    void drawLoupeBody(V2 c, float R) {
        int W = cv.w, H = cv.h;
        // The scale, engraved on a dark plate round the inside of the glass, along the bottom.
        float r0 = R * 0.80f, r1 = R * 0.985f;
        float lo = tabAngle(10) - 0.1f, hi = tabAngle(2) + 0.1f;
        for (int y = std::max(0, int(c.y)); y < std::min(H, int(c.y + R) + 1); y++)
            for (int x = std::max(0, int(c.x - R)); x < std::min(W, int(c.x + R) + 1); x++) {
                float dx = x + 0.5f - c.x, dy = y + 0.5f - c.y, d = std::sqrt(dx * dx + dy * dy), a = std::atan2(dy, dx);
                if (d < r0 - 1 || d > r1 + 1 || a < lo || a > hi) continue;
                float edge = std::min({d - r0, r1 - d, (a - lo) * d, (hi - a) * d});
                cv.blend(x, y, {0.03f, 0.03f, 0.03f, 1}, 0.85f * std::clamp(edge + 0.5f, 0.f, 1.f));
            }
        RGBA ink{0.86f, 0.84f, 0.80f, 0.9f};
        for (float p = 2; p <= 10.01f; p += 0.5f) {
            bool major = p == 2 || p == 3 || p == 4 || p == 6 || p == 8 || p == 10;
            float a = tabAngle(p), ca = std::cos(a), sa = std::sin(a);
            float ra = major ? r0 + (r1 - r0) * 0.15f : r0 + (r1 - r0) * 0.45f;
            cv.line({c.x + ca * ra, c.y + sa * ra}, {c.x + ca * r1 * 0.985f, c.y + sa * r1 * 0.985f}, std::max(1.f, R * (major ? 0.008f : 0.005f)), ink);
            if (major) {
                std::string s = p == 10 ? "10×" : std::to_string(int(p));
                int size = std::max(8, int(R * 0.055f));
                float rl = r0 - size * 0.9f;
                font.draw(cv, s, c.x + ca * rl - font.width(s, size) / 2, c.y + sa * rl - size * 0.6f, size, ink, 0);
            }
        }
        // The pointer, geared to the knob.
        float pa = tabAngle(loupePower);
        cv.line({c.x + std::cos(pa) * (r0 - R * 0.02f), c.y + std::sin(pa) * (r0 - R * 0.02f)},
                {c.x + std::cos(pa) * r1, c.y + std::sin(pa) * r1}, std::max(1.5f, R * 0.012f), {0.15f, 0.15f, 0.15f, 0.95f});
        // The barrel: a brass lip at the glass, then black anodised metal, its grip knurled.
        float band = R * 0.16f, outer = R + band;
        V2 light = norm2(V2{-0.6f, -0.8f});
        for (int y = std::max(0, int(c.y - outer - 2)); y < std::min(H, int(c.y + outer + 2)); y++)
            for (int x = std::max(0, int(c.x - outer - 2)); x < std::min(W, int(c.x + outer + 2)); x++) {
                float dx = x + 0.5f - c.x, dy = y + 0.5f - c.y, d = std::sqrt(dx * dx + dy * dy);
                if (d < R - 1 || d > outer + 1) continue;
                float cover = std::clamp(std::min(d - R, outer - d) + 0.5f, 0.f, 1.f);
                float t = (d - R) / band;                      // 0 at the glass ... 1 at the rim
                V2 n{dx / std::max(d, 1e-3f), dy / std::max(d, 1e-3f)};
                float facing = n.x * light.x + n.y * light.y;   // the side toward the window
                RGBA col;
                if (t < 0.10f) {
                    // The brass lip holding the glass.
                    float l = 0.55f + 0.35f * std::max(0.f, -facing) + 0.25f * (1 - t / 0.10f);
                    col = {0.74f * l, 0.56f * l, 0.26f * l, 1};
                } else {
                    // A rounded profile: brighter where the curve turns to the light.
                    float prof = std::sin((t - 0.10f) / 0.90f * float(M_PI));
                    float l = 0.07f + 0.10f * prof + 0.16f * std::max(0.f, facing) * prof + 0.05f * std::max(0.f, -facing) * (1 - prof);
                    if (t > 0.55f) {
                        // The knurled grip: fine diagonal ridges catching the light.
                        float a = std::atan2(dy, dx);
                        float ridge = 0.5f + 0.5f * std::sin(a * 180 + (t - 0.55f) * 40);
                        l *= 0.75f + 0.55f * ridge;
                    }
                    col = {l, l * 0.98f, l * 0.95f, 1};
                }
                cv.blend(x, y, col, cover);
            }
        // The zoom knob on the barrel's neck, where the power has it.
        float ka = tabAngle(loupePower), kr = outer + R * 0.03f;
        V2 kc{c.x + std::cos(ka) * kr, c.y + std::sin(ka) * kr};
        float kR = R * 0.07f;
        for (int y = std::max(0, int(kc.y - kR - 2)); y < std::min(H, int(kc.y + kR + 2)); y++)
            for (int x = std::max(0, int(kc.x - kR - 2)); x < std::min(W, int(kc.x + kR + 2)); x++) {
                float dx = x + 0.5f - kc.x, dy = y + 0.5f - kc.y, d = std::sqrt(dx * dx + dy * dy);
                if (d > kR + 1) continue;
                float l = 0.10f + 0.22f * std::max(0.f, -(dx * 0.6f + dy * 0.8f) / std::max(kR, 1.f)) + (d > kR * 0.75f ? 0.05f : 0.f);
                cv.blend(x, y, {l, l * 0.98f, l * 0.95f, 1}, std::clamp(kR - d + 0.5f, 0.f, 1.f));
            }
        fillEllipse(cv, kc.x, kc.y, kR * 0.25f, kR * 0.25f, {0.32f, 0.31f, 0.30f, 1});
    }
    static V2 norm2(V2 v) { float l = len(v); return l > 0 ? v * (1 / l) : v; }

    // ---- the print wall (PrintWall.swift) ----
    // The session's prints pinned to a white gallery wall under track lights, to walk
    // along and look at closely. Positions in wall metres.
    struct Print { fs::path path; std::string caption; };
    std::vector<std::pair<std::string, std::vector<Print>>> wallSessions;
    int wallSession = 0, wallSel = 0;
    V2 wallCentre{0, 0}, wallTarget{0, 0};
    float wallZoom = 400, wallTargetZoom = 400;
    bool wallClose = false;
    static constexpr float printW = 0.40f, matBorder = 0.075f, printGap = 0.16f;
    const std::vector<Print>& wallPrints() const {
        static const std::vector<Print> none;
        return wallSession >= 0 && wallSession < int(wallSessions.size()) ? wallSessions[wallSession].second : none;
    }
    int wallColumns() const {
        int n = int(wallPrints().size());
        return std::max(1, std::min({8, n, int(std::ceil(std::sqrt(n * 1.6)))}));
    }
    void wallFrame(int i, float& x, float& y, float& w, float& h) const {
        int cols = wallColumns(), c = i % cols, r = i / cols;
        w = printW + 2 * matBorder; h = printW / 1.5f + 2 * matBorder;
        x = c * (w + printGap); y = r * (h + printGap * 1.3f);
    }
    void wallBounds(float& x0, float& y0, float& x1, float& y1) const {
        x0 = y0 = 1e9f; x1 = y1 = -1e9f;
        for (int i = 0; i < int(wallPrints().size()); i++) {
            float x, y, w, h;
            wallFrame(i, x, y, w, h);
            x0 = std::min(x0, x); y0 = std::min(y0, y); x1 = std::max(x1, x + w); y1 = std::max(y1, y + h);
        }
        if (x0 > x1) { x0 = y0 = 0; x1 = y1 = 1; }
        x0 -= 0.3f; x1 += 0.3f; y0 -= 0.35f; y1 += 0.35f;
    }
    static std::string printCaption(const fs::path& f, const Roll& r) {
        std::string n = f.stem().u8string();
        if (n.rfind("frame-", 0) == 0) n = n.substr(6);
        std::string s = "Roll " + std::to_string(r.number) + " · " + n;
        std::ifstream in(fs::path(f).replace_extension(".json"), std::ios::binary);
        std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        Json j; std::string err;
        if (!text.empty() && Json::parse(text, j, err)) {
            if (j.has("lens")) s += " · " + j["lens"].str();
            if (j.has("aperture") && j.has("shutter")) { char b[64]; snprintf(b, sizeof b, " · f/%.1f %s", j["aperture"].num(), j["shutter"].str().c_str()); s += b; }
            if (j.has("film")) s += " · " + j["film"].str();
        }
        return s;
    }
    void openWall() {
        // Every session's prints (Windows makes full prints at the shutter: every frame is one);
        // the light table's session first.
        std::string want = sessions.empty() ? "" : rolls[sessions[sessionIndex][0]].session;
        wallSessions.clear();
        for (auto& r : rolls) {
            if (r.take) continue;
            for (auto& f : r.frames) {
                if (isProof(f)) continue;
                if (wallSessions.empty() || wallSessions.back().first != r.session) wallSessions.push_back({r.session, {}});
                wallSessions.back().second.push_back({f, printCaption(f, r)});
            }
        }
        wallSession = std::max(0, int(wallSessions.size()) - 1);
        for (int i = 0; i < int(wallSessions.size()); i++) if (wallSessions[i].first == want) wallSession = i;
        wallSel = 0;
        wallFrameAll(false);
        mode = Mode::Wall;
    }
    void wallFrameAll(bool animated) {
        float x0, y0, x1, y1;
        wallBounds(x0, y0, x1, y1);
        wallTarget = {(x0 + x1) / 2, (y0 + y1) / 2};
        wallTargetZoom = std::min(cv.w / std::max(x1 - x0, 0.1f), (cv.h - 34) * 0.9f / std::max(y1 - y0, 0.1f));
        wallClose = false;
        if (!animated) { wallCentre = wallTarget; wallZoom = wallTargetZoom; }
    }
    void wallFrameSelected() {
        if (wallSel < 0 || wallSel >= int(wallPrints().size())) return;
        float x, y, w, h;
        wallFrame(wallSel, x, y, w, h);
        wallTarget = {x + w / 2, y + h / 2};
        wallTargetZoom = std::min(cv.w / (w * 1.15f), (cv.h - 34) / (h * 1.25f));
        wallClose = true;
    }
    void wallStep(int dx, int dy) {
        int n = int(wallPrints().size());
        if (!n) return;
        wallSel = std::clamp(wallSel + dx + dy * wallColumns(), 0, n - 1);
        wallFrameSelected();
    }
    void wallChangeSession(int d) {
        if (wallSessions.empty()) return;
        wallSession = std::clamp(wallSession + d, 0, int(wallSessions.size()) - 1);
        wallSel = 0;
        wallFrameAll(false);
    }
    void wallUpdate(V2 move, float zoomBy, float dt) {
        // The sticks walk along the wall (faster when stood back), the triggers step in and out.
        float speed = 0.9f * cv.w / std::max(wallTargetZoom, 1.f);
        wallTarget = wallTarget + move * (speed * dt);
        if (zoomBy != 0) wallTargetZoom = std::clamp(wallTargetZoom * std::exp(zoomBy * dt * 1.6f), 60.f, 40000.f);
        float x0, y0, x1, y1;
        wallBounds(x0, y0, x1, y1);
        wallTarget.x = std::clamp(wallTarget.x, x0, x1);
        wallTarget.y = std::clamp(wallTarget.y, y0, y1);
        float ease = 1 - std::exp(-dt / 0.12f);
        wallCentre = wallCentre + (wallTarget - wallCentre) * ease;
        wallZoom *= std::pow(wallTargetZoom / wallZoom, ease);
    }
    void wallWheel(float d, V2 at) {
        float old = wallTargetZoom;
        wallTargetZoom = std::clamp(wallTargetZoom * std::exp(d * 0.12f), 60.f, 40000.f);
        // Toward the pointer, as a magnifier would.
        V2 w = wallToWall(at);
        wallTarget = w + (wallTarget - w) * (old / wallTargetZoom);
    }
    V2 wallToView(V2 w) const { return {(w.x - wallCentre.x) * wallZoom + cv.w / 2.f, (w.y - wallCentre.y) * wallZoom + (cv.h - 34) / 2.f}; }
    V2 wallToWall(V2 v) const { return {(v.x - cv.w / 2.f) / wallZoom + wallCentre.x, (v.y - (cv.h - 34) / 2.f) / wallZoom + wallCentre.y}; }
    /// The chosen print, full size, for looking closely.
    std::string bigKey;
    std::vector<uint8_t> bigPx;
    int bigW = 0, bigH = 0;
    const std::vector<uint8_t>* fullPrint(const fs::path& p, int& w, int& h) {
        std::string k = p.u8string();
        if (k != bigKey) {
            int n;
            unsigned char* d = stbi_load(k.c_str(), &bigW, &bigH, &n, 3);
            bigKey = k;
            bigPx.assign(d, d ? d + size_t(bigW) * bigH * 3 : d);
            if (d) stbi_image_free(d); else bigW = bigH = 0;
        }
        w = bigW; h = bigH;
        return bigPx.empty() ? nullptr : &bigPx;
    }

    void drawWall() {
        int W = cv.w, H = cv.h;
        float mm = wallZoom / 1000;
        // The wall's paint: eggshell white, gently uneven, with a roller's stipple.
        parallelRows(H, [&](int ya, int yb) {
          for (int y = ya; y < yb; y++)
            for (int x = 0; x < W; x++) {
                V2 w = wallToWall({x + 0.5f, y + 0.5f});
                float m = 0.02f * (valueNoise(w.x / 0.8f, w.y / 0.8f, 3) - 0.5f) + (wallZoom > 300 ? 0.025f * std::min(1.f, wallZoom / 2000) * (valueNoise(w.x / 0.004f, w.y / 0.004f, 11) - 0.5f) : 0);
                cv.px[size_t(y) * W + x] = 0xff000000u | uint32_t(sat(0.95f + m) * 255) | uint32_t(sat(0.93f + m) * 255) << 8 | uint32_t(sat(0.87f + m) * 255) << 16;
            }
        });
        const auto& prints = wallPrints();
        auto soft = [&](float x0, float y0, float x1, float y1, float dyOff, float blur, float alpha) {
            y0 += dyOff; y1 += dyOff;
            for (int y = std::max(0, int(y0 - blur)); y < std::min(H, int(y1 + blur) + 1); y++)
                for (int x = std::max(0, int(x0 - blur)); x < std::min(W, int(x1 + blur) + 1); x++) {
                    float qx = std::max({x0 - x, 0.f, x - x1}), qy = std::max({y0 - y, 0.f, y - y1});
                    float d = std::sqrt(qx * qx + qy * qy);
                    float a = alpha * (1 - std::clamp(d / std::max(blur, 1.f), 0.f, 1.f));
                    cv.blend(x, y, {0, 0, 0, 1}, a * a / std::max(alpha, 1e-3f));
                }
        };
        for (int i = 0; i < int(prints.size()); i++) {
            float fx, fy, fw, fh;
            wallFrame(i, fx, fy, fw, fh);
            V2 a = wallToView({fx, fy});
            float x0 = a.x, y0 = a.y, x1 = a.x + fw * wallZoom, y1 = a.y + fh * wallZoom;
            if (x1 < -80 || y1 < -80 || x0 > W + 80 || y0 > H + 80) continue;
            // The board's shadows on the wall: a tight one and a soft one, both below.
            soft(x0, y0, x1, y1, std::max(1.f, 2.5f * mm), std::max(1.5f, 3 * mm), 0.38f);
            soft(x0, y0, x1, y1, std::max(3.f, 16 * mm), std::max(5.f, 32 * mm), 0.28f);
            // Its face, white with fine fibre; its thickness lit on top, shaded below.
            cv.rect(x0, y0, x1, y1, {0.985f, 0.983f, 0.975f, 1});
            float t = std::max(0.8f, 2 * mm);
            cv.rect(x0, y0, x1, y0 + t * 0.6f, {1, 1, 1, 0.9f});
            cv.rect(x0, y1 - t, x1, y1, {0.80f, 0.79f, 0.76f, 1});
            cv.rect(x0, y0, x0 + t * 0.6f, y1, {0.90f, 0.895f, 0.88f, 1});
            cv.rect(x1 - t * 0.6f, y0, x1, y1, {0.90f, 0.895f, 0.88f, 1});
            // The print in the window, its bevel cut at 45 degrees round it.
            float inset = matBorder * wallZoom, bev = std::max(1.f, 3.5f * mm);
            float ix0 = x0 + inset, iy0 = y0 + inset, ix1 = x1 - inset, iy1 = y1 - inset;
            for (int y = std::max(0, int(iy0 - bev)); y < std::min(H, int(iy1 + bev) + 1); y++)
                for (int x = std::max(0, int(ix0 - bev)); x < std::min(W, int(ix1 + bev) + 1); x++) {
                    float px = x + 0.5f, py = y + 0.5f;
                    if (px >= ix0 && px < ix1 && py >= iy0 && py < iy1) continue;
                    float dl = ix0 - px, dr = px - ix1, dt = iy0 - py, db = py - iy1;
                    float l;
                    if (dt >= std::max({dl, dr, db})) l = 0.84f + (0.76f - 0.84f) * (1 - dt / bev);
                    else if (db >= std::max(dl, dr)) l = 1.0f + (0.97f - 1.0f) * (db / bev);
                    else if (dl >= dr) l = 0.95f + (0.90f - 0.95f) * (1 - dl / bev);
                    else l = 0.94f + (0.88f - 0.94f) * (1 - dr / bev);
                    cv.px[size_t(y) * W + x] = 0xff000000u | uint32_t(sat(l) * 255) | uint32_t(sat(l * 0.996f) * 255) << 8 | uint32_t(sat(l * 0.985f) * 255) << 16;
                }
            int tw, th;
            const std::vector<uint8_t>* tp = nullptr;
            if (wallClose && i == wallSel && (ix1 - ix0) > 900) tp = fullPrint(prints[i].path, tw, th);
            if (!tp) tp = thumb(prints[i].path, tw, th);
            if (tp) {
                // Fitted to the window, its shape kept.
                float rw = ix1 - ix0, rh = iy1 - iy0, a2 = float(tw) / th;
                float px0 = ix0, py0 = iy0, pw = rw, ph = rh;
                if (a2 > rw / rh) { ph = rw / a2; py0 += (rh - ph) / 2; } else { pw = rh * a2; px0 += (rw - pw) / 2; }
                cv.rect(ix0, iy0, ix1, iy1, {0.85f, 0.85f, 0.85f, 1});
                for (int y = std::max(0, int(py0)); y < std::min(H, int(py0 + ph)); y++)
                    for (int x = std::max(0, int(px0)); x < std::min(W, int(px0 + pw)); x++) {
                        int sx = std::clamp(int((x - px0) / pw * tw), 0, tw - 1), sy = std::clamp(int((y - py0) / ph * th), 0, th - 1);
                        const uint8_t* p = &(*tp)[(size_t(sy) * tw + sx) * 3];
                        cv.px[size_t(y) * W + x] = 0xff000000u | p[0] | p[1] << 8 | p[2] << 16;
                    }
            } else {
                cv.rect(ix0, iy0, ix1, iy1, {0.85f, 0.85f, 0.85f, 1});
            }
            // The crisp cut where the bevel meets the face.
            RGBA cut{0.55f, 0.55f, 0.55f, 0.35f};
            float lw = std::max(0.6f, 0.25f * mm);
            cv.line({ix0 - bev, iy0 - bev}, {ix1 + bev, iy0 - bev}, lw, cut); cv.line({ix0 - bev, iy1 + bev}, {ix1 + bev, iy1 + bev}, lw, cut);
            cv.line({ix0 - bev, iy0 - bev}, {ix0 - bev, iy1 + bev}, lw, cut); cv.line({ix1 + bev, iy0 - bev}, {ix1 + bev, iy1 + bev}, lw, cut);
            // Real things are not perfect: dust, worn corners. Fixed per print.
            Grit g(std::hash<std::string>{}(prints[i].path.u8string()));
            for (V2 cr : {V2{x0, y0}, V2{x1, y0}, V2{x0, y1}, V2{x1, y1}})
                if (g.unit() < 0.5f) { float rr = (2 + 3 * g.unit()) * mm; fillEllipse(cv, cr.x, cr.y, rr, rr, {0.8f, 0.8f, 0.8f, 0.35f}); }
            if (mm > 0.25f)
                for (int k = 0, n = 14 + int(g.unit() * 24); k < n; k++) {
                    bool onPrint = k % 4 == 0;
                    float ax0 = onPrint ? ix0 : x0, ay0 = onPrint ? iy0 : y0, aw = onPrint ? ix1 - ix0 : x1 - x0, ah = onPrint ? iy1 - iy0 : y1 - y0;
                    float dx = ax0 + g.unit() * aw, dy = ay0 + g.unit() * ah;
                    if (!onPrint && dx > ix0 - bev && dx < ix1 + bev && dy > iy0 - bev && dy < iy1 + bev) continue;
                    float rr = std::max(0.35f, (0.08f + 0.35f * std::pow(g.unit(), 3.f)) * mm);
                    float dk = onPrint ? 0.2f + 0.5f * g.unit() : 0.35f + 0.3f * g.unit();
                    fillEllipse(cv, dx, dy, rr, rr * (0.7f + 0.6f * g.unit()), {dk, dk, dk, 0.55f});
                }
            // L-pins: two along the top edge, two along the bottom: round steel wire.
            float wire = std::max(0.8f, 1.0f * mm), leg = std::max(4.f, 11 * mm);
            for (int k = 0; k < 4; k++) {
                float px = k % 2 == 0 ? x0 + (x1 - x0) * 0.14f : x1 - (x1 - x0) * 0.14f;
                bool topEdge = k < 2;
                float edgeY = topEdge ? y0 : y1, onto = topEdge ? 1.f : -1.f;
                float hy = edgeY - onto * wire * 1.4f, ey = edgeY + onto * leg;
                fillEllipse(cv, px, hy, wire * 0.9f, wire * 0.9f, {0.25f, 0.25f, 0.25f, 0.6f});
                cv.line({px + wire * 0.6f, std::min(hy, ey) + wire * 1.8f}, {px + wire * 0.6f, std::max(hy, ey) + wire * 1.8f}, wire, {0, 0, 0, 0.25f}, wire * 1.5f);
                for (float s = -0.5f; s <= 0.5f; s += 0.25f) {
                    float l = s < -0.2f ? 0.38f : s < 0.1f ? 0.95f : s < 0.3f ? 0.70f : 0.32f;
                    cv.line({px + s * wire, std::min(hy, ey)}, {px + s * wire, std::max(hy, ey)}, std::max(0.5f, wire * 0.3f), {l, l, l, 1});
                }
            }
        }
        // The light over everything: the house light, and a track spot over each column
        // of prints, brightest a little above their middle (multiplied over the wall).
        int cols = wallColumns(), rows = prints.empty() ? 0 : (int(prints.size()) + cols - 1) / cols;
        std::vector<V2> spots;
        std::vector<float> reach;
        for (int c = 0; c < cols && !prints.empty(); c++) {
            float fx, fy, fw, fh;
            wallFrame(c, fx, fy, fw, fh);
            V2 top = wallToView({fx + fw / 2, fy - 0.15f});
            float rc = (rows * (fh + printGap * 1.3f) + 0.4f) * wallZoom;
            spots.push_back({top.x, top.y + rc * 0.35f});
            reach.push_back(rc * 0.8f);
        }
        parallelRows(H - 34, [&](int ya, int yb) {
            for (int y = ya; y < yb; y++)
                for (int x = 0; x < W; x++) {
                    float r = 0.70f, gg = 0.69f, b = 0.67f;
                    for (size_t s = 0; s < spots.size(); s++) {
                        float dx = (x + 0.5f - spots[s].x) / 0.6f, dy = y + 0.5f - spots[s].y;
                        float t = std::sqrt(dx * dx + dy * dy) / std::max(reach[s], 1.f);
                        if (t >= 1) continue;
                        float a = t < 0.5f ? 1 - 0.9f * t : 0.55f * (1 - (t - 0.5f) * 2);
                        r = std::max(r, r + (1.0f - r) * a); gg = std::max(gg, gg + (0.98f - gg) * a); b = std::max(b, b + (0.93f - b) * a);
                    }
                    uint32_t& p = cv.px[size_t(y) * W + x];
                    p = 0xff000000u | uint32_t((p & 255) * r) | uint32_t(((p >> 8) & 255) * gg) << 8 | uint32_t(((p >> 16) & 255) * b) << 16;
                }
        });
        // Captions, pencilled under each print once close enough to read.
        if (wallZoom > 900)
            for (int i = 0; i < int(prints.size()); i++) {
                float fx, fy, fw, fh;
                wallFrame(i, fx, fy, fw, fh);
                V2 a = wallToView({fx, fy + fh});
                if (a.x > W || a.y > H || a.x + fw * wallZoom < 0) continue;
                font.draw(cv, prints[i].caption, a.x, a.y + 0.016f * wallZoom, std::max(8, int(0.011f * wallZoom)), {0.3f, 0.3f, 0.3f, 0.75f}, 0);
            }
        std::string name = wallSessions.empty() ? "" : wallSessions[wallSession].first;
        std::string hint = prints.empty()
            ? "No enlarged prints in this session yet: mark frames on the light table and press Y / P to enlarge them     Q / E (L1 / R1): other sessions  Esc (B): back"
            : name + " · " + std::to_string(prints.size()) + (prints.size() == 1 ? " print" : " prints") + " (session " + std::to_string(wallSession + 1) + " of " +
                  std::to_string(wallSessions.size()) + ")     WASD / sticks: walk  wheel / triggers: closer  arrows / d-pad: next print  Return (A): look closely  Q / E (L1 / R1): session  Esc (B): back";
        cv.rect(0, H - 34, W, H, {0.06f, 0.06f, 0.06f, 0.92f});
        int size = 13;
        float hw = font.width(hint, size);
        while (hw > W - 20 && size > 9) hw = font.width(hint, --size);
        font.draw(cv, hint, std::max(10.f, W / 2 - hw / 2), H - 25, size, {1.0f, 0.92f, 0.80f, 0.92f}, 0.2f);
    }
    int sheetCells = 0;
    std::vector<int> sheetRolls;        // each cell's roll

    /// Where rolls are kept (File > Choose Where Rolls Are Kept on the Mac): a folder, remembered.
    void chooseRollsFolder() {
        static std::string start;
        start = rollsRoot().u8string();
        SDL_ShowOpenFolderDialog([](void* ud, const char* const* list, int) {
            if (!list || !list[0]) return;
            g_prefs.set("rollsFolder", list[0]);
            static_cast<App*>(ud)->say("ROLLS NOW KEPT IN " + upper(fs::u8path(list[0]).filename().u8string()));
        }, this, window, start.c_str(), false);
    }
    void chooseScene() {
        static const SDL_DialogFileFilter filters[] = {{"Scans and scenes", "ply;vcscene"}, {"Gaussian splat scan", "ply"}, {"Vintage Click scene", "vcscene"}};
        SDL_ShowOpenFileDialog([](void* ud, const char* const* list, int) {
            if (!list || !list[0]) return;
            App* app = static_cast<App*>(ud);
            app->pendingOpen = list[0];
        }, this, window, filters, 1, nullptr, false);
    }
    std::string pendingOpen;

    // ---- input ----
    float axis(SDL_GamepadAxis a) const {
        if (!pad) return 0;
        float v = SDL_GetGamepadAxis(pad, a) / 32767.f;
        float dz = 0.12f, m = std::fabs(v);
        if (m < dz) return 0;
        float t = (m - dz) / (1 - dz);
        return (v < 0 ? -1 : 1) * t * t;
    }
    bool button(SDL_GamepadButton b) const { return pad && SDL_GetGamepadButton(pad, b); }

    void press(const std::string& what) {
        if (mode == Mode::Menu && showingHelp) {
            if (what == "a" || what == "b" || what == "menu") showingHelp = false;
            return;
        }
        if (mode == Mode::Menu) {
            int n = int(menuItems().size());
            if (what == "up") menuSel = (menuSel + n - 1) % n;
            if (what == "down") menuSel = (menuSel + 1) % n;
            if (what == "a") chooseMenu();
            if (what == "b" || what == "menu") {
                // Back a page (Controls → Settings → main), or out of the menu.
                if (menuPage == Page::Controls || menuPage == Page::Finder) go(Page::Settings);
                else if (menuPage == Page::Motion) go(Page::Bag);
                else if (menuPage != Page::Main) go(Page::Main);
                else mode = playMode;
            }
            return;
        }
        if (mode == Mode::List) {
            int n = int(listRows.size());
            if (n && what == "up") listChoice = (listChoice + n - 1) % n;
            if (n && what == "down") listChoice = (listChoice + 1) % n;
            if (n && what == "a" && onChooseList) onChooseList(listChoice);
            if (what == "b" || what == "menu") mode = playMode;
            return;
        }
        if (mode == Mode::Lighting) { lightingPress(what); return; }
        if (mode == Mode::Bag) {
            // The bag's shelves, then the filters (the last shelf, as on the Mac).
            int filterShelf = int(lensShelves().size()), ns = filterShelf + 1;
            int nl = shelf == filterShelf ? int(lensFilters().size()) : lensShelves()[shelf].count;
            // Shelves whose lenses fit the body (the filters always do), as moveShelf does.
            auto allowed = [&](int sIdx) {
                if (sIdx == filterShelf) return true;
                for (int k = 0; k < lensShelves()[sIdx].count; k++) if (body.fits(lensBag()[shelfStart(sIdx) + k])) return true;
                return false;
            };
            if (what == "left" || what == "right") {
                int d = what == "left" ? ns - 1 : 1;
                for (int t = 0; t < ns; t++) { shelf = (shelf + d) % ns; if (allowed(shelf)) break; }
                lensSel = shelf == filterShelf ? body.filterIndex : 0;
            }
            if (what == "up") lensSel = (lensSel + nl - 1) % nl;
            if (what == "down") lensSel = (lensSel + 1) % nl;
            if (what == "a" && shelf == filterShelf) {
                if (!body.fits(lensFilters()[lensSel])) { say("THIS LENS TAKES ONLY COLOUR AND ND FILTERS, AT THE BACK"); return; }
                body.filterIndex = lensSel;
                body.meterShutter(meterLum);
                say(lensSel == 0 ? "FILTER OFF" : upper(lensFilters()[lensSel].name));
                mode = Mode::Camera;
                return;
            }
            if (what == "a" && !body.fits(lensBag()[shelfStart(shelf) + lensSel])) {
                say(body.model().rangefinder() ? "THE " + upper(body.model().fullName()) + " TAKES ITS OWN LENSES"
                                               : "A RANGEFINDER LENS: IT FITS THE LAHNTAL R5");
                return;
            }
            if (what == "a") {
                body.chooseLens(shelfStart(shelf) + lensSel);
                camera.focalMM = body.lens().focalMM;
                playFelt("lens-change");
                say(mountedLabel());
                mode = Mode::Camera;
            }
            if (what == "b" || what == "menu") mode = Mode::Camera;
            return;
        }
        if (mode == Mode::Film) {
            int n = int(filmStocks().size());
            if (what == "up") filmSel = (filmSel + n - 1) % n;
            if (what == "down") filmSel = (filmSel + 1) % n;
            if (what == "left") filmPush = std::max(-1, filmPush - 1);
            if (what == "right") filmPush = std::min(3, filmPush + 1);
            if (what == "a") {
                body.loadRoll(filmSel, filmPush);
                body.meterShutter(meterLum);
                playFelt("film-change");
                say("LOADED " + body.rollName());
                mode = Mode::Camera;
            }
            if (what == "b" || what == "menu") mode = Mode::Camera;
            return;
        }
        if (mode == Mode::Wall) {
            if (what == "left") wallStep(-1, 0);
            if (what == "right") wallStep(1, 0);
            if (what == "up") wallStep(0, -1);
            if (what == "down") wallStep(0, 1);
            if (what == "a") { if (wallClose) wallFrameAll(true); else wallFrameSelected(); }
            if (what == "l1") wallChangeSession(-1);
            if (what == "r1") wallChangeSession(1);
            if (what == "b" || what == "view" || what == "x") mode = Mode::Sheet;
            if (what == "menu") openMenu();
            return;
        }
        if (mode == Mode::Sheet) {
            // A marks a keeper; on a take's posters it plays the movie, Y / P develops its final.
            int roll = sheetSel >= 0 && sheetSel < int(sheetRolls.size()) ? sheetRolls[sheetSel] : -1;
            bool take = roll >= 0 && roll < int(rolls.size()) && rolls[roll].take;
            if (take && what == "a") playTake(rolls[roll].dir);
            if (take && what == "y") developFinal(rolls[roll].dir);
            if (!take && what == "y") enlarge(enlargeCandidates());
            if (!take && what == "a") toggleMark();
            if (what == "x") { openWall(); return; }
            if (what == "left") sheetSel = std::max(0, sheetSel - 1);
            if (what == "right") sheetSel = std::min(sheetCells - 1, sheetSel + 1);
            if (what == "up") sheetSel = std::max(0, sheetSel - 6);
            if (what == "down") sheetSel = std::min(sheetCells - 1, sheetSel + 6);
            if (what == "left" || what == "right" || what == "up" || what == "down") loupe = {-1, -1};
            if (what == "l1") { sessionIndex = std::max(0, sessionIndex - 1); sheetSel = 0; loupe = {-1, -1}; }
            if (what == "r1") { sessionIndex = std::min(int(sessions.size()) - 1, sessionIndex + 1); sheetSel = 0; loupe = {-1, -1}; }
            if (what == "b" || what == "view") mode = Mode::Camera;
            if (what == "menu") openMenu();
            return;
        }
        // The camera, measuring: A sets each point, B steps back, the d-pad dials the length.
        if (measure != Measure::None) {
            if (what == "a") { measurePress(); return; }
            if (what == "b" || what == "menu") { measureBack(); return; }
            if (measure == Measure::Entry && (what == "up" || what == "down" || what == "left" || what == "right")) { measureDial(what); return; }
        }
        // The camera.
        if ((what == "left" || what == "right") && body.autoOn()) {
            // Turning the ring off A: manual.
            body.autoExposure = 0;
            say("MANUAL EXPOSURE");
        }
        if (body.model().isMotion() && pad && button(SDL_GAMEPAD_BUTTON_EAST)) {
            // Holding B (the preview lever), the d-pad and shoulders work the timeline.
            if (what == "left") { motionKey("prevKey", false); return; }
            if (what == "right") { motionKey("nextKey", false); return; }
            if (what == "down") { motionKey("setKey", true); return; }
            if (what == "up") { motionKey("develop", false); return; }
            if (what == "l1") { pose(playhead - 1); return; }
            if (what == "r1") { pose(playhead + 1); return; }
        }
        if (what == "left" || what == "right") {
            body.stopBetween = 0;
            int was = body.apertureIndex;
            body.changeAperture(what == "left" ? -1 : 1);
            if (body.apertureIndex != was) playFelt("iris-click", 0.6f);
        }
        if (what == "up" || what == "down") {
            int was = body.shutterIndex;
            body.changeShutter(what == "up" ? 1 : -1);
            if (body.shutterIndex != was) playFelt("shutter-change", 0.7f);
        }
        if (what == "a") release();
        if (what == "x") openBag();
        if (what == "y" && body.model().isMotion()) { motionKey("setKey", false); return; }
        if (what == "y") { filmSel = body.stockIndex; filmPush = body.push; mode = Mode::Film; }
        if (what == "view") openSheet();
        if (what == "menu") { mode = Mode::Menu; menuSel = 0; }
        if (what == "l3") changeGait(gait + 1 < int(gaits().size()) ? 1 : -gait);
        if (what == "slower") changeGait(-1);
        if (what == "faster") changeGait(1);
        if (what == "r3") toggleLighting();
    }

    void handle(const SDL_Event& e) {
        switch (e.type) {
        case SDL_EVENT_QUIT: quit = true; break;
        case SDL_EVENT_GAMEPAD_ADDED: if (!pad) pad = SDL_OpenGamepad(e.gdevice.which); break;
        case SDL_EVENT_DROP_FILE: if (e.drop.data) pendingOpen = e.drop.data; break;
        case SDL_EVENT_GAMEPAD_BUTTON_DOWN: {
            static const std::map<int, std::string> m = {
                {SDL_GAMEPAD_BUTTON_SOUTH, "a"}, {SDL_GAMEPAD_BUTTON_EAST, "b"}, {SDL_GAMEPAD_BUTTON_WEST, "x"},
                {SDL_GAMEPAD_BUTTON_NORTH, "y"}, {SDL_GAMEPAD_BUTTON_DPAD_LEFT, "left"}, {SDL_GAMEPAD_BUTTON_DPAD_RIGHT, "right"},
                {SDL_GAMEPAD_BUTTON_DPAD_UP, "up"}, {SDL_GAMEPAD_BUTTON_DPAD_DOWN, "down"}, {SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, "l1"},
                {SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, "r1"}, {SDL_GAMEPAD_BUTTON_START, "menu"}, {SDL_GAMEPAD_BUTTON_BACK, "view"},
                {SDL_GAMEPAD_BUTTON_LEFT_STICK, "l3"}, {SDL_GAMEPAD_BUTTON_RIGHT_STICK, "r3"}};
            auto it = m.find(e.gbutton.button);
            if (mode == Mode::Camera && e.gbutton.button == SDL_GAMEPAD_BUTTON_NORTH) {
                // Y: a tap loads film; held, the right stick tilts or shifts the lens.
                padYDown = true; padYMoved = false;
                break;
            }
            if (mode == Mode::Camera && padYDown && e.gbutton.button == SDL_GAMEPAD_BUTTON_RIGHT_STICK) {
                // Y + R3: the lens back square and centred.
                padYMoved = true;
                if (body.tilt.x != 0 || body.tilt.y != 0 || body.shift.x != 0 || body.shift.y != 0) {
                    body.tilt = {}; body.shift = {};
                    say(movementLabel());
                }
                break;
            }
            // In the camera the shoulders rise and sink (held), not presses.
            bool flying = mode == Mode::Camera || mode == Mode::Lighting;
            bool timeline = mode == Mode::Camera && body.model().isMotion() && button(SDL_GAMEPAD_BUTTON_EAST);
            if (movie && mode == Mode::Camera && (it != m.end() && (it->second == "b" || it->second == "menu"))) {
                movie->cancelled = true;
                say("STOPPING THE TAKE");
                break;
            }
            if (it != m.end() && !(flying && !timeline && (it->second == "l1" || it->second == "r1"))) press(it->second);
            break;
        }
        case SDL_EVENT_GAMEPAD_BUTTON_UP:
            if (e.gbutton.button == SDL_GAMEPAD_BUTTON_NORTH && padYDown) {
                padYDown = false;
                if (!padYMoved && mode == Mode::Camera) press("y");
            }
            break;
        case SDL_EVENT_TEXT_INPUT:
            if (measure == Measure::Entry && e.text.text) measureType(e.text.text, 0);
            break;
        case SDL_EVENT_KEY_DOWN: {
            bool flying = mode == Mode::Camera || mode == Mode::Lighting;
            SDL_Keycode k = e.key.key;
            // Measuring: Enter sets, Esc steps back; typing the length takes the other keys.
            if (measure != Measure::None && mode == Mode::Camera) {
                if (k == SDLK_ESCAPE) { measureBack(); break; }
                if (k == SDLK_RETURN || k == SDLK_KP_ENTER) { measurePress(); break; }
                if (measure == Measure::Entry) {
                    if (k == SDLK_BACKSPACE) measureType("", 1);
                    if (k == SDLK_UP) measureDial("up");
                    if (k == SDLK_DOWN) measureDial("down");
                    if (k == SDLK_LEFT) measureDial("left");
                    if (k == SDLK_RIGHT) measureDial("right");
                    break;
                }
            }
            if (e.key.repeat && flying) break;
            // W on the camera bag's body row: the movie camera (hidden), and back.
            if (k == SDLK_W && mode == Mode::Menu && !showingHelp && menuPage == Page::Bag && menuSel == 1) {
                body.chooseBody(body.model().isMotion() ? 0 : CameraModel::wilmont);
                if (body.model().isMotion()) body.frameRate = workingTake().frameRate;
                playFelt("lens-change");
                break;
            }
            // Esc while a take develops stops it (the frames so far are kept).
            if (k == SDLK_ESCAPE && movie && mode == Mode::Camera) {
                movie->cancelled = true;
                say("STOPPING THE TAKE");
                break;
            }
            if (k == SDLK_ESCAPE) {
                if (mouseCaptured) { SDL_SetWindowRelativeMouseMode(window, false); mouseCaptured = false; }
                press(flying ? "menu" : "b");
            }
            if (k == SDLK_L && flying) { press("r3"); break; }
            if (mode == Mode::Lighting) {
                // GamepadInput.swift's lighting keys.
                static const std::map<SDL_Keycode, std::string> lk = {
                    {SDLK_F, "x"}, {SDLK_T, "y"}, {SDLK_BACKSPACE, "removeLight"}, {SDLK_DELETE, "removeLight"}, {SDLK_G, "l3"},
                    {SDLK_C, "gels"}, {SDLK_M, "modifiers"}, {SDLK_K, "patternFocus"}, {SDLK_P, "flare"},
                    {SDLK_LEFTBRACKET, "left"}, {SDLK_RIGHTBRACKET, "right"}, {SDLK_EQUALS, "up"}, {SDLK_MINUS, "down"},
                    {SDLK_TAB, "view"}};
                auto it = lk.find(k);
                if (it != lk.end()) press(it->second);
                if (k >= SDLK_0 && k <= SDLK_9) press(std::string(1, char('0' + (k - SDLK_0))));
                if (k == SDLK_GRAVE) press("0");
                if (k == SDLK_COMMA) press("slower");
                if (k == SDLK_PERIOD) press("faster");
                break;
            }
            bool menuLike = mode != Mode::Camera;
            if (k == SDLK_RETURN || k == SDLK_KP_ENTER) press("a");
            if (menuLike) {
                // On the print wall WASD walk (each frame, in update); the arrows step.
                bool walk = mode == Mode::Wall;
                if (k == SDLK_UP || (k == SDLK_W && !walk)) press("up");
                if (k == SDLK_DOWN || (k == SDLK_S && !walk)) press("down");
                if (k == SDLK_LEFT || (k == SDLK_A && !walk)) press("left");
                if (k == SDLK_RIGHT || (k == SDLK_D && !walk)) press("right");
                if ((mode == Mode::Sheet || mode == Mode::Wall) && (k == SDLK_X || k == SDLK_G)) press("x");
                if (mode == Mode::Sheet && k == SDLK_P) press("y");
                if (mode == Mode::Wall && k == SDLK_Q) press("l1");
                if (mode == Mode::Wall && k == SDLK_E) press("r1");
                if (k == SDLK_SPACE) press("a");
                if (mode == Mode::Sheet && k == SDLK_Q) press("l1");
                if (mode == Mode::Sheet && k == SDLK_E) press("r1");
                if (mode == Mode::Sheet && k == SDLK_R) press("y");
                if (mode == Mode::Sheet && k == SDLK_Y) press("y");
                if (k == SDLK_TAB && mode == Mode::Sheet) press("view");
                break;
            }
            if (k == SDLK_LEFTBRACKET) press("left");
            if (k == SDLK_RIGHTBRACKET) press("right");
            if (k == SDLK_EQUALS) press("up");
            if (k == SDLK_MINUS) press("down");
            if (k == SDLK_B) press("x");
            if (k == SDLK_V) openBag(true);
            if (k == SDLK_R) press("y");
            if (k == SDLK_TAB) press("view");
            if (k == SDLK_H) press("menu");
            if (k == SDLK_U) cycleUp();
            if (k >= SDLK_1 && k <= SDLK_9) mountFromCollection(int(k - SDLK_0));
            if (body.model().isMotion()) {
                // GamepadInput.swift's timeline keys.
                bool shift = (e.key.mod & SDL_KMOD_SHIFT) != 0;
                if (k == SDLK_K) motionKey("setKey", shift);
                if (k == SDLK_I) motionKey("prevKey", shift);
                if (k == SDLK_O) motionKey("nextKey", shift);
                if (k == SDLK_Z) motionKey("stepBack", shift);
                if (k == SDLK_X) motionKey("stepForward", shift);
                if (k == SDLK_P) motionKey("roll", shift);
                if (k == SDLK_G) motionKey("develop", shift);
            }
            if (k == SDLK_COMMA) press("slower");
            if (k == SDLK_PERIOD) press("faster");
            break;
        }
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            if (mode == Mode::Camera || mode == Mode::Lighting) {
                if (!mouseCaptured) { SDL_SetWindowRelativeMouseMode(window, true); mouseCaptured = true; }
                else if (e.button.button == SDL_BUTTON_LEFT && mode == Mode::Camera) press("a");
                else if (e.button.button == SDL_BUTTON_RIGHT && mode == Mode::Camera && measure != Measure::None) measureBack();
            } else if (mode == Mode::Sheet && e.button.button == SDL_BUTTON_LEFT) {
                loupe = toCanvas(e.button.x, e.button.y);
            } else if (e.button.button == SDL_BUTTON_LEFT) {
                menuClick(toCanvas(e.button.x, e.button.y));
            } else if (e.button.button == SDL_BUTTON_RIGHT && (mode == Mode::Menu || mode == Mode::List || mode == Mode::Bag || mode == Mode::Film)) {
                press("b");
            }
            break;
        case SDL_EVENT_MOUSE_MOTION:
            if (mode == Mode::Camera && mouseCaptured) camera.turn({e.motion.xrel, -e.motion.yrel});
            if (mode == Mode::Lighting && mouseCaptured) (pov >= 0 ? lightCam : camera).turn({e.motion.xrel, -e.motion.yrel});
            if (mode == Mode::Sheet && (e.motion.state & SDL_BUTTON_LMASK)) loupe = toCanvas(e.motion.x, e.motion.y);
            // The main menu's rows light up under the mouse (MenuOverlay.mouseMoved).
            if (mode == Mode::Menu && !showingHelp)
                if (const Hit* h = hitAt(toCanvas(e.motion.x, e.motion.y)); h && h->kind == HitKind::Item) menuSel = h->index;
            break;
        case SDL_EVENT_MOUSE_WHEEL:
            if (mode == Mode::Camera) body.focusM = std::clamp(body.focusM * std::exp(e.wheel.y * 0.06f), body.lens().minFocusM, 200.f);
            if (mode == Mode::Sheet) loupePower = std::clamp(loupePower * std::exp(e.wheel.y * 0.1f), 2.f, 10.f);
            if (mode == Mode::Wall) wallWheel(e.wheel.y, toCanvas(e.wheel.mouse_x, e.wheel.mouse_y));
            if (mode == Mode::Lighting && pov >= 0 && pov < int(lighting.lights.size())) {
                // The wheel: spot / flood.
                auto& l = lighting.lights[pov];
                l.spot = std::clamp(l.spot + e.wheel.y * 0.05f, 0.f, 1.f);
                char b[48]; snprintf(b, sizeof b, "%s %.0f°", l.spot > 0.5f ? "SPOT" : "FLOOD", l.beamAngle()); say(b);
            }
            break;
        default: break;
        }
        // The menus want the mouse free, to point with.
        bool pointing = mode == Mode::Menu || mode == Mode::List || mode == Mode::Bag || mode == Mode::Film || mode == Mode::Sheet || mode == Mode::Wall;
        if (pointing && mouseCaptured) { SDL_SetWindowRelativeMouseMode(window, false); mouseCaptured = false; }
    }
    /// A click on a menu (MenuOverlay.mouseDown): a row of the main menu chooses it; in the
    /// lists, the bag and the film, a click picks a row and a second click on it takes it.
    void menuClick(V2 p) {
        if (mode == Mode::Menu && showingHelp) { showingHelp = false; return; }
        const Hit* h = hitAt(p);
        if (!h) return;
        switch (h->kind) {
        case HitKind::Item:
            if (mode == Mode::Menu) { menuSel = h->index; chooseMenu(); }
            break;
        case HitKind::ListRow:
            if (mode != Mode::List) break;
            if (h->index == listChoice) press("a"); else listChoice = h->index;
            break;
        case HitKind::Shelf:
            if (mode != Mode::Bag) break;
            shelf = h->index;
            lensSel = shelf == int(lensShelves().size()) ? body.filterIndex : 0;
            break;
        case HitKind::BagRow:
            if (mode != Mode::Bag) break;
            if (h->index == lensSel) press("a"); else lensSel = h->index;
            break;
        case HitKind::FilmRow:
            if (mode != Mode::Film) break;
            if (h->index == filmSel) press("a"); else filmSel = h->index;
            break;
        case HitKind::Rating:
            if (mode == Mode::Film) press(p.x < (h->x0 + h->x1) / 2 ? "left" : "right");
            break;
        }
    }
    /// A window position (mouse) on the drawable the page is laid out on.
    V2 toCanvas(float x, float y) const { float cx = x, cy = y; SDL_RenderCoordinatesFromWindow(sdl, x, y, &cx, &cy); return {cx, cy}; }

    /// The lens's movement as the HUD says it (movementLabel in Viewer.swift).
    std::string movementLabel() const {
        char b[96];
        if (body.lens().movement == Movement::Tilt) snprintf(b, sizeof b, "TILT %+.1f° ACROSS  %+.1f° UP", body.tilt.x, body.tilt.y);
        else if (body.lens().movement == Movement::Shift) snprintf(b, sizeof b, "SHIFT %+.1f MM RIGHT  %+.1f MM UP", body.shift.x, body.shift.y);
        else return "";
        return b;
    }
    /// What the HUD says on mounting a lens (mount in Viewer.swift).
    std::string mountedLabel() const {
        std::string n = body.lens().name;
        for (auto& c : n) c = char(std::toupper((unsigned char)c));
        if (body.lens().movement == Movement::Tilt) return n + " · TILT: HOLD Y + RIGHT STICK (M + ARROWS)";
        if (body.lens().movement == Movement::Shift) return n + " · SHIFT: HOLD Y + RIGHT STICK (M + ARROWS)";
        return n;
    }
    bool padYDown = false, padYMoved = false;

    // ---- lighting mode (lightingInput, fly in Viewer.swift) ----
    // Choose a light and you see from it, down its beam, and the same controls
    // fly and aim it. The camera waits where you left it.
    Mode playMode = Mode::Camera;      // camera or lighting: where the menu returns to
    int pov = -1;                      // the light being flown (-1: looking through the camera)
    FlyCamera lightCam;
    bool newLightsFlare = false;
    // A simple chooser page (the gel book, the modifiers): a title, a line, rows.
    std::string listTitle, listAbout;
    std::vector<std::pair<std::string, std::string>> listRows;
    int listChoice = 0, listMarked = -1;
    std::function<void(int)> onChooseList;

    int chosenLight() const { return pov >= 0 ? pov : std::min(lighting.selected, int(lighting.lights.size()) - 1); }
    /// Climbs into light `i`: the view from its lens, looking down the beam.
    void fly(int i) {
        if (i < 0 || i >= int(lighting.lights.size())) return;
        const PlacedLight& l = lighting.lights[i];
        lighting.selected = i;
        pov = i;
        lightCam = FlyCamera();
        lightCam.up = camera.up;
        lightCam.focalMM = 28;
        lightCam.lookAt(l.position + l.aim, l.position);
    }
    void toggleLighting() {
        pov = -1;
        playMode = mode = (mode == Mode::Lighting ? Mode::Camera : Mode::Lighting);
        say(mode == Mode::Lighting ? "LIGHTING: F ADDS A LIGHT, 1-9 FLIES ONE, L BACK TO THE CAMERA" : "CAMERA");
    }
    void openList(const std::string& title, const std::string& about, std::vector<std::pair<std::string, std::string>> rows, int marked,
                  std::function<void(int)> choose) {
        listTitle = title; listAbout = about; listRows = std::move(rows);
        listMarked = marked; listChoice = std::max(0, marked); onChooseList = std::move(choose);
        mode = Mode::List;
    }
    /// The gel book, for the light being flown (or the one chosen): C in lighting, or the menu.
    void openGels() {
        if (lighting.lights.empty()) { say("ADD A LIGHT FIRST (LIGHTING MODE)"); return; }
        int k = chosenLight();
        std::vector<std::pair<std::string, std::string>> rows;
        for (auto& g : gels()) {
            float stops = -std::log2(std::max(g.transmission.x * 0.2126f + g.transmission.y * 0.7152f + g.transmission.z * 0.0722f, 1e-4f));
            char b[32]; snprintf(b, sizeof b, " · %.1f stops", stops);
            rows.push_back({g.name, g.about + (stops < 0.05f ? "" : b)});
        }
        openList("GELS · LIGHT " + std::to_string(k + 1), lighting.lights[k].kit().name + ": a sheet of colour in front of the lens",
                 rows, lighting.lights[k].gel, [this, k](int g) {
                     if (k >= int(lighting.lights.size())) return;
                     lighting.lights[k].gel = g;
                     say(g == 0 ? "GEL OFF" : upper(gels()[g].name));
                     mode = playMode;
                 });
    }
    void openModifiers() {
        if (lighting.lights.empty()) { say("ADD A LIGHT FIRST (LIGHTING MODE)"); return; }
        int k = chosenLight();
        const PlacedLight& light = lighting.lights[k];
        std::vector<int> choices;
        for (int i = 0; i < int(lightModifiers().size()); i++) if (light.fits(lightModifiers()[i])) choices.push_back(i);
        std::vector<std::pair<std::string, std::string>> rows;
        int marked = 0;
        for (size_t i = 0; i < choices.size(); i++) {
            rows.push_back({lightModifiers()[choices[i]].name, lightModifiers()[choices[i]].about});
            if (choices[i] == light.modifier) marked = int(i);
        }
        bool ell = light.kit().kind == LightHead::Kind::Ellipsoidal;
        openList("MODIFIERS · LIGHT " + std::to_string(k + 1),
                 light.kit().name + (ell ? ": a metal gobo in the gate (K: focus, sharp to soft)"
                                         : ": barn doors, flags and cookies (K: how far the cookie stands from the lamp)"),
                 rows, marked, [this, k, choices](int row) {
                     if (k >= int(lighting.lights.size())) return;
                     int m = choices[row];
                     lighting.lights[k].modifier = m;
                     say(m == 0 ? "OPEN BEAM" : upper(lightModifiers()[m].name));
                     mode = playMode;
                 });
    }
    static std::string upper(std::string s) { for (auto& c : s) c = char(std::toupper((unsigned char)c)); return s; }

    /// Lighting's presses (lightingInput in Viewer.swift).
    void lightingPress(const std::string& what) {
        if (what == "gels") { openGels(); return; }
        if (what == "modifiers") { openModifiers(); return; }
        int n = int(lighting.lights.size());
        if ((what == "flare" || what == "view") && n) {
            int k = chosenLight();
            lighting.lights[k].flare = lighting.lights[k].flareOn() ? 0 : 1;
            say("LENS FLARE FROM LIGHT " + std::to_string(k + 1) + ": " + (lighting.lights[k].flareOn() ? "ON" : "OFF"));
        }
        if (what == "patternFocus" && n) {
            int k = chosenLight();
            static const float steps[] = {0, 0.25f, 0.5f, 1};
            float now = lighting.lights[k].patternFocus, next = steps[0];
            for (float s : steps) if (s > now + 0.01f) { next = s; break; }
            lighting.lights[k].patternFocus = next;
            bool gobo = lighting.lights[k].kit().kind == LightHead::Kind::Ellipsoidal;
            say(gobo ? std::string("GOBO FOCUS: ") + (next == 0 ? "SHARP" : next < 0.5f ? "A TOUCH SOFT" : next < 1 ? "SOFT" : "VERY SOFT")
                     : std::string("COOKIE: ") + (next == 0 ? "CLOSE TO THE LAMP (SOFT)" : next < 1 ? "FURTHER OUT" : "FAR OUT (CRISP)"));
        }
        if (what == "x" && n < Renderer::maxLights) {
            // A new head where you are looking from, aimed the same way.
            const FlyCamera& from = pov >= 0 ? lightCam : camera;
            PlacedLight l;
            l.head = lighting.kitChoice;
            l.position = from.position;
            l.aim = from.forward();
            l.flare = newLightsFlare ? 1 : 0;
            lighting.lights.push_back(l);
            fly(int(lighting.lights.size()) - 1);
            say("LIGHT " + std::to_string(lighting.lights.size()) + ": " + upper(l.kit().name));
        }
        if (what.size() == 1 && what[0] >= '0' && what[0] <= '9') {
            int d = what[0] - '0';
            if (d == 0) pov = -1; else if (d <= n) fly(d - 1);
        }
        n = int(lighting.lights.size());
        if (n > 0) {
            if (what == "left") fly(((pov >= 0 ? pov : lighting.selected) + n - 1) % n);
            if (what == "right") fly(((pov >= 0 ? pov : lighting.selected) + 1) % n);
        }
        if (what == "b") pov = -1;
        if (what == "y") {
            lighting.kitChoice = (lighting.kitChoice + 1) % int(lightKit().size());
            if (pov >= 0) {
                auto& l = lighting.lights[pov];
                l.head = lighting.kitChoice;
                if (!l.fits(lightModifiers()[l.modifier])) l.modifier = 0;
            }
            say(upper(lightKit()[lighting.kitChoice].name));
        }
        if (pov >= 0 && pov < n) {
            if (what == "removeLight") {
                lighting.lights.erase(lighting.lights.begin() + pov);
                lighting.selected = std::max(0, pov - 1);
                pov = -1;
                say("LIGHT REMOVED");
            } else {
                auto& l = lighting.lights[pov];
                if (what == "up") l.dimmerStops = std::min(0.f, l.dimmerStops + 0.5f);
                if (what == "down") l.dimmerStops = std::max(-4.f, l.dimmerStops - 0.5f);
                if (what == "up" || what == "down") { char b[48]; snprintf(b, sizeof b, "DIMMER %+.1f STOPS", l.dimmerStops); say(b); }
            }
        }
        if (what == "l3") { lighting.cycleHouseLights(); say("HOUSE LIGHTS: " + upper(lighting.ambientName)); }
        if (what == "r3") toggleLighting();
        if (what == "menu") openMenu();
        if (what == "slower") changeGait(-1);
        if (what == "faster") changeGait(1);
    }
    /// Lighting, each frame: the controls fly whichever you look through, the
    /// light being flown or the camera; the triggers spot and flood the light.
    void updateLighting(float dt) {
        const bool* k = SDL_GetKeyboardState(nullptr);
        V2 move{axis(SDL_GAMEPAD_AXIS_LEFTX) + (k[SDL_SCANCODE_D] - k[SDL_SCANCODE_A]),
                -axis(SDL_GAMEPAD_AXIS_LEFTY) + (k[SDL_SCANCODE_W] - k[SDL_SCANCODE_S])};
        V2 look{axis(SDL_GAMEPAD_AXIS_RIGHTX) + 0.6f * (k[SDL_SCANCODE_RIGHT] - k[SDL_SCANCODE_LEFT]),
                -axis(SDL_GAMEPAD_AXIS_RIGHTY) + 0.6f * (k[SDL_SCANCODE_UP] - k[SDL_SCANCODE_DOWN])};
        float rise = float(button(SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER)) - float(button(SDL_GAMEPAD_BUTTON_LEFT_SHOULDER)) +
                     (k[SDL_SCANCODE_SPACE] + k[SDL_SCANCODE_E]) - (k[SDL_SCANCODE_LCTRL] + k[SDL_SCANCODE_Q]);
        move.x = std::clamp(move.x, -1.f, 1.f); move.y = std::clamp(move.y, -1.f, 1.f);
        bool run = k[SDL_SCANCODE_LSHIFT] || k[SDL_SCANCODE_RSHIFT];
        float speed = gaits()[gait].metres / body.metresPerUnit * (run ? 3 : 1);
        lighting.up = camera.up;
        if (pov >= 0 && pov < int(lighting.lights.size())) {
            lightCam.moveSpeed = speed;
            lightCam.update(move, look, rise, dt);
            auto& l = lighting.lights[pov];
            l.position = lightCam.position;
            l.aim = lightCam.forward();
            if (pad) {
                float r = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) / 32767.f, lt = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) / 32767.f;
                float trig = r * r - lt * lt;
                if (trig != 0) l.spot = std::clamp(l.spot + trig * dt * 0.8f, 0.f, 1.f);
            }
        } else {
            pov = -1;
            camera.moveSpeed = speed;
            camera.update(move, look, rise, dt);
        }
        camera.focalMM = body.lens().focalMM;
        body.dofPreview = false;
    }
    /// What the caption says in lighting (Viewer's mode name and the light in hand).
    std::string lightingCaption() const {
        std::string s = pov >= 0 ? "lighting · flying light " + std::to_string(pov + 1) : "lighting";
        if (pov >= 0 && pov < int(lighting.lights.size())) {
            const auto& l = lighting.lights[pov];
            char b[200];
            snprintf(b, sizeof b, "  ·  %s, %s %.0f°, %+.1f stops%s%s", l.kit().name.c_str(), l.spot > 0.5f ? "spot" : "flood", l.beamAngle(),
                     l.dimmerStops, l.gel ? (", " + gels()[l.gel].name).c_str() : "", l.modifier ? (", " + lightModifiers()[l.modifier].name).c_str() : "");
            s += b;
        }
        s += "  ·  house lights: " + lighting.ambientName;
        return s;
    }

    void update(float dt) {
        V3 was = camera.position;
        if (mode == Mode::Camera && measure == Measure::Entry && pad) {
            float trig = (SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) - SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER)) / 32767.f;
            if (trig != 0) { entryValue *= std::exp(trig * dt * 0.8f); entryText.clear(); }
        }
        if (mode == Mode::Camera && measure != Measure::Entry) {
            const bool* k = SDL_GetKeyboardState(nullptr);
            V2 move{axis(SDL_GAMEPAD_AXIS_LEFTX) + (k[SDL_SCANCODE_D] - k[SDL_SCANCODE_A]),
                    -axis(SDL_GAMEPAD_AXIS_LEFTY) + (k[SDL_SCANCODE_W] - k[SDL_SCANCODE_S])};
            V2 stick{axis(SDL_GAMEPAD_AXIS_RIGHTX), -axis(SDL_GAMEPAD_AXIS_RIGHTY)};
            V2 arrows{float(k[SDL_SCANCODE_RIGHT] - k[SDL_SCANCODE_LEFT]), float(k[SDL_SCANCODE_UP] - k[SDL_SCANCODE_DOWN])};
            // M + arrows, or Y + right stick: tilt or shift the lens (GamepadInput.swift).
            V2 movement{};
            if (padYDown) { movement = stick; if (len(stick) > 0) padYMoved = true; stick = {}; }
            if (k[SDL_SCANCODE_M]) { movement = movement + arrows; arrows = {}; }
            movement.x = std::clamp(movement.x, -1.f, 1.f); movement.y = std::clamp(movement.y, -1.f, 1.f);
            if (movement.x != 0 || movement.y != 0) say(body.move(movement * dt) ? movementLabel() : "THIS LENS DOES NOT TILT OR SHIFT");
            if (k[SDL_SCANCODE_N] && (body.tilt.x != 0 || body.tilt.y != 0 || body.shift.x != 0 || body.shift.y != 0)) {
                body.tilt = {}; body.shift = {};
                say(movementLabel());
            }
            V2 look{stick.x + 0.6f * arrows.x, stick.y + 0.6f * arrows.y};
            float rise = float(button(SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER)) - float(button(SDL_GAMEPAD_BUTTON_LEFT_SHOULDER)) +
                         (k[SDL_SCANCODE_SPACE] + k[SDL_SCANCODE_E]) - (k[SDL_SCANCODE_LCTRL] + k[SDL_SCANCODE_Q]);
            move.x = std::clamp(move.x, -1.f, 1.f); move.y = std::clamp(move.y, -1.f, 1.f);
            bool run = k[SDL_SCANCODE_LSHIFT] || k[SDL_SCANCODE_RSHIFT];
            camera.moveSpeed = gaits()[gait].metres / body.metresPerUnit * (run ? 3 : 1);
            camera.update(move, look, rise, dt);
            camera.focalMM = body.lens().focalMM;
            float trig = 0;
            if (pad) {
                float r = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) / 32767.f, l = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) / 32767.f;
                trig = r * r - l * l;
            }
            // F held focuses farther, C nearer (GamepadInput's focusKeys).
            float focusKeys = float(k[SDL_SCANCODE_F]) - float(k[SDL_SCANCODE_C]);
            body.turnFocus(trig + focusKeys * 0.6f, dt);
            body.dofPreview = button(SDL_GAMEPAD_BUTTON_EAST) || (SDL_GetMouseState(nullptr, nullptr) & SDL_BUTTON_RMASK);
        }
        if (mode == Mode::Lighting) updateLighting(dt);
        // The scene's bounds: a move that would leave them slides along the edge.
        if (!bounds.volumes.empty() && (mode == Mode::Camera || (mode == Mode::Lighting && pov < 0)))
            camera.position = bounds.confine(was, camera.position);
        // The ears go with the camera; quiet in the background and while a take develops.
        if (soundscape) {
            bool heard = window && (SDL_GetWindowFlags(window) & SDL_WINDOW_INPUT_FOCUS) && !movie && sceneSoundOn();
            soundscape->update(camera.position, camera.right(), body.metresPerUnit, heard ? sceneSoundLevel() : 0.f);
        }
        if (mode == Mode::Wall) {
            // The sticks and WASD walk along the wall, the triggers and Space / Ctrl step in and out.
            const bool* k = SDL_GetKeyboardState(nullptr);
            V2 mv{axis(SDL_GAMEPAD_AXIS_LEFTX) + axis(SDL_GAMEPAD_AXIS_RIGHTX) + float(k[SDL_SCANCODE_D] - k[SDL_SCANCODE_A]),
                  axis(SDL_GAMEPAD_AXIS_LEFTY) + axis(SDL_GAMEPAD_AXIS_RIGHTY) + float(k[SDL_SCANCODE_S] - k[SDL_SCANCODE_W])};
            float z = float(k[SDL_SCANCODE_SPACE]) - float(k[SDL_SCANCODE_LCTRL]);
            if (pad) z += (SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) - SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER)) / 32767.f;
            wallUpdate(mv, z, dt);
        }
        if (mode == Mode::Sheet && pad) {
            V2 v{axis(SDL_GAMEPAD_AXIS_LEFTX) + axis(SDL_GAMEPAD_AXIS_RIGHTX), axis(SDL_GAMEPAD_AXIS_LEFTY) + axis(SDL_GAMEPAD_AXIS_RIGHTY)};
            if (len(v) > 0.01f) {
                if (loupe.x < 0) loupe = {cv.w / 2.f, cv.h / 2.f};
                loupe = loupe + v * (cv.h * 0.9f * dt);
            }
            float trig = (SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) - SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER)) / 32767.f;
            loupePower = std::clamp(loupePower * std::exp(trig * dt), 2.f, 10.f);
        }
        if (mode == Mode::Camera && body.model().isMotion()) {
            // No prism on the ground glass: the distance, as the focus puller calls it.
            if (body.focusM != focusSeen && focusSeen > 0) {
                char b[32]; snprintf(b, sizeof b, "FOCUS %.2f M", body.focusM);
                say(body.focusM >= 100 ? "FOCUS ∞" : b);
                // Turning the ring while rolling: you pull focus for the rest of the roll.
                if (rolling) pullingFocus = true;
            }
            advanceRoll();
            focusSeen = body.focusM;
        } else if (mode != Mode::Menu) {
            rolling = false;
        }
        feedMovie();
        feedEnlarger();
        double now = SDL_GetTicks() / 1000.0;
        if (advanceAt > 0 && now > advanceAt) { playFelt("film-advance"); advanceAt = 0; }
        sounds.tidy();
    }

    /// The meter: the finder frame's light, centre-weighted, as the scene sends it.
    void meter(const Frame& f, const FinderJob& j) {
        Optics o = finderOptics(j);
        double sum = 0, wsum = 0;
        for (int gy = 0; gy < 24; gy++)
            for (int gx = 0; gx < 36; gx++) {
                int x = (gx * f.w) / 36 + f.w / 72, y = (gy * f.h) / 24 + f.h / 48;
                V3 c = toLin(frameRGB(f, x, y, o));
                float dx = (gx + 0.5f) / 36 - 0.5f, dy = (gy + 0.5f) / 24 - 0.5f;
                float w = std::exp(-(dx * dx + dy * dy) * 6);
                sum += w * (0.2126f * c.x + 0.7152f * c.y + 0.0722f * c.z); wsum += w;
            }
        float lum = float(sum / std::max(wsum, 1e-9));
        meterLum += (lum - meterLum) * 0.3f;
        if (body.autoOn()) body.meterAperture(meterLum);
    }

    void frame() {
        Uint64 t = SDL_GetTicks();
        float dt = lastTicks ? std::min(0.1f, (t - lastTicks) / 1000.f) : 1 / 30.f;
        lastTicks = t;
        update(dt);
        // The window shows a fixed drawable the finder's size (as the Mac's
        // drawableSize), letterboxed: the finder, the HUD and the pages lay out on it.
        if (cv.w != finderW || cv.h != finderH) {
            cv.resize(finderW, finderH);
            if (tex) SDL_DestroyTexture(tex);
            tex = SDL_CreateTexture(sdl, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, finderW, finderH);
            SDL_SetRenderLogicalPresentation(sdl, finderW, finderH, SDL_LOGICAL_PRESENTATION_LETTERBOX);
        }
        if (!pendingSky.empty()) { setSky(SkySetting{pendingSky}); pendingSky.clear(); say("SKY: " + upper(sky.name())); }
        if (scan.count && mode != Mode::Sheet && mode != Mode::Wall) renderer.ask(finderJob());
        std::shared_ptr<Frame> f;
        std::shared_ptr<FinderJob> j;
        int slot;
        { std::lock_guard<std::mutex> l(renderer.m); f = renderer.latest; j = renderer.latestJob; slot = renderer.latestSlot; }
        if (mode == Mode::Sheet) {
            drawSheet();
        } else if (mode == Mode::Wall) {
            drawWall();
        } else if (f && j) {
            bool mirrorUp = SDL_GetTicks() / 1000.0 < mirrorUpUntil;
            updateCrosshair(*f, *j);
            bool onGpu = Renderer::gpu && slot >= 0 && drawFinderGPU(slot, *j, mirrorUp, dt);
            if (!onGpu) meter(*f, *j);
            // A new scene: set the shutter from the first few metered frames.
            if (meterSettle > 0 && --meterSettle == 0) body.meterShutter(meterLum);
            if (!onGpu) drawFinder(*f, *j, mirrorUp);
            if (!mirrorUp) drawWireframes(*f, *j);
            drawMonitor();
            if (mode == Mode::Menu) drawMenu();
            if (mode == Mode::List) drawList();
            if (mode == Mode::Bag) drawBag();
            if (mode == Mode::Film) drawFilm();
        } else {
            std::fill(cv.px.begin(), cv.px.end(), 0xff060606u);
            std::string msg = scan.count ? "Loading the scan..." : "Open a .ply scan or a .vcscene: drop it on this window, or press O";
            float w = font.width(msg, 22);
            font.draw(cv, msg, cv.w / 2 - w / 2, cv.h / 2 - 12, 22, {1.0f, 0.90f, 0.74f, 0.95f}, 0.4f);
            if (mode == Mode::Menu) drawMenu();
        }
        SDL_UpdateTexture(tex, nullptr, cv.px.data(), cv.w * 4);
        SDL_SetRenderDrawColor(sdl, 0, 0, 0, 255);
        SDL_RenderClear(sdl);
        SDL_RenderTexture(sdl, tex, nullptr, nullptr);
        SDL_RenderPresent(sdl);
    }
};

#if defined(_WIN32)
extern "C" __declspec(dllimport) void* __stdcall GetCurrentProcess(void);
extern "C" __declspec(dllimport) int __stdcall TerminateProcess(void*, unsigned);
#endif

// End the process once everything is saved and shut down. On Windows the
// renderer library keeps its Vulkan device in a static; destroying it as the
// library unloads (at exit, or on FreeLibrary) runs under the loader lock,
// possibly after the graphics driver has gone, and crashes or deadlocks. So skip
// library teardown there and let Windows reclaim the process.
static int endProcess(int rc) {
#if defined(_WIN32)
    fflush(nullptr);
    TerminateProcess(GetCurrentProcess(), unsigned(rc));
#endif
    return rc;
}

// The GPU kernels (Shaders.swift's, on Vulkan through SDL_GPU). Without them
// the CPU path develops instead; VC_CPU=1 forces it, for comparing the two.
static Gpu g_gpu;
static void startGpu() {
    if (SDL_getenv("VC_CPU")) return;
    if (!g_gpu.init() || !Renderer::kernels.make(g_gpu)) {
        fprintf(stderr, "GPU kernels unavailable (%s): developing on the CPU\n", g_gpu.error.c_str());
        return;
    }
    Renderer::gpu = &g_gpu;
}

// Headless: open a scan, shoot one frame, write it and quit (for tests and CI).
static int shootHeadless(App& app) {
    if (!app.open(option("--scan"))) { fprintf(stderr, "%s\n", app.flash.c_str()); return 1; }
    if (!option("--focus").empty()) app.body.focusM = std::stof(option("--focus"));
    app.applyTestLighting();
    app.renderer.start();
    // Meter from a finder frame, as the camera would.
    app.renderer.ask(app.finderJob());
    for (int i = 0; i < 600; i++) {
        std::shared_ptr<Frame> f; std::shared_ptr<FinderJob> j;
        { std::lock_guard<std::mutex> l(app.renderer.m); f = app.renderer.latest; j = app.renderer.latestJob; }
        if (f && j) { for (int k = 0; k < 20; k++) app.meter(*f, *j); break; }
        if (!app.renderer.error.empty()) break;
        SDL_Delay(50);
    }
    app.body.meterShutter(app.meterLum);
    app.release();
    while (app.renderer.developedCount < 1) {
        if (!app.renderer.error.empty()) { fprintf(stderr, "render error: %s\n", app.renderer.error.c_str()); app.renderer.stop(); return 1; }
        SDL_Delay(50);
    }
    app.renderer.stop();
    printf("Saved %s (%s, f/%.1f, 1/%s, meter %.3f)\n", option("--shoot").c_str(), app.body.lens().name.c_str(),
           app.body.takingAperture(), app.body.shutter().label, app.meterLum);
    return 0;
}

int main(int argc, char** argv) {
    for (int i = 1; i < argc; i++) g_args.push_back(argv[i]);
    std::string scanArg;
    for (size_t i = 0; i < g_args.size(); i++) {
        if (g_args[i].rfind("--", 0) == 0) { if (i + 1 < g_args.size() && g_args[i + 1].rfind("--", 0) != 0 && g_args[i] != "--inside" && g_args[i] != "--object") i++; continue; }
        if (scanArg.empty()) scanArg = g_args[i];
    }
    if (!scanArg.empty()) { g_args.push_back("--scan"); g_args.push_back(scanArg); }
    g_prefs.load();
    App app;
    if (!option("--res").empty()) sscanf(option("--res").c_str(), "%dx%d", &app.finderW, &app.finderH);
    // Saved settings for play; a scripted --shoot stays at the defaults, so tests repeat.
    bool play = option("--shoot").empty();
    int photoScale = play ? std::clamp(g_prefs.getInt("photoScale", 2), 2, 4) : 2;
    app.photoW = app.finderW * photoScale; app.photoH = app.finderH * photoScale;
    if (play) {
        app.cells = std::clamp(g_prefs.getInt("cells", 32), 32, 128);
        app.sounds.enabled = g_prefs.getBool("sounds", true);
    }
    if (!option("--cells").empty()) app.cells = std::stoi(option("--cells"));
    if (!option("--lens").empty()) app.body.chooseLens(std::stoi(option("--lens")));
    if (!option("--film").empty()) app.body.stockIndex = std::stoi(option("--film")) % int(filmStocks().size());
    if (!option("--aperture").empty()) {
        auto s = app.body.lens().apertureStops();
        float n = std::stof(option("--aperture"));
        for (int i = 0; i < int(s.size()); i++) if (std::fabs(s[i] - n) < std::fabs(s[app.body.apertureIndex] - n)) app.body.apertureIndex = i;
    }
    // --tilt X,Y (degrees) / --shift X,Y (mm, right and up): lens movements, for tests (main.swift).
    // --body S2|EF|R5 (or a make): another camera body, for tests.
    if (!option("--body").empty()) {
        std::string b = option("--body");
        for (int i = 0; i < int(CameraModel::every().size()); i++) {
            const CameraModel& m = CameraModel::every()[i];
            std::string lm = m.model, lk = m.make, lb = b;
            for (auto* str : {&lm, &lk, &lb}) for (auto& ch : *str) ch = char(std::tolower((unsigned char)ch));
            if (lm == lb || lk.rfind(lb, 0) == 0) { app.body.chooseBody(i); break; }
        }
    }
    if (!option("--filter").empty()) app.body.filterIndex = std::clamp(std::stoi(option("--filter")), 0, int(lensFilters().size()) - 1);
    if (!option("--tilt").empty()) sscanf(option("--tilt").c_str(), "%f,%f", &app.body.tilt.x, &app.body.tilt.y);
    if (!option("--shift").empty()) sscanf(option("--shift").c_str(), "%f,%f", &app.body.shift.x, &app.body.shift.y);
    CameraBody::finderThinning = g_prefs.getBool("fastFocus", false) ? 0.1f : 0.05f;
    if (!option("--shoot").empty()) {
        // No window, but SDL_GPU needs the video subsystem: the off-screen driver.
        SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "offscreen");
        if (!SDL_Init(SDL_INIT_VIDEO) && !SDL_Init(0)) return 1;
        std::string why = sr::load(basePath());
        if (!why.empty()) { fprintf(stderr, "%s\n", why.c_str()); return 1; }
        startGpu();
        int rc = shootHeadless(app);
        sr::shutdown();
        SDL_Quit();
        return endProcess(rc);
    }

    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD | SDL_INIT_AUDIO)) { fprintf(stderr, "SDL: %s\n", SDL_GetError()); return 1; }
    // The window: the drawable's shape, at most 90% of the screen (main.swift).
    float fit = 1;
    SDL_Rect usable;
    if (SDL_GetDisplayUsableBounds(SDL_GetPrimaryDisplay(), &usable))
        fit = std::min(1.f, std::min(usable.w * 0.9f / app.finderW, usable.h * 0.9f / app.finderH));
    app.window = SDL_CreateWindow("Vintage Click", int(app.finderW * fit), int(app.finderH * fit),
                                  SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (app.window) SDL_SetWindowAspectRatio(app.window, float(app.finderW) / app.finderH, float(app.finderW) / app.finderH);
    app.sdl = SDL_CreateRenderer(app.window, nullptr);
    if (!app.window || !app.sdl) { fprintf(stderr, "SDL: %s\n", SDL_GetError()); return 1; }
    fs::path assets = fs::u8path(basePath()) / "assets";
    if (!app.font.load((assets / "Jost-Medium.ttf").u8string())) fprintf(stderr, "font not found in %s\n", assets.string().c_str());
    app.sounds.load(assets / "Sounds");
    std::string why = sr::load(basePath());
    if (!why.empty()) {
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Vintage Click",
            (why + "\n\nVintage Click needs a graphics card with a Vulkan 1.3 driver (most from 2016 on: update the driver from NVIDIA, AMD or Intel).").c_str(), app.window);
        return 1;
    }
    startGpu();
    app.renderer.start();
    if (!option("--scan").empty()) app.open(option("--scan"));
    if (!option("--focus").empty()) app.body.focusM = std::stof(option("--focus"));
    if (app.scan.count) app.applyTestLighting();
    // --take-demo S: a demo take on the movie camera; --develop preview|final sends it to the darkroom.
    if (app.scan.count && !option("--take-demo").empty()) app.demoTake(std::stod(option("--take-demo")), option("--develop"));
    // --measure: start setting the scale, for tests.
    if (flag("--measure")) app.startMeasure();
    if (flag("--motion-menu")) { app.body.chooseBody(CameraModel::wilmont); app.go(App::Page::Motion); }
    if (!app.scan.count) app.chooseScene();
    while (!app.quit) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            app.handle(e);
            if (e.type == SDL_EVENT_KEY_DOWN && e.key.key == SDLK_O && app.mode != Mode::Camera) app.chooseScene();
            if (e.type == SDL_EVENT_KEY_DOWN && e.key.key == SDLK_O && !app.scan.count) app.chooseScene();
        }
        if (!app.pendingOpen.empty()) {
            std::string p = app.pendingOpen; app.pendingOpen.clear();
            // The renderer holds one scene: swap it while the render thread is stopped.
            app.renderer.stop();
            app.renderer.quit = false;
            { std::lock_guard<std::mutex> l(app.renderer.m); app.renderer.latest.reset(); app.renderer.latestJob.reset(); }
            app.open(p);
            app.mode = Mode::Camera;
            app.renderer.start();
        }
        app.frame();
    }
    app.renderer.stop();
    sr::shutdown();
    SDL_Quit();
    return endProcess(0);
}
