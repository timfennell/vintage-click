import CryptoKit
import Foundation
import simd

/// One key on the movie camera's timeline: where the camera stood and how it
/// was set at that moment of the take.
struct MotionKey: Codable {
    var time: Double                // seconds from the start of the take
    var camera: FlyCamera
    var focusM: Float
    var fNumber: Float
    var shutterAngle: Float
}

/// A shot for the movie camera: keys on a timeline, and everything else the
/// darkroom needs to expose it again (the lens, film, lights and sky are held
/// for the whole take). Saved as take.json beside its clips.
struct MotionTake: Codable {
    var scene: String
    var keys: [MotionKey] = []
    var duration: Double = 10
    var frameRate: Float = 24
    /// The camera as it was set when the take went to the darkroom (lens,
    /// film, filter, the scene's light); the keys move its focus, iris and angle.
    var body: CameraBody? = nil
    var lighting = LightingPlot()
    var sky: SkySetting? = nil
    var takeNumber = 0

    static let lengths: [Double] = [5, 10, 20, 30]
    var frameCount: Int { max(1, Int((duration * Double(frameRate)).rounded())) }
    var frameTime: Double { 1 / Double(frameRate) }

    /// The camera and its settings at `t`: a smooth curve through the keys
    /// (time-spaced Catmull-Rom, still at the first and last key, so a move
    /// eases in and out), held before the first and after the last.
    /// Focus eases in dioptres, as a focus ring turns; the iris in stops.
    func sample(at t: Double) -> MotionKey? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if keys.count == 1 || t <= first.time { var k = first; k.time = t; return k }
        if t >= last.time { var k = last; k.time = t; return k }
        let i = keys.lastIndex { $0.time <= t }!
        let a = keys[i]
        let h = keys[i + 1].time - a.time
        let u = Float((t - a.time) / max(h, 1e-9))
        // Hermite through each value, with tangents (per second) from the
        // neighbouring keys, zero at the ends of the take.
        func curve<V: SIMD>(_ v: [V]) -> V where V.Scalar == Float {
            func slope(_ j: Int) -> V {
                guard j > 0, j < keys.count - 1 else { return V(repeating: 0) }
                return (v[j + 1] - v[j - 1]) / max(Float(keys[j + 1].time - keys[j - 1].time), 1e-6)
            }
            let m0 = slope(i) * Float(h), m1 = slope(i + 1) * Float(h)
            let u2 = u * u, u3 = u2 * u
            return v[i] * (2 * u3 - 3 * u2 + 1) + m0 * (u3 - 2 * u2 + u)
                + v[i + 1] * (-2 * u3 + 3 * u2) + m1 * (u3 - u2)
        }
        let yaws = unwrappedYaws
        let pos = curve(keys.map { $0.camera.position })
        let angles = curve(keys.indices.map { SIMD2(yaws[$0], keys[$0].camera.pitch) })
        let settings = curve(keys.map { SIMD3(1 / max($0.focusM, 0.01), log2($0.fNumber), $0.shutterAngle) })
        var cam = a.camera
        cam.position = pos
        cam.yaw = angles.x
        cam.pitch = max(-1.5, min(1.5, angles.y))
        return MotionKey(time: t, camera: cam, focusM: 1 / max(settings.x, 0.005),
                         fNumber: exp2(settings.y), shutterAngle: max(1, min(360, settings.z)))
    }

    /// Each key's yaw, turned by whole turns to be nearest the one before (so
    /// a pan from 350° to 10° goes 20°, not the long way round).
    private var unwrappedYaws: [Float] {
        var out: [Float] = []
        for k in keys {
            var y = k.camera.yaw
            if let prev = out.last {
                y -= 2 * .pi * ((y - prev) / (2 * .pi)).rounded()
            }
            out.append(y)
        }
        return out
    }

    /// Adds a key at `key.time`, replacing one within half a frame of it.
    mutating func setKey(_ key: MotionKey) {
        let half = frameTime / 2
        keys.removeAll { abs($0.time - key.time) < half }
        keys.append(key)
        keys.sort { $0.time < $1.time }
    }

    /// Removes the key within half a frame of `t`; false when there is none.
    @discardableResult
    mutating func deleteKey(near t: Double) -> Bool {
        let n = keys.count, half = frameTime / 2
        keys.removeAll { abs($0.time - t) < half }
        return keys.count != n
    }

    /// The key at `t` (within half a frame), if any: its number from 1.
    func keyNumber(at t: Double) -> Int? {
        keys.firstIndex { abs($0.time - t) < frameTime / 2 }.map { $0 + 1 }
    }

    // MARK: on disk

    /// The working take for a scan, kept between launches.
    static func workingURL(scene: String) -> URL {
        let digest = SHA256.hash(data: Data(scene.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vintage Click/takes", isDirectory: true)
        return dir.appendingPathComponent(digest + ".json")
    }

    static func load(_ url: URL) -> MotionTake? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MotionTake.self, from: d)
    }

    func save(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: url)
    }

    /// "00:00:04:12": hours, minutes, seconds and frames.
    static func timecode(_ t: Double, fps: Float) -> String {
        let f = Int((t * Double(fps)).rounded())
        let r = max(1, Int(fps.rounded()))
        let s = f / r
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, f % r)
    }
}
