import CryptoKit
import Foundation
import simd

/// A scene composed in Blender (the Vintage Click Scene Builder add-on): one
/// .vcscene file, a zip of the scan, its sky, its sounds and scene.json, which
/// says how big the scan is, where to stand, what lights stand in it, how
/// bright the house lights are and where sounds come from. Positions are in the
/// scan's own units and axes.
struct SceneFile: Codable {
    struct Start: Codable {
        var position: [Float]
        var forward: [Float]
        var focalMM: Float?
    }
    struct Sky: Codable {
        var file: String
        var yawDegrees: Float?
        var stops: Float?
    }
    struct Light: Codable {
        var head: String
        var position: [Float]
        var aim: [Float]
        var spot: Float?
        var dimmerStops: Float?
        var gel: String?
        var modifier: String?
        var patternFocus: Float?
        var flare: Bool?
    }
    struct Sound: Codable {
        var file: String
        var position: [Float]
        var volume: Float?
        var fullWithinM: Float?
        var silentBeyondM: Float?
    }
    struct Bed: Codable {
        var file: String
        var volume: Float?
    }
    /// A volume the camera may move in: the unit box (|x|,|y|,|z| <= 1), sphere
    /// or cylinder (x²+y² <= 1, |z| <= 1), placed by `matrix` (row-major 4x4,
    /// unit primitive to the scan's space).
    struct Bound: Codable {
        var shape: String
        var matrix: [Float]
    }

    var format: String
    var version: Int
    var name: String?
    var splats: String
    var metresPerUnit: Float?
    var place: Bool?
    var ev: Float?
    var up: [Float]?
    var start: Start?
    var sky: Sky?
    var houseLights: String?
    var lights: [Light]?
    var sounds: [Sound]?
    var ambience: [Bed]?
    var bounds: [Bound]?
}

/// A .vcscene unpacked (once per version of the file) into the caches.
struct SceneBundle {
    let source: URL
    let folder: URL
    let file: SceneFile

    static let fileExtension = "vcscene"
    static func isBundle(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == fileExtension }

    var plyPath: String { folder.appendingPathComponent(file.splats).path }
    var name: String { file.name ?? source.deletingPathExtension().lastPathComponent }
    var place: Bool { file.place ?? false }
    var ev: Float { file.ev ?? (place ? 13 : 12) }

    static func vec(_ a: [Float]?) -> SIMD3<Float>? {
        guard let a, a.count == 3 else { return nil }
        return SIMD3(a[0], a[1], a[2])
    }

    /// Its scene.json, read straight from the zip (quick: the scan stays packed).
    static func peek(_ path: String) -> SceneFile? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", path, "scene.json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try? JSONDecoder().decode(SceneFile.self, from: data)
    }

    /// Unpacks `path` (or finds it unpacked already) and reads its scene.json.
    static func open(_ path: String) throws -> SceneBundle {
        let src = URL(fileURLWithPath: path).standardizedFileURL
        let attrs = try FileManager.default.attributesOfItem(atPath: src.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let stamp = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = SHA256.hash(data: Data("\(src.path)|\(size)|\(stamp)".utf8)).prefix(10)
            .map { String(format: "%02x", $0) }.joined()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vintage Click/scenes", isDirectory: true)
        let folder = caches.appendingPathComponent(key, isDirectory: true)
        let json = folder.appendingPathComponent("scene.json")
        if !FileManager.default.fileExists(atPath: json.path) {
            // A new version of this file: drop older copies of it, unpack this one.
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            let tmp = caches.appendingPathComponent(key + ".partial", isDirectory: true)
            try? FileManager.default.removeItem(at: tmp)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", src.path, tmp.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw failure("couldn't unpack \(src.lastPathComponent)") }
            pruneOlder(of: src.path, in: caches)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.moveItem(at: tmp, to: folder)
            try? Data(src.path.utf8).write(to: folder.appendingPathComponent(".source"))
        }
        let file = try JSONDecoder().decode(SceneFile.self, from: Data(contentsOf: json))
        guard file.format == "vintage-click-scene" else { throw failure("\(src.lastPathComponent) isn't a Vintage Click scene") }
        guard file.version <= 1 else { throw failure("\(src.lastPathComponent) is from a newer Scene Builder: update Vintage Click") }
        let b = SceneBundle(source: src, folder: folder, file: file)
        guard FileManager.default.fileExists(atPath: b.plyPath) else { throw failure("\(src.lastPathComponent) has no scan in it") }
        return b
    }

    /// Earlier unpacked versions of the same file (the scans are big).
    private static func pruneOlder(of path: String, in caches: URL) {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
        for d in dirs {
            let s = d.appendingPathComponent(".source")
            if let data = try? Data(contentsOf: s), String(decoding: data, as: UTF8.self) == path {
                try? FileManager.default.removeItem(at: d)
            }
        }
    }

    private static func failure(_ s: String) -> NSError {
        NSError(domain: "VintageClick.Scene", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }

    // MARK: into the game

    /// The scan's up (unit), if given.
    var up: SIMD3<Float>? {
        guard let u = Self.vec(file.up), simd_length(u) > 1e-6 else { return nil }
        return simd_normalize(u)
    }

    var skySetting: SkySetting? {
        guard let s = file.sky else { return nil }
        let p = folder.appendingPathComponent(s.file).path
        guard FileManager.default.fileExists(atPath: p) else { return nil }
        return SkySetting(path: p, yawDegrees: s.yawDegrees ?? 0, stops: s.stops ?? 0)
    }

    /// The lights, matched to the kit by name (an unknown name: the first, logged).
    func placedLights(defaultFlare: Bool) -> [PlacedLight] {
        (file.lights ?? []).compactMap { l in
            guard let pos = Self.vec(l.position), let aim = Self.vec(l.aim), simd_length(aim) > 1e-6 else { return nil }
            func index(_ name: String?, in names: [String], _ what: String) -> Int {
                guard let name else { return 0 }
                if let i = names.firstIndex(of: name) { return i }
                print("Scene: no \(what) called \"\(name)\": using \(names.first ?? "?")")
                return 0
            }
            var p = PlacedLight(head: index(l.head, in: lightKit.map(\.name), "light head"),
                                position: pos, aim: simd_normalize(aim))
            if let s = l.spot { p.spot = max(0, min(1, s)) }
            if let d = l.dimmerStops { p.dimmerStops = d }
            p.gel = index(l.gel, in: gels.map(\.name), "gel")
            p.modifier = index(l.modifier, in: lightModifiers.map(\.name), "light modifier")
            if !p.fits(lightModifiers[p.modifier]) { p.modifier = 0 }
            if let f = l.patternFocus { p.patternFocus = max(0, min(1, f)) }
            p.flare = l.flare ?? defaultFlare
            return p
        }
    }

    /// The sounds with their files where they were unpacked.
    var emitters: [Soundscape.Emitter] {
        (file.sounds ?? []).compactMap { s in
            guard let pos = Self.vec(s.position) else { return nil }
            return Soundscape.Emitter(url: folder.appendingPathComponent(s.file), position: pos,
                                      volume: s.volume ?? 1, fullWithinM: max(0.05, s.fullWithinM ?? 1),
                                      silentBeyondM: s.silentBeyondM ?? 50)
        }
    }
    /// Where the camera may go (nil: anywhere).
    var movementBounds: MovementBounds? {
        let vols: [MovementBounds.Volume] = (file.bounds ?? []).compactMap { b in
            guard b.matrix.count == 16 else { return nil }
            let m = b.matrix
            // Row-major in the file; simd's initialiser takes columns.
            let M = simd_float4x4(columns: (SIMD4(m[0], m[4], m[8], m[12]), SIMD4(m[1], m[5], m[9], m[13]),
                                            SIMD4(m[2], m[6], m[10], m[14]), SIMD4(m[3], m[7], m[11], m[15])))
            guard abs(M.determinant) > 1e-12 else { return nil }
            let shape: MovementBounds.Shape
            switch b.shape.lowercased() {
            case "box": shape = .box
            case "sphere": shape = .sphere
            case "cylinder": shape = .cylinder
            default: print("Scene: unknown bound shape \(b.shape)"); return nil
            }
            return MovementBounds.Volume(shape: shape, toUnit: M.inverse)
        }
        return vols.isEmpty ? nil : MovementBounds(volumes: vols)
    }

    var beds: [Soundscape.Bed] {
        (file.ambience ?? []).map { Soundscape.Bed(url: folder.appendingPathComponent($0.file), volume: $0.volume ?? 1) }
    }
}

/// The space the camera may move in: the union of a few volumes. A move that
/// would leave it slides along the edge instead (the part of the step that
/// stays inside), so a wall is felt, not a stop.
struct MovementBounds {
    enum Shape { case box, sphere, cylinder }
    struct Volume {
        let shape: Shape
        let toUnit: simd_float4x4
        func contains(_ p: SIMD3<Float>) -> Bool {
            let q = toUnit * SIMD4(p, 1)
            switch shape {
            case .box: return abs(q.x) <= 1 && abs(q.y) <= 1 && abs(q.z) <= 1
            case .sphere: return q.x * q.x + q.y * q.y + q.z * q.z <= 1
            case .cylinder: return q.x * q.x + q.y * q.y <= 1 && abs(q.z) <= 1
            }
        }
    }
    let volumes: [Volume]

    func contains(_ p: SIMD3<Float>) -> Bool { volumes.contains { $0.contains(p) } }

    /// Where a move from `from` to `to` ends up.
    func confine(from: SIMD3<Float>, to: SIMD3<Float>) -> SIMD3<Float> {
        if contains(to) { return to }
        // Started outside (a start view outside the bounds): let it walk in.
        if !contains(from) { return to }
        let d = to - from
        // Slide: the step without one axis, then with only one; the longest that stays in.
        var best = from, bestLen: Float = 0
        let masks: [SIMD3<Float>] = [[0, 1, 1], [1, 0, 1], [1, 1, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for m in masks {
            let step = d * m
            let len = simd_length(step)
            if len > bestLen, contains(from + step) { best = from + step; bestLen = len }
        }
        if bestLen > 0 { return best }
        // Nothing slides: go as far as stays inside.
        var lo: Float = 0, hi: Float = 1
        for _ in 0..<8 {
            let mid = (lo + hi) / 2
            if contains(from + d * mid) { lo = mid } else { hi = mid }
        }
        return from + d * lo
    }
}

/// What the Scene Builder add-on needs from the game's kit, so its lists match:
/// `VintageClick --export-kit kit.json`.
func exportKit(to path: String) throws {
    func kind(_ k: LightHead.Kind) -> String {
        switch k { case .fresnel: return "fresnel"; case .softlight: return "softlight"; case .ellipsoidal: return "ellipsoidal" }
    }
    let heads: [[String: Any]] = lightKit.map {
        ["name": $0.name, "kind": kind($0.kind), "lumens": $0.lumens, "spotAngle": $0.spotAngle,
         "floodAngle": $0.floodAngle, "size": [$0.size.x, $0.size.y, $0.size.z]]
    }
    let gelRows: [[String: Any]] = gels.map {
        ["name": $0.name, "about": $0.about, "rgb": [$0.transmission.x, $0.transmission.y, $0.transmission.z]]
    }
    let mods: [[String: Any]] = lightModifiers.map { m in
        ["name": m.name, "about": m.about, "fits": lightKit.filter { m.fits($0) }.map { kind($0.kind) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }]
    }
    let house: [[String: Any]] = LightingPlot.houseLevels.map {
        ["name": $0.name, "level": $0.level, "tint": [$0.tint.x, $0.tint.y, $0.tint.z]]
    }
    let light: [[String: Any]] = sceneLightChoices.map { ["name": $0.0, "ev": $0.1] }
    let kit: [String: Any] = ["tungstenRGB": [tungsten.x, tungsten.y, tungsten.z],
                              "heads": heads, "gels": gelRows, "modifiers": mods,
                              "houseLevels": house, "sceneLight": light]
    let data = try JSONSerialization.data(withJSONObject: kit, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
}
