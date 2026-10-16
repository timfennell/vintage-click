import Foundation
import GameController
import simd

/// The camera in your hands, on a game controller (Xbox / PlayStation / MFi),
/// with the keyboard as a fallback.
///
///   left stick     walk / strafe          right stick    look
///   L1 / R1        sink / rise            L2 / R2        focus ring near / far
///   d-pad < >      aperture open / close  d-pad ^ v      shutter faster / slower
///   A / cross      shutter release        B / circle     hold: depth-of-field preview
///   X / square     next lens from the bag Y / triangle   load a new roll (next stock)
///   Menu           reset the view         View / Share   film-look preview in the finder
///   L-stick click  walk faster / slower
///
/// Keyboard: WASD walk, arrows look, Q/E sink/rise, Z/C focus near/far,
/// 1/2 aperture, 3/4 shutter, Space shutter, Tab DOF preview, L lens,
/// R new roll, 0 reset, P film preview, G walk speed, U up axis.
final class GamepadInput {
    struct State {
        var move = SIMD2<Float>(0, 0)
        var look = SIMD2<Float>(0, 0)
        var rise: Float = 0
        var focus: Float = 0           // + far, - near
        var dofPreview = false         // held
        var pressed: Set<Control> = [] // pressed since the last poll
    }
    enum Control: Hashable {
        case shutter, apertureOpen, apertureClose, shutterFaster, shutterSlower
        case nextLens, newRoll, reset, filmPreview, walkSpeed, cycleUp
    }

    private var held: Set<Control> = []
    private(set) var controllerName: String?

    init() {
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil,
                                               queue: .main) { [weak self] n in
            self?.controllerName = (n.object as? GCController)?.vendorName ?? "controller"
            print("Controller connected: \(self?.controllerName ?? "?")")
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.controllerName = GCController.controllers().first?.vendorName
        }
        GCController.startWirelessControllerDiscovery {}
        controllerName = GCController.controllers().first?.vendorName
    }

    /// Dead zone then a squared response: small deflections for fine framing.
    private static func shape(_ v: Float) -> Float {
        let dz: Float = 0.12
        let a = abs(v)
        if a < dz { return 0 }
        let t = (a - dz) / (1 - dz)
        return (v < 0 ? -1 : 1) * t * t
    }

    func poll() -> State {
        var s = State()
        var now: Set<Control> = []
        if let pad = GCController.controllers().first(where: { $0.extendedGamepad != nil })?
            .extendedGamepad {
            s.move = SIMD2(Self.shape(pad.leftThumbstick.xAxis.value),
                           Self.shape(pad.leftThumbstick.yAxis.value))
            s.look = SIMD2(Self.shape(pad.rightThumbstick.xAxis.value),
                           Self.shape(pad.rightThumbstick.yAxis.value))
            s.rise = (pad.rightShoulder.isPressed ? 1 : 0) - (pad.leftShoulder.isPressed ? 1 : 0)
            s.focus = pad.rightTrigger.value * pad.rightTrigger.value
                - pad.leftTrigger.value * pad.leftTrigger.value
            s.dofPreview = pad.buttonB.isPressed
            if pad.buttonA.isPressed { now.insert(.shutter) }
            if pad.buttonX.isPressed { now.insert(.nextLens) }
            if pad.buttonY.isPressed { now.insert(.newRoll) }
            if pad.dpad.left.isPressed { now.insert(.apertureOpen) }
            if pad.dpad.right.isPressed { now.insert(.apertureClose) }
            if pad.dpad.up.isPressed { now.insert(.shutterFaster) }
            if pad.dpad.down.isPressed { now.insert(.shutterSlower) }
            if pad.buttonMenu.isPressed { now.insert(.reset) }
            if pad.buttonOptions?.isPressed == true { now.insert(.filmPreview) }
            if pad.leftThumbstickButton?.isPressed == true { now.insert(.walkSpeed) }
        }
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            func k(_ c: GCKeyCode) -> Float { kb.button(forKeyCode: c)?.isPressed == true ? 1 : 0 }
            s.move += SIMD2(k(.keyD) - k(.keyA), k(.keyW) - k(.keyS))
            s.look += SIMD2(k(.rightArrow) - k(.leftArrow), k(.upArrow) - k(.downArrow)) * 0.6
            s.rise += k(.keyE) - k(.keyQ)
            s.focus += (k(.keyC) - k(.keyZ)) * 0.6
            if k(.tab) > 0 { s.dofPreview = true }
            let keys: [(GCKeyCode, Control)] = [
                (.spacebar, .shutter), (.one, .apertureOpen), (.two, .apertureClose),
                (.three, .shutterSlower), (.four, .shutterFaster), (.keyL, .nextLens),
                (.keyR, .newRoll), (.zero, .reset), (.keyP, .filmPreview), (.keyG, .walkSpeed),
                (.keyU, .cycleUp),
            ]
            for (code, control) in keys where k(code) > 0 { now.insert(control) }
        }
        s.move = simd_clamp(s.move, SIMD2<Float>(repeating: -1), SIMD2<Float>(repeating: 1))
        s.pressed = now.subtracting(held)
        held = now
        return s
    }
}
