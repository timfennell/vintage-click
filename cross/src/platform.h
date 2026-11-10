// What the system does for us: unpacking a .vcscene, decoding a scene's sounds (platform.cpp).
#pragma once
#include <filesystem>
#include <string>
#include <vector>

namespace platform {
/// Unpacks the zip at `zip` into `dir` (made if missing); false and `err` on failure.
bool unzip(const std::filesystem::path& zip, const std::filesystem::path& dir, std::string& err);
/// Decodes a sound file (WAV, MP3, M4A / AAC, FLAC...) to interleaved float samples.
bool decodeAudio(const std::filesystem::path& file, std::vector<float>& samples, int& rate, int& channels, std::string& err);
}
