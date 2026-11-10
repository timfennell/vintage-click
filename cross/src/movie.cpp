// The movie file for the movie camera (MovieDeveloper.swift's writer): Media
// Foundation's sink writer, H.264 or HEVC in an .mp4.
#include "motion.h"

#if defined(_WIN32)
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <codecapi.h>
#include <algorithm>
#include <cmath>

struct MovieWriter::Impl {
    IMFSinkWriter* writer = nullptr;
    DWORD stream = 0;
    LONGLONG frameDuration = 416667;
    bool started = false;
    std::vector<uint32_t> bgra;
    void release() { if (writer) { writer->Release(); writer = nullptr; } }
};

MovieWriter::MovieWriter() : impl(new Impl) {}
MovieWriter::~MovieWriter() { finish(); }

bool MovieWriter::open(const fs::path& path, int w, int h, float fps, bool hevc, unsigned bitrate, std::string& err, bool ten) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    tenBit = ten && hevc;
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) { err = "Media Foundation didn't start"; return false; }
    impl->started = true;
    W = w; H = h;
    impl->frameDuration = LONGLONG(std::llround(1e7 / fps));
    IMFAttributes* attrs = nullptr;
    MFCreateAttributes(&attrs, 2);
    attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    attrs->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    HRESULT hr = MFCreateSinkWriterFromURL(path.wstring().c_str(), nullptr, attrs, &impl->writer);
    attrs->Release();
    if (FAILED(hr)) { err = "can't create the movie file"; return false; }
    UINT32 num = UINT32(std::lround(fps * 1000)), den = 1000;
    IMFMediaType* out = nullptr;
    MFCreateMediaType(&out);
    out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    out->SetGUID(MF_MT_SUBTYPE, hevc ? MFVideoFormat_HEVC : MFVideoFormat_H264);
    out->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
    out->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    if (!hevc) out->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
    if (tenBit) out->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH265VProfile_Main_420_10);
    MFSetAttributeSize(out, MF_MT_FRAME_SIZE, W, H);
    MFSetAttributeRatio(out, MF_MT_FRAME_RATE, num, den);
    MFSetAttributeRatio(out, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    // The print is display-referred, Rec. 709 primaries.
    out->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
    out->SetUINT32(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709);
    out->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
    hr = impl->writer->AddStream(out, &impl->stream);
    out->Release();
    if (FAILED(hr)) { err = tenBit ? "no 10-bit HEVC encoder on this PC" : hevc ? "no HEVC encoder on this PC" : "no H.264 encoder on this PC"; impl->release(); return false; }
    IMFMediaType* in = nullptr;
    MFCreateMediaType(&in);
    in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    // 8 bits: RGB, converted by Media Foundation; 10 bits: P010, made here from the floats.
    in->SetGUID(MF_MT_SUBTYPE, tenBit ? MFVideoFormat_P010 : MFVideoFormat_RGB32);
    in->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    in->SetUINT32(MF_MT_DEFAULT_STRIDE, UINT32(W * (tenBit ? 2 : 4)));
    if (tenBit) {
        in->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
        in->SetUINT32(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709);
        in->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
        in->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
    }
    MFSetAttributeSize(in, MF_MT_FRAME_SIZE, W, H);
    MFSetAttributeRatio(in, MF_MT_FRAME_RATE, num, den);
    MFSetAttributeRatio(in, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    hr = impl->writer->SetInputMediaType(impl->stream, in, nullptr);
    in->Release();
    if (FAILED(hr)) { err = tenBit ? "the HEVC encoder won't take 10-bit frames" : hevc ? "no HEVC encoder on this PC for these frames" : "the H.264 encoder won't take these frames"; impl->release(); return false; }
    if (FAILED(impl->writer->BeginWriting())) { err = "can't start writing the movie"; impl->release(); return false; }
    return true;
}

bool MovieWriter::write(const uint32_t* rgba, int frame) {
    if (!impl->writer) return false;
    IMFMediaBuffer* buf = nullptr;
    DWORD bytes = DWORD(W) * H * 4;
    if (FAILED(MFCreateMemoryBuffer(bytes, &buf))) return false;
    BYTE* dst = nullptr;
    buf->Lock(&dst, nullptr, nullptr);
    // RGB32 is B, G, R, X in memory.
    uint32_t* d = reinterpret_cast<uint32_t*>(dst);
    for (size_t i = 0, n = size_t(W) * H; i < n; i++) {
        uint32_t p = rgba[i];
        d[i] = 0xff000000u | (p & 0xffu) << 16 | (p & 0xff00u) | (p >> 16 & 0xffu);
    }
    buf->Unlock();
    buf->SetCurrentLength(bytes);
    IMFSample* sample = nullptr;
    MFCreateSample(&sample);
    sample->AddBuffer(buf);
    sample->SetSampleTime(LONGLONG(frame) * impl->frameDuration);
    sample->SetSampleDuration(impl->frameDuration);
    HRESULT hr = impl->writer->WriteSample(impl->stream, sample);
    sample->Release();
    buf->Release();
    return SUCCEEDED(hr);
}

bool MovieWriter::writeFloat(const float* rgb, int frame) {
    if (!impl->writer || !tenBit) return false;
    // P010: a plane of luma, then one of interleaved Cb Cr at half size each way; 16-bit
    // samples with the value in the top 10 bits. The print's values are taken as Rec. 709
    // R'G'B' (display-referred, as the 8-bit path is), studio range.
    size_t n = size_t(W) * H;
    DWORD bytes = DWORD(n * 2 + n);
    IMFMediaBuffer* buf = nullptr;
    if (FAILED(MFCreateMemoryBuffer(bytes, &buf))) return false;
    BYTE* dst = nullptr;
    buf->Lock(&dst, nullptr, nullptr);
    uint16_t* Y = reinterpret_cast<uint16_t*>(dst);
    uint16_t* C = Y + n;
    auto q = [](float v) { return uint16_t(std::lround(std::clamp(v, 0.f, 1023.f)) << 6); };
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            const float* p = rgb + (size_t(y) * W + x) * 3;
            Y[size_t(y) * W + x] = q(64 + 876 * (0.2126f * p[0] + 0.7152f * p[1] + 0.0722f * p[2]));
        }
    for (int y = 0; y < H / 2; y++)
        for (int x = 0; x < W / 2; x++) {
            // Chroma from the 2 x 2 block's average.
            float r = 0, g = 0, b = 0;
            for (int dy = 0; dy < 2; dy++)
                for (int dx = 0; dx < 2; dx++) {
                    const float* p = rgb + (size_t(2 * y + dy) * W + 2 * x + dx) * 3;
                    r += p[0]; g += p[1]; b += p[2];
                }
            r /= 4; g /= 4; b /= 4;
            float yy = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            C[(size_t(y) * (W / 2) + x) * 2] = q(512 + 896 * (b - yy) / 1.8556f);
            C[(size_t(y) * (W / 2) + x) * 2 + 1] = q(512 + 896 * (r - yy) / 1.5748f);
        }
    buf->Unlock();
    buf->SetCurrentLength(bytes);
    IMFSample* sample = nullptr;
    MFCreateSample(&sample);
    sample->AddBuffer(buf);
    sample->SetSampleTime(LONGLONG(frame) * impl->frameDuration);
    sample->SetSampleDuration(impl->frameDuration);
    HRESULT hr = impl->writer->WriteSample(impl->stream, sample);
    sample->Release();
    buf->Release();
    return SUCCEEDED(hr);
}

bool MovieWriter::finish() {
    bool ok = false;
    if (impl->writer) { ok = SUCCEEDED(impl->writer->Finalize()); impl->release(); }
    if (impl->started) { MFShutdown(); impl->started = false; }
    return ok;
}
#else
struct MovieWriter::Impl {};
MovieWriter::MovieWriter() : impl(new Impl) {}
MovieWriter::~MovieWriter() {}
bool MovieWriter::open(const fs::path&, int w, int h, float, bool, unsigned, std::string& err, bool) {
    W = w; H = h;
    err = "movies are written on Windows only for now";
    return false;
}
bool MovieWriter::write(const uint32_t*, int) { return false; }
bool MovieWriter::writeFloat(const float*, int) { return false; }
bool MovieWriter::finish() { return false; }
#endif
