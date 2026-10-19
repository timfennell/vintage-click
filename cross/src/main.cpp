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
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <ctime>
#include <deque>
#include <filesystem>
#include <memory>
#include <mutex>
#include <sstream>

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBIW_WINDOWS_UTF8
#include "stb_image_write.h"
#define STB_IMAGE_IMPLEMENTATION
#define STBI_WINDOWS_UTF8
#define STBI_ONLY_PNG
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
// Where rolls are kept: <Pictures>/Vintage Click/<day>/<HH.MM scene>/<Roll NN - stock>/frame-NN.png

static fs::path rollsRoot() {
    if (const char* env = SDL_getenv("VINTAGE_CLICK_ROLLS")) return fs::u8path(env);
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

struct FinderJob {
    std::vector<float> view;
    float fx = 1; V2 axis;
    int W = 0, H = 0;
    std::vector<V4> lens;           // empty: pinhole
    bool fisheye = false;
    Optics optics;
};

struct Exposure {
    CameraBody body;
    FlyCamera camera;
    int W = 0, H = 0, tileW = 0, tileH = 0;
    std::vector<V2> cells;
    size_t next = 0;
    std::vector<V4> acc;            // accumulated light and weight per pixel
    int frameNumber = 0;
    fs::path out;
    bool done = false;
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
                setLens(job->lens);
                sr::set_camera_model(job->fisheye ? "FISHEYE" : "PINHOLE");
                auto f = std::make_shared<Frame>();
                bool ok = render(*f, job->view, job->fx, job->axis.x, job->axis.y, job->W, job->H);
                sr::set_camera_model("PINHOLE");
                std::lock_guard<std::mutex> l(m);
                if (ok) { latest = f; latestJob = std::shared_ptr<FinderJob>(std::move(job)); }
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

    /// One sub-pupil: render the view sheared to that lens point (focus plane
    /// fixed), add it to the film; develop after the last.
    static void step(Exposure& e) {
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
        std::vector<float> vm = e.camera.viewMatrix();
        vm[3] -= d.x; vm[7] -= d.y;
        V2 axis{e.W / 2.f, e.H / 2.f};
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
        fs::create_directories(e.out.parent_path());
        stbi_write_png(e.out.u8string().c_str(), W, H, 3, out.data(), W * 3);
        std::ofstream j(fs::path(e.out).replace_extension(".json"));
        j << "{\n  \"lens\": \"" << L.name << "\",\n  \"film\": \"" << b.stock().name << "\",\n  \"aperture\": " << n
          << ",\n  \"shutter\": \"1/" << b.shutter().label << "\",\n  \"iso\": " << b.stock().iso << ",\n  \"rated_ei\": "
          << b.ratedEI() << ",\n  \"push\": " << b.push << ",\n  \"focus_m\": " << b.focusM << ",\n  \"scene_ev\": "
          << b.sceneEV << ",\n  \"exposure_stops\": " << b.exposureStops() << ",\n  \"magnification\": "
          << b.magnification() << ",\n  \"sub_pupils\": " << e.cells.size() << ",\n  \"width\": " << W
          << ",\n  \"height\": " << H << "\n}\n";
        e.acc.clear(); e.acc.shrink_to_fit();
    }
};

// ---------------------------------------------------------------------------
// The game.

enum class Mode { Camera, Menu, Bag, Film, Sheet };

struct Roll { int number; std::string stock, session; fs::path dir; std::vector<fs::path> frames; };

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
    int finderW = 1080, finderH = 720;
    int photoW = 2160, photoH = 1440;
    int cells = 32;
    Mode mode = Mode::Camera;
    int menuSel = 0, shelf = 0, lensSel = 0, filmSel = 0, filmPush = 0;
    float meterLum = 0.18f, finderGain = 1, needle = 7, needleSpeed = 0;
    double mirrorUpUntil = 0;
    std::string flash; double flashUntil = 0;
    std::string session;
    bool mouseCaptured = false;
    float pace = 1.4f;
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
        try {
            scan = loadPLY(path);
        } catch (std::exception& ex) {
            say(std::string("COULD NOT OPEN THE SCAN: ") + ex.what());
            return false;
        }
        scanPath = path;
        sceneName = fs::u8path(path).parent_path().filename().u8string();
        if (sceneName.empty()) sceneName = fs::u8path(path).stem().u8string();
        // A place is dominated by its ground (flat); an object on the rig is a rounder blob.
        float flat = flatness(scan);
        if (flag("--inside")) place = true; else if (flag("--object")) place = false; else place = flat < 0.15f;
        Renderer::sceneIsPlace = place;
        float scale = option("--scale").empty() ? (place ? 15.f : 0.3f) / scan.radius : std::stof(option("--scale"));
        body.metresPerUnit = scale;
        body.sceneEV = option("--ev").empty() ? (place ? 13.f : 12.f) : std::stof(option("--ev"));
        body.calibration = std::clamp(std::log2(0.18f / middleTone(scan)), -4.f, 4.f);
        // The renderer wants some higher SH bands: give a flat-colour scan one
        // band of zeros (the same picture).
        if (scan.shDegree == 0) { scan.shDegree = 1; scan.sh.assign(size_t(scan.count) * 3 * 3, 0.f); }
        int rc = sr::set_splats(scan.count, scan.shDegree, scan.means.data(), scan.quats.data(), scan.scales.data(),
                               scan.opacities.data(), scan.dc.data(), scan.shDegree > 0 ? scan.sh.data() : nullptr);
        if (rc != 0) { say(std::string("THE RENDERER REFUSED THE SCAN: ") + sr::last_error()); return false; }
        pace = place ? 1.4f : 0.08f;
        meterSettle = 12;
        hasSpot = place && findOpenSpot(scan, scale, FlyCamera().up, spot, spotYaw);
        resetView();
        session = stamp("%Y-%m-%d") + "/" + stamp("%H.%M") + " " + sceneName;
        if (window) SDL_SetWindowTitle(window, ("Vintage Click — " + sceneName).c_str());
        return true;
    }
    void resetView() {
        camera = FlyCamera();
        camera.focalMM = body.lens().focalMM;
        if (place) {
            camera.position = scan.center + camera.up * (1.6f / body.metresPerUnit);
            if (hasSpot) { camera.position = spot; camera.yaw = spotYaw; }
            body.focusM = std::max(body.lens().minFocusM, 5.f);
        } else {
            float dist = std::max(scan.radius * 1.2f * camera.focalMM / 36 + scan.radius,
                                  body.lens().minFocusM * 1.15f / body.metresPerUnit);
            FlyCamera c;
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
        j.axis = {finderW / 2.f, finderH / 2.f};
        j.fisheye = body.lens().isFisheye();
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
        double now = SDL_GetTicks() / 1000.0;
        if (now < mirrorUpUntil) return;
        if (body.framesLeft() <= 0) { say("END OF ROLL: LOAD FILM (R)"); return; }
        mirrorUpUntil = now + 0.07 + body.shutter().seconds;
        sounds.shutter(body.shutter().seconds);
        auto e = std::make_shared<Exposure>();
        e->body = body; e->camera = camera;
        e->W = photoW; e->H = photoH; e->tileW = finderW; e->tileH = finderH;
        e->cells = body.lens().isFisheye() ? std::vector<V2>{{0, 0}} : body.cellCentres(cells);
        body.framesShot++;
        e->frameNumber = body.framesShot;
        char roll[256];
        snprintf(roll, sizeof roll, "Roll %02d - %s", body.rollNumber, body.rollName().c_str());
        char frame[32]; snprintf(frame, sizeof frame, "frame-%02d.png", e->frameNumber);
        e->out = rollsRoot() / fs::u8path(session) / fs::u8path(roll) / frame;
        if (!option("--shoot").empty() && option("--shoot") != "-") e->out = fs::u8path(option("--shoot"));
        renderer.expose(e);
        // The advance lever, once the shutter has closed.
        advanceAt = now + body.shutter().seconds + 0.4;
    }
    double advanceAt = 0;

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
                    if (nm.rfind("Roll ", 0) != 0) continue;
                    Roll roll{std::atoi(nm.c_str() + 5), nm.find(" - ") != std::string::npos ? nm.substr(nm.find(" - ") + 3) : "",
                              day.filename().u8string() + " · " + sit.filename().u8string(), r, {}};
                    for (auto& f : fs::directory_iterator(r))
                        if (f.path().extension() == ".png" && f.path().filename().u8string().rfind("frame-", 0) == 0)
                            roll.frames.push_back(f.path());
                    std::sort(roll.frames.begin(), roll.frames.end());
                    group.push_back(int(rolls.size()));
                    rolls.push_back(roll);
                }
                if (!group.empty()) sessions.push_back(group);
            }
        }
        sessionIndex = std::max(0, int(sessions.size()) - 1);
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
    struct Inset { float x, y, s, corner; };
    Inset inset() const {
        float s = std::min(cv.w * 0.82f / finderW, cv.h * 0.82f / finderH);
        return {(cv.w - finderW * s) / 2, cv.h * 0.075f, s, cv.h * 0.025f};
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
        float imgH = finderH * in.s, u = imgH / 50;
        float cardW = 3.6f * u, cardH = imgH * 0.66f;
        float cx0 = in.x + 1.0f * u, cy0 = in.y + imgH / 2 - cardH / 2;
        RGBA cream{1.0f, 0.90f, 0.78f, 1}, red{1.0f, 0.40f, 0.28f, 1};
        auto& sp = shutterSpeeds();
        int n = int(sp.size());
        float cap = 2 * u, step = (cardH - 2 * cap) / n;
        auto yAt = [&](float idx) { return cy0 + cap + (n - 1 - idx + 0.5f) * step; };
        cv.roundRect(cx0, cy0, cx0 + cardW, cy0 + cardH, 0.5f * u, {cream.r, cream.g, cream.b, 0.10f}, true);
        cv.roundRect(cx0, cy0, cx0 + cardW, cy0 + cap * 0.8f, 0.4f * u, {red.r, red.g, red.b, 0.5f}, true);
        cv.roundRect(cx0, cy0 + cardH - cap * 0.8f, cx0 + cardW, cy0 + cardH, 0.4f * u, {red.r, red.g, red.b, 0.5f}, true);
        V2 pivot{cx0 - 9 * u, cy0 + cardH / 2};
        for (int i = 0; i < n; i++) {
            bool slow = sp[i].seconds >= 1 / 30.f;
            RGBA c = slow ? red : cream;
            float y = yAt(float(i));
            int size = int(std::min(step * 0.58f, cardW * 0.25f));
            float w = font.width(sp[i].label, size);
            font.draw(cv, sp[i].label, cx0 + cardW - w - 0.35f * u, y - size * 0.6f, size, {c.r, c.g, c.b, 0.85f}, 0.4f);
            V2 p0{cx0 + 0.1f * u, y};
            V2 d = p0 - pivot; float L = len(d);
            cv.line(p0, p0 + d * (0.9f * u / L), 0.13f * u, {c.r, c.g, c.b, 0.8f}, 0, true);
        }
        // The set speed's green tab.
        float ty = yAt(float(body.shutterIndex));
        for (float k = -0.4f; k <= 0.4f; k += 0.05f)
            cv.line({cx0 + cardW - 0.2f * u, ty + k * step}, {cx0 + cardW + 1.4f * u, ty + k * step * 0.55f}, 1.5f,
                    {0.45f, 0.95f, 0.70f, 0.85f}, 0, false);
        // The needle: it has mass, and aims through the reading's tick.
        float set = float(body.shutterIndex);
        float meterStops = body.exposureStops() + std::log2(std::max(meterLum, 1e-4f) / 0.18f);
        float wantN = std::clamp(set + meterStops, -1.5f, float(n) + 0.5f);
        float dt = 1 / 30.f;
        needleSpeed += (60 * (wantN - needle) - 11 * needleSpeed) * dt;
        needle += needleSpeed * dt;
        V2 aim{cx0 + 0.1f * u, yAt(needle)};
        float reach = (cx0 + 1.15f * u - pivot.x) / (aim.x - pivot.x);
        V2 tip = pivot + (aim - pivot) * reach;
        V2 start = pivot + (aim - pivot) * ((in.x - pivot.x) / (aim.x - pivot.x));
        cv.line(start, tip, std::max(1.2f, 0.11f * u), {0.9f, 0.08f, 0.05f, 0.85f}, 0.15f * u, true);
    }

    void drawReadouts(const Inset& in) {
        float imgH = finderH * in.s, imgW = finderW * in.s, u = imgH / 50;
        char top[256];
        snprintf(top, sizeof top, "%s  ·  %s %.1f m/s  ·  %s", body.lens().name.c_str(), pace < 0.1f ? "inch" : "walk",
                 pace, body.rollName().c_str());
        font.draw(cv, top, in.x + 0.5f * u, in.y - 2.15f * u, int(0.95f * u), {1.0f, 0.90f, 0.76f, 0.9f}, 0.3f);
        float h = 2 * u, y = in.y + imgH + (cv.h - in.y - imgH - h) * 0.4f;
        char ap[16];
        float N = body.takingAperture();
        snprintf(ap, sizeof ap, N < 10 ? "%.1f" : "%.0f", N);
        float ax = in.x + imgW * 0.16f;
        drawLED(cv, "F", ax, y, h, 1);
        drawLED(cv, ap, ax + h * 0.52f * 1.45f, y, h, 3);
        std::string sh = body.shutter().label;
        float sEnd = drawLED(cv, sh, in.x + imgW * 0.34f, y, h, 4);
        if (body.shutter().seconds >= 1) font.draw(cv, "s", sEnd + 0.1f * u, y + h * 0.1f, int(h * 0.75f), {1, 0.12f, 0.1f, 1}, 0);
        char fm[16];
        snprintf(fm, sizeof fm, "%.2f", body.focusM);
        float fEnd = drawLED(cv, body.focusM >= 100 ? "" : fm, in.x + imgW * 0.54f, y, h, 4);
        font.draw(cv, "m", fEnd + 0.2f * u, y + h * 0.1f, int(h * 0.75f), {1, 0.12f, 0.1f, 1}, 0);
        int left = body.framesLeft() > 0 ? body.framesShot + 1 : 0;
        drawLED(cv, left ? std::to_string(left) : "E", in.x + imgW * 0.80f, y, h, 2);
        std::string notes;
        double now = SDL_GetTicks() / 1000.0;
        if (now < flashUntil) notes = flash + "   ·   ";
        if (renderer.pending() > 0) notes += "DEVELOPING " + std::to_string(renderer.pending()) + "   ·   ";
        char iso[32]; snprintf(iso, sizeof iso, body.push ? "EI %.0f" : "ISO %.0f", body.ratedEI());
        notes += iso;
        float nw = font.width(notes, int(0.75f * u));
        font.draw(cv, notes, in.x + imgW / 2 - nw / 2, y + h * 1.3f, int(0.75f * u), {1, 0.12f, 0.1f, 0.85f}, 0);
    }

    void panel(float x0, float y0, float x1, float y1) {
        cv.roundRect(x0, y0, x1, y1, 12, {0.08f, 0.08f, 0.08f, 0.96f});
    }
    void drawMenu() {
        float u = cv.h / 60.f, w = std::min(cv.w * 0.5f, 56 * u);
        const std::vector<std::pair<std::string, std::string>>& items = menuItems();
        float h = items.size() * 2.9f * u + 9 * u, x0 = cv.w / 2 - w / 2, y0 = cv.h / 2 - h / 2;
        panel(x0, y0, x0 + w, y0 + h);
        RGBA amber{1.0f, 0.78f, 0.42f, 1}, cream{1.0f, 0.92f, 0.80f, 0.95f}, dim{0.75f, 0.70f, 0.62f, 0.8f};
        font.draw(cv, "VINTAGE CLICK", x0 + 2 * u, y0 + 1.6f * u, int(1.5f * u), amber, 0.2f);
        for (size_t i = 0; i < items.size(); i++) {
            float y = y0 + 5 * u + i * 2.9f * u;
            if (int(i) == menuSel) cv.roundRect(x0 + u, y - 0.2f * u, x0 + w - u, y + 2.6f * u, 6, {amber.r, amber.g, amber.b, 0.18f});
            font.draw(cv, items[i].first, x0 + 2 * u, y, int(1.15f * u), int(i) == menuSel ? amber : cream, 0.15f);
            font.draw(cv, items[i].second, x0 + 3.5f * u, y + 1.45f * u, int(0.8f * u), dim, 0.1f);
        }
        font.draw(cv, "up / down choose   A / Enter select   B / Esc back", x0 + 2 * u, y0 + h - 2.6f * u, int(0.9f * u), dim, 0.1f);
    }
    std::vector<std::pair<std::string, std::string>> menuItems() const {
        char ev[64]; snprintf(ev, sizeof ev, "Scene light: EV %.0f", body.sceneEV);
        return {{"Back to the camera", "carry on where you were"},
                {"Change lens...", "now: " + body.lens().name},
                {"Load film...", "now: " + body.rollName()},
                {"Light table", "your rolls, through a loupe (Tab)"},
                {ev, "the light the scan was made in: select to step brighter (9 to 15)"},
                {"Reset the view", "back to where you started"},
                {std::string("Camera sounds: ") + (sounds.enabled ? "on" : "off"), "a real Nikon (select to switch)"},
                {"Open another scene...", "a .ply scan"},
                {"Quit", ""}};
    }
    void chooseMenu() {
        switch (menuSel) {
        case 0: mode = Mode::Camera; break;
        case 1: openBag(); break;
        case 2: filmSel = body.stockIndex; filmPush = body.push; mode = Mode::Film; break;
        case 3: openSheet(); break;
        case 4: body.sceneEV = body.sceneEV >= 15 ? 9 : body.sceneEV + 1; break;
        case 5: camera = home; mode = Mode::Camera; break;
        case 6: sounds.enabled = !sounds.enabled; break;
        case 7: chooseScene(); break;
        case 8: quit = true; break;
        }
    }
    void openBag() {
        shelf = 0;
        for (int s = 0, k = 0; s < int(lensShelves().size()); k += lensShelves()[s].count, s++)
            if (body.lensIndex >= k && body.lensIndex < k + lensShelves()[s].count) { shelf = s; lensSel = body.lensIndex - k; }
        mode = Mode::Bag;
    }
    int shelfStart(int s) const { int k = 0; for (int i = 0; i < s; i++) k += lensShelves()[i].count; return k; }
    void drawBag() {
        float u = cv.h / 60.f, w = std::min(cv.w * 0.86f, 84 * u);
        const LensShelf& sh = lensShelves()[shelf];
        float rowH = 3.3f * u, h = std::max(sh.count, 8) * rowH + 15 * u, x0 = cv.w / 2 - w / 2, y0 = cv.h / 2 - h / 2;
        panel(x0, y0, x0 + w, y0 + h);
        RGBA amber{1.0f, 0.78f, 0.42f, 1}, cream{1.0f, 0.92f, 0.80f, 0.95f}, dim{0.75f, 0.70f, 0.62f, 0.8f};
        font.draw(cv, "CAMERA BAG", x0 + 2 * u, y0 + 1.5f * u, int(1.5f * u), amber, 0.2f);
        float x = x0 + 17 * u;
        for (int i = 0; i < int(lensShelves().size()); i++) {
            int size = int(0.95f * u);
            float tw = font.width(lensShelves()[i].name, size) + 1.6f * u;
            if (i == shelf) cv.roundRect(x, y0 + 1.2f * u, x + tw, y0 + 3.3f * u, 5, {amber.r, amber.g, amber.b, 0.25f});
            font.draw(cv, lensShelves()[i].name, x + 0.8f * u, y0 + 1.6f * u, size, i == shelf ? amber : dim, 0.1f);
            x += tw + 0.5f * u;
        }
        font.draw(cv, sh.about, x0 + 2 * u, y0 + 4 * u, int(0.9f * u), dim, 0.1f);
        for (int i = 0; i < sh.count; i++) {
            const Lens& L = lensBag()[shelfStart(shelf) + i];
            float y = y0 + 6.2f * u + i * rowH;
            if (i == lensSel) cv.roundRect(x0 + u, y, x0 + w - u, y + rowH - 0.4f * u, 6, {amber.r, amber.g, amber.b, 0.18f});
            bool mounted = shelfStart(shelf) + i == body.lensIndex;
            font.draw(cv, L.name + (mounted ? "  (on the camera)" : ""), x0 + 2 * u, y + 0.4f * u, int(1.2f * u), i == lensSel ? amber : cream, 0.15f);
            char close[64];
            snprintf(close, sizeof close, L.minFocusM < 1 ? "close %.0f cm" : "close %.1f m", L.minFocusM < 1 ? L.minFocusM * 100 : L.minFocusM);
            std::string kind = L.projection == Projection::CircularFisheye ? "circular fisheye" : L.projection == Projection::Fisheye ? "fisheye"
                             : (L.blades == 0 ? std::string("round iris") : std::to_string(L.blades) + "-blade iris");
            font.draw(cv, kind + " · " + close, x0 + w * 0.5f, y + 0.55f * u, int(0.95f * u), dim, 0.1f);
            font.draw(cv, L.inspiredBy, x0 + 3.5f * u, y + 1.95f * u, int(0.8f * u), dim, 0.05f);
        }
        font.draw(cv, "left / right shelf   up / down lens   A / Enter mount   B / Esc back", x0 + 2 * u, y0 + h - 2.6f * u, int(0.9f * u), dim, 0.1f);
    }
    void drawFilm() {
        float u = cv.h / 60.f, w = std::min(cv.w * 0.7f, 70 * u);
        int n = int(filmStocks().size()), shown = std::min(n, 9);
        int first = std::clamp(filmSel - shown / 2, 0, n - shown);
        float rowH = 3.3f * u, h = shown * rowH + 15 * u, x0 = cv.w / 2 - w / 2, y0 = cv.h / 2 - h / 2;
        panel(x0, y0, x0 + w, y0 + h);
        RGBA amber{1.0f, 0.78f, 0.42f, 1}, cream{1.0f, 0.92f, 0.80f, 0.95f}, dim{0.75f, 0.70f, 0.62f, 0.8f};
        font.draw(cv, "LOAD FILM", x0 + 2 * u, y0 + 1.5f * u, int(1.5f * u), amber, 0.2f);
        font.draw(cv, "the roll in the camera is rewound and put away", x0 + 15 * u, y0 + 1.9f * u, int(0.9f * u), dim, 0.1f);
        for (int k = 0; k < shown; k++) {
            int i = first + k;
            const FilmStock& s = filmStocks()[i];
            float y = y0 + 4.5f * u + k * rowH;
            if (i == filmSel) cv.roundRect(x0 + u, y, x0 + w - u, y + rowH - 0.4f * u, 6, {amber.r, amber.g, amber.b, 0.18f});
            font.draw(cv, s.name, x0 + 2 * u, y + 0.3f * u, int(1.15f * u), i == filmSel ? amber : cream, 0.15f);
            char d[96]; snprintf(d, sizeof d, "ISO %.0f · %s · %d exp", s.iso, s.blackAndWhite ? "b&w" : "colour", s.exposures);
            font.draw(cv, d, x0 + w * 0.45f, y + 0.5f * u, int(0.95f * u), dim, 0.1f);
            font.draw(cv, s.inspiredBy, x0 + 3.5f * u, y + 1.75f * u, int(0.8f * u), dim, 0.05f);
        }
        char rate[96];
        float ei = filmStocks()[filmSel].iso * std::exp2(float(filmPush));
        snprintf(rate, sizeof rate, "<  rate at EI %.0f (%s)  >", ei, filmPush == 0 ? "box speed" : filmPush > 0 ? "push" : "pull");
        font.draw(cv, rate, x0 + 2 * u, y0 + h - 5 * u, int(1.1f * u), amber, 0.2f);
        font.draw(cv, "up / down stock   left / right push or pull   A / Enter load   B / Esc back", x0 + 2 * u, y0 + h - 2.6f * u, int(0.9f * u), dim, 0.1f);
    }

    void openSheet() { scanRolls(); sheetSel = 0; loupe = {-1, -1}; mode = Mode::Sheet; }
    void drawSheet() {
        int W = cv.w, H = cv.h;
        // The light table: an even cool glow, a little darker at the edges.
        parallelRows(H, [&](int y0, int y1) {
            for (int y = y0; y < y1; y++)
                for (int x = 0; x < W; x++) {
                    float dx = x / float(W) - 0.5f, dy = y / float(H) - 0.5f;
                    float l = 0.93f + 0.03f * std::cos(x / float(W) * 2 * float(M_PI) * 3.5f) + 0.02f * (valueNoise(x / 300.f, y / 300.f, 5) - 0.5f);
                    l *= 1 - 0.6f * (dx * dx + dy * dy);
                    cv.px[size_t(y) * W + x] = 0xff000000u | uint32_t(sat(l + 0.01f) * 255) | uint32_t(sat(l) * 255) << 8 | uint32_t(sat(l + 0.03f) * 255) << 16;
                }
        });
        RGBA cream{1.0f, 0.92f, 0.80f, 0.92f};
        if (sessions.empty()) {
            font.draw(cv, "No rolls developed yet: shoot a roll, and it comes here from the darkroom.", 40, H - 30, 16, {0.15f, 0.15f, 0.15f, 1}, 0);
            return;
        }
        // Strips of six, each roll cut on its own.
        struct Cell { float x, y, w, h; int roll, frame; };
        std::vector<Cell> cells;
        std::vector<std::tuple<float, float, float, float, int, int, int>> strips;
        std::vector<std::tuple<int, int, int>> cuts;
        for (int r : sessions[sessionIndex])
            for (int f = 0; f < int(rolls[r].frames.size()); f += 6) cuts.emplace_back(r, f, std::min(6, int(rolls[r].frames.size()) - f));
        int rowsN = std::max(1, int(cuts.size()));
        float mm = std::min(W * 0.9f / (6 * 38 + 6), H * 0.85f / (rowsN * 41.f));
        float x0 = W / 2.f - (6 * 38 + 6) * mm / 2, y0 = std::max(H * 0.03f, (H * 0.92f - rowsN * 41 * mm) / 2);
        for (size_t k = 0; k < cuts.size(); k++) {
            auto [r, first, count] = cuts[k];
            float y = y0 + k * 41 * mm, w = (count * 38 + 6) * mm;
            cv.rect(x0, y, x0 + w, y + 35 * mm, {0.05f, 0.05f, 0.05f, 1});
            for (float hx = x0 + 1.2f * mm; hx < x0 + w - 2 * mm; hx += 4.75f * mm)
                for (float hy : {y + 2 * mm, y + 35 * mm - 4.8f * mm})
                    cv.roundRect(hx, hy, hx + 1.98f * mm, hy + 2.79f * mm, 0.5f * mm, {0.93f, 0.95f, 0.98f, 1});
            bool bw = false;
            for (auto& s : filmStocks()) if (rolls[r].stock.rfind(s.name, 0) == 0) bw = s.blackAndWhite;
            RGBA edge = bw ? RGBA{0.8f, 0.8f, 0.8f, 0.85f} : RGBA{1.0f, 0.70f, 0.30f, 0.85f};
            std::string up = rolls[r].stock;
            for (auto& ch : up) ch = char(std::toupper(ch));
            font.draw(cv, up + "  SAFETY FILM", x0 + 3 * mm, y + 0.3f * mm, std::max(7, int(1.5f * mm)), edge, 0.3f);
            for (int j = 0; j < count; j++) {
                Cell c{x0 + (4 + j * 38) * mm, y + 5.5f * mm, 36 * mm, 24 * mm, r, first + j};
                font.draw(cv, std::to_string(first + j + 1), c.x + 2 * mm, y + 35 * mm - 1.9f * mm, std::max(7, int(1.5f * mm)), edge, 0.3f);
                cells.push_back(c);
            }
        }
        auto drawImage = [&](const Cell& c, float scale, V2 centre, float R) {
            int tw, th;
            const std::vector<uint8_t>* t = thumb(rolls[c.roll].frames[c.frame], tw, th);
            if (!t) return;
            // Destination rect, magnified about `centre` by `scale`, clipped to the circle R (or none).
            float dx0 = centre.x + (c.x - centre.x) * scale, dy0 = centre.y + (c.y - centre.y) * scale;
            float dw = c.w * scale, dh = c.h * scale;
            for (int y = std::max(0, int(dy0)); y < std::min(H, int(dy0 + dh)); y++)
                for (int x = std::max(0, int(dx0)); x < std::min(W, int(dx0 + dw)); x++) {
                    if (R > 0 && len(V2{x + 0.5f, y + 0.5f} - centre) > R) continue;
                    int sx = std::clamp(int((x - dx0) / dw * tw), 0, tw - 1), sy = std::clamp(int((y - dy0) / dh * th), 0, th - 1);
                    const uint8_t* p = &(*t)[(size_t(sy) * tw + sx) * 3];
                    cv.px[size_t(y) * W + x] = 0xff000000u | p[0] | p[1] << 8 | p[2] << 16;
                }
        };
        for (auto& c : cells) drawImage(c, 1, {0, 0}, 0);
        if (sheetSel >= int(cells.size())) sheetSel = int(cells.size()) - 1;
        if (sheetSel >= 0) {
            const Cell& c = cells[sheetSel];
            cv.circle({0, 0}, 0, 0, cream);
            for (float t = -2; t <= 2; t += 1) {
                cv.line({c.x - 3, c.y - 3 + t}, {c.x + c.w + 3, c.y - 3 + t}, 1, {0.1f, 0.1f, 0.1f, 0.6f});
                cv.line({c.x - 3, c.y + c.h + 3 + t}, {c.x + c.w + 3, c.y + c.h + 3 + t}, 1, {0.1f, 0.1f, 0.1f, 0.6f});
            }
            if (loupe.x < 0) loupe = {c.x + c.w / 2, c.y + c.h / 2};
        }
        // The loupe: what is under it, magnified, in a worn black barrel.
        float R = H * 0.2f;
        if (loupe.x >= 0) {
            for (int y = std::max(0, int(loupe.y - R)); y < std::min(H, int(loupe.y + R)); y++)
                for (int x = std::max(0, int(loupe.x - R)); x < std::min(W, int(loupe.x + R)); x++)
                    if (len(V2{x + 0.5f, y + 0.5f} - loupe) <= R) {
                        // The table under the loupe: a little brighter, magnified glow.
                        cv.px[size_t(y) * W + x] = 0xfff4f1edu;
                    }
            for (auto& c : cells) drawImage(c, loupePower, loupe, R);
            // Fall-off toward the rim, then the barrel.
            for (int y = std::max(0, int(loupe.y - R - 30)); y < std::min(H, int(loupe.y + R + 30)); y++)
                for (int x = std::max(0, int(loupe.x - R - 30)); x < std::min(W, int(loupe.x + R + 30)); x++) {
                    float d = len(V2{x + 0.5f, y + 0.5f} - loupe) / R;
                    if (d <= 1) { float t = 0.62f * d, c2 = 1 / (1 + t * t); float v = c2 * c2; cv.blend(x, y, {0, 0, 0, 1}, 1 - v); }
                    else if (d <= 1.16f) {
                        float u2 = (d - 1) / 0.16f;
                        float l = 0.05f + 0.12f * std::sin(u2 * float(M_PI)) * (0.6f + 0.4f * std::cos(std::atan2(y - loupe.y, x - loupe.x) + 2.3f));
                        cv.blend(x, y, {l, l * 0.97f, l * 0.93f, 1}, std::clamp((1.16f - d) * R, 0.f, 1.f));
                    }
                }
        }
        char hint[256];
        auto& r0 = rolls[sessions[sessionIndex][0]];
        snprintf(hint, sizeof hint, "%s · %zu rolls (session %d of %zu) · loupe %.0fx     sticks / mouse: loupe   triggers / wheel: power   d-pad / arrows: frame   L1 R1 / Q E: session   B / Tab: back",
                 r0.session.c_str(), sessions[sessionIndex].size(), sessionIndex + 1, sessions.size(), loupePower);
        cv.rect(0, H - 34, W, H, {0.08f, 0.08f, 0.08f, 1});
        float hw = font.width(hint, 13);
        font.draw(cv, hint, std::max(10.f, W / 2 - hw / 2), H - 26, 13, cream, 0.2f);
        sheetCells = int(cells.size());
    }
    int sheetCells = 0;

    void chooseScene() {
        static const SDL_DialogFileFilter filters[] = {{"Gaussian splat scan", "ply"}};
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
        if (mode == Mode::Menu) {
            int n = int(menuItems().size());
            if (what == "up") menuSel = (menuSel + n - 1) % n;
            if (what == "down") menuSel = (menuSel + 1) % n;
            if (what == "a") chooseMenu();
            if (what == "b" || what == "menu") mode = Mode::Camera;
            return;
        }
        if (mode == Mode::Bag) {
            int ns = int(lensShelves().size()), nl = lensShelves()[shelf].count;
            if (what == "left") { shelf = (shelf + ns - 1) % ns; lensSel = 0; }
            if (what == "right") { shelf = (shelf + 1) % ns; lensSel = 0; }
            if (what == "up") lensSel = (lensSel + nl - 1) % nl;
            if (what == "down") lensSel = (lensSel + 1) % nl;
            if (what == "a") {
                body.chooseLens(shelfStart(shelf) + lensSel);
                camera.focalMM = body.lens().focalMM;
                sounds.play("lens-change");
                say(body.lens().name);
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
                sounds.play("film-change");
                say("LOADED " + body.rollName());
                mode = Mode::Camera;
            }
            if (what == "b" || what == "menu") mode = Mode::Camera;
            return;
        }
        if (mode == Mode::Sheet) {
            if (what == "left") sheetSel = std::max(0, sheetSel - 1);
            if (what == "right") sheetSel = std::min(sheetCells - 1, sheetSel + 1);
            if (what == "up") sheetSel = std::max(0, sheetSel - 6);
            if (what == "down") sheetSel = std::min(sheetCells - 1, sheetSel + 6);
            if (what == "left" || what == "right" || what == "up" || what == "down") loupe = {-1, -1};
            if (what == "l1") { sessionIndex = std::max(0, sessionIndex - 1); sheetSel = 0; loupe = {-1, -1}; }
            if (what == "r1") { sessionIndex = std::min(int(sessions.size()) - 1, sessionIndex + 1); sheetSel = 0; loupe = {-1, -1}; }
            if (what == "b" || what == "view") mode = Mode::Camera;
            if (what == "menu") { mode = Mode::Menu; menuSel = 0; }
            return;
        }
        // The camera.
        if (what == "left" || what == "right") {
            int was = body.apertureIndex;
            body.changeAperture(what == "left" ? -1 : 1);
            if (body.apertureIndex != was) sounds.play("iris-click", 0.6f);
        }
        if (what == "up" || what == "down") {
            int was = body.shutterIndex;
            body.changeShutter(what == "up" ? 1 : -1);
            if (body.shutterIndex != was) sounds.play("shutter-change", 0.7f);
        }
        if (what == "a") release();
        if (what == "x") openBag();
        if (what == "y") { filmSel = body.stockIndex; filmPush = body.push; mode = Mode::Film; }
        if (what == "view") openSheet();
        if (what == "menu") { mode = Mode::Menu; menuSel = 0; }
        if (what == "l3") pace = place ? (pace < 1 ? 1.4f : pace < 2 ? 3.0f : 0.3f) : (pace < 0.05f ? 0.08f : pace < 0.1f ? 0.3f : 0.02f);
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
            // In the camera the shoulders rise and sink (held), not presses.
            if (it != m.end() && !(mode == Mode::Camera && (it->second == "l1" || it->second == "r1"))) press(it->second);
            break;
        }
        case SDL_EVENT_KEY_DOWN: {
            if (e.key.repeat && mode == Mode::Camera) break;
            SDL_Keycode k = e.key.key;
            if (k == SDLK_ESCAPE) {
                if (mouseCaptured) { SDL_SetWindowRelativeMouseMode(window, false); mouseCaptured = false; }
                press(mode == Mode::Camera ? "menu" : "b");
            }
            bool menuLike = mode != Mode::Camera;
            if (k == SDLK_RETURN || k == SDLK_KP_ENTER) press("a");
            if (menuLike) {
                if (k == SDLK_UP || k == SDLK_W) press("up");
                if (k == SDLK_DOWN || k == SDLK_S) press("down");
                if (k == SDLK_LEFT || k == SDLK_A) press("left");
                if (k == SDLK_RIGHT || k == SDLK_D) press("right");
                if (k == SDLK_SPACE) press("a");
                if (mode == Mode::Sheet && k == SDLK_Q) press("l1");
                if (mode == Mode::Sheet && k == SDLK_E) press("r1");
                if (k == SDLK_TAB && mode == Mode::Sheet) press("view");
                break;
            }
            if (k == SDLK_LEFTBRACKET) press("left");
            if (k == SDLK_RIGHTBRACKET) press("right");
            if (k == SDLK_EQUALS) press("up");
            if (k == SDLK_MINUS) press("down");
            if (k == SDLK_B) press("x");
            if (k == SDLK_R) press("y");
            if (k == SDLK_TAB) press("view");
            if (k == SDLK_H) camera = home;
            if (k == SDLK_COMMA || k == SDLK_PERIOD) press("l3");
            break;
        }
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            if (mode == Mode::Camera) {
                if (!mouseCaptured) { SDL_SetWindowRelativeMouseMode(window, true); mouseCaptured = true; }
                else if (e.button.button == SDL_BUTTON_LEFT) press("a");
            } else if (mode == Mode::Sheet && e.button.button == SDL_BUTTON_LEFT) {
                loupe = {e.button.x * pixelScale(), e.button.y * pixelScale()};
            }
            break;
        case SDL_EVENT_MOUSE_MOTION:
            if (mode == Mode::Camera && mouseCaptured) camera.turn({e.motion.xrel, -e.motion.yrel});
            if (mode == Mode::Sheet && (e.motion.state & SDL_BUTTON_LMASK)) loupe = {e.motion.x * pixelScale(), e.motion.y * pixelScale()};
            break;
        case SDL_EVENT_MOUSE_WHEEL:
            if (mode == Mode::Camera) body.focusM = std::clamp(body.focusM * std::exp(e.wheel.y * 0.06f), body.lens().minFocusM, 200.f);
            if (mode == Mode::Sheet) loupePower = std::clamp(loupePower * std::exp(e.wheel.y * 0.1f), 2.f, 10.f);
            break;
        default: break;
        }
    }
    float pixelScale() const { int w, pw; SDL_GetWindowSize(window, &w, nullptr); SDL_GetWindowSizeInPixels(window, &pw, nullptr); return w ? float(pw) / w : 1; }

    void update(float dt) {
        if (mode == Mode::Camera) {
            const bool* k = SDL_GetKeyboardState(nullptr);
            V2 move{axis(SDL_GAMEPAD_AXIS_LEFTX) + (k[SDL_SCANCODE_D] - k[SDL_SCANCODE_A]),
                    -axis(SDL_GAMEPAD_AXIS_LEFTY) + (k[SDL_SCANCODE_W] - k[SDL_SCANCODE_S])};
            V2 look{axis(SDL_GAMEPAD_AXIS_RIGHTX) + 0.6f * (k[SDL_SCANCODE_RIGHT] - k[SDL_SCANCODE_LEFT]),
                    -axis(SDL_GAMEPAD_AXIS_RIGHTY) + 0.6f * (k[SDL_SCANCODE_UP] - k[SDL_SCANCODE_DOWN])};
            float rise = float(button(SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER)) - float(button(SDL_GAMEPAD_BUTTON_LEFT_SHOULDER)) +
                         (k[SDL_SCANCODE_SPACE] + k[SDL_SCANCODE_E]) - (k[SDL_SCANCODE_LCTRL] + k[SDL_SCANCODE_Q]);
            move.x = std::clamp(move.x, -1.f, 1.f); move.y = std::clamp(move.y, -1.f, 1.f);
            bool run = k[SDL_SCANCODE_LSHIFT] || k[SDL_SCANCODE_RSHIFT];
            camera.moveSpeed = pace / body.metresPerUnit * (run ? 3 : 1);
            camera.update(move, look, rise, dt);
            camera.focalMM = body.lens().focalMM;
            float trig = 0;
            if (pad) {
                float r = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) / 32767.f, l = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) / 32767.f;
                trig = r * r - l * l;
            }
            body.turnFocus(trig, dt);
            body.dofPreview = button(SDL_GAMEPAD_BUTTON_EAST) || (SDL_GetMouseState(nullptr, nullptr) & SDL_BUTTON_RMASK);
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
        double now = SDL_GetTicks() / 1000.0;
        if (advanceAt > 0 && now > advanceAt) { sounds.play("film-advance"); advanceAt = 0; }
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
    }

    void frame() {
        Uint64 t = SDL_GetTicks();
        float dt = lastTicks ? std::min(0.1f, (t - lastTicks) / 1000.f) : 1 / 30.f;
        lastTicks = t;
        update(dt);
        int pw, ph;
        SDL_GetWindowSizeInPixels(window, &pw, &ph);
        if (pw != cv.w || ph != cv.h) {
            cv.resize(pw, ph);
            if (tex) SDL_DestroyTexture(tex);
            tex = SDL_CreateTexture(sdl, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, pw, ph);
        }
        if (scan.count && mode != Mode::Sheet) renderer.ask(finderJob());
        std::shared_ptr<Frame> f;
        std::shared_ptr<FinderJob> j;
        { std::lock_guard<std::mutex> l(renderer.m); f = renderer.latest; j = renderer.latestJob; }
        if (mode == Mode::Sheet) {
            drawSheet();
        } else if (f && j) {
            meter(*f, *j);
            // A new scene: set the shutter from the first few metered frames.
            if (meterSettle > 0 && --meterSettle == 0) body.meterShutter(meterLum);
            drawFinder(*f, *j, SDL_GetTicks() / 1000.0 < mirrorUpUntil);
            if (mode == Mode::Menu) drawMenu();
            if (mode == Mode::Bag) drawBag();
            if (mode == Mode::Film) drawFilm();
        } else {
            std::fill(cv.px.begin(), cv.px.end(), 0xff060606u);
            std::string msg = scan.count ? "Loading the scan..." : "Open a .ply scan: drop it on this window, or press O";
            float w = font.width(msg, 22);
            font.draw(cv, msg, cv.w / 2 - w / 2, cv.h / 2 - 12, 22, {1.0f, 0.90f, 0.74f, 0.95f}, 0.4f);
            if (mode == Mode::Menu) drawMenu();
        }
        SDL_UpdateTexture(tex, nullptr, cv.px.data(), cv.w * 4);
        SDL_RenderClear(sdl);
        SDL_RenderTexture(sdl, tex, nullptr, nullptr);
        SDL_RenderPresent(sdl);
    }
};

// Headless: open a scan, shoot one frame, write it and quit (for tests and CI).
static int shootHeadless(App& app) {
    if (!app.open(option("--scan"))) { fprintf(stderr, "%s\n", app.flash.c_str()); return 1; }
    if (!option("--focus").empty()) app.body.focusM = std::stof(option("--focus"));
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
    App app;
    if (!option("--res").empty()) sscanf(option("--res").c_str(), "%dx%d", &app.finderW, &app.finderH);
    app.photoW = app.finderW * 2; app.photoH = app.finderH * 2;
    if (!option("--cells").empty()) app.cells = std::stoi(option("--cells"));
    if (!option("--lens").empty()) app.body.chooseLens(std::stoi(option("--lens")));
    if (!option("--film").empty()) app.body.stockIndex = std::stoi(option("--film")) % int(filmStocks().size());
    if (!option("--aperture").empty()) {
        auto s = app.body.lens().apertureStops();
        float n = std::stof(option("--aperture"));
        for (int i = 0; i < int(s.size()); i++) if (std::fabs(s[i] - n) < std::fabs(s[app.body.apertureIndex] - n)) app.body.apertureIndex = i;
    }
    if (!option("--shoot").empty()) {
        if (!SDL_Init(0)) return 1;
        std::string why = sr::load(basePath());
        if (!why.empty()) { fprintf(stderr, "%s\n", why.c_str()); return 1; }
        int rc = shootHeadless(app);
        sr::shutdown();
        SDL_Quit();
        return rc;
    }

    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD | SDL_INIT_AUDIO)) { fprintf(stderr, "SDL: %s\n", SDL_GetError()); return 1; }
    app.window = SDL_CreateWindow("Vintage Click", 1440, 960, SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
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
    app.renderer.start();
    if (!option("--scan").empty()) app.open(option("--scan"));
    if (!option("--focus").empty()) app.body.focusM = std::stof(option("--focus"));
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
    return 0;
}
