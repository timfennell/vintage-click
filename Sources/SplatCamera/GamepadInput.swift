import Foundation
import GameController
import simd

/// A game controller (Xbox / PlayStation / MFi), with the keyboard standing in
/// for one. Buttons are reported by position; what they do depends on the mode
/// (see Viewer: camera, lighting, contact sheet).
///
/// Keyboard: WASD = left stick, arrows = right stick, Q/E = L1/R1 (held and
/// pressed), Z/C = L2/R2, Space = A, Tab = B, L = X, R = Y, 1/2/4/3 = d-pad
/// left/right/up/down, 0 = Menu, K = View, G = L3, M = R3, U = cycle up axis.
final class GamepadInput {
    struct State {
        var move = SIMD2<Float>(0, 0)   // left stick
        var look = SIMD2<Float>(0, 0)   // right stick
        var shoulders: Float = 0        // R1 - L1, held
        var triggers: Float = 0         // R2 - L2
        var bHeld = false
        var pressed: Set<Button> = []   // pressed since the last poll
    }
    enum Button: Hashable {
        case a, b, x, y, left, right, up, down, l1, r1, menu, view, l3, r3, cycleUp
    }

    private var held: Set<Button> = []
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
        var now: Set<Button> = []
        if let pad = GCController.controllers().first(where: { $0.extendedGamepad != nil })?
            .extendedGamepad {
            s.move = SIMD2(Self.shape(pad.leftThumbstick.xAxis.value),
                           Self.shape(pad.leftThumbstick.yAxis.value))
            s.look = SIMD2(Self.shape(pad.rightThumbstick.xAxis.value),
                           Self.shape(pad.rightThumbstick.yAxis.value))
            s.shoulders = (pad.rightShoulder.isPressed ? 1 : 0) - (pad.leftShoulder.isPressed ? 1 : 0)
            s.triggers = pad.rightTrigger.value * pad.rightTrigger.value
                - pad.leftTrigger.value * pad.leftTrigger.value
            s.bHeld = pad.buttonB.isPressed
            let map: [(Bool, Button)] = [
                (pad.buttonA.isPressed, .a), (pad.buttonB.isPressed, .b),
                (pad.buttonX.isPressed, .x), (pad.buttonY.isPressed, .y),
                (pad.dpad.left.isPressed, .left), (pad.dpad.right.isPressed, .right),
                (pad.dpad.up.isPressed, .up), (pad.dpad.down.isPressed, .down),
                (pad.leftShoulder.isPressed, .l1), (pad.rightShoulder.isPressed, .r1),
                (pad.buttonMenu.isPressed, .menu), (pad.buttonOptions?.isPressed == true, .view),
                (pad.leftThumbstickButton?.isPressed == true, .l3),
                (pad.rightThumbstickButton?.isPressed == true, .r3),
            ]
            for (down, b) in map where down { now.insert(b) }
        }
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            func k(_ c: GCKeyCode) -> Float { kb.button(forKeyCode: c)?.isPressed == true ? 1 : 0 }
            s.move += SIMD2(k(.keyD) - k(.keyA), k(.keyW) - k(.keyS))
            s.look += SIMD2(k(.rightArrow) - k(.leftArrow), k(.upArrow) - k(.downArrow)) * 0.6
            s.shoulders += k(.keyE) - k(.keyQ)
            s.triggers += (k(.keyC) - k(.keyZ)) * 0.6
            if k(.tab) > 0 { s.bHeld = true }
            let keys: [(GCKeyCode, Button)] = [
                (.spacebar, .a), (.tab, .b), (.keyL, .x), (.keyR, .y),
                (.one, .left), (.two, .right), (.four, .up), (.three, .down),
                (.keyQ, .l1), (.keyE, .r1), (.zero, .menu), (.keyK, .view),
                (.keyG, .l3), (.keyM, .r3), (.keyU, .cycleUp),
            ]
            for (code, b) in keys where k(code) > 0 { now.insert(b) }
        }
        s.move = simd_clamp(s.move, SIMD2<Float>(repeating: -1), SIMD2<Float>(repeating: 1))
        s.pressed = now.subtracting(held)
        held = now
        return s
    }
}
