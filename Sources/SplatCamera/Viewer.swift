import AppKit
import CSpirula
import Foundation
import MetalKit
import simd

struct SpirulaError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String) { description = "\(what): \(String(cString: sr_last_error()))" }
}

/// The camera: the finder shows Spirula's render through the lens (depth of
/// field made by the projection, sr_set_lens) on a focusing screen; the
/// shutter exposes the film by adding up renders from sub-pupils of the
/// taking aperture, then develops it with the loaded stock.
final class Viewer: NSObject, MTKViewDelegate {
    let width: Int, height: Int
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let finderPSO: MTLRenderPipelineState
    private let printPSO: MTLRenderPipelineState
    private let meterPSO: MTLComputePipelineState
    private let accumulatePSO: MTLComputePipelineState
    private let developPSO: MTLComputePipelineState
    private var frames: [(MTLBuffer, Int)] = []
    private let accum: MTLBuffer
    private let print: MTLBuffer
    private let meterBuf: MTLBuffer
    private static let meterGrid = (48, 32)
    private let inFlight: DispatchSemaphore
    private var frameIndex = 0

    var camera = FlyCamera()
    var body = CameraBody()
    private var home = FlyCamera()
    private let center: SIMD3<Float>
    private let radius: Float
    private let input = GamepadInput()
    private let background: SIMD4<Float> = [0.08, 0.08, 0.09, 1]
    private var meterLum: Float = 0.18
    private var tables: [String: [SIMD4<Float>]] = [:]
    private var lensOn = true
    var hud: ViewfinderHUD?

    /// Sub-pupils per exposure: more = truer bokeh, slower shutter.
    var cellsPerExposure = 32
    var filmFPS: Double = 24

    private enum Mode {
        case finder
        case exposing(Exposure)
        case review(String)
    }
    private struct Exposure {
        var camera: FlyCamera
        var body: CameraBody
        var cells: [SIMD2<Float>]
        var next = 0
        var started = CACurrentMediaTime()
    }
    private var mode = Mode.finder

    // Timing
    private var lastTime = CACurrentMediaTime()
    private var statStart = CACurrentMediaTime()
    private var statFrames = 0
    private var statRender: [Double] = []
    private var statsLine = ""
    var onStats: ((String) -> Void)?

    // Scripted benchmark: orbit for `benchFrames` frames, then report and quit.
    var benchFrames = 0
    private var benchCount = 0
    private var benchRender: [Double] = []
    private var benchStart = 0.0
    var onBenchDone: ((String) -> Void)?

    init(model: SplatModel, width: Int, height: Int, metresPerUnit: Float?) throws {
        self.width = width
        self.height = height
        let b = model.bounds()
        center = b.center
        radius = b.radius

        let ok = model.means.withUnsafeBufferPointer { m in
            model.quats.withUnsafeBufferPointer { q in
                model.scales.withUnsafeBufferPointer { s in
                    model.opacities.withUnsafeBufferPointer { o in
                        model.dc.withUnsafeBufferPointer { dc in
                            model.sh.withUnsafeBufferPointer { sh in
                                sr_set_splats(Int64(model.count), Int32(model.shDegree), m.baseAddress,
                                              q.baseAddress, s.baseAddress, o.baseAddress,
                                              dc.baseAddress, model.shDegree > 0 ? sh.baseAddress : nil)
                            }}}}}}
        if ok != 0 { throw SpirulaError("loading splats") }

        let count = 2
        var bufs = [UnsafeMutableRawPointer?](repeating: nil, count: count)
        var offs = [Int](repeating: 0, count: count)
        if sr_shared_frames(Int32(width), Int32(height), Int32(count), &bufs, &offs) != 0 {
            throw SpirulaError("sharing frames with Metal")
        }
        var shared: [(MTLBuffer, Int)] = []
        for i in 0..<count {
            let buf = Unmanaged<MTLBuffer>.fromOpaque(bufs[i]!).takeUnretainedValue()
            shared.append((buf, offs[i]))
        }
        frames = shared
        inFlight = DispatchSemaphore(value: count)
        // Draw on the GPU Spirula renders on, so the buffers are directly usable.
        let device = shared[0].0.device
        self.device = device
        queue = device.makeCommandQueue()!
        accum = device.makeBuffer(length: width * height * 16, options: .storageModePrivate)!
        print = device.makeBuffer(length: width * height * 4, options: .storageModeShared)!
        meterBuf = device.makeBuffer(length: Self.meterGrid.0 * Self.meterGrid.1 * 4,
                                     options: .storageModeShared)!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        func render(_ frag: String) throws -> MTLRenderPipelineState {
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: "fullscreen")
            pd.fragmentFunction = lib.makeFunction(name: frag)
            pd.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: pd)
        }
        func compute(_ name: String) throws -> MTLComputePipelineState {
            try device.makeComputePipelineState(function: lib.makeFunction(name: name)!)
        }
        finderPSO = try render("viewfinder")
        printPSO = try render("show_print")
        meterPSO = try compute("meter")
        accumulatePSO = try compute("accumulate")
        developPSO = try compute("develop")
        super.init()

        // Scans have no scale: unless told, call the subject a 60 cm still life.
        body.metresPerUnit = metresPerUnit ?? 0.3 / radius
        Swift.print(String(format: "Scene scale: %.4g m per unit (subject radius %.2f m)",
                           body.metresPerUnit, radius * body.metresPerUnit))
        resetView()
    }

    // MARK: view

    func resetView() {
        let keepUp = camera.up
        camera = FlyCamera()
        camera.up = keepUp
        camera.focalMM = body.lens.focalMM
        camera.moveSpeed = radius * 0.6
        // Back off far enough to frame the subject, a little above it.
        let dist = max(radius * 1.2 * camera.focalMM / 36 + radius,
                       body.lens.minFocusM * 1.15 / body.metresPerUnit)
        var c = FlyCamera()   // yaw 0, pitch 0: looking along the horizon
        c.up = keepUp
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

    /// Optics for the shaders (layout in Shaders.swift).
    private func optics(_ b: CameraBody, fNumber n: Float, cx: Float, cy: Float, fx: Float,
                        filmPreview: Bool, seed: UInt32) -> [SIMD4<Float>] {
        let l = b.lens
        return [
            SIMD4(Float(width), Float(height), fx, fx),
            SIMD4(cx, cy, b.metresPerUnit, b.focusM),
            SIMD4(l.focalMM / 1000, n, l.maxAperture, Float(l.blades)),
            SIMD4(l.catsEye, l.soapBubble, l.bladeRotation, l.vignette),
            background,
            SIMD4(Float(height) * 0.065, filmPreview ? 1 : 0, Float(seed), b.exposureStops),
        ]
    }

    private func setLens(_ params: [SIMD4<Float>]?) {
        let rc: Int32
        if let p = params {
            rc = p.withUnsafeBytes { sr_set_lens($0.baseAddress!.assumingMemoryBound(to: Float.self), Int32(p.count)) }
        } else {
            rc = sr_set_lens(nil, 0)
        }
        if rc != 0 { Swift.print(SpirulaError("lens")) }
    }

    private func render(slot: Int, view: [Float], fx: Float, cx: Float, cy: Float) -> Bool {
        let rc = view.withUnsafeBufferPointer {
            sr_render_to_frame(Int32(slot), $0.baseAddress, fx, fx, cx, cy, "3dgs")
        }
        if rc != 0 { Swift.print(SpirulaError("render")) }
        return rc == 0
    }

    // MARK: frame loop

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastTime))
        lastTime = now
        switch mode {
        case .finder: drawFinder(view, now: now, dt: dt)
        case .exposing(var e): expose(&e, view)
        case .review(let what): drawReview(view, what)
        }
    }

    private func handleFinderInput(dt: Float) {
        let s = input.poll()
        let p = s.pressed
        if p.contains(.reset) { camera = home }
        if p.contains(.cycleUp) { cycleUp() }
        if p.contains(.apertureOpen) { body.changeAperture(-1) }
        if p.contains(.apertureClose) { body.changeAperture(1) }
        if p.contains(.shutterFaster) { body.changeShutter(1) }
        if p.contains(.shutterSlower) { body.changeShutter(-1) }
        if p.contains(.filmPreview) { body.filmPreview.toggle() }
        if p.contains(.walkSpeed) {
            camera.moveSpeed = camera.moveSpeed > radius ? radius * 0.6 : radius * 2.4
        }
        if p.contains(.nextLens) {
            body.nextLens()
            camera.focalMM = body.lens.focalMM
        }
        if p.contains(.newRoll) { body.loadNextRoll() }
        body.dofPreview = s.dofPreview
        body.turnFocus(s.focus, dt: dt)
        camera.update(FlyInput(move: s.move, look: s.look, rise: s.rise, zoom: 0), dt: dt)
        camera.focalMM = body.lens.focalMM
        if p.contains(.shutter) { releaseShutter() }
    }

    private func drawFinder(_ view: MTKView, now: Double, dt: Float) {
        if benchFrames > 0 {
            benchOrbit()
        } else {
            handleFinderInput(dt: dt)
            if case .exposing = mode { return }
        }
        let n = body.viewingAperture
        let fx = camera.focalPixels(width: width)
        setLens(lensOn ? body.lensParams(fNumber: n, focalPx: fx, cells: 1, table: table(body, n)) : nil)

        inFlight.wait()
        let slot = frameIndex % frames.count
        frameIndex += 1
        let t0 = CACurrentMediaTime()
        let ok = render(slot: slot, view: camera.viewMatrix, fx: fx, cx: Float(width) / 2, cy: Float(height) / 2)
        let renderMs = (CACurrentMediaTime() - t0) * 1000
        guard ok, let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        var o = optics(body, fNumber: n, cx: Float(width) / 2, cy: Float(height) / 2, fx: fx,
                       filmPreview: body.filmPreview, seed: UInt32(frameIndex))
        var f = body.stock.packed
        let frame = frames[slot]

        let ce = cb.makeComputeCommandEncoder()!
        ce.setComputePipelineState(meterPSO)
        ce.setBuffer(frame.0, offset: frame.1, index: 0)
        ce.setBytes(&o, length: o.count * 16, index: 1)
        ce.setBuffer(meterBuf, offset: 0, index: 2)
        ce.dispatchThreads(MTLSize(width: Self.meterGrid.0, height: Self.meterGrid.1, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        ce.endEncoding()

        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(finderPSO)
        enc.setFragmentBuffer(frame.0, offset: frame.1, index: 0)
        enc.setFragmentBytes(&o, length: o.count * 16, index: 1)
        enc.setFragmentBytes(&f, length: f.count * 16, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        present(cb, drawable)
        let sem = inFlight
        let meter = meterBuf
        cb.addCompletedHandler { [weak self] _ in
            let lum = Self.centreWeighted(meter)
            DispatchQueue.main.async { self?.meterLum = lum }
            sem.signal()
        }
        cb.commit()
        record(renderMs: renderMs, now: now)
        updateHUD()
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

    // MARK: shutter

    private func releaseShutter() {
        guard body.framesLeft > 0 else {
            Swift.print("Roll finished: load a new one")
            return
        }
        let e = Exposure(camera: camera, body: body, cells: body.cellCentres(cellsPerExposure))
        mode = .exposing(e)
        Swift.print("Shutter: \(body.lens.name) f/\(body.takingAperture) 1/\(body.shutter.label) " +
                    "focus \(String(format: "%.2f", body.focusM)) m, \(e.cells.count) sub-pupils")
    }

    /// One sub-pupil per frame, so the window stays live while the film is exposed.
    private func expose(_ e: inout Exposure, _ view: MTKView) {
        let b = e.body
        let n = b.takingAperture
        let fx = e.camera.focalPixels(width: width)
        let radiusUnits = b.lens.focalMM / 1000 / n / 2 / b.metresPerUnit
        let invFocus = b.metresPerUnit / b.focusM
        setLens(b.lensParams(fNumber: n, focalPx: fx, cells: e.cells.count, table: nil))

        inFlight.wait()
        let slot = frameIndex % frames.count
        frameIndex += 1
        // Shear the view to this lens point, keeping the focus plane in place.
        let c = e.cells[e.next]
        let d = c * radiusUnits
        var vm = e.camera.viewMatrix
        vm[3] -= d.x
        vm[7] -= d.y
        let ok = render(slot: slot, view: vm, fx: fx, cx: Float(width) / 2 + fx * d.x * invFocus,
                        cy: Float(height) / 2 + fx * d.y * invFocus)
        guard ok, let cb = queue.makeCommandBuffer() else {
            inFlight.signal()
            mode = .finder
            return
        }
        var o = optics(b, fNumber: n, cx: Float(width) / 2, cy: Float(height) / 2, fx: fx,
                       filmPreview: false, seed: UInt32(b.rollNumber * 100 + b.framesShot))
        var l = SIMD4<Float>(c.x, c.y, 1, e.next == 0 ? 1 : 0)
        let grid = MTLSize(width: width, height: height, depth: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let ce = cb.makeComputeCommandEncoder()!
        ce.setComputePipelineState(accumulatePSO)
        ce.setBuffer(frames[slot].0, offset: frames[slot].1, index: 0)
        ce.setBytes(&o, length: o.count * 16, index: 1)
        ce.setBuffer(accum, offset: 0, index: 2)
        ce.setBytes(&l, length: 16, index: 3)
        ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
        e.next += 1
        let done = e.next == e.cells.count
        if done {
            // Light through the unclipped centre of the frame sets the scale.
            let full = e.cells.reduce(Float(0)) { $0 + pupilWeight($1, q: .zero, lens: b.lens, fNumber: n) }
            var dv = SIMD4<Float>(1 / max(full, 1e-6), 0, 0, 0)
            var f = b.stock.packed
            ce.setComputePipelineState(developPSO)
            ce.setBuffer(accum, offset: 0, index: 0)
            ce.setBytes(&o, length: o.count * 16, index: 1)
            ce.setBytes(&f, length: f.count * 16, index: 2)
            ce.setBytes(&dv, length: 16, index: 3)
            ce.setBuffer(print, offset: 0, index: 4)
            ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
        }
        ce.endEncoding()
        // Mirror up: the finder is dark while the shutter is open.
        if let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable {
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].loadAction = .clear
            cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
            present(cb, drawable)
        }
        let sem = inFlight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
        hud?.info.mode = "EXPOSING  \(e.next)/\(e.cells.count)"
        if done {
            cb.waitUntilCompleted()
            let seconds = CACurrentMediaTime() - e.started
            let path = saveFrame(e, to: scriptedPath)
            body.framesShot += 1
            mode = .review(String(format: "Frame %d of %@ · developed in %.1f s · A to continue",
                                  b.framesShot + 1, b.stock.name, seconds))
            Swift.print("Developed \(path) in \(String(format: "%.1f", seconds)) s")
            onDeveloped?(path)
        } else {
            mode = .exposing(e)
        }
    }

    private func drawReview(_ view: MTKView, _ what: String) {
        let s = input.poll()
        if s.pressed.contains(.shutter) || s.dofPreview || s.pressed.contains(.reset) {
            mode = .finder
            return
        }
        inFlight.wait()
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        var o = optics(body, fNumber: body.takingAperture, cx: 0, cy: 0, fx: 1, filmPreview: false, seed: 0)
        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(printPSO)
        enc.setFragmentBuffer(print, offset: 0, index: 0)
        enc.setFragmentBytes(&o, length: o.count * 16, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        present(cb, drawable)
        let sem = inFlight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
        hud?.info = ViewfinderHUD.Info(mode: what, reviewing: true)
    }

    /// The developed frame, as a PNG with a JSON of how it was taken.
    @discardableResult
    private func saveFrame(_ e: Exposure, to url: URL? = nil) -> String {
        let b = e.body
        let w = width, h = height
        let px = print.contents()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let out: URL
        if let url {
            out = url
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/Splat Camera")
                .appendingPathComponent(String(format: "Roll %02d - %@", b.rollNumber, b.stock.name))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            out = dir.appendingPathComponent(String(format: "frame-%02d.png", b.framesShot + 1))
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: out)
        let meta: [String: Any] = [
            "lens": b.lens.name, "lens_inspired_by": b.lens.inspiredBy,
            "aperture": b.takingAperture, "shutter": "1/\(b.shutter.label)",
            "film": b.stock.name, "iso": b.stock.iso, "focus_m": b.focusM,
            "exposure_stops": b.exposureStops, "sub_pupils": e.cells.count,
            "metres_per_unit": b.metresPerUnit,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: out.deletingPathExtension().appendingPathExtension("json"))
        }
        return out.path
    }

    /// Scripted runs: where the next developed frame goes, and who to tell.
    var scriptedPath: URL?
    var onDeveloped: ((String) -> Void)?
    func shoot() { releaseShutter() }

    // MARK: HUD and stats

    private func updateHUD() {
        guard let hud else { return }
        let b = body
        var i = ViewfinderHUD.Info()
        i.lens = b.lens.name
        i.aperture = String(format: b.takingAperture < 10 ? "%.1f" : "%.0f", b.takingAperture)
        i.shutter = b.shutter.seconds >= 1 ? "\(b.shutter.label)s" : "1/\(b.shutter.label)"
        i.stock = b.stock.name
        i.iso = Int(b.stock.iso)
        i.counter = "\(b.framesShot + 1 <= b.stock.exposures ? b.framesShot + 1 : b.stock.exposures)/\(b.stock.exposures)"
            + (b.framesLeft == 0 ? "  END" : "")
        i.focus = b.focusM >= 100 ? "∞" : String(format: "%.2f m", b.focusM)
        i.meterStops = b.exposureStops + log2(max(meterLum, 1e-4) / 0.18)
        var modes: [String] = []
        if b.dofPreview { modes.append("DOF PREVIEW") }
        if b.filmPreview { modes.append("FILM PREVIEW") }
        i.mode = modes.joined(separator: "  ")
        i.stats = statsLine
        hud.info = i
    }

    private func benchOrbit() {
        if benchCount == 0 { benchStart = CACurrentMediaTime() }
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

    func setBenchLens(_ on: Bool) { lensOn = on }

    private func record(renderMs: Double, now: Double) {
        statFrames += 1
        statRender.append(renderMs)
        if now - statStart >= 1 {
            let fps = Double(statFrames) / (now - statStart)
            let mean = statRender.reduce(0, +) / Double(statRender.count)
            statsLine = String(format: "%.1f fps | render %.1f ms (max %.1f) | %dx%d%@",
                               fps, mean, statRender.max() ?? 0, width, height,
                               input.controllerName.map { " | \($0)" } ?? " | no controller")
            onStats?(statsLine)
            statStart = now
            statFrames = 0
            statRender.removeAll()
        }
        if benchFrames > 0 {
            // Skip the first frames: shader pipelines and buffers warm up.
            if benchCount >= 10 { benchRender.append(renderMs) } else { benchStart = now }
            benchCount += 1
            if benchCount == benchFrames + 10 {
                let s = benchRender.sorted()
                let wall = now - benchStart
                let report = String(format: "bench %dx%d %@ f/%.1f: %.1f fps wall | render mean %.2f ms, median %.2f, p95 %.2f, max %.2f (%d frames)",
                                    width, height, lensOn ? body.lens.name : "pinhole",
                                    body.viewingAperture, Double(s.count) / wall,
                                    s.reduce(0, +) / Double(s.count), s[s.count / 2],
                                    s[Int(Double(s.count) * 0.95)], s.last!, s.count)
                benchFrames = 0
                onBenchDone?(report)
            }
        }
    }
}
