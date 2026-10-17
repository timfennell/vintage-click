import AppKit
import CSpirula
import Foundation
import MetalKit
import simd

/// The camera body in your hands: reads the controls, shows the newest finder
/// frame on the focusing screen at a film cadence, and fires the shutter. The
/// mirror blacks out the finder for the exposure; the frame itself is exposed
/// and developed by the render loop in the background, so you keep shooting.
final class Viewer: NSObject, MTKViewDelegate {
    let width: Int, height: Int
    let device: MTLDevice
    let loop: RenderLoop
    private let queue: MTLCommandQueue
    private let finderPSO: MTLRenderPipelineState
    private let meterPSO: MTLComputePipelineState
    private let wirePSO: MTLRenderPipelineState
    private let meterBuf: MTLBuffer
    private static let meterGrid = (48, 32)
    private static let maxPending = 4

    var camera = FlyCamera()
    var body = CameraBody()
    private var home = FlyCamera()
    private let center: SIMD3<Float>
    private let radius: Float
    private let input = GamepadInput()
    private var meterLum: Float = 0.18
    private var tables: [String: [SIMD4<Float>]] = [:]
    private var lensOn = true
    private var displayFrame = 0
    private var mirrorUpUntil = 0.0
    var hud: ViewfinderHUD?
    var sheet: ContactSheetView?

    /// What the controls are doing: the camera, placing lights, or the contact sheet.
    enum Mode { case camera, lighting, sheet }
    private(set) var mode = Mode.camera
    var lighting = LightingPlot()

    /// Sub-pupils per exposure: more = truer bokeh, longer to develop.
    var cellsPerExposure = 32
    var filmFPS: Double = 24
    /// Scripted runs: where the next developed frame goes, and who to tell.
    var scriptedPath: URL?
    var onSaved: ((String) -> Void)?

    // Timing (finder renders, which is what the GPU can keep up with)
    private var statStart = CACurrentMediaTime()
    private var lastTime = CACurrentMediaTime()
    private var statRender: [Double] = []
    private var statsLine = ""
    var onStats: ((String) -> Void)?

    // Scripted benchmark: orbit for `benchFrames` finder renders, then report.
    var benchFrames = 0
    private var benchCount = 0
    private var benchRender: [Double] = []
    private var benchStart = 0.0
    var onBenchDone: ((String) -> Void)?

    private let inside: Bool

    init(model: SplatModel, width: Int, height: Int, photo: (Int, Int), metresPerUnit: Float,
         inside: Bool = false) throws {
        self.inside = inside
        self.width = width
        self.height = height
        let b = model.bounds()
        center = b.center
        radius = b.radius
        loop = try RenderLoop(model: model, finder: (width, height), photo: photo,
                              background: [0.08, 0.08, 0.09, 1])
        device = loop.device
        queue = device.makeCommandQueue()!
        meterBuf = device.makeBuffer(length: Self.meterGrid.0 * Self.meterGrid.1 * 4,
                                     options: .storageModeShared)!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "fullscreen")
        pd.fragmentFunction = lib.makeFunction(name: "viewfinder")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        finderPSO = try device.makeRenderPipelineState(descriptor: pd)
        let wd = MTLRenderPipelineDescriptor()
        wd.vertexFunction = lib.makeFunction(name: "wire_vertex")
        wd.fragmentFunction = lib.makeFunction(name: "wire_fragment")
        wd.colorAttachments[0].pixelFormat = .bgra8Unorm
        wd.colorAttachments[0].isBlendingEnabled = true
        wd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        wd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        wirePSO = try device.makeRenderPipelineState(descriptor: wd)
        meterPSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "meter")!)
        super.init()

        body.metresPerUnit = metresPerUnit
        print(String(format: "Scene scale: %.4g m per unit (subject radius %.2f m); photos %dx%d",
                     body.metresPerUnit, radius * body.metresPerUnit, photo.0, photo.1))
        // A new session loads a new roll after the ones already in the darkroom.
        body.rollNumber = (ContactSheetView.scanRolls().map(\.number).max() ?? 0) + 1
        loop.onFinderRendered = { [weak self] ms in self?.record(renderMs: ms) }
        loop.onDeveloped = { [weak self] job, image, seconds in self?.developed(job, image, seconds) }
        resetView()
    }

    // MARK: view

    func resetView() {
        let keepUp = camera.up
        camera = FlyCamera()
        camera.up = keepUp
        camera.focalMM = body.lens.focalMM
        camera.moveSpeed = radius * 0.6
        // Back off far enough to frame the subject, beyond the lens's closest focus.
        let dist = max(radius * 1.2 * camera.focalMM / 36 + radius,
                       body.lens.minFocusM * 1.15 / body.metresPerUnit)
        var c = FlyCamera()   // yaw 0, pitch 0: looking along the horizon
        c.up = keepUp
        if inside {
            // Standing in the middle of the place at eye height, looking level.
            camera.position = center + keepUp * (1.6 / body.metresPerUnit)
            camera.moveSpeed = 1.4 / body.metresPerUnit      // walking pace
            home = camera
            body.focusM = max(body.lens.minFocusM, 5)
            return
        }
        let eye = center - c.forward * dist + keepUp * radius * 0.35
        camera.lookAt(center, from: eye)
        home = camera
        body.focusM = max(body.lens.minFocusM, simd_distance(eye, center) * body.metresPerUnit)
    }

    private func cycleUp() {
        let axes: [SIMD3<Float>] = [[0, -1, 0], [0, 0, 1], [0, 1, 0], [0, 0, -1], [1, 0, 0], [-1, 0, 0]]
        let i = axes.firstIndex(of: camera.up) ?? 0
        camera.up = axes[(i + 1) % axes.count]
        resetView()
    }

    private func table(_ b: CameraBody, _ n: Float) -> [SIMD4<Float>] {
        let key = "\(b.lensIndex)@\(n)"
        if let t = tables[key] { return t }
        let t = CameraBody.pupilTable(lens: b.lens, fNumber: n)
        tables[key] = t
        return t
    }

    func setBenchLens(_ on: Bool) { lensOn = on }

    // MARK: frame loop

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastTime))
        lastTime = now
        if benchFrames > 0 { benchOrbit() } else { handleInput(dt: dt) }

        // Looking at prints: the finder rests and the darkroom gets the GPU.
        if mode == .sheet {
            if let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
               let cb = queue.makeCommandBuffer() {
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
                present(cb, drawable)
                cb.commit()
            }
            sheet?.pending = (body.rollNumber, loop.pendingFrames(roll: body.rollNumber))
            return
        }

        // Ask for the next finder frame of where the camera is now.
        let n = body.viewingAperture
        let fx = camera.focalPixels(width: width)
        loop.requestFinder(FinderJob(
            view: camera.viewMatrix, position: camera.position, fx: fx,
            lens: lensOn ? body.lensParams(fNumber: n, focalPx: fx, cells: 1, table: table(body, n)) : nil,
            body: body, lighting: lighting))

        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        displayFrame += 1
        // Mirror up: the finder is black while the shutter is open.
        if now < mirrorUpUntil {
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].loadAction = .clear
            cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
            present(cb, drawable)
            cb.commit()
            updateHUD(mirrorUp: true)
            return
        }
        guard let frame = loop.acquireLatest() else {
            cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
            present(cb, drawable)
            cb.commit()
            return
        }
        var o = finderOptics(frame.job, seed: UInt32(displayFrame))
        var f = frame.job.body.stock.packed

        let ce = cb.makeComputeCommandEncoder()!
        ce.setComputePipelineState(meterPSO)
        ce.setBuffer(frame.buf, offset: frame.off, index: 0)
        ce.setBytes(&o, length: o.count * 16, index: 1)
        ce.setBuffer(meterBuf, offset: 0, index: 2)
        ce.dispatchThreads(MTLSize(width: Self.meterGrid.0, height: Self.meterGrid.1, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        ce.endEncoding()

        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(finderPSO)
        enc.setFragmentBuffer(frame.buf, offset: frame.off, index: 0)
        enc.setFragmentBytes(&o, length: o.count * 16, index: 1)
        enc.setFragmentBytes(&f, length: f.count * 16, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        drawWireframes(enc, frame: frame, optics: &o)
        enc.endEncoding()
        present(cb, drawable)
        let loop = self.loop, slot = frame.slot, meter = meterBuf
        cb.addCompletedHandler { [weak self] _ in
            loop.release(slot: slot)
            let lum = Self.centreWeighted(meter)
            DispatchQueue.main.async { self?.meterLum = lum }
        }
        cb.commit()
        updateHUD(mirrorUp: false)
    }

    /// Optics for the focusing screen (layout in Shaders.swift).
    private func finderOptics(_ job: FinderJob, seed: UInt32) -> [SIMD4<Float>] {
        let b = job.body, l = b.lens
        return [
            SIMD4(Float(width), Float(height), job.fx, job.fx),
            SIMD4(Float(width) / 2, Float(height) / 2, b.metresPerUnit, b.focusM),
            SIMD4(l.focalMM / 1000, b.viewingAperture, l.maxAperture, Float(l.blades)),
            SIMD4(l.catsEye, l.soapBubble, l.bladeRotation, l.vignette),
            loop.background,
            // Stopping down for the depth-of-field preview darkens the screen.
            SIMD4(Float(height) * 0.065, pow(l.maxAperture / b.viewingAperture, 2), Float(seed),
                  b.exposureStops),
            SIMD4(l.lateralCA, l.axialCA, 0, 0),
        ]
    }

    /// The light heads as wireframes on the screen, over the frame they belong to.
    private func drawWireframes(_ enc: MTLRenderCommandEncoder,
                                frame: (buf: MTLBuffer, off: Int, slot: Int, job: FinderJob),
                                optics o: inout [SIMD4<Float>]) {
        let plot = frame.job.lighting
        guard !plot.lights.isEmpty else { return }
        let V = frame.job.view, fx = frame.job.fx
        let scale = frame.job.body.metresPerUnit
        let focusUnits = frame.job.body.focusM / scale
        func cam(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(V[0] * p.x + V[1] * p.y + V[2] * p.z + V[3],
                  V[4] * p.x + V[5] * p.y + V[6] * p.z + V[7],
                  V[8] * p.x + V[9] * p.y + V[10] * p.z + V[11])
        }
        let near = 0.02 / scale
        for (i, light) in plot.lights.enumerated() {
            let chosen = mode == .lighting && i == plot.selected
            let target = simd_distance(light.position, camera.position + camera.forward * focusUnits)
            let segs = light.wireframe(up: camera.up, metresPerUnit: scale, beamTo: chosen ? target : nil)
            var verts: [SIMD4<Float>] = []
            for (a, b) in segs {
                var pa = cam(a), pb = cam(b)
                if pa.z < near && pb.z < near { continue }
                // Clip to just in front of the lens.
                if pa.z < near { pa = pb + (pa - pb) * ((pb.z - near) / (pb.z - pa.z)) }
                if pb.z < near { pb = pa + (pb - pa) * ((pa.z - near) / (pa.z - pb.z)) }
                for q in [pa, pb] {
                    verts.append(SIMD4(fx * q.x / q.z + Float(width) / 2, fx * q.y / q.z + Float(height) / 2,
                                       q.z * scale, 1))
                }
            }
            guard !verts.isEmpty,
                  let vb = device.makeBuffer(bytes: verts, length: verts.count * 16, options: .storageModeShared)
            else { continue }
            var colour: SIMD4<Float> = chosen ? [1.0, 0.72, 0.25, 0.95] : [0.85, 0.88, 0.9, 0.55]
            enc.setRenderPipelineState(wirePSO)
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setVertexBytes(&o, length: o.count * 16, index: 1)
            enc.setFragmentBuffer(frame.buf, offset: frame.off, index: 0)
            enc.setFragmentBytes(&o, length: o.count * 16, index: 1)
            enc.setFragmentBytes(&colour, length: 16, index: 2)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: verts.count)
        }
    }

    private func present(_ cb: MTLCommandBuffer, _ drawable: MTLDrawable) {
        // A film cadence wants even frame spacing: hold each frame for its
        // full 1/fps (24 fps lands on every 5th refresh of a 120 Hz display).
        if filmFPS > 0 && benchFrames == 0 {
            cb.present(drawable, afterMinimumDuration: 1 / filmFPS)
        } else {
            cb.present(drawable)
        }
    }

    private static func centreWeighted(_ buf: MTLBuffer) -> Float {
        let (gw, gh) = meterGrid
        let v = buf.contents().bindMemory(to: Float.self, capacity: gw * gh)
        var sum: Float = 0, wsum: Float = 0
        for y in 0..<gh {
            for x in 0..<gw {
                let u = (Float(x) + 0.5) / Float(gw) - 0.5, w2 = (Float(y) + 0.5) / Float(gh) - 0.5
                let w = 0.25 + exp(-(u * u + w2 * w2) / 0.03)   // centre-weighted
                sum += w * v[y * gw + x]
                wsum += w
            }
        }
        return sum / wsum
    }

    private func handleInput(dt: Float) {
        let s = input.poll()
        let p = s.pressed
        if p.contains(.cycleUp) { cycleUp() }
        switch mode {
        case .sheet:
            sheetInput(s, dt: dt)
            return
        case .camera:
            if p.contains(.left) { body.changeAperture(-1) }
            if p.contains(.right) { body.changeAperture(1) }
            if p.contains(.up) { body.changeShutter(1) }
            if p.contains(.down) { body.changeShutter(-1) }
            if p.contains(.x) { body.nextLens() }
            if p.contains(.y) { body.loadNextRoll() }
            if p.contains(.l3) {
                let walk = inside ? 1.4 / body.metresPerUnit : radius * 0.6
            camera.moveSpeed = camera.moveSpeed > walk * 1.5 ? walk : walk * 4
            }
            body.dofPreview = s.bHeld
            body.turnFocus(s.triggers, dt: dt)
        case .lighting:
            lightingInput(s, dt: dt)
            body.dofPreview = false
        }
        if p.contains(.menu) { camera = home }
        if p.contains(.view) { openSheet() }
        if p.contains(.r3) {
            mode = mode == .lighting ? .camera : .lighting
            lighting.carrying = false
        }
        camera.update(FlyInput(move: s.move, look: s.look, rise: s.shoulders, zoom: 0), dt: dt)
        camera.focalMM = body.lens.focalMM
        if lighting.carrying, lighting.lights.indices.contains(lighting.selected) {
            carry(&lighting.lights[lighting.selected])
        }
        if mode == .camera && p.contains(.a) { releaseShutter() }
    }

    /// Placing lights: walk them into position, aim them where you look.
    private func lightingInput(_ s: GamepadInput.State, dt: Float) {
        let p = s.pressed
        var plot = lighting
        if p.contains(.x) {
            plot.lights.append(PlacedLight(head: plot.kitChoice, position: camera.position, aim: camera.forward))
            plot.selected = plot.lights.count - 1
            plot.carrying = true
        }
        if p.contains(.y) {
            plot.kitChoice = (plot.kitChoice + 1) % lightKit.count
            if plot.lights.indices.contains(plot.selected) { plot.lights[plot.selected].head = plot.kitChoice }
        }
        if !plot.lights.isEmpty {
            if p.contains(.left) { plot.selected = (plot.selected + plot.lights.count - 1) % plot.lights.count; plot.carrying = false }
            if p.contains(.right) { plot.selected = (plot.selected + 1) % plot.lights.count; plot.carrying = false }
            plot.selected = min(plot.selected, plot.lights.count - 1)
            if p.contains(.a) { plot.carrying.toggle() }
            if p.contains(.b) {
                plot.lights.remove(at: plot.selected)
                plot.selected = max(0, plot.selected - 1)
                plot.carrying = false
            }
            if !plot.lights.isEmpty {
                var l = plot.lights[plot.selected]
                if p.contains(.up) { l.dimmerStops = min(0, l.dimmerStops + 0.5) }
                if p.contains(.down) { l.dimmerStops = max(-4, l.dimmerStops - 0.5) }
                l.spot = max(0, min(1, l.spot + s.triggers * dt * 0.8))
                plot.lights[plot.selected] = l
            }
        }
        if p.contains(.l3) { plot.cycleHouseLights() }
        lighting = plot
    }

    /// A light in hand: held out in front, aimed at the point you are focused on.
    private func carry(_ l: inout PlacedLight) {
        let focusUnits = body.focusM / body.metresPerUnit
        let target = camera.position + camera.forward * focusUnits
        l.position = camera.position + camera.forward * focusUnits * 0.35
        l.aim = simd_normalize(target - l.position)
    }

    /// A classic setup for scripted runs: a hard Fresnel key high at 45 degrees,
    /// a broad softlight fill from the other side, house lights down.
    func startLighting() { mode = .lighting }

    func demoLights() {
        let subject = camera.position + camera.forward * (body.focusM / body.metresPerUnit)
        func place(_ head: Int, side: Float, up: Float, metres: Float, spot: Float) -> PlacedLight {
            let toCam = simd_normalize(camera.position - subject)
            let dir = simd_normalize(toCam * cos(side) + camera.right * sin(side) + camera.up * up)
            let pos = subject + dir * (metres / body.metresPerUnit)
            var l = PlacedLight(head: head, position: pos, aim: simd_normalize(subject - pos))
            l.spot = spot
            return l
        }
        lighting.lights = [place(2, side: -0.8, up: 0.7, metres: 2.0, spot: 0.6),
                           place(3, side: 0.9, up: 0.2, metres: 2.2, spot: 0)]
        lighting.ambient = 0.1
    }

    // MARK: contact sheet

    func openSheet() {
        guard let sheet else { return }
        mode = .sheet
        sheet.reload(showRoll: body.rollNumber)
        sheet.pending = (body.rollNumber, loop.pendingFrames(roll: body.rollNumber))
        sheet.isHidden = false
        hud?.isHidden = true
    }

    private func closeSheet() {
        mode = .camera
        sheet?.isHidden = true
        hud?.isHidden = false
    }

    private func sheetInput(_ s: GamepadInput.State, dt: Float) {
        guard let sheet else { return }
        let p = s.pressed
        // Either stick slides the loupe over the table; the triggers turn its power.
        let v = s.move + s.look
        let speed = CGFloat(sheet.bounds.height) * 0.9
        sheet.handleLoupe(move: CGVector(dx: CGFloat(v.x) * speed, dy: CGFloat(-v.y) * speed),
                          power: CGFloat(s.triggers) * 1.2, dt: CGFloat(dt))
        let dx = (p.contains(.right) ? 1 : 0) - (p.contains(.left) ? 1 : 0)
        let dy = (p.contains(.down) ? 1 : 0) - (p.contains(.up) ? 1 : 0)
        if dx != 0 || dy != 0 { sheet.move(dx: dx, dy: dy) }
        if p.contains(.l1) { sheet.changeRoll(-1) }
        if p.contains(.r1) { sheet.changeRoll(1) }
        if p.contains(.a) { sheet.toggleMark() }
        if p.contains(.b) || p.contains(.view) { closeSheet() }
        if loop.pendingFrames(roll: body.rollNumber) != sheet.pending.frames { sheet.reload(showRoll: nil) }
    }


    // MARK: shutter

    /// Fires: the mirror swings up for the exposure, the film advances, and
    /// the frame is exposed and developed in the background.
    func releaseShutter() {
        guard body.framesLeft > 0 else {
            hud?.flash("END OF ROLL — load a new one")
            return
        }
        guard loop.pendingExposures < Self.maxPending, let accum = loop.makeAccumulator() else {
            hud?.flash("BUFFER FULL")
            return
        }
        let job = ExposureJob(camera: camera, body: body, lighting: lighting, frameNumber: body.framesShot + 1,
                              cells: body.cellCentres(cellsPerExposure), accum: accum)
        job.outputPath = scriptedPath
        loop.expose(job)
        body.framesShot += 1
        // Mirror travel (~1/15 s round trip) plus the shutter time.
        mirrorUpUntil = CACurrentMediaTime() + 0.07 + Double(body.shutter.seconds)
        print("Shutter: frame \(job.frameNumber), \(body.lens.name) f/\(body.takingAperture) " +
              "1/\(body.shutter.label), focus \(String(format: "%.2f", body.focusM)) m")
    }

    private func developed(_ job: ExposureJob, _ image: CGImage, _ seconds: Double) {
        let b = job.body
        let url: URL
        if let p = job.outputPath {
            url = p
        } else {
            let dir = ContactSheetView.root
                .appendingPathComponent(String(format: "Roll %02d - %@", b.rollNumber, b.stock.name))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent(String(format: "frame-%02d.png", job.frameNumber))
        }
        print(String(format: "Developed frame %d in %.1f s", job.frameNumber, seconds))
        let meta: [String: Any] = [
            "lens": b.lens.name, "lens_inspired_by": b.lens.inspiredBy,
            "aperture": b.takingAperture, "shutter": "1/\(b.shutter.label)",
            "film": b.stock.name, "iso": b.stock.iso, "focus_m": b.focusM,
            "exposure_stops": b.exposureStops, "sub_pupils": job.cells.count,
            "metres_per_unit": b.metresPerUnit, "width": image.width, "height": image.height,
        ]
        // Writing a big PNG takes a moment: off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            if let json = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: url.deletingPathExtension().appendingPathExtension("json"))
            }
            DispatchQueue.main.async {
                self?.onSaved?(url.path)
                if self?.mode == .sheet { self?.sheet?.reload(showRoll: nil) }
            }
        }
    }

    // MARK: HUD and stats

    private func updateHUD(mirrorUp: Bool) {
        guard let hud else { return }
        let b = body
        var i = ViewfinderHUD.Info()
        i.lens = b.lens.name
        i.aperture = String(format: b.takingAperture < 10 ? "%.1f" : "%.0f", b.takingAperture)
        i.shutter = b.shutter.seconds >= 1 ? "\(b.shutter.label)s" : "1/\(b.shutter.label)"
        i.stock = b.stock.name
        i.iso = Int(b.stock.iso)
        i.counter = b.framesLeft > 0 ? "\(b.framesShot + 1)/\(b.stock.exposures)" : "END"
        i.focus = b.focusM >= 100 ? "∞" : String(format: "%.2f m", b.focusM)
        i.meterStops = b.exposureStops + log2(max(meterLum, 1e-4) / 0.18)
        var modes: [String] = []
        if b.dofPreview { modes.append("DOF PREVIEW") }
        if mode == .lighting { modes.append("LIGHTING") }
        let pending = loop.pendingExposures
        if pending > 0 { modes.append("DEVELOPING \(pending)") }
        i.mode = modes.joined(separator: "  ")
        i.stats = statsLine
        i.mirrorUp = mirrorUp
        if mode == .lighting {
            var lines = lighting.lights.enumerated().map { k, l -> String in
                let mark = k == lighting.selected ? (lighting.carrying ? "▶ in hand" : "▶") : " "
                return String(format: "%@ %d %@  beam %.0f°  %@", mark, k + 1, l.kit.name, l.beamAngle,
                              l.dimmerStops == 0 ? "full" : String(format: "%+.1f stop", l.dimmerStops))
            }
            lines.append(String(format: "House lights %.0f%%   ·   X adds a %@", lighting.ambient * 100,
                                lightKit[lighting.kitChoice].name))
            lines.append("A take/place · B remove · Y change head · ◀▶ choose · ▲▼ dimmer · L2/R2 flood/spot · L3 house lights · R3 done")
            i.lines = lines
        }
        hud.info = i
    }

    private func benchOrbit() {
        let a = Float(benchCount) / Float(benchFrames) * 2 * .pi
        var c = FlyCamera()
        c.up = camera.up
        let a0 = c.forward, b0 = simd_cross(camera.up, a0)
        let dist = simd_distance(home.position, center)
        let around: SIMD3<Float> = cos(a) * -a0 + sin(a) * b0
        let lift: SIMD3<Float> = camera.up * (radius * 0.35)
        let eye = center + around * dist + lift
        camera.lookAt(center, from: eye)
        body.focusM = simd_distance(eye, center) * body.metresPerUnit
    }

    private func record(renderMs: Double) {
        let now = CACurrentMediaTime()
        statRender.append(renderMs)
        if now - statStart >= 1 {
            let fps = Double(statRender.count) / (now - statStart)
            let mean = statRender.reduce(0, +) / Double(statRender.count)
            statsLine = String(format: "finder %.1f renders/s | render %.1f ms (max %.1f) | %dx%d%@",
                               fps, mean, statRender.max() ?? 0, width, height,
                               input.controllerName.map { " | \($0)" } ?? " | no controller")
            onStats?(statsLine)
            statStart = now
            statRender.removeAll()
        }
        guard benchFrames > 0 else { return }
        // Skip the first renders: shader pipelines and buffers warm up.
        if benchCount >= 10 { benchRender.append(renderMs) } else { benchStart = now }
        benchCount += 1
        if benchCount == benchFrames + 10 {
            let s = benchRender.sorted()
            let report = String(format: "bench %dx%d %@ f/%.1f: %.1f renders/s wall | render mean %.2f ms, median %.2f, p95 %.2f, max %.2f (%d frames)",
                                width, height, lensOn ? body.lens.name : "pinhole",
                                body.viewingAperture, Double(s.count) / (now - benchStart),
                                s.reduce(0, +) / Double(s.count), s[s.count / 2],
                                s[Int(Double(s.count) * 0.95)], s.last!, s.count)
            benchFrames = 0
            onBenchDone?(report)
        }
    }
}
