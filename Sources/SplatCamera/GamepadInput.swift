import AppKit
import Foundation
import GameController
import simd

/// A game controller (Xbox / PlayStation / MFi), or keyboard and mouse laid out
/// like a first-person game. Buttons are reported by pad position; what they
/// do depends on the mode (see Viewer: camera, lighting, light table).
///
/// Keyboard and mouse (click in the window to take the mouse, Esc to let go):
///   mouse look · WASD walk · Shift run · Space / Ctrl rise / sink (also E / Q)
///   left click shutter · right button (hold) depth-of-field preview
///   wheel focus ring · [ ] aperture · - = shutter speed · 1-8 lens from the bag
///   R new roll (reload) · L lighting · Tab light table · H reset view · U up axis
/// Lighting: 1-9 fly that light (its own view; the same keys move and aim it),
///   0 or ` back to the camera's view · F add a light · Backspace remove ·
///   T change head · [ ] previous / next light · - = dimmer · wheel flood / spot ·
///   G house lights
/// Light table: the mouse is the loupe · wheel its power · click marks a keeper ·
///   arrows choose · Q / E roll · Tab or Esc back
final class GamepadInput {
    struct State {
        var move = SIMD2<Float>(0, 0)   // left stick
        var look = SIMD2<Float>(0, 0)   // right stick
        var shoulders: Float = 0        // R1 - L1, held
        var triggers: Float = 0         // R2 - L2
        var bHeld = false
        var pressed: Set<Button> = []   // pressed since the last poll
        var mouseLook = SIMD2<Float>(0, 0)  // mouse travel since the last poll (points, + right / up)
        var wheel: Float = 0                // wheel travel since the last poll (+ away from you)
        var digit: Int?                     // number key pressed: 1-9, or 0 (also `)
        var run = false                     // Shift held
        var pointer: CGPoint?               // mouse in the window (light table), view points
    }
    enum KeyMode { case camera, lighting, sheet }
    /// Which layout the keyboard is in (set by the viewer).
    var keyMode = KeyMode.camera
    /// The view the mouse is taken by (mouse look) and reported over.
    weak var view: NSView?
    enum Button: Hashable {
        case a, b, x, y, left, right, up, down, l1, r1, menu, view, l3, r3, cycleUp
    }

    private var held: Set<Button> = []
    private(set) var controllerName: String?
    private var mouseDelta = SIMD2<Float>(0, 0)
    private var heldSlots: Set<Int> = []
    private var wheelDelta: Float = 0
    private var leftClick = false, rightHeld = false
    private(set) var mouseCaptured = false

    init() {
        // Mouse and keys arrive as AppKit events; eat the keys so the window does not beep.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { _ in nil }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                                    .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                                    .rightMouseUp, .scrollWheel]) { [weak self] e in
            self?.handle(e)
            return e
        }
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

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            if mouseCaptured { mouseDelta += SIMD2(Float(e.deltaX), Float(-e.deltaY)) }
        case .leftMouseDown:
            // The first click only takes the mouse; after that it is the shutter.
            if keyMode != .sheet && !mouseCaptured { capture(true) } else { leftClick = true }
        case .rightMouseDown: rightHeld = true
        case .rightMouseUp: rightHeld = false
        case .scrollWheel:
            wheelDelta += Float(e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 10 : e.scrollingDeltaY)
        default: break
        }
    }

    /// Mouse look: hide the pointer and keep it from wandering off the window.
    func capture(_ on: Bool) {
        guard on != mouseCaptured else { return }
        mouseCaptured = on
        CGAssociateMouseAndMouseCursorPosition(on ? 0 : 1)
        if on { NSCursor.hide() } else { NSCursor.unhide() }
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
        // The keyboard and mouse only count while this app is in front.
        if !NSApplication.shared.isActive {
            capture(false)
        } else if let kb = GCKeyboard.coalesced?.keyboardInput {
            func k(_ c: GCKeyCode) -> Float { kb.button(forKeyCode: c)?.isPressed == true ? 1 : 0 }
            s.move += SIMD2(k(.keyD) - k(.keyA), k(.keyW) - k(.keyS))
            s.look += SIMD2(k(.rightArrow) - k(.leftArrow), k(.upArrow) - k(.downArrow)) * 0.6
            s.shoulders += k(.spacebar) + k(.keyE) - k(.leftControl) - k(.keyQ)
            s.run = k(.leftShift) + k(.rightShift) > 0
            if rightHeld { s.bHeld = true }
            var keys: [(GCKeyCode, Button)] = [
                (.openBracket, .left), (.closeBracket, .right), (.equalSign, .up), (.hyphen, .down),
                (.keyL, .r3), (.tab, .view), (.keyH, .menu), (.keyU, .cycleUp),
            ]
            switch keyMode {
            case .camera:
                keys += [(.keyR, .y), (.keyG, .l3)]
            case .lighting:
                keys += [(.keyF, .x), (.keyT, .y), (.deleteOrBackspace, .menu), (.keyG, .l3)]
            case .sheet:
                keys += [(.leftArrow, .left), (.rightArrow, .right), (.upArrow, .up), (.downArrow, .down),
                         (.keyQ, .l1), (.keyE, .r1), (.escape, .b), (.returnOrEnter, .a)]
                s.look = .zero
                s.shoulders = 0
            }
            for (code, b) in keys where k(code) > 0 { now.insert(b) }
            let slots: [GCKeyCode] = [.zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine,
                                      .graveAccentAndTilde]
            for (n, code) in slots.enumerated() where k(code) > 0 && !heldSlots.contains(n) { s.digit = n % 10 }
            heldSlots = Set(slots.enumerated().filter { k($0.1) > 0 }.map(\.0))
            if k(.escape) > 0 { capture(false) }
            if leftClick { now.insert(.a) }
            leftClick = false
            s.mouseLook = mouseDelta
            s.wheel = wheelDelta
            if keyMode == .sheet, let v = view, let w = v.window {
                capture(false)
                let p = v.convert(w.mouseLocationOutsideOfEventStream, from: nil)
                if v.bounds.contains(p) { s.pointer = CGPoint(x: p.x, y: v.isFlipped ? p.y : v.bounds.height - p.y) }
            }
        }
        mouseDelta = .zero
        wheelDelta = 0
        s.move = simd_clamp(s.move, SIMD2<Float>(repeating: -1), SIMD2<Float>(repeating: 1))
        s.pressed = now.subtracting(held)
        held = now
        return s
    }
}
