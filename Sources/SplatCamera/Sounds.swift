import AVFoundation
import Foundation

/// The camera's own sounds, recorded by you: files in the sounds folder named
/// by what they are, any number of takes each (shutter-1.wav, shutter-2.wav,
/// advance-1.wav ...). Each event plays a random take (never the same one
/// twice running), a touch faster or slower and louder or softer, so a burst
/// of frames never sounds like a loop. With no recordings the camera is silent.
final class Sounds {
    enum Event: String, CaseIterable {
        case shutter            // the whole shutter, at any speed
        case shutterOpen = "shutter-open"     // first curtain (with shutter-close: slow speeds come apart)
        case shutterClose = "shutter-close"   // second curtain, after the exposure time
        case mirror             // the mirror slapping up and back
        case advance            // the film advance lever: frame wound on
        case rewind             // rewinding the roll
        case aperture           // a click of the aperture ring
        case focus              // the focus ring (short, plays now and then as it turns)
        case back               // opening / closing the back to load film
    }

    static let shared = Sounds()

    /// ~/Library/Application Support/Splat Camera/Sounds (SPLAT_CAMERA_SOUNDS overrides, for tests).
    static var folder: URL {
        if let env = ProcessInfo.processInfo.environment["SPLAT_CAMERA_SOUNDS"] { return URL(fileURLWithPath: env) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Splat Camera/Sounds")
    }

    private var takes: [Event: [Data]] = [:]
    private var last: [Event: Int] = [:]
    private var playing: Set<AVAudioPlayer> = []
    private let lock = NSLock()

    init() { reload() }

    /// (Re)reads the folder. Files are matched by name: "advance-3.wav" is a take
    /// of `advance`; "shutter-open-2.aiff" of `shutterOpen`.
    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        writeReadme()
        var found: [Event: [Data]] = [:]
        let files = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        // Longest names first, so "shutter-open-1" is not taken for "shutter".
        let events = Event.allCases.sorted { $0.rawValue.count > $1.rawValue.count }
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where ["wav", "aif", "aiff", "caf", "m4a", "mp3"].contains(f.pathExtension.lowercased()) {
            let stem = f.deletingPathExtension().lastPathComponent.lowercased()
            guard let e = events.first(where: { stem == $0.rawValue || stem.hasPrefix($0.rawValue + "-")
                                                    || stem.hasPrefix($0.rawValue + "_") }),
                  let data = try? Data(contentsOf: f) else { continue }
            // A take named for the event family but meant for a longer name is skipped above by ordering.
            found[e, default: []].append(data)
        }
        lock.lock()
        takes = found
        lock.unlock()
        let summary = Event.allCases.compactMap { e in found[e].map { "\(e.rawValue) ×\($0.count)" } }
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
        let data = list[i]
        lock.unlock()
        let start = { [weak self] in
            guard let self, let p = try? AVAudioPlayer(data: data) else { return }
            p.enableRate = true
            p.rate = Float.random(in: 0.97...1.03)
            p.volume = volume * Float.random(in: 0.88...1.0)
            p.prepareToPlay()
            p.play()
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
        if has(.shutterOpen) && has(.shutterClose) {
            play(.shutterOpen)
            play(.shutterClose, after: Double(seconds))
        } else {
            play(.shutter)
        }
        play(.mirror)
        // The thumb goes to the lever once the shutter has closed.
        play(.advance, after: Double(seconds) + 0.35 + Double.random(in: 0...0.25))
    }

    private func writeReadme() {
        let url = Self.folder.appendingPathComponent("README.txt")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        Splat Camera plays your own recordings of a camera. Put them here, one
        sound per file (WAV or AIFF, 48 kHz is ideal, silence trimmed at the start),
        named for what they are; record several takes of each for variety:

          shutter-1.wav, shutter-2.wav ...      the whole shutter
          shutter-open-1.wav + shutter-close-1.wav   (optional) first and second
                                                curtain apart: at slow speeds the
                                                close plays after the exposure time
          advance-1.wav ... advance-8.wav       the film advance lever
          mirror-1.wav                          (optional) mirror slap
          rewind-1.wav                          (optional) rewinding a roll
          back-1.wav                            (optional) opening the back to load film
          aperture-1.wav                        (optional) an aperture ring click
          focus-1.wav                           (optional) the focus ring

        Then choose Reload Sounds in the game menu (or restart).
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
