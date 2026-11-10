// Vintage Click, cross-platform: a small 2D kit over an RGBA canvas: shapes,
// glowing projected-light text (the finder's and menus' lettering), and
// seven-segment LEDs.
#pragma once
#include <filesystem>
#include <fstream>
#include <iterator>
#include "kit.h"
#include "stb_truetype.h"
#include <cstdint>
#include <map>
#include <string>

struct RGBA { float r, g, b, a; };

struct Canvas {
    int w = 0, h = 0;
    std::vector<uint32_t> px;    // 0xAABBGGRR (little-endian RGBA bytes)

    void resize(int W, int H) { w = W; h = H; px.assign(size_t(W) * H, 0xff000000u); }
    void blend(int x, int y, RGBA c, float cover) {
        if (x < 0 || y < 0 || x >= w || y >= h || cover <= 0) return;
        float a = std::min(1.f, c.a * cover);
        uint32_t& d = px[size_t(y) * w + x];
        float dr = (d & 255) / 255.f, dg = ((d >> 8) & 255) / 255.f, db = ((d >> 16) & 255) / 255.f;
        dr += (c.r - dr) * a; dg += (c.g - dg) * a; db += (c.b - db) * a;
        d = 0xff000000u | uint32_t(std::clamp(dr, 0.f, 1.f) * 255 + 0.5f) |
            uint32_t(std::clamp(dg, 0.f, 1.f) * 255 + 0.5f) << 8 | uint32_t(std::clamp(db, 0.f, 1.f) * 255 + 0.5f) << 16;
    }
    /// Light added (projected markings, LEDs, glows).
    void add(int x, int y, RGBA c, float cover) {
        if (x < 0 || y < 0 || x >= w || y >= h || cover <= 0) return;
        uint32_t& d = px[size_t(y) * w + x];
        float k = c.a * cover;
        float dr = (d & 255) / 255.f + c.r * k, dg = ((d >> 8) & 255) / 255.f + c.g * k, db = ((d >> 16) & 255) / 255.f + c.b * k;
        d = 0xff000000u | uint32_t(std::min(dr, 1.f) * 255 + 0.5f) | uint32_t(std::min(dg, 1.f) * 255 + 0.5f) << 8 |
            uint32_t(std::min(db, 1.f) * 255 + 0.5f) << 16;
    }
    void rect(float x0, float y0, float x1, float y1, RGBA c) {
        for (int y = std::max(0, int(y0)); y < std::min(h, int(std::ceil(y1))); y++)
            for (int x = std::max(0, int(x0)); x < std::min(w, int(std::ceil(x1))); x++) blend(x, y, c, 1);
    }
    /// Rounded rectangle, antialiased.
    void roundRect(float x0, float y0, float x1, float y1, float rad, RGBA c, bool additive = false) {
        for (int y = std::max(0, int(y0) - 1); y < std::min(h, int(y1) + 2); y++)
            for (int x = std::max(0, int(x0) - 1); x < std::min(w, int(x1) + 2); x++) {
                float px_ = x + 0.5f, py_ = y + 0.5f;
                float qx = std::fabs(px_ - (x0 + x1) / 2) - ((x1 - x0) / 2 - rad);
                float qy = std::fabs(py_ - (y0 + y1) / 2) - ((y1 - y0) / 2 - rad);
                float d = std::sqrt(std::max(qx, 0.f) * std::max(qx, 0.f) + std::max(qy, 0.f) * std::max(qy, 0.f)) +
                          std::min(std::max(qx, qy), 0.f) - rad;
                float cover = std::clamp(0.5f - d, 0.f, 1.f);
                if (additive) add(x, y, c, cover); else blend(x, y, c, cover);
            }
    }
    /// A thick line, antialiased, optionally with a soft glow.
    void line(V2 a, V2 b, float width, RGBA c, float glow = 0, bool additive = false) {
        float pad = width + glow * 3 + 2;
        int xa = int(std::min(a.x, b.x) - pad), xb = int(std::max(a.x, b.x) + pad);
        int ya = int(std::min(a.y, b.y) - pad), yb = int(std::max(a.y, b.y) + pad);
        V2 ab = b - a; float L2 = std::max(ab.x * ab.x + ab.y * ab.y, 1e-6f);
        for (int y = std::max(0, ya); y < std::min(h, yb); y++)
            for (int x = std::max(0, xa); x < std::min(w, xb); x++) {
                V2 p{x + 0.5f, y + 0.5f};
                float t = std::clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / L2, 0.f, 1.f);
                float d = len(p - (a + ab * t));
                float cover = std::clamp(width / 2 + 0.5f - d, 0.f, 1.f);
                if (glow > 0) cover = std::max(cover, 0.25f * std::exp(-d * d / (2 * glow * glow)));
                if (additive) add(x, y, c, cover); else blend(x, y, c, cover);
            }
    }
    void circle(V2 c, float r, float width, RGBA col) {
        for (int y = std::max(0, int(c.y - r - width - 2)); y < std::min(h, int(c.y + r + width + 2)); y++)
            for (int x = std::max(0, int(c.x - r - width - 2)); x < std::min(w, int(c.x + r + width + 2)); x++) {
                float d = std::fabs(len(V2{x + 0.5f, y + 0.5f} - c) - r);
                blend(x, y, col, std::clamp(width / 2 + 0.5f - d, 0.f, 1.f));
            }
    }
};

/// Text from a bundled font, glowing a little as projected light does.
struct Font {
    std::vector<unsigned char> data;
    stbtt_fontinfo info{};
    bool ok = false;
    struct Glyph {
        int w, h, xoff, yoff; float advance; std::vector<unsigned char> bmp;
        int pad = -1; float haloBlur = 0; std::vector<float> halo;   // the glow: coverage blurred, padded by `pad` each side
    };
    std::map<std::pair<int, int>, Glyph> cache;   // (codepoint, pixel size)

    bool load(const std::string& path) {
        std::ifstream f(std::filesystem::u8path(path), std::ios::binary);
        if (!f) return false;
        data.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
        if (data.empty()) return false;
        ok = stbtt_InitFont(&info, data.data(), stbtt_GetFontOffsetForIndex(data.data(), 0)) != 0;
        return ok;
    }
    /// `size` is a point size, as the Mac's fonts take it: the em, not the whole line.
    float scaleFor(int size) const { return stbtt_ScaleForMappingEmToPixels(&info, float(size)); }
    Glyph& glyph(int cp, int size) {
        auto key = std::make_pair(cp, size);
        auto it = cache.find(key);
        if (it != cache.end()) return it->second;
        Glyph g{};
        float s = scaleFor(size);
        int adv, lsb; stbtt_GetCodepointHMetrics(&info, cp, &adv, &lsb);
        g.advance = adv * s;
        bool missing = stbtt_FindGlyphIndex(&info, cp) == 0;
        if (missing && (cp == 0x25B6 || cp == 0x25C0 || cp == 0x25B2 || cp == 0x25BC || cp == 0x25CF || cp == 0x25C9)) {
            // The marks the menus use (▶ ◀ ▲ ▼ ● ◉), drawn when the font has none: 4 x 4 samples a pixel.
            int n = std::max(3, int(size * 0.62f));
            g.w = g.h = n;
            g.xoff = int(size * 0.06f);
            int asc, desc, gap; stbtt_GetFontVMetrics(&info, &asc, &desc, &gap);
            g.yoff = -int(asc * s * 0.72f);
            g.advance = n + size * 0.18f;
            g.bmp.assign(size_t(n) * n, 0);
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++) {
                    int c = 0;
                    for (int sy = 0; sy < 4; sy++)
                        for (int sx = 0; sx < 4; sx++) {
                            float u = (x + (sx + 0.5f) / 4) / n, v = (y + (sy + 0.5f) / 4) / n;
                            bool in = false;
                            float r = std::sqrt((u - 0.5f) * (u - 0.5f) + (v - 0.5f) * (v - 0.5f));
                            if (cp == 0x25B6) in = u >= 0.1f && std::fabs(v - 0.5f) <= 0.45f * (1 - (u - 0.1f) / 0.85f);
                            if (cp == 0x25C0) in = u <= 0.9f && std::fabs(v - 0.5f) <= 0.45f * (1 - (0.9f - u) / 0.85f);
                            if (cp == 0x25B2) in = v <= 0.9f && std::fabs(u - 0.5f) <= 0.45f * (1 - (0.9f - v) / 0.85f);
                            if (cp == 0x25BC) in = v >= 0.1f && std::fabs(u - 0.5f) <= 0.45f * (1 - (v - 0.1f) / 0.85f);
                            if (cp == 0x25CF) in = r <= 0.32f;
                            if (cp == 0x25C9) in = r <= 0.2f || (r >= 0.36f && r <= 0.47f);
                            c += in;
                        }
                    g.bmp[size_t(y) * n + x] = (unsigned char)(c * 255 / 16);
                }
            return cache.emplace(key, std::move(g)).first->second;
        }
        unsigned char* b = stbtt_GetCodepointBitmap(&info, s, s, cp, &g.w, &g.h, &g.xoff, &g.yoff);
        if (b) { g.bmp.assign(b, b + size_t(g.w) * g.h); stbtt_FreeBitmap(b, nullptr); }
        return cache.emplace(key, std::move(g)).first->second;
    }
    /// The glyph's glow (ViewfinderHUD's text shadow: blurred to about 0.45 x the size), made once.
    void makeHalo(Glyph& g, int size, float blur) {
        if (g.pad >= 0 && std::fabs(g.haloBlur - blur) < 1e-4f) return;
        g.haloBlur = blur;
        float sigma = std::max(0.5f, size * blur / 2);
        int pad = int(std::ceil(sigma * 2.5f));
        int W = g.w + 2 * pad, H = g.h + 2 * pad;
        std::vector<float> a(size_t(W) * H, 0.f), t(size_t(W) * H, 0.f);
        for (int y = 0; y < g.h; y++)
            for (int x = 0; x < g.w; x++) a[size_t(y + pad) * W + x + pad] = g.bmp[size_t(y) * g.w + x] / 255.f;
        std::vector<float> k(2 * pad + 1);
        float ks = 0;
        for (int i = -pad; i <= pad; i++) { k[i + pad] = std::exp(-0.5f * i * i / (sigma * sigma)); ks += k[i + pad]; }
        for (auto& v : k) v /= ks;
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                float sum = 0;
                for (int i = -pad; i <= pad; i++) { int xx = x + i; if (xx >= 0 && xx < W) sum += a[size_t(y) * W + xx] * k[i + pad]; }
                t[size_t(y) * W + x] = sum;
            }
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                float sum = 0;
                for (int i = -pad; i <= pad; i++) { int yy = y + i; if (yy >= 0 && yy < H) sum += t[size_t(yy) * W + x] * k[i + pad]; }
                a[size_t(y) * W + x] = sum;
            }
        g.halo = std::move(a);
        g.pad = pad;
    }
    static std::vector<int> codepoints(const std::string& s) {
        std::vector<int> out;
        for (size_t i = 0; i < s.size();) {
            unsigned char c = s[i];
            int cp, n;
            if (c < 0x80) { cp = c; n = 1; }
            else if ((c >> 5) == 6) { cp = c & 31; n = 2; }
            else if ((c >> 4) == 14) { cp = c & 15; n = 3; }
            else { cp = c & 7; n = 4; }
            for (int k = 1; k < n && i + k < s.size(); k++) cp = (cp << 6) | (s[i + k] & 63);
            out.push_back(cp); i += n;
        }
        return out;
    }
    float width(const std::string& s, int size) {
        if (!ok) return 0;
        float x = 0;
        for (int cp : codepoints(s)) x += glyph(cp, size).advance;
        return x;
    }
    /// Draws text with its top-left at (x, y). `glow` > 0: projected light, as the
    /// Mac's finder and menus letter it: a soft shadow in the text's own colour
    /// (0.55 of it, blurred to about 0.45 x the size) under the letters.
    void draw(Canvas& cv, const std::string& s, float x, float y, int size, RGBA c, float glow = 0.45f, float shadowAlpha = 0.55f) {
        if (!ok || size < 1) return;
        float scale = scaleFor(size);
        int asc, desc, gap; stbtt_GetFontVMetrics(&info, &asc, &desc, &gap);
        float base = y + asc * scale;
        auto cps = codepoints(s);
        if (glow > 0) {
            float gx0 = x;
            RGBA shadow{c.r, c.g, c.b, c.a * shadowAlpha};
            for (int cp : cps) {
                Glyph& g = glyph(cp, size);
                makeHalo(g, size, glow);
                int W = g.w + 2 * g.pad, H = g.h + 2 * g.pad;
                int ox = int(gx0 + g.xoff) - g.pad, oy = int(base + g.yoff) - g.pad;
                for (int yy = 0; yy < H; yy++)
                    for (int xx = 0; xx < W; xx++) {
                        float v = g.halo[size_t(yy) * W + xx];
                        if (v > 0.004f) cv.blend(ox + xx, oy + yy, shadow, v);
                    }
                gx0 += g.advance;
            }
        }
        for (int cp : cps) {
            const Glyph& g = glyph(cp, size);
            int gx = int(x + g.xoff), gy = int(base + g.yoff);
            for (int yy = 0; yy < g.h; yy++)
                for (int xx = 0; xx < g.w; xx++) cv.blend(gx + xx, gy + yy, c, g.bmp[size_t(yy) * g.w + xx] / 255.f);
            x += g.advance;
        }
    }
};

/// Seven-segment digits in fixed cells, right-aligned, unlit segments faint.
inline float drawLED(Canvas& cv, const std::string& text, float x0, float y0, float h, int cells) {
    static const std::map<char, const char*> segs = {
        {'0', "abcdef"}, {'1', "bc"}, {'2', "abdeg"}, {'3', "abcdg"}, {'4', "bcfg"}, {'5', "acdfg"}, {'6', "acdefg"},
        {'7', "abc"}, {'8', "abcdefg"}, {'9', "abcdfg"}, {'-', "g"}, {'F', "aefg"}, {'E', "adefg"}};
    std::vector<std::pair<char, bool>> glyphs;
    for (char ch : text) {
        if (ch == '.') { if (glyphs.empty()) glyphs.push_back({' ', true}); else glyphs.back().second = true; }
        else glyphs.push_back({ch, false});
    }
    if (int(glyphs.size()) > cells) glyphs.erase(glyphs.begin(), glyphs.end() - cells);
    glyphs.insert(glyphs.begin(), size_t(cells - int(glyphs.size())), {' ', false});
    float w = h * 0.52f, t = h * 0.11f, slant = h * 0.12f;
    RGBA lit{0.92f, 0.29f, 0.19f, 1}, ghost{0.92f, 0.29f, 0.19f, 0.07f};   // the Mac's calibrated (1, 0.12, 0.10) as it shows
    for (int k = 0; k < cells; k++) {
        float x = x0 + k * w * 1.45f;
        auto pt = [&](float fx, float fy) { return V2{x + fx * w + (1 - fy) * slant, y0 + fy * h}; };
        struct S { char n; V2 a, b; };
        S all[7] = {{'a', pt(0, 0), pt(1, 0)}, {'b', pt(1, 0), pt(1, 0.5f)}, {'c', pt(1, 0.5f), pt(1, 1)},
                    {'d', pt(0, 1), pt(1, 1)}, {'e', pt(0, 0.5f), pt(0, 1)}, {'f', pt(0, 0), pt(0, 0.5f)},
                    {'g', pt(0, 0.5f), pt(1, 0.5f)}};
        auto it = segs.find(glyphs[k].first);
        std::string on = it == segs.end() ? "" : it->second;
        for (auto& sg : all) {
            V2 d = sg.b - sg.a; float L = len(d);
            V2 u = d * (t * 0.7f / std::max(L, 1e-3f));
            bool isOn = on.find(sg.n) != std::string::npos;
            cv.line(sg.a + u, sg.b - u, t, isOn ? lit : ghost, isOn ? t * 0.9f : 0, isOn);
        }
        V2 dot{x + w * 1.08f + t * 0.5f, y0 + h - t * 0.5f};
        cv.line(dot, dot, t * 1.1f, glyphs[k].second ? lit : ghost, glyphs[k].second ? t : 0, glyphs[k].second);
    }
    return x0 + cells * w * 1.45f;
}
