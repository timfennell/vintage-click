import AppKit
import AVFoundation
import CoreHaptics
import GameController

/// A tap felt with a sound: when in the recording (seconds), how hard (0...1
/// of the take's loudest) and how crisp (0 a dull thud, 1 a sharp click).
struct HapticHit {
    var time: Double
    var strength: Float
    var sharpness: Float
}

/// The camera felt as well as heard: the trackpad's Force Touch engine and a
/// game controller's, tapping out the same hits the recording makes (the
/// curtains, the lever's ratchet, the bayonet's clicks), started with it.
/// Light: a nudge in the fingers, not a buzz.
final class Haptics {
    static let shared = Haptics()

    /// Felt or not (the menu's toggle), remembered.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "haptics") }
    }

    private var engines: [ObjectIdentifier: CHHapticEngine] = [:]
    /// The trackpad pressed in (a click): its own click is all that is felt
    /// then, so a tap due meanwhile waits for the release.
    private var pressed = false
    private var waiting: NSHapticFeedbackManager.FeedbackPattern?

    init() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            guard let self else { return e }
            self.pressed = e.type == .leftMouseDown
            if !self.pressed, let p = self.waiting {
                self.waiting = nil
                // Just after the click lets go: click, then the knock.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
                    NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
                }
            }
            return e
        }
        // Engines are slow to start: have one ready on each controller as it arrives.
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { _ = self?.engine(for: c) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.engines[ObjectIdentifier(c)] = nil }
        }
        for c in GCController.controllers() { _ = engine(for: c) }
    }

    /// Plays `hits` from now, as a take played at `rate` (its times shrink with
    /// it). `gain` scales them all (a mirror is felt less than the shutter).
    func play(_ hits: [HapticHit], rate: Double = 1, gain: Float = 1) {
        guard enabled, !hits.isEmpty else { return }
        trackpad(hits, rate: rate, gain: gain)
        for c in GCController.controllers() { controller(c, hits, rate: rate, gain: gain) }
    }

    /// The trackpad has only a few fixed taps and felt only under a finger: the
    /// strongest hits, kept apart so they stay taps, the firmest for a hard hit.
    private func trackpad(_ hits: [HapticHit], rate: Double, gain: Float) {
        var last = -1.0, count = 0
        for h in hits where h.strength * gain >= 0.3 && count < 4 {
            let t = h.time / rate
            guard t - last >= 0.05 else { continue }
            last = t
            count += 1
            let pattern: NSHapticFeedbackManager.FeedbackPattern = h.strength * gain > 0.6 ? .levelChange : .generic
            let fire = { [weak self] in
                guard let self else { return }
                if self.pressed {
                    // Keep the firmest due while pressed for the release.
                    if self.waiting != .levelChange { self.waiting = pattern }
                } else {
                    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
                }
            }
            if t <= 0.002 { fire() } else { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: fire) }
        }
    }

    private func controller(_ c: GCController, _ hits: [HapticHit], rate: Double, gain: Float) {
        guard let engine = engine(for: c) else { return }
        // Transients only: each a short knock, at most about half the motor.
        let events = hits.map { h in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, 0.12 + h.strength * gain * 0.5)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: h.sharpness),
            ], relativeTime: h.time / rate)
        }
        do {
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // A controller asleep or gone: start afresh next time.
            engines[ObjectIdentifier(c)] = nil
        }
    }

    private func engine(for c: GCController) -> CHHapticEngine? {
        let id = ObjectIdentifier(c)
        if let e = engines[id] { return e }
        guard let e = c.haptics?.createEngine(withLocality: .default) else { return nil }
        e.playsHapticsOnly = true
        e.stoppedHandler = { [weak self] _ in DispatchQueue.main.async { self?.engines[id] = nil } }
        e.resetHandler = { try? e.start() }
        guard (try? e.start()) != nil else { return nil }
        engines[id] = e
        return e
    }

    /// Where a recording knocks: sudden rises in its loudness, with how hard
    /// and how crisp each is. Read once, when the sounds are loaded.
    static func hits(in url: URL, limit: Int = 10) -> [HapticHit] {
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { return [] }
        let n = Int(buf.frameLength), chans = Int(buf.format.channelCount)
        let sr = buf.format.sampleRate
        guard n > 0 else { return [] }
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<chans { for i in 0..<n { mono[i] += ch[c][i] / Float(chans) } }
        // Peak loudness in 3 ms steps, and its slow average (about 30 ms).
        let step = max(1, Int(sr * 0.003))
        let frames = n / step
        guard frames > 2 else { return [] }
        var env = [Float](repeating: 0, count: frames)
        var crisp = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var peak: Float = 0, level: Float = 0, change: Float = 0
            for i in f * step..<(f + 1) * step {
                peak = max(peak, abs(mono[i]))
                level += abs(mono[i])
                if i > 0 { change += abs(mono[i] - mono[i - 1]) }
            }
            env[f] = peak
            // How much of it is high frequency: a click's samples jump about.
            crisp[f] = level > 1e-6 ? change / level : 0
        }
        let top = env.max() ?? 0
        guard top > 1e-4 else { return [] }
        var found: [HapticHit] = []
        var slow = env[0], lastAt = -1.0
        for f in 1..<frames {
            let t = Double(f * step) / sr
            if env[f] > slow * 2.2 && env[f] > top * 0.12 && t - lastAt > 0.03 {
                // Its strength: the loudest of the next 15 ms.
                let end = min(frames, f + 5)
                let peak = env[f..<end].max() ?? env[f]
                let c = crisp[f..<end].reduce(0, +) / Float(end - f)
                found.append(HapticHit(time: t, strength: peak / top, sharpness: min(0.9, max(0.15, c * 0.6))))
                lastAt = t
            }
            slow += (env[f] - slow) * 0.1
        }
        // The strongest few, in order.
        return Array(found.sorted { $0.strength > $1.strength }.prefix(limit)).sorted { $0.time < $1.time }
    }
}
