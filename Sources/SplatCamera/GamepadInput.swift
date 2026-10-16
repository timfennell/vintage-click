import Foundation
import GameController
import simd

/// Polls the first game controller (Xbox / PlayStation / MFi) each frame, with
/// the keyboard as a fallback for when no pad is connected.
///
///   left stick   walk / strafe        right stick  look
///   R2 / L2      rise / sink          d-pad up/dn  zoom (focal length)
///   R1 / L1      walk faster / slower A / cross    reset view
///   Y / triangle cycle the up axis    B / circle   SH bands: full / base colour
///   X / square   save a full-quality still
///
/// Keyboard: WASD walk, arrows look, E/Q rise/sink, =/- zoom, ]/[ speed,
/// R reset, U up axis, H SH bands, Space still.
final class GamepadInput {
    struct Buttons: OptionSet {
        let rawValue: Int
        static let reset = Buttons(rawValue: 1)
        static let cycleUp = Buttons(rawValue: 2)
        static let toggleSH = Buttons(rawValue: 4)
        static let still = Buttons(rawValue: 8)
        static let faster = Buttons(rawValue: 16)
        static let slower = Buttons(rawValue: 32)
    }

    private var held: Buttons = []
    private(set) var controllerName: String?

    init() {
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil,
                                               queue: .main) { [weak self] n in
            let c = n.object as? GCController
            self?.controllerName = c?.vendorName ?? "controller"
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

    /// The fly input for this frame plus buttons newly pressed since the last call.
    func poll() -> (FlyInput, Buttons) {
        var input = FlyInput()
        var now: Buttons = []
        if let pad = GCController.controllers().first(where: { $0.extendedGamepad != nil })?
            .extendedGamepad {
            input.move = SIMD2(Self.shape(pad.leftThumbstick.xAxis.value),
                               Self.shape(pad.leftThumbstick.yAxis.value))
            input.look = SIMD2(Self.shape(pad.rightThumbstick.xAxis.value),
                               Self.shape(pad.rightThumbstick.yAxis.value))
            input.rise = pad.rightTrigger.value - pad.leftTrigger.value
            input.zoom = (pad.dpad.up.isPressed ? 1 : 0) - (pad.dpad.down.isPressed ? 1 : 0)
            if pad.buttonA.isPressed { now.insert(.reset) }
            if pad.buttonY.isPressed { now.insert(.cycleUp) }
            if pad.buttonB.isPressed { now.insert(.toggleSH) }
            if pad.buttonX.isPressed { now.insert(.still) }
            if pad.rightShoulder.isPressed { now.insert(.faster) }
            if pad.leftShoulder.isPressed { now.insert(.slower) }
        }
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            func k(_ c: GCKeyCode) -> Float { kb.button(forKeyCode: c)?.isPressed == true ? 1 : 0 }
            input.move += SIMD2(k(.keyD) - k(.keyA), k(.keyW) - k(.keyS))
            input.look += SIMD2(k(.rightArrow) - k(.leftArrow), k(.upArrow) - k(.downArrow)) * 0.6
            input.rise += k(.keyE) - k(.keyQ)
            input.zoom += k(.equalSign) - k(.hyphen)
            if k(.keyR) > 0 { now.insert(.reset) }
            if k(.keyU) > 0 { now.insert(.cycleUp) }
            if k(.keyH) > 0 { now.insert(.toggleSH) }
            if k(.spacebar) > 0 { now.insert(.still) }
            if k(.closeBracket) > 0 { now.insert(.faster) }
            if k(.openBracket) > 0 { now.insert(.slower) }
        }
        input.move = simd.simd_clamp(input.move, SIMD2<Float>(repeating: -1), SIMD2<Float>(repeating: 1))
        let pressed = now.subtracting(held)
        held = now
        return (input, pressed)
    }
}
