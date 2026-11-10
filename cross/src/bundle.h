// A scene composed in Blender (the Vintage Click Scene Builder add-on), SceneBundle.swift:
// one .vcscene file, a zip of the scan, its sky, its sounds and scene.json, which says
// how big the scan is, where to stand, what lights stand in it, how bright the house
// lights are, where sounds come from, where the camera may go and where fog lies.
// Positions are in the scan's own units and axes.
#pragma once
#include "fog.h"
#include "json.h"
#include "platform.h"
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

struct SceneBundle {
    std::filesystem::path source, folder;
    Json file;

    static bool isBundle(const std::string& path) {
        std::string e = std::filesystem::u8path(path).extension().u8string();
        for (auto& c : e) c = char(std::tolower((unsigned char)c));
        return e == ".vcscene";
    }
    std::string plyPath() const { return (folder / std::filesystem::u8path(file["splats"].str())).u8string(); }
    std::string name() const { return file.has("name") ? file["name"].str() : source.stem().u8string(); }
    bool place() const { return file["place"].boolean(false); }
    float ev() const { return float(file["ev"].num(place() ? 13 : 12)); }
    float metresPerUnit() const { return float(file["metresPerUnit"].num(0)); }
    std::string path(const std::string& rel) const { return (folder / std::filesystem::u8path(rel)).u8string(); }

    static bool vec(const Json& j, V3& out) {
        auto f = j.floats();
        if (f.size() != 3) return false;
        out = {f[0], f[1], f[2]};
        return true;
    }
    /// A row-major 4x4 from the file (false if malformed or flat), and its inverse.
    static bool matrix(const Json& j, Mat4& toUnit) {
        auto f = j.floats();
        if (f.size() != 16) return false;
        Mat4 M;
        for (int i = 0; i < 16; i++) M.m[i] = f[i];
        return M.inverse(toUnit);
    }
    static bool shape(const std::string& s0, Shape& out) {
        std::string s = s0;
        for (auto& c : s) c = char(std::tolower((unsigned char)c));
        if (s == "box") out = Shape::Box;
        else if (s == "sphere") out = Shape::Sphere;
        else if (s == "cylinder") out = Shape::Cylinder;
        else return false;
        return true;
    }

    /// The caches: unpacked scenes, one folder per version of each file.
    static std::filesystem::path caches() {
        std::filesystem::path base;
        if (const char* l = std::getenv("LOCALAPPDATA")) base = std::filesystem::u8path(l) / "Vintage Click";
        else if (const char* h = std::getenv("HOME")) base = std::filesystem::u8path(h) / ".cache" / "Vintage Click";
        else base = std::filesystem::temp_directory_path() / "Vintage Click";
        return base / "scenes";
    }

    /// Unpacks `path` (or finds it unpacked already) and reads its scene.json.
    static bool open(const std::string& path, SceneBundle& b, std::string& err) {
        namespace fs = std::filesystem;
        std::error_code ec;
        fs::path src = fs::absolute(fs::u8path(path), ec).lexically_normal();
        auto size = fs::file_size(src, ec);
        if (ec) { err = "can't read " + src.filename().u8string(); return false; }
        auto stamp = fs::last_write_time(src, ec).time_since_epoch().count();
        // A key for this version of this file.
        std::string id = src.u8string() + "|" + std::to_string(size) + "|" + std::to_string(stamp);
        uint64_t h = 1469598103934665603ull;
        for (unsigned char c : id) { h ^= c; h *= 1099511628211ull; }
        char key[24];
        snprintf(key, sizeof key, "%016llx", (unsigned long long)h);
        fs::path dir = caches(), folder = dir / key, json = folder / "scene.json";
        if (!fs::exists(json)) {
            // A new version of this file: drop older copies of it, unpack this one.
            fs::create_directories(dir, ec);
            fs::path tmp = dir / (std::string(key) + ".partial");
            fs::remove_all(tmp, ec);
            if (!platform::unzip(src, tmp, err)) { fs::remove_all(tmp, ec); return false; }
            for (auto& d : fs::directory_iterator(dir, ec)) {
                std::ifstream s(d.path() / ".source", std::ios::binary);
                std::string was((std::istreambuf_iterator<char>(s)), std::istreambuf_iterator<char>());
                s.close();
                if (was == src.u8string()) fs::remove_all(d.path(), ec);
            }
            fs::remove_all(folder, ec);
            fs::rename(tmp, folder, ec);
            if (ec) { err = "couldn't keep the unpacked scene"; return false; }
            std::ofstream(folder / ".source", std::ios::binary) << src.u8string();
        }
        std::ifstream in(json, std::ios::binary);
        std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        Json j;
        std::string why;
        if (!Json::parse(text, j, why)) { err = src.filename().u8string() + "'s scene.json isn't readable (" + why + ")"; return false; }
        if (j["format"].str() != "vintage-click-scene") { err = src.filename().u8string() + " isn't a Vintage Click scene"; return false; }
        if (j["version"].num(1) > 1) { err = src.filename().u8string() + " is from a newer Scene Builder: update Vintage Click"; return false; }
        b.source = src;
        b.folder = folder;
        b.file = std::move(j);
        if (b.file["splats"].str().empty() || !fs::exists(fs::u8path(b.plyPath()))) { err = src.filename().u8string() + " has no scan in it"; return false; }
        return true;
    }

    /// The scan's up (unit), if given.
    bool up(V3& u) const { return vec(file["up"], u) && len(u) > 1e-6f && ((u = norm(u)), true); }

    /// The scene's fog: its haze and its patches (empty: clear air).
    SceneFog fog() const {
        SceneFog f;
        const Json& a = file["fog"];
        if (a.kind == Json::Object && a["visibilityM"].num(0) > 0) {
            f.visibilityM = float(a["visibilityM"].num());
            vec(a["colour"], f.tint);
            f.heightFalloffM = std::max(0.f, float(a["heightFalloffM"].num(0)));
            vec(a["base"], f.base);
        }
        for (auto& v : file["fogVolumes"].a) {
            if (int(f.patches.size()) >= SceneFog::maxPatches) break;
            SceneFog::Patch p;
            if (!matrix(v["matrix"], p.toUnit) || !(v["visibilityM"].num(0) > 0)) continue;
            if (!shape(v["shape"].str(), p.shape)) { fprintf(stderr, "Scene: unknown fog shape %s\n", v["shape"].str().c_str()); continue; }
            p.visibilityM = float(v["visibilityM"].num());
            vec(v["colour"], p.tint);
            p.softness = float(v["softness"].num(0.4));
            f.patches.push_back(p);
        }
        return f;
    }

    /// Where the camera may go (no volumes: anywhere).
    MovementBounds bounds() const {
        MovementBounds mb;
        for (auto& v : file["bounds"].a) {
            MovementBounds::Volume vol;
            if (!matrix(v["matrix"], vol.toUnit)) continue;
            if (!shape(v["shape"].str(), vol.shape)) { fprintf(stderr, "Scene: unknown bound shape %s\n", v["shape"].str().c_str()); continue; }
            mb.volumes.push_back(vol);
        }
        return mb;
    }
};
