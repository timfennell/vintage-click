// What a camera of the day would have written on the frame, had it had EXIF
// (PhotoMetadata in Exif.swift): the body, the lens and its settings, as the tags
// real files carry, in a PNG's eXIf chunk.
#pragma once
#include "kit.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace exif {

/// A little-endian TIFF structure: IFD0 and the Exif IFD, values past 4 bytes after each.
class Writer {
public:
    enum Type : uint16_t { BYTE = 1, ASCII = 2, SHORT = 3, LONG = 4, RATIONAL = 5, UNDEFINED = 7, SRATIONAL = 10 };
    struct Tag { uint16_t id, type; uint32_t count; std::vector<uint8_t> data; };
    std::vector<Tag> ifd0, sub;

    static Tag ascii(uint16_t id, const std::string& s) {
        Tag t{id, ASCII, uint32_t(s.size() + 1), std::vector<uint8_t>(s.begin(), s.end())};
        t.data.push_back(0);
        return t;
    }
    static Tag shorts(uint16_t id, std::initializer_list<uint16_t> v) {
        Tag t{id, SHORT, uint32_t(v.size()), {}};
        for (uint16_t x : v) { t.data.push_back(uint8_t(x)); t.data.push_back(uint8_t(x >> 8)); }
        return t;
    }
    static void put32(std::vector<uint8_t>& d, uint32_t x) { for (int k = 0; k < 4; k++) d.push_back(uint8_t(x >> (8 * k))); }
    static Tag longs(uint16_t id, uint32_t v) { Tag t{id, LONG, 1, {}}; put32(t.data, v); return t; }
    /// Rationals from doubles (a denominator fit for the value).
    static Tag rationals(uint16_t id, std::initializer_list<double> v, bool sign = false) {
        Tag t{id, uint16_t(sign ? SRATIONAL : RATIONAL), uint32_t(v.size()), {}};
        for (double x : v) {
            uint32_t den = std::fabs(x) < 1 ? 100000 : std::fabs(x) < 1000 ? 1000 : 1;
            if (x > 0 && x < 1 && std::fabs(1 / x - std::round(1 / x)) < 1e-3) { den = uint32_t(std::lround(1 / x)); put32(t.data, 1); put32(t.data, den); continue; }
            put32(t.data, uint32_t(int32_t(std::lround(x * den))));
            put32(t.data, den);
        }
        return t;
    }
    static Tag undefined(uint16_t id, const std::vector<uint8_t>& bytes) { return {id, UNDEFINED, uint32_t(bytes.size()), bytes}; }

    std::vector<uint8_t> bytes() const {
        auto sorted = [](std::vector<Tag> v) { std::sort(v.begin(), v.end(), [](const Tag& a, const Tag& b) { return a.id < b.id; }); return v; };
        std::vector<Tag> a = sorted(ifd0), b = sorted(sub);
        // IFD0 carries a pointer to the Exif IFD (34665), its offset filled in below.
        a.push_back({34665, LONG, 1, {0, 0, 0, 0}});
        a = sorted(a);
        auto ifdSize = [](const std::vector<Tag>& v) {
            size_t n = 2 + v.size() * 12 + 4;
            for (auto& t : v) if (t.data.size() > 4) n += (t.data.size() + 1) & ~size_t(1);
            return n;
        };
        uint32_t off0 = 8, offSub = uint32_t(off0 + ifdSize(a));
        for (auto& t : a) if (t.id == 34665) { t.data.clear(); put32(t.data, offSub); }
        std::vector<uint8_t> out = {'I', 'I', 42, 0};
        put32(out, off0);
        auto write = [&](const std::vector<Tag>& v, uint32_t base) {
            uint32_t extra = base + 2 + uint32_t(v.size()) * 12 + 4;
            std::vector<uint8_t> tail;
            out.push_back(uint8_t(v.size())); out.push_back(uint8_t(v.size() >> 8));
            for (auto& t : v) {
                out.push_back(uint8_t(t.id)); out.push_back(uint8_t(t.id >> 8));
                out.push_back(uint8_t(t.type)); out.push_back(uint8_t(t.type >> 8));
                put32(out, t.count);
                if (t.data.size() <= 4) {
                    std::vector<uint8_t> d = t.data;
                    d.resize(4, 0);
                    out.insert(out.end(), d.begin(), d.end());
                } else {
                    put32(out, extra + uint32_t(tail.size()));
                    tail.insert(tail.end(), t.data.begin(), t.data.end());
                    if (tail.size() % 2) tail.push_back(0);
                }
            }
            put32(out, 0);   // no next IFD
            out.insert(out.end(), tail.begin(), tail.end());
        };
        write(a, off0);
        write(b, offSub);
        return out;
    }
};

/// "2026:10:19 14:05:33", EXIF's own date form.
inline std::string date(std::time_t t) {
    char b[32];
    std::tm tm{};
#if defined(_WIN32)
    localtime_s(&tm, &t);
#else
    localtime_r(&t, &tm);
#endif
    std::strftime(b, sizeof b, "%Y:%m:%d %H:%M:%S", &tm);
    return b;
}

/// The tags for a print: the body, the lens and its settings; the film and filter in the comment.
inline std::vector<uint8_t> forPrint(const CameraBody& b, std::time_t shotAt, const std::string& description, const std::string& software) {
    const Lens& l = b.lens();
    double n = b.takingAperture(), t = b.shutter().seconds;
    std::string when = date(shotAt);
    Writer w;
    w.ifd0 = {Writer::ascii(270, description), Writer::ascii(271, b.model().make), Writer::ascii(272, b.model().model),
              Writer::shorts(274, {1}), Writer::ascii(305, software), Writer::ascii(306, when)};
    std::string notes = b.model().fullName() + " (" + std::to_string(b.model().year) + ") - " + b.rollName();
    if (b.filterIndex != 0) notes += " - filter: " + b.filter().name;
    std::vector<uint8_t> comment = {'A', 'S', 'C', 'I', 'I', 0, 0, 0};
    comment.insert(comment.end(), notes.begin(), notes.end());
    std::string lensMake = l.name.substr(0, l.name.find(' '));
    w.sub = {Writer::rationals(33434, {t}), Writer::rationals(33437, {n}), Writer::shorts(34850, {1}),
             Writer::shorts(34855, {uint16_t(std::min(65535.f, std::round(b.ratedEI())))}), Writer::shorts(34864, {3}),
             Writer::undefined(36864, {'0', '2', '3', '2'}), Writer::ascii(36867, when), Writer::ascii(36868, when),
             Writer::rationals(37377, {-std::log2(t)}, true), Writer::rationals(37378, {2 * std::log2(n)}),
             Writer::rationals(37381, {2 * std::log2(double(l.maxAperture))}), Writer::rationals(37382, {double(b.focusM)}),
             Writer::shorts(37383, {2}), Writer::shorts(37385, {0}), Writer::rationals(37386, {double(l.focalMM)}),
             Writer::undefined(37510, comment), Writer::undefined(41728, {1}), Writer::shorts(41985, {1}),
             Writer::shorts(41989, {uint16_t(std::lround(l.focalMM))}), Writer::ascii(42033, b.model().serial),
             Writer::rationals(42034, {double(l.focalMM), double(l.focalMM), double(l.maxAperture), double(l.maxAperture)}),
             Writer::ascii(42035, lensMake), Writer::ascii(42036, l.name)};
    return w.bytes();
}

inline uint32_t crc32(const uint8_t* p, size_t n, uint32_t c = 0xffffffffu) {
    static uint32_t table[256];
    static bool made = false;
    if (!made) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t v = i;
            for (int k = 0; k < 8; k++) v = v & 1 ? 0xedb88320u ^ (v >> 1) : v >> 1;
            table[i] = v;
        }
        made = true;
    }
    for (size_t i = 0; i < n; i++) c = table[(c ^ p[i]) & 255] ^ (c >> 8);
    return c;
}

/// A PNG file's bytes with an eXIf chunk put in after its header.
inline std::vector<uint8_t> withExif(const uint8_t* png, size_t size, const std::vector<uint8_t>& tiff) {
    std::vector<uint8_t> out(png, png + size);
    if (size < 33) return out;
    size_t at = 8 + 8 + 13 + 4;   // signature, IHDR's length, type, data, CRC
    std::vector<uint8_t> chunk;
    uint32_t len = uint32_t(tiff.size());
    for (int k = 3; k >= 0; k--) chunk.push_back(uint8_t(len >> (8 * k)));
    const char* type = "eXIf";
    chunk.insert(chunk.end(), type, type + 4);
    chunk.insert(chunk.end(), tiff.begin(), tiff.end());
    uint32_t crc = crc32(chunk.data() + 4, chunk.size() - 4) ^ 0xffffffffu;
    for (int k = 3; k >= 0; k--) chunk.push_back(uint8_t(crc >> (8 * k)));
    out.insert(out.begin() + std::ptrdiff_t(at), chunk.begin(), chunk.end());
    return out;
}

}  // namespace exif

namespace dng {

/// Writes a digital negative (DNG.swift): a DNG 1.4 "LinearRaw" image (already RGB, no
/// mosaic) of 16-bit floating-point linear light, so highlights past white survive for
/// the raw developer. Its colour matrix says the RGB is linear Rec.709 / sRGB under D65.
/// `pixels`: width x height x 3 half floats (little-endian).
inline bool write(const std::string& path, const std::vector<uint16_t>& pixels, int width, int height,
                  const std::string& description, const CameraBody& b, std::time_t shotAt, const std::string& software) {
    using W = exif::Writer;
    const Lens& lens = b.lens();
    double n = b.takingAperture(), t = b.shutter().seconds, f = lens.focalMM;
    std::string when = exif::date(shotAt);
    uint32_t imageBytes = uint32_t(width) * uint32_t(height) * 6;
    std::vector<W::Tag> ifd = {
        W::longs(254, 0), W::longs(256, uint32_t(width)), W::longs(257, uint32_t(height)), W::shorts(258, {16, 16, 16}),
        W::shorts(259, {1}), W::shorts(262, {34892}), W::ascii(270, description), W::ascii(271, b.model().make),
        W::ascii(272, b.model().model), W::longs(273, 8), W::shorts(274, {1}), W::shorts(277, {3}), W::longs(278, uint32_t(height)),
        W::longs(279, imageBytes), W::shorts(284, {1}), W::ascii(305, software), W::ascii(306, when), W::shorts(339, {3, 3, 3}),
        W::rationals(33434, {t}), W::rationals(33437, {n}), W::shorts(34850, {1}),
        W::shorts(34855, {uint16_t(std::clamp(std::round(b.ratedEI()), 1.f, 65535.f))}), W::ascii(36867, when),
        W::rationals(37377, {-std::log2(t)}, true), W::rationals(37378, {2 * std::log2(n)}),
        W::rationals(37381, {2 * std::log2(double(lens.maxAperture))}), W::rationals(37382, {double(b.focusM)}),
        W::shorts(37383, {2}), W::rationals(37386, {f}), W::shorts(41989, {uint16_t(std::lround(f))}),
        W::ascii(42033, b.model().serial), W::rationals(42034, {f, f, double(lens.maxAperture), double(lens.maxAperture)}),
        W::ascii(42035, lens.name.substr(0, lens.name.find(' '))), W::ascii(42036, lens.name),
        W::Tag{50706, W::BYTE, 4, {1, 4, 0, 0}}, W::Tag{50707, W::BYTE, 4, {1, 4, 0, 0}}, W::ascii(50708, b.model().fullName()),
        W::longs(50717, 1),   // WhiteLevel: 1.0 is white for float data (brighter is kept)
        W::rationals(50721, {3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570}, true),
        W::rationals(50728, {1, 1, 1}), W::rationals(50730, {0}, true), W::ascii(50735, b.model().serial),
        W::rationals(50736, {f, f, double(lens.maxAperture), double(lens.maxAperture)}), W::shorts(50778, {21})};
    // WhiteLevel is 3 values on the Mac (one per sample): repeat it.
    for (auto& tg : ifd) if (tg.id == 50717) { tg.count = 3; tg.data.clear(); for (int k = 0; k < 3; k++) W::put32(tg.data, 1); }
    std::sort(ifd.begin(), ifd.end(), [](const W::Tag& a, const W::Tag& b2) { return a.id < b2.id; });
    // Layout: header (8) | image data | IFD | values that do not fit in 4 bytes.
    uint32_t ifdOffset = 8 + imageBytes + (imageBytes % 2);
    uint32_t ifdSize = 2 + uint32_t(ifd.size()) * 12 + 4;
    std::vector<uint8_t> entries, extra;
    entries.push_back(uint8_t(ifd.size())); entries.push_back(uint8_t(ifd.size() >> 8));
    for (auto& e : ifd) {
        entries.push_back(uint8_t(e.id)); entries.push_back(uint8_t(e.id >> 8));
        entries.push_back(uint8_t(e.type)); entries.push_back(uint8_t(e.type >> 8));
        W::put32(entries, e.count);
        if (e.data.size() <= 4) {
            std::vector<uint8_t> d = e.data;
            d.resize(4, 0);
            entries.insert(entries.end(), d.begin(), d.end());
        } else {
            W::put32(entries, ifdOffset + ifdSize + uint32_t(extra.size()));
            extra.insert(extra.end(), e.data.begin(), e.data.end());
            if (extra.size() % 2) extra.push_back(0);
        }
    }
    W::put32(entries, 0);
    std::ofstream o(std::filesystem::u8path(path), std::ios::binary);
    if (!o) return false;
    std::vector<uint8_t> head = {'I', 'I', 42, 0};
    W::put32(head, ifdOffset);
    o.write(reinterpret_cast<const char*>(head.data()), 8);
    o.write(reinterpret_cast<const char*>(pixels.data()), std::streamsize(imageBytes));
    if (imageBytes % 2) o.put(0);
    o.write(reinterpret_cast<const char*>(entries.data()), std::streamsize(entries.size()));
    o.write(reinterpret_cast<const char*>(extra.data()), std::streamsize(extra.size()));
    return bool(o);
}

}  // namespace dng
