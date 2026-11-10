// A small JSON reader: enough for a .vcscene's scene.json.
#pragma once
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <vector>

struct Json {
    enum Kind { Null, Bool, Number, String, Array, Object } kind = Null;
    bool b = false;
    double n = 0;
    std::string s;
    std::vector<Json> a;
    std::map<std::string, Json> o;

    bool has(const std::string& k) const { return kind == Object && o.count(k) && o.at(k).kind != Null; }
    const Json& operator[](const std::string& k) const {
        static const Json none;
        auto it = o.find(k);
        return kind == Object && it != o.end() ? it->second : none;
    }
    double num(double d = 0) const { return kind == Number ? n : d; }
    std::string str(const std::string& d = "") const { return kind == String ? s : d; }
    bool boolean(bool d = false) const { return kind == Bool ? b : d; }
    /// Numbers of an array (empty if it isn't one).
    std::vector<float> floats() const {
        std::vector<float> v;
        if (kind == Array) for (auto& x : a) if (x.kind == Number) v.push_back(float(x.n));
        return v;
    }

    /// Parses `text`; false (and `err`) when it isn't JSON.
    static bool parse(const std::string& text, Json& out, std::string& err) {
        size_t i = 0;
        if (text.size() >= 3 && (unsigned char)text[0] == 0xEF && (unsigned char)text[1] == 0xBB && (unsigned char)text[2] == 0xBF) i = 3;
        if (!value(text, i, out, err, 0)) return false;
        ws(text, i);
        if (i != text.size()) { err = "trailing characters"; return false; }
        return true;
    }

private:
    static void ws(const std::string& t, size_t& i) {
        while (i < t.size() && (t[i] == ' ' || t[i] == '\t' || t[i] == '\n' || t[i] == '\r')) i++;
    }
    static void utf8(std::string& out, unsigned cp) {
        if (cp < 0x80) out += char(cp);
        else if (cp < 0x800) { out += char(0xC0 | cp >> 6); out += char(0x80 | (cp & 0x3F)); }
        else if (cp < 0x10000) { out += char(0xE0 | cp >> 12); out += char(0x80 | (cp >> 6 & 0x3F)); out += char(0x80 | (cp & 0x3F)); }
        else { out += char(0xF0 | cp >> 18); out += char(0x80 | (cp >> 12 & 0x3F)); out += char(0x80 | (cp >> 6 & 0x3F)); out += char(0x80 | (cp & 0x3F)); }
    }
    static bool string(const std::string& t, size_t& i, std::string& out, std::string& err) {
        i++;   // the opening quote
        while (i < t.size() && t[i] != '"') {
            char c = t[i++];
            if (c != '\\') { out += c; continue; }
            if (i >= t.size()) break;
            char e = t[i++];
            switch (e) {
            case 'n': out += '\n'; break;
            case 't': out += '\t'; break;
            case 'r': out += '\r'; break;
            case 'b': out += '\b'; break;
            case 'f': out += '\f'; break;
            case 'u': {
                if (i + 4 > t.size()) { err = "bad escape"; return false; }
                unsigned cp = unsigned(std::strtoul(t.substr(i, 4).c_str(), nullptr, 16));
                i += 4;
                if (cp >= 0xD800 && cp < 0xDC00 && i + 6 <= t.size() && t[i] == '\\' && t[i + 1] == 'u') {
                    unsigned lo = unsigned(std::strtoul(t.substr(i + 2, 4).c_str(), nullptr, 16));
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 6;
                }
                utf8(out, cp);
                break;
            }
            default: out += e;
            }
        }
        if (i >= t.size()) { err = "unterminated string"; return false; }
        i++;
        return true;
    }
    static bool value(const std::string& t, size_t& i, Json& v, std::string& err, int depth) {
        if (depth > 64) { err = "nested too deep"; return false; }
        ws(t, i);
        if (i >= t.size()) { err = "unexpected end"; return false; }
        char c = t[i];
        if (c == '{') {
            v.kind = Object;
            i++;
            ws(t, i);
            if (i < t.size() && t[i] == '}') { i++; return true; }
            for (;;) {
                ws(t, i);
                if (i >= t.size() || t[i] != '"') { err = "expected a key"; return false; }
                std::string k;
                if (!string(t, i, k, err)) return false;
                ws(t, i);
                if (i >= t.size() || t[i] != ':') { err = "expected ':'"; return false; }
                i++;
                Json x;
                if (!value(t, i, x, err, depth + 1)) return false;
                v.o[k] = std::move(x);
                ws(t, i);
                if (i < t.size() && t[i] == ',') { i++; continue; }
                if (i < t.size() && t[i] == '}') { i++; return true; }
                err = "expected ',' or '}'";
                return false;
            }
        }
        if (c == '[') {
            v.kind = Array;
            i++;
            ws(t, i);
            if (i < t.size() && t[i] == ']') { i++; return true; }
            for (;;) {
                Json x;
                if (!value(t, i, x, err, depth + 1)) return false;
                v.a.push_back(std::move(x));
                ws(t, i);
                if (i < t.size() && t[i] == ',') { i++; continue; }
                if (i < t.size() && t[i] == ']') { i++; return true; }
                err = "expected ',' or ']'";
                return false;
            }
        }
        if (c == '"') { v.kind = String; return string(t, i, v.s, err); }
        if (t.compare(i, 4, "true") == 0) { v.kind = Bool; v.b = true; i += 4; return true; }
        if (t.compare(i, 5, "false") == 0) { v.kind = Bool; v.b = false; i += 5; return true; }
        if (t.compare(i, 4, "null") == 0) { v.kind = Null; i += 4; return true; }
        const char* start = t.c_str() + i;
        char* end = nullptr;
        double d = std::strtod(start, &end);
        if (end == start) { err = "unexpected character"; return false; }
        v.kind = Number;
        v.n = d;
        i += size_t(end - start);
        return true;
    }
};
