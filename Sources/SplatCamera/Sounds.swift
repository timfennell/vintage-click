import AVFoundation
import Foundation

/// The camera's own sounds: a real Nikon recorded for the game (in the app,
/// Resources/Sounds), plus any recordings of your own in the sounds folder,
/// named by what they are, any number of takes each (film-advance-1.wav,
/// film-advance-2.wav ...). Each event plays a random take (never the same
/// one twice running), a touch faster or slower and louder or softer, so a
/// burst of frames never sounds like a loop.
final class Sounds {
    enum Event: String, CaseIterable {
        case shutter            // the whole shutter, at any speed
        case shutterOpen = "shutter-open"     // first curtain (with shutter-close: slow speeds come apart)
        case shutterClose = "shutter-close"   // second curtain, after the exposure time
        case shutterDial = "shutter-change"   // a click of the shutter-speed dial
        case mirror             // the mirror slapping up and back
        case advance            // the film advance lever: frame wound on
        case rewind             // rewinding the roll
        case aperture           // a click of the aperture ring
        case focus              // the focus ring (short, plays now and then as it turns)
        case back               // opening / closing the back to load film
        case filmChange = "film-change"       // the whole of loading a new roll
        case lensChange = "lens-change"       // a lens off the mount and another on

        /// How strongly it is felt (nil: not at all): the shutter, the lever, a lens.
        var feel: Float? {
            switch self {
            case .shutter, .shutterOpen, .shutterClose: return 1
            case .lensChange: return 0.8
            case .advance, .mirror: return 0.65
            default: return nil
            }
        }

        /// The names its files may start with.
        var names: [String] {
            switch self {
            case .advance: return ["film-advance", "advance"]
            case .aperture: return ["iris-click", "iris", "aperture"]
            default: return [rawValue]
            }
        }
    }

    /// The recordings that come with the app.
    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("Sounds") }

    static let shared = Sounds()

    /// ~/Library/Application Support/Vintage Click/Sounds (or the old name's, Splat Camera,
    /// if recordings are already there). SPLAT_CAMERA_SOUNDS overrides, for tests.
    static var folder: URL {
        if let env = ProcessInfo.processInfo.environment["SPLAT_CAMERA_SOUNDS"] { return URL(fileURLWithPath: env) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let now = support.appendingPathComponent("Vintage Click/Sounds")
        let before = support.appendingPathComponent("Splat Camera/Sounds")
        let fm = FileManager.default
        return !fm.fileExists(atPath: now.path) && fm.fileExists(atPath: before.path) ? before : now
    }

    /// A recording, and where it knocks (for the haptics; empty if not felt).
    struct Take {
        var data: Data
        var hits: [HapticHit] = []
    }

    private var takes: [Event: [Take]] = [:]
    /// Shutter recordings made at a known speed (seconds -> takes): played for
    /// the exposure nearest to theirs, so 1/1000 snaps and 1 s comes apart.
    private var shutterAt: [Float: [Take]] = [:]
    private var lastSpeedTake: [Float: Int] = [:]

    /// "1000" -> 1/1000 s, "8" -> 1/8 s; seconds: "1" or "1s", "0.5", "0.125", "2s".
    static func speed(_ token: String) -> Float? {
        if token.hasSuffix("s"), let n = Float(token.dropLast()), n > 0 { return n }
        guard let d = Float(token), d > 0 else { return nil }
        return token.contains(".") || d <= 1 ? d : 1 / d
    }
    private var last: [Event: Int] = [:]
    private var playing: Set<AVAudioPlayer> = []
    private let lock = NSLock()

    init() {
        reload()
        _ = Haptics.shared     // controllers' engines ready before the first shot
    }

    /// (Re)reads the folder. Files are matched by name: "advance-3.wav" is a take
    /// of `advance`; "shutter-open-2.aiff" of `shutterOpen`.
    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        writeReadme()
        var found: [Event: [Take]] = [:]
        var atSpeed: [Float: [Take]] = [:]
        // The app's own recordings, then yours (they add to them).
        var files: [URL] = []
        for dir in [Self.bundled, Self.folder].compactMap({ $0 }) {
            files += ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        // Longest names first, so "shutter-change-1" is not taken for "shutter".
        let names = Event.allCases.flatMap { e in e.names.map { (e, $0) } }.sorted { $0.1.count > $1.1.count }
        for f in files where ["wav", "aif", "aiff", "caf", "m4a", "mp3"].contains(f.pathExtension.lowercased())
            && !f.lastPathComponent.hasPrefix("._") {
            let stem = f.deletingPathExtension().lastPathComponent.lowercased()
            guard let (e, name) = names.first(where: { stem == $0.1 || stem.hasPrefix($0.1 + "-") || stem.hasPrefix($0.1 + "_") }),
                  let data = try? Data(contentsOf: f) else { continue }
            let take = Take(data: data, hits: e.feel == nil ? [] : Haptics.hits(in: f))
            // "shutter-125" or "shutter-125-2": recorded at 1/125 ("shutter-0.5": half a second).
            if e == .shutter {
                let parts = stem.dropFirst(name.count + 1).split(whereSeparator: { $0 == "-" || $0 == "_" })
                if let first = parts.first, let sp = Self.speed(String(first)) {
                    atSpeed[sp, default: []].append(take)
                    continue
                }
            }
            found[e, default: []].append(take)
        }
        lock.lock()
        takes = found
        shutterAt = atSpeed
        lock.unlock()
        var summary = Event.allCases.compactMap { e in found[e].map { "\(e.rawValue) ×\($0.count)" } }
        for sp in atSpeed.keys.sorted() {
            summary.append((sp >= 1 ? String(format: "shutter at %.0fs", sp) : String(format: "shutter at 1/%.0f", 1 / sp))
                           + " ×\(atSpeed[sp]!.count)")
        }
        print("Sounds: " + (summary.isEmpty ? "none yet (\(Self.folder.path))" : summary.joined(separator: ", ")))
    }

    func has(_ e: Event) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !(takes[e]?.isEmpty ?? true)
    }

    /// Plays a take of `e` after `delay` seconds.
    func play(_ e: Event, after delay: Double = 0, volume: Float = 1) {
        lock.lock()
        guard let list = takes[e], !list.isEmpty else { lock.unlock(); return }
        var i = Int.random(in: 0..<list.count)
        if list.count > 1, i == last[e] { i = (i + 1 + Int.random(in: 0..<(list.count - 1))) % list.count }
        last[e] = i
        let take = list[i]
        lock.unlock()
        play(take, feel: e.feel, after: delay, volume: volume)
    }

    /// Camera sounds on or off (the menu's toggle), remembered.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "cameraSounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cameraSounds") }
    }

    /// Plays the take, and its hits felt from the same moment (felt even with
    /// the sounds off).
    private func play(_ take: Take, feel: Float?, after delay: Double, volume: Float) {
        let start = { [weak self] in
            let rate = Float.random(in: 0.97...1.03)
            guard let self, self.enabled, let p = try? AVAudioPlayer(data: take.data) else {
                if let feel { Haptics.shared.play(take.hits, rate: Double(rate), gain: feel) }
                return
            }
            p.enableRate = true
            p.rate = rate
            p.volume = volume * Float.random(in: 0.88...1.0)
            p.prepareToPlay()
            p.play()
            if let feel { Haptics.shared.play(take.hits, rate: Double(rate), gain: feel) }
            self.playing.insert(p)
            // Let go of it once it has finished.
            DispatchQueue.main.asyncAfter(deadline: .now() + p.duration / Double(p.rate) + 0.5) { self.playing.remove(p) }
        }
        if delay <= 0 { start() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: start) }
    }

    /// The shutter firing at `seconds`: one recording, or first and second
    /// curtains apart by the exposure time when both are recorded; the mirror
    /// if recorded; then the film wound on.
    func fire(shutterSeconds seconds: Float) {
        // A recording made at (or within a stop of) this speed sounds right as it is.
        lock.lock()
        let nearest = shutterAt.keys.min { abs(log2($0 / seconds)) < abs(log2($1 / seconds)) }
        var take: Take?
        if let sp = nearest, let list = shutterAt[sp], !list.isEmpty {
            let close = abs(log2(sp / seconds)) <= 1
            let curtains = !(takes[.shutterOpen]?.isEmpty ?? true) && !(takes[.shutterClose]?.isEmpty ?? true)
            // Far from every recorded speed, separate curtains (timed) beat the wrong length.
            if close || !curtains {
                var i = Int.random(in: 0..<list.count)
                if list.count > 1, i == lastSpeedTake[sp] { i = (i + 1) % list.count }
                lastSpeedTake[sp] = i
                take = list[i]
            }
        }
        lock.unlock()
        if let take {
            play(take, feel: Event.shutter.feel, after: 0, volume: 1)
        } else if has(.shutterOpen) && has(.shutterClose) {
            // The curtains, apart by the exposure (at fast speeds they all but meet).
            play(.shutterOpen)
            play(.shutterClose, after: Double(seconds))
        } else {
            play(.shutter)
        }
        play(.mirror)
        // The thumb goes to the lever once the shutter has closed.
        play(.advance, after: Double(seconds) + 0.35 + Double.random(in: 0...0.25))
    }

    /// Which recording an exposure of `seconds` would use (for checks).
    func choice(shutterSeconds seconds: Float) -> String {
        lock.lock()
        defer { lock.unlock() }
        let nearest = shutterAt.keys.min { abs(log2($0 / seconds)) < abs(log2($1 / seconds)) }
        let curtains = !(takes[.shutterOpen]?.isEmpty ?? true) && !(takes[.shutterClose]?.isEmpty ?? true)
        if let sp = nearest, abs(log2(sp / seconds)) <= 1 || !curtains {
            return sp >= 1 ? String(format: "recording at %.0f s", sp) : String(format: "recording at 1/%.0f", 1 / sp)
        }
        if curtains { return String(format: "curtains %.3f s apart", seconds) }
        return "plain shutter"
    }

    private func writeReadme() {
        let url = Self.folder.appendingPathComponent("README.txt")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        Vintage Click comes with its own camera's sounds (a real Nikon). Recordings
        you put here are played too, alongside them: one sound per file (WAV or
        AIFF, 48 kHz is ideal, silence trimmed at the start), named for what it
        is; several takes of each give variety:

          shutter-2000.wav ... shutter-15.wav      the whole release recorded at each
          shutter-1.wav, shutter-0.5.wav ...       speed: 2000 is 1/2000; 1, 0.5, 0.25
          shutter-125-2.wav (more takes)           are seconds. The game plays the
                                                   recording nearest each exposure.
          shutter-open-1.wav + shutter-close-1.wav (optional) the two curtains alone,
                                                   played apart by the exposure time
          shutter-change-1.wav                     a click of the shutter-speed dial
          film-advance-1.wav ...                   the film advance lever
          iris-click.wav                           a click of the aperture ring
          lens-change-1.wav ...                    a lens off and another on
          film-change-1.wav ...                    loading a new roll
          mirror-1.wav, focus-1.wav                (optional) mirror slap, focus ring

        Then choose Reload Sounds in the game menu (or restart).
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
