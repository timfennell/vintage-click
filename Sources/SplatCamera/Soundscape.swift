import AVFoundation
import Foundation
import simd

/// A scene's sound, from its .vcscene: looping sounds at places in the scan
/// (a stream, an engine idling), louder as you walk up to them and placed
/// around your head, and beds heard everywhere (wind, distant traffic).
final class Soundscape {
    struct Emitter {
        var url: URL
        var position: SIMD3<Float>      // scan units
        var volume: Float
        var fullWithinM: Float          // full volume this close
        var silentBeyondM: Float        // nothing past this
    }
    struct Bed {
        var url: URL
        var volume: Float
    }

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var sources: [(Emitter, AVAudioPlayerNode)] = []
    private var beds: [(Bed, AVAudioPlayerNode)] = []
    private var running = false
    var isEmpty: Bool { sources.isEmpty && beds.isEmpty }

    /// On or off, and how loud, kept between launches.
    static var on: Bool {
        get { UserDefaults.standard.object(forKey: "soundscape") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundscape") }
    }
    static var level: Float {
        get { UserDefaults.standard.object(forKey: "soundscapeLevel") as? Float ?? 0.8 }
        set { UserDefaults.standard.set(max(0, min(1, newValue)), forKey: "soundscapeLevel") }
    }

    init(emitters: [Emitter], beds: [Bed]) {
        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        // Each source's falloff is its own (set per frame below), not the environment's.
        environment.distanceAttenuationParameters.rolloffFactor = 0
        environment.renderingAlgorithm = .HRTFHQ
        environment.outputType = .headphones
        for e in emitters {
            guard let buf = Self.load(e.url, mono: true) else { print("Soundscape: can't read \(e.url.lastPathComponent)"); continue }
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: environment, format: buf.format)
            p.renderingAlgorithm = .HRTFHQ
            p.volume = 0
            Self.loop(p, buf)
            sources.append((e, p))
        }
        for b in beds {
            guard let buf = Self.load(b.url, mono: false) else { print("Soundscape: can't read \(b.url.lastPathComponent)"); continue }
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: buf.format)
            p.volume = b.volume
            Self.loop(p, buf)
            self.beds.append((b, p))
        }
        engine.mainMixerNode.outputVolume = 0
    }

    /// Reads a whole file (mixed down to mono for a sound placed in the scene:
    /// only a mono source can be placed).
    private static func load(_ url: URL, mono: Bool) -> AVAudioPCMBuffer? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let n = AVAudioFrameCount(f.length)
        guard n > 0, let src = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n),
              (try? f.read(into: src)) != nil else { return nil }
        let ch = Int(src.format.channelCount)
        guard mono && ch > 1 else { return src }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: src.format.sampleRate, channels: 1),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: src.frameLength),
              let i = src.floatChannelData, let o = out.floatChannelData else { return nil }
        out.frameLength = src.frameLength
        for k in 0..<Int(src.frameLength) {
            var s: Float = 0
            for c in 0..<ch { s += i[c][k] }
            o[0][k] = s / Float(ch)
        }
        return out
    }

    /// Loops the buffer, starting somewhere in it (so beds of the same length don't beat together).
    private static func loop(_ p: AVAudioPlayerNode, _ buf: AVAudioPCMBuffer) {
        let n = buf.frameLength
        let start = AVAudioFramePosition(Int.random(in: 0..<max(1, Int(n))))
        if start > 0, let first = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: n - AVAudioFrameCount(start)) {
            first.frameLength = n - AVAudioFrameCount(start)
            for c in 0..<Int(buf.format.channelCount) {
                if let s = buf.floatChannelData?[c], let d = first.floatChannelData?[c] {
                    d.update(from: s + Int(start), count: Int(first.frameLength))
                }
            }
            p.scheduleBuffer(first)
        }
        p.scheduleBuffer(buf, at: nil, options: .loops)
    }

    /// How loud a source is at `d` metres: full within its near distance,
    /// falling as 1/distance beyond, eased to nothing at its far distance.
    static func gain(_ e: Emitter, distance d: Float) -> Float {
        let near = e.fullWithinM, far = max(e.silentBeyondM, near + 0.01)
        guard d < far else { return 0 }
        let fall = near / max(d, near)
        let t = max(0, min(1, (d - (near + 0.75 * (far - near))) / (0.25 * (far - near))))
        return e.volume * fall * (1 - t * t * (3 - 2 * t))
    }

    /// Each frame: where the ears are (scan units) and which way they face.
    func update(position: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>, metresPerUnit: Float, audible: Bool) {
        if audible && !running {
            do { try engine.start(); running = true; for (_, p) in sources { p.play() }; for (_, p) in beds { p.play() } }
            catch { print("Soundscape: can't start audio: \(error)") }
        }
        // Fade in and out rather than click.
        let want: Float = audible && Self.on ? Self.level : 0
        let mix = engine.mainMixerNode
        mix.outputVolume += (want - mix.outputVolume) * 0.15
        guard running else { return }
        let ears = position * metresPerUnit
        environment.listenerPosition = AVAudio3DPoint(x: ears.x, y: ears.y, z: ears.z)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: forward.x, y: forward.y, z: forward.z),
            up: AVAudio3DVector(x: up.x, y: up.y, z: up.z))
        for (e, p) in sources {
            let at = e.position * metresPerUnit
            p.position = AVAudio3DPoint(x: at.x, y: at.y, z: at.z)
            p.volume = Self.gain(e, distance: simd_distance(at, ears))
        }
    }

    /// For checks: each source's gain from `position`.
    func gains(at position: SIMD3<Float>, metresPerUnit: Float) -> [(String, Float, Float)] {
        sources.map { (e, _) in
            let d = simd_distance(e.position * metresPerUnit, position * metresPerUnit)
            return (e.url.lastPathComponent, d, Self.gain(e, distance: d))
        }
    }

    func stop() {
        engine.stop()
        running = false
    }
}
