// Vintage Click, cross-platform: the GPU kernels (cross/shaders, translated
// from Shaders.swift) run through SDL_GPU on Vulkan. Synchronous and simple:
// each run() uploads its uniforms, dispatches and waits, which is how the Mac's
// render thread uses Metal too (commit, waitUntilCompleted).
#pragma once
#include <SDL3/SDL_gpu.h>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
#include "shaders_spv.h"

struct Gpu {
    SDL_GPUDevice* dev = nullptr;
    std::recursive_mutex m;
    std::string error;

    bool init() {
        std::lock_guard<std::recursive_mutex> l(m);
        if (dev) return true;
        dev = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV, false, "vulkan");
        if (!dev) { error = std::string("GPU: ") + SDL_GetError(); return false; }
        return true;
    }
    ~Gpu() { /* the device goes with the process (see endProcess in main.cpp) */ }

    struct Kernel {
        SDL_GPUComputePipeline* p = nullptr;
        Uint32 tx = 16, ty = 16;
    };
    /// A compute pipeline from embedded SPIR-V: how many read-only buffers
    /// (set 0), read-write buffers (set 1) and uniform blocks (set 2) it takes.
    Kernel kernel(const uint8_t* spv, size_t bytes, Uint32 ro, Uint32 rw, Uint32 uniforms, Uint32 tx, Uint32 ty = 1,
                  Uint32 samplers = 0, Uint32 rwTextures = 0) {
        SDL_GPUComputePipelineCreateInfo ci{};
        ci.code = spv; ci.code_size = bytes; ci.entrypoint = "main";
        ci.format = SDL_GPU_SHADERFORMAT_SPIRV;
        ci.num_samplers = samplers;
        ci.num_readwrite_storage_textures = rwTextures;
        ci.num_readonly_storage_buffers = ro;
        ci.num_readwrite_storage_buffers = rw;
        ci.num_uniform_buffers = uniforms;
        ci.threadcount_x = tx; ci.threadcount_y = ty; ci.threadcount_z = 1;
        Kernel k;
        k.p = SDL_CreateGPUComputePipeline(dev, &ci);
        k.tx = tx; k.ty = ty;
        if (!k.p) error = std::string("GPU kernel: ") + SDL_GetError();
        return k;
    }

    SDL_GPUBuffer* buffer(size_t bytes) {
        SDL_GPUBufferCreateInfo ci{};
        ci.usage = SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ | SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE;
        ci.size = Uint32(std::max<size_t>(bytes, 16));
        SDL_GPUBuffer* b = SDL_CreateGPUBuffer(dev, &ci);
        if (!b) error = std::string("GPU buffer: ") + SDL_GetError();
        return b;
    }
    void release(SDL_GPUBuffer*& b) { if (b) SDL_ReleaseGPUBuffer(dev, b); b = nullptr; }

    // One transfer buffer each way, grown as needed.
    SDL_GPUTransferBuffer* up = nullptr; Uint32 upSize = 0;
    SDL_GPUTransferBuffer* down = nullptr; Uint32 downSize = 0;
    SDL_GPUTransferBuffer* staging(bool upload, size_t bytes) {
        SDL_GPUTransferBuffer*& t = upload ? up : down;
        Uint32& sz = upload ? upSize : downSize;
        if (t && sz >= bytes) return t;
        if (t) SDL_ReleaseGPUTransferBuffer(dev, t);
        SDL_GPUTransferBufferCreateInfo ci{};
        ci.usage = upload ? SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD : SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
        ci.size = Uint32(bytes);
        t = SDL_CreateGPUTransferBuffer(dev, &ci);
        sz = t ? Uint32(bytes) : 0;
        return t;
    }
    bool finish(SDL_GPUCommandBuffer* cb) {
        SDL_GPUFence* f = SDL_SubmitGPUCommandBufferAndAcquireFence(cb);
        if (!f) { error = std::string("GPU submit: ") + SDL_GetError(); return false; }
        SDL_WaitForGPUFences(dev, true, &f, 1);
        SDL_ReleaseGPUFence(dev, f);
        return true;
    }
    bool upload(SDL_GPUBuffer* dst, const void* data, size_t bytes) {
        std::lock_guard<std::recursive_mutex> l(m);
        SDL_GPUTransferBuffer* t = staging(true, bytes);
        if (!t) return false;
        void* p = SDL_MapGPUTransferBuffer(dev, t, true);
        std::memcpy(p, data, bytes);
        SDL_UnmapGPUTransferBuffer(dev, t);
        SDL_GPUCommandBuffer* cb = SDL_AcquireGPUCommandBuffer(dev);
        SDL_GPUCopyPass* cp = SDL_BeginGPUCopyPass(cb);
        SDL_GPUTransferBufferLocation src{t, 0};
        SDL_GPUBufferRegion r{dst, 0, Uint32(bytes)};
        SDL_UploadToGPUBuffer(cp, &src, &r, true);
        SDL_EndGPUCopyPass(cp);
        return finish(cb);
    }
    /// Copies `bytes` from one buffer to another, on the GPU.
    bool copy(SDL_GPUBuffer* src, Uint32 srcOffset, SDL_GPUBuffer* dst, Uint32 dstOffset, Uint32 bytes) {
        std::lock_guard<std::recursive_mutex> l(m);
        SDL_GPUCommandBuffer* cb = SDL_AcquireGPUCommandBuffer(dev);
        SDL_GPUCopyPass* cp = SDL_BeginGPUCopyPass(cb);
        SDL_GPUBufferLocation from{src, srcOffset};
        SDL_GPUBufferLocation to{dst, dstOffset};
        SDL_CopyGPUBufferToBuffer(cp, &from, &to, bytes, false);
        SDL_EndGPUCopyPass(cp);
        return finish(cb);
    }
    bool download(SDL_GPUBuffer* src, void* data, size_t bytes) {
        std::lock_guard<std::recursive_mutex> l(m);
        SDL_GPUTransferBuffer* t = staging(false, bytes);
        if (!t) return false;
        SDL_GPUCommandBuffer* cb = SDL_AcquireGPUCommandBuffer(dev);
        SDL_GPUCopyPass* cp = SDL_BeginGPUCopyPass(cb);
        SDL_GPUBufferRegion r{src, 0, Uint32(bytes)};
        SDL_GPUTransferBufferLocation dst{t, 0};
        SDL_DownloadFromGPUBuffer(cp, &r, &dst);
        SDL_EndGPUCopyPass(cp);
        if (!finish(cb)) return false;
        void* p = SDL_MapGPUTransferBuffer(dev, t, false);
        std::memcpy(data, p, bytes);
        SDL_UnmapGPUTransferBuffer(dev, t);
        return true;
    }

    /// A float texture for compute (written by a kernel, sampled by another),
    /// with `levels` mip levels (made by mipmaps()).
    SDL_GPUTexture* texture(int w, int h, SDL_GPUTextureFormat fmt, int levels) {
        SDL_GPUTextureCreateInfo ci{};
        ci.type = SDL_GPU_TEXTURETYPE_2D;
        ci.format = fmt;
        ci.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER | SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE |
                   (levels > 1 ? SDL_GPU_TEXTUREUSAGE_COLOR_TARGET : 0);
        ci.width = Uint32(w); ci.height = Uint32(h);
        ci.layer_count_or_depth = 1; ci.num_levels = Uint32(levels);
        SDL_GPUTexture* t = SDL_CreateGPUTexture(dev, &ci);
        if (!t) error = std::string("GPU texture: ") + SDL_GetError();
        return t;
    }
    void release(SDL_GPUTexture*& t) { if (t) SDL_ReleaseGPUTexture(dev, t); t = nullptr; }
    bool mipmaps(SDL_GPUTexture* t) {
        std::lock_guard<std::recursive_mutex> l(m);
        SDL_GPUCommandBuffer* cb = SDL_AcquireGPUCommandBuffer(dev);
        SDL_GenerateMipmapsForGPUTexture(cb, t);
        return finish(cb);
    }
    /// Linear, linear between mips, clamped to the edge (Metal's
    /// filter::linear, mip_filter::linear, address::clamp_to_edge).
    SDL_GPUSampler* linear() {
        if (lin) return lin;
        SDL_GPUSamplerCreateInfo ci{};
        ci.min_filter = SDL_GPU_FILTER_LINEAR; ci.mag_filter = SDL_GPU_FILTER_LINEAR;
        ci.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_LINEAR;
        ci.address_mode_u = ci.address_mode_v = ci.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        ci.max_lod = 1000;
        lin = SDL_CreateGPUSampler(dev, &ci);
        return lin;
    }
    SDL_GPUSampler* lin = nullptr;
    /// The sky's: repeating around, clamped at the poles (s_address::repeat, t_address::clamp_to_edge).
    SDL_GPUSampler* skySampler() {
        if (skyS) return skyS;
        SDL_GPUSamplerCreateInfo ci{};
        ci.min_filter = SDL_GPU_FILTER_LINEAR; ci.mag_filter = SDL_GPU_FILTER_LINEAR;
        ci.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_LINEAR;
        ci.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_REPEAT;
        ci.address_mode_v = ci.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        ci.max_lod = 1000;
        skyS = SDL_CreateGPUSampler(dev, &ci);
        return skyS;
    }
    SDL_GPUSampler* skyS = nullptr;
    /// Fills mip 0 of a texture (tightly packed rows of `pixelBytes` each).
    bool uploadTexture(SDL_GPUTexture* t, const void* data, int w, int h, int pixelBytes) {
        std::lock_guard<std::recursive_mutex> l(m);
        size_t bytes = size_t(w) * h * pixelBytes;
        SDL_GPUTransferBuffer* tb = staging(true, bytes);
        if (!tb) return false;
        void* p = SDL_MapGPUTransferBuffer(dev, tb, false);
        std::memcpy(p, data, bytes);
        SDL_UnmapGPUTransferBuffer(dev, tb);
        SDL_GPUCommandBuffer* cb = SDL_AcquireGPUCommandBuffer(dev);
        SDL_GPUCopyPass* cp = SDL_BeginGPUCopyPass(cb);
        SDL_GPUTextureTransferInfo src{tb, 0, Uint32(w), Uint32(h)};
        SDL_GPUTextureRegion dst{};
        dst.texture = t; dst.w = Uint32(w); dst.h = Uint32(h); dst.d = 1;
        SDL_UploadToGPUTexture(cp, &src, &dst, false);
        SDL_EndGPUCopyPass(cp);
        return finish(cb);
    }

    struct Uniform { const void* data; size_t bytes; };
    /// Dispatch `k` over gx * gy threads (rounded up to whole groups) and wait.
    /// `sampled`: textures read through the linear sampler (set 0, first);
    /// `rwTex`: textures written at mip 0 (set 1, first).
    bool run(const Kernel& k, std::initializer_list<SDL_GPUBuffer*> ro, std::initializer_list<SDL_GPUBuffer*> rw,
             std::initializer_list<Uniform> uniforms, Uint32 gx, Uint32 gy = 1,
             std::initializer_list<SDL_GPUTexture*> sampled = {}, std::initializer_list<SDL_GPUTexture*> rwTex = {},
             std::initializer_list<SDL_GPUSampler*> samplers = {}) {
        std::lock_guard<std::recursive_mutex> l(m);
        if (!k.p) return false;
        SDL_GPUCommandBuffer* cb = SDL_AcquireGPUCommandBuffer(dev);
        Uint32 slot = 0;
        for (auto& u : uniforms) SDL_PushGPUComputeUniformData(cb, slot++, u.data, Uint32(u.bytes));
        std::vector<SDL_GPUStorageBufferReadWriteBinding> rwb;
        for (auto* b : rw) rwb.push_back({b, false});
        std::vector<SDL_GPUStorageTextureReadWriteBinding> rwt;
        for (auto* t : rwTex) { SDL_GPUStorageTextureReadWriteBinding b{}; b.texture = t; rwt.push_back(b); }
        SDL_GPUComputePass* cp = SDL_BeginGPUComputePass(cb, rwt.data(), Uint32(rwt.size()), rwb.data(), Uint32(rwb.size()));
        SDL_BindGPUComputePipeline(cp, k.p);
        std::vector<SDL_GPUTextureSamplerBinding> sb;
        std::vector<SDL_GPUSampler*> ss(samplers);
        for (auto* t : sampled) sb.push_back({t, sb.size() < ss.size() && ss[sb.size()] ? ss[sb.size()] : linear()});
        if (!sb.empty()) SDL_BindGPUComputeSamplers(cp, 0, sb.data(), Uint32(sb.size()));
        std::vector<SDL_GPUBuffer*> rob(ro);
        if (!rob.empty()) SDL_BindGPUComputeStorageBuffers(cp, 0, rob.data(), Uint32(rob.size()));
        SDL_DispatchGPUCompute(cp, (gx + k.tx - 1) / k.tx, (gy + k.ty - 1) / k.ty, 1);
        SDL_EndGPUComputePass(cp);
        return finish(cb);
    }
};

/// The kernels, made once.
struct PhotoKernels {
    Gpu::Kernel accumulate, streak, develop, negative, shellStore, develop16;
    Gpu::Kernel viewfinder, meter, dofPack, dofTiles, dofBlur, relight, shadowVis, flareProbe, lensFx, backgroundFill;
    bool make(Gpu& g) {
        accumulate = g.kernel(spv_accumulate, sizeof spv_accumulate, 1, 1, 3, 16, 16);
        streak = g.kernel(spv_streak, sizeof spv_streak, 1, 1, 3, 32, 1);
        develop = g.kernel(spv_develop, sizeof spv_develop, 3, 1, 4, 16, 16);
        viewfinder = g.kernel(spv_viewfinder, sizeof spv_viewfinder, 2, 1, 3, 16, 16);
        meter = g.kernel(spv_meter, sizeof spv_meter, 1, 1, 1, 16, 16);
        dofPack = g.kernel(spv_dof_pack, sizeof spv_dof_pack, 1, 0, 1, 16, 16, 0, 2);
        dofTiles = g.kernel(spv_dof_tiles, sizeof spv_dof_tiles, 0, 1, 1, 8, 8, 1, 0);
        dofBlur = g.kernel(spv_dof_blur, sizeof spv_dof_blur, 1, 1, 2, 16, 16, 2, 0);
        relight = g.kernel(spv_relight, sizeof spv_relight, 5, 1, 2, 256, 1, 1, 0);
        shadowVis = g.kernel(spv_shadow_vis, sizeof spv_shadow_vis, 2, 1, 2, 256, 1);
        flareProbe = g.kernel(spv_flare_probe, sizeof spv_flare_probe, 1, 1, 2, 8, 1);
        lensFx = g.kernel(spv_lens_fx, sizeof spv_lens_fx, 1, 1, 2, 16, 16);
        backgroundFill = g.kernel(spv_background_fill, sizeof spv_background_fill, 2, 1, 4, 16, 16, 4, 0);
        negative = g.kernel(spv_negative, sizeof spv_negative, 3, 1, 3, 16, 16);
        develop16 = g.kernel(spv_develop16, sizeof spv_develop16, 3, 1, 4, 16, 16);
        shellStore = g.kernel(spv_shell_store, sizeof spv_shell_store, 1, 0, 1, 16, 16, 0, 2);
        return accumulate.p && streak.p && develop.p && viewfinder.p && meter.p && dofPack.p && dofTiles.p && dofBlur.p &&
               relight.p && shadowVis.p && flareProbe.p && lensFx.p && backgroundFill.p && negative.p && shellStore.p && develop16.p;
    }
};
