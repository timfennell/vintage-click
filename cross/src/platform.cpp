// Unpacking a .vcscene and decoding its sounds: Windows' own tar (it reads zips)
// and Media Foundation's source reader.
#include "platform.h"
#include <cstring>

#if defined(_WIN32)
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>

namespace platform {

bool unzip(const std::filesystem::path& zip, const std::filesystem::path& dir, std::string& err) {
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    wchar_t sys[MAX_PATH];
    GetSystemDirectoryW(sys, MAX_PATH);
    std::wstring tar = std::wstring(sys) + L"\\tar.exe";
    std::wstring cmd = L"\"" + tar + L"\" -xf \"" + zip.wstring() + L"\" -C \"" + dir.wstring() + L"\"";
    STARTUPINFOW si{};
    si.cb = sizeof si;
    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> line(cmd.begin(), cmd.end());
    line.push_back(0);
    if (!CreateProcessW(tar.c_str(), line.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        err = "couldn't run tar to unpack it";
        return false;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    if (code != 0) { err = "couldn't unpack it (is it a zip?)"; return false; }
    return true;
}

bool decodeAudio(const std::filesystem::path& file, std::vector<float>& samples, int& rate, int& channels, std::string& err) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) { err = "Media Foundation didn't start"; return false; }
    bool ok = false;
    IMFSourceReader* reader = nullptr;
    IMFMediaType* want = nullptr;
    IMFMediaType* got = nullptr;
    do {
        if (FAILED(MFCreateSourceReaderFromURL(file.wstring().c_str(), nullptr, &reader))) { err = "can't read it"; break; }
        reader->SetStreamSelection(DWORD(MF_SOURCE_READER_ALL_STREAMS), FALSE);
        reader->SetStreamSelection(DWORD(MF_SOURCE_READER_FIRST_AUDIO_STREAM), TRUE);
        MFCreateMediaType(&want);
        want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        want->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
        if (FAILED(reader->SetCurrentMediaType(DWORD(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr, want))) { err = "no audio decoder for it"; break; }
        if (FAILED(reader->GetCurrentMediaType(DWORD(MF_SOURCE_READER_FIRST_AUDIO_STREAM), &got))) { err = "unknown audio format"; break; }
        UINT32 r = 0, c = 0;
        got->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &r);
        got->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &c);
        if (!r || !c) { err = "unknown audio format"; break; }
        rate = int(r);
        channels = int(c);
        samples.clear();
        for (;;) {
            DWORD flags = 0;
            IMFSample* s = nullptr;
            if (FAILED(reader->ReadSample(DWORD(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, nullptr, &flags, nullptr, &s))) break;
            if (s) {
                IMFMediaBuffer* buf = nullptr;
                if (SUCCEEDED(s->ConvertToContiguousBuffer(&buf))) {
                    BYTE* p = nullptr;
                    DWORD n = 0;
                    if (SUCCEEDED(buf->Lock(&p, nullptr, &n))) {
                        size_t k = samples.size();
                        samples.resize(k + n / sizeof(float));
                        std::memcpy(samples.data() + k, p, n / sizeof(float) * sizeof(float));
                        buf->Unlock();
                    }
                    buf->Release();
                }
                s->Release();
            }
            if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
        }
        ok = !samples.empty();
        if (!ok) err = "no sound in it";
    } while (false);
    if (got) got->Release();
    if (want) want->Release();
    if (reader) reader->Release();
    MFShutdown();
    return ok;
}

}  // namespace platform
#else
#include <cstdlib>
namespace platform {
bool unzip(const std::filesystem::path& zip, const std::filesystem::path& dir, std::string& err) {
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    std::string cmd = "unzip -q -o '" + zip.string() + "' -d '" + dir.string() + "'";
    if (std::system(cmd.c_str()) != 0) { err = "couldn't unpack it"; return false; }
    return true;
}
bool decodeAudio(const std::filesystem::path&, std::vector<float>&, int&, int&, std::string& err) {
    err = "scene sounds are read on Windows only for now";
    return false;
}
}  // namespace platform
#endif
