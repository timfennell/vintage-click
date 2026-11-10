// A scene's sound (Soundscape.swift), from its .vcscene: looping sounds at
// places in the scan (a stream, an engine idling), louder as you walk up to them
// and placed left and right of you, and beds heard everywhere (wind, traffic).
// The Mac places sources around the head (HRTF); here they pan between the ears.
#pragma once
#include "kit.h"
#include "platform.h"
#include <SDL3/SDL.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <mutex>
#include <random>
#include <string>
#include <vector>

struct Soundscape {
    struct Emitter {
        std::string file;
        V3 position;               // scan units
        float volume = 1, fullWithinM = 1, silentBeyondM = 50;
        std::vector<float> mono;   // at the mix rate
        size_t pos = 0;
        float gl = 0, gr = 0, tl = 0, tr = 0;   // gains now and wanted, per ear
    };
    struct Bed {
        std::string file;
        float volume = 1;
        std::vector<float> stereo;
        size_t pos = 0;
    };
    static constexpr int rate = 48000;
    std::vector<Emitter> sources;
    std::vector<Bed> beds;
    SDL_AudioStream* stream = nullptr;
    std::mutex m;
    float master = 0, masterWant = 0;

    ~Soundscape() { if (stream) SDL_DestroyAudioStream(stream); }
    bool empty() const { return sources.empty() && beds.empty(); }

    /// Reads a file at the mix rate: mono for a source placed in the scene, stereo for a bed.
    static bool load(const std::string& path, int channels, std::vector<float>& out) {
        std::vector<float> raw;
        int r = 0, c = 0;
        std::string err;
        if (!platform::decodeAudio(std::filesystem::u8path(path), raw, r, c, err)) {
            fprintf(stderr, "Soundscape: can't read %s: %s\n", path.c_str(), err.c_str());
            return false;
        }
        SDL_AudioSpec from{SDL_AUDIO_F32, c, r}, to{SDL_AUDIO_F32, channels, rate};
        Uint8* dst = nullptr;
        int n = 0;
        if (!SDL_ConvertAudioSamples(&from, reinterpret_cast<const Uint8*>(raw.data()), int(raw.size() * sizeof(float)), &to, &dst, &n))
            return false;
        out.assign(reinterpret_cast<float*>(dst), reinterpret_cast<float*>(dst) + n / sizeof(float));
        SDL_free(dst);
        return !out.empty();
    }

    /// Loads the sounds and starts them looping (silent until `update` lets them be heard).
    void start(std::vector<Emitter> emitters, std::vector<Bed> bedList) {
        std::mt19937 rng(std::random_device{}());
        for (auto& e : emitters)
            if (load(e.file, 1, e.mono)) {
                // Each starts somewhere in its loop, so sounds of one length don't beat together.
                e.pos = std::uniform_int_distribution<size_t>(0, e.mono.size() - 1)(rng);
                sources.push_back(std::move(e));
            }
        for (auto& b : bedList)
            if (load(b.file, 2, b.stereo)) {
                b.pos = std::uniform_int_distribution<size_t>(0, b.stereo.size() / 2 - 1)(rng) * 2;
                beds.push_back(std::move(b));
            }
        if (empty()) return;
        SDL_AudioSpec spec{SDL_AUDIO_F32, 2, rate};
        stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, &Soundscape::feed, this);
        if (stream) SDL_ResumeAudioStreamDevice(stream);
        else fprintf(stderr, "Soundscape: no audio: %s\n", SDL_GetError());
    }

    /// How loud a source is at `d` metres: full within its near distance, falling as
    /// 1/distance beyond, eased to nothing at its far distance.
    static float gain(const Emitter& e, float d) {
        float nearM = e.fullWithinM, farM = std::max(e.silentBeyondM, nearM + 0.01f);
        if (d >= farM) return 0;
        float fall = nearM / std::max(d, nearM);
        float t = std::clamp((d - (nearM + 0.75f * (farM - nearM))) / (0.25f * (farM - nearM)), 0.f, 1.f);
        return e.volume * fall * (1 - t * t * (3 - 2 * t));
    }

    /// Each frame: where the ears are (scan units), which way is right, and how loud it all is (0: silent).
    void update(V3 ears, V3 right, float metresPerUnit, float level) {
        std::lock_guard<std::mutex> l(m);
        masterWant = level;
        for (auto& e : sources) {
            V3 rel = (e.position - ears) * metresPerUnit;
            float d = len(rel);
            float g = gain(e, d);
            // Equal-power pan by how far to the side it is; close in, both ears.
            float side = d > 1e-4f ? std::clamp(dot(rel * (1 / d), norm(right)), -1.f, 1.f) * std::min(1.f, d / std::max(e.fullWithinM, 0.05f)) : 0;
            float a = (side + 1) * float(M_PI) / 4;
            e.tl = g * std::cos(a) * float(M_SQRT2);
            e.tr = g * std::sin(a) * float(M_SQRT2);
        }
    }

    static void SDLCALL feed(void* user, SDL_AudioStream* s, int additional, int) {
        auto* self = static_cast<Soundscape*>(user);
        int frames = additional / int(2 * sizeof(float));
        if (frames <= 0) return;
        std::vector<float> out(size_t(frames) * 2, 0.f);
        {
            std::lock_guard<std::mutex> l(self->m);
            float m0 = self->master, m1 = self->master + (self->masterWant - self->master) * 0.2f;
            self->master = m1;
            for (auto& e : self->sources) {
                float l0 = e.gl, r0 = e.gr;
                for (int i = 0; i < frames; i++) {
                    float k = float(i) / frames, v = e.mono[e.pos];
                    out[2 * i] += v * (l0 + (e.tl - l0) * k);
                    out[2 * i + 1] += v * (r0 + (e.tr - r0) * k);
                    if (++e.pos >= e.mono.size()) e.pos = 0;
                }
                e.gl = e.tl; e.gr = e.tr;
            }
            for (auto& b : self->beds)
                for (int i = 0; i < frames; i++) {
                    out[2 * i] += b.stereo[b.pos] * b.volume;
                    out[2 * i + 1] += b.stereo[b.pos + 1] * b.volume;
                    b.pos += 2;
                    if (b.pos + 1 >= b.stereo.size()) b.pos = 0;
                }
            for (int i = 0; i < frames; i++) {
                float g = m0 + (m1 - m0) * float(i) / frames;
                out[2 * i] *= g; out[2 * i + 1] *= g;
            }
        }
        SDL_PutAudioStreamData(s, out.data(), int(out.size() * sizeof(float)));
    }
};
