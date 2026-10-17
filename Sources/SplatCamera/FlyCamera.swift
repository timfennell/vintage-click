import Foundation
import simd

/// What the sticks and buttons ask for this frame, in [-1, 1] (already shaped).
struct FlyInput {
    var move = SIMD2<Float>(0, 0)   // x strafe right, y forward
    var look = SIMD2<Float>(0, 0)   // x yaw right, y pitch up
    var rise: Float = 0             // up minus down
    var zoom: Float = 0             // longer minus shorter focal length
}

/// A hand-held camera: yaw/pitch about a world up axis, eased velocities so
/// stick movements read as a person walking and panning, not as teleporting.
struct FlyCamera {
    var position = SIMD3<Float>(0, 0, 0)
    var yaw: Float = 0
    var pitch: Float = 0
    var up = SIMD3<Float>(0, -1, 0)   // COLMAP scans are usually -Y up
    var focalMM: Float = 50           // on a 36 mm wide frame
    var moveSpeed: Float = 1          // world units / s at full stick
    var lookSpeed: Float = 1.6        // rad / s at full stick

    private var velocity = SIMD3<Float>(0, 0, 0)
    private var lookRate = SIMD2<Float>(0, 0)
    private var zoomRate: Float = 0

    /// Two horizontal axes perpendicular to `up` (yaw 0 looks along the first).
    private var horizon: (SIMD3<Float>, SIMD3<Float>) {
        let seed: SIMD3<Float> = abs(up.x) < 0.9 ? [1, 0, 0] : [0, 0, 1]
        let a = simd_normalize(seed - simd_dot(seed, up) * up)
        return (a, simd_cross(up, a))
    }

    var forward: SIMD3<Float> {
        let (a, b) = horizon
        return cos(pitch) * (cos(yaw) * a + sin(yaw) * b) + sin(pitch) * up
    }
    var right: SIMD3<Float> { simd_normalize(simd_cross(forward, up)) }
    var down: SIMD3<Float> { simd_cross(forward, right) }

    mutating func lookAt(_ target: SIMD3<Float>, from eye: SIMD3<Float>) {
        position = eye
        let d = simd_normalize(target - eye)
        let (a, b) = horizon
        pitch = asin(max(-1, min(1, simd_dot(d, up))))
        yaw = atan2(simd_dot(d, b), simd_dot(d, a))
    }

    /// Mouse look: turns straight away (no easing), slower on longer lenses.
    mutating func turn(_ d: SIMD2<Float>) {
        let k: Float = 0.0022 * min(1, 50 / focalMM)
        yaw -= d.x * k
        pitch = max(-1.5, min(1.5, pitch + d.y * k))
    }

    mutating func update(_ input: FlyInput, dt: Float) {
        // Critically damped-ish easing toward the stick targets.
        let ease = 1 - exp(-dt / 0.12)
        let wantLook = input.look * lookSpeed * (focalMM < 50 ? 1 : 50 / focalMM)
        lookRate += (wantLook - lookRate) * ease
        // Stick right turns right: in these axes that is decreasing yaw.
        yaw -= lookRate.x * dt
        pitch = max(-1.5, min(1.5, pitch + lookRate.y * dt))

        let f = forward, r = right
        let flat = simd_normalize(f - simd_dot(f, up) * up)
        let want = (flat * input.move.y + r * input.move.x + up * input.rise) * moveSpeed
        velocity += (want - velocity) * ease
        position += velocity * dt

        zoomRate += (input.zoom - zoomRate) * ease
        focalMM = max(18, min(300, focalMM * exp(zoomRate * dt * 0.8)))
    }

    /// World-to-camera, row-major, OpenCV axes (x right, y down, z forward).
    var viewMatrix: [Float] {
        let r = right, d = down, f = forward, p = position
        return [r.x, r.y, r.z, -simd_dot(r, p),
                d.x, d.y, d.z, -simd_dot(d, p),
                f.x, f.y, f.z, -simd_dot(f, p),
                0, 0, 0, 1]
    }

    func focalPixels(width: Int) -> Float { Float(width) * focalMM / 36 }
}
