import AppKit
import CSpirula
import Foundation
import Metal
import simd

struct SpirulaError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String) { description = "\(what): \(String(cString: sr_last_error()))" }
}

/// A finder frame to render: the camera at this moment through the lens wide open.
struct FinderJob {
    var view: [Float]
    var position: SIMD3<Float>
    var fx: Float
    var lens: [SIMD4<Float>]?
    var body: CameraBody
    var lighting: LightingPlot
    var fromLight: Int? = nil       // seen from this light's head, not the camera
    var fisheye = false             // through a fisheye: Spirula's equidistant camera
}

/// One exposure on its way through the camera: the scene as it was when the
/// shutter fired, added up sub-pupil by sub-pupil, then developed.
final class ExposureJob {
    let camera: FlyCamera
    let body: CameraBody          // settings at the moment of release
    let lighting: LightingPlot
    let frameNumber: Int
    let cells: [SIMD2<Float>]
    var next = 0
    let accum: MTLBuffer
    /// The photo's size, and whether to keep a digital negative (DNG) too.
    let size: (w: Int, h: Int)
    let wantsNegative: Bool
    /// Linear light, three half floats per pixel, when a negative was asked for.
    var negative: Data?
    let started = CACurrentMediaTime()
    var outputPath: URL?

    init(camera: FlyCamera, body: CameraBody, lighting: LightingPlot, frameNumber: Int,
         cells: [SIMD2<Float>], accum: MTLBuffer, size: (w: Int, h: Int), wantsNegative: Bool) {
        self.size = size
        self.wantsNegative = wantsNegative
        self.camera = camera
        self.body = body
        self.lighting = lighting
        self.frameNumber = frameNumber
        self.cells = cells
        self.accum = accum
    }
}

/// Owns Spirula: one thread does every render, alternating the live finder
/// with the next sub-pupil of the oldest exposure still on the film, so the
/// camera stays in your hands while frames develop behind it.
final class RenderLoop {
    let device: MTLDevice
    let finderSize: (w: Int, h: Int)
    let photoSize: (w: Int, h: Int)
    let background: SIMD4<Float>

    private let queue: MTLCommandQueue
    private let accumulatePSO: MTLComputePipelineState
    private let developPSO: MTLComputePipelineState
    private let relightPSO: MTLComputePipelineState
    private let negativePSO: MTLComputePipelineState
    // The scan's own colours (relighting reads them; Spirula's are overwritten).
    private let means: MTLBuffer, dc0: MTLBuffer, sh0: MTLBuffer
    private let colours: (buf: MTLBuffer, off: Int)
    private let count: Int, higherCoeffs: Int
    private var lastRelight: [SIMD4<Float>] = []

    // Shadow maps: per light, Spirula's render from the head (transmittance and
    // median depth), at finder or photo quality; and per splat, per light, how
    // much light gets through (0-255), worked out from them.
    enum ShadowQuality: Int {
        case finder, photo
        var size: Int { self == .finder ? 512 : 1536 }
        /// Blocker taps, filter taps, largest penumbra (texels).
        var taps: SIMD3<Float> { self == .finder ? [8, 12, 10] : [24, 48, 48] }
    }
    static let maxLights = 8
    var shadowsOn = true
    /// The scan was lit by the sun or a room, not from the camera: relight from base colour.
    var daylightScan = false
    private let shadowPSO: MTLComputePipelineState
    private var shadowMaps: [ShadowQuality: [(buf: MTLBuffer, off: Int, index: Int32)]] = [:]
    private var shadowKeys: [ShadowQuality: [[SIMD4<Float>]]] = [:]
    private var visibility: [ShadowQuality: MTLBuffer] = [:]
    private var shadowVersion = 0
    private var finderSlots: [(buf: MTLBuffer, off: Int, index: Int32)] = []
    private let photoSlot: (buf: MTLBuffer, off: Int, index: Int32)

    // Shared with the main thread, under `cond`.
    private let cond = NSCondition()
    private var finderRequest: FinderJob?
    private var exposures: [ExposureJob] = []
    private var latest: (slot: Int, job: FinderJob)?
    private var displaying = [Int](repeating: 0, count: 4)
    private var stopping = false
    private let stopped = DispatchSemaphore(value: 0)

    /// Called on the main thread.
    var onFinderRendered: ((Double) -> Void)?
    var onDeveloped: ((ExposureJob, CGImage, Double) -> Void)?

    init(model: SplatModel, finder: (Int, Int), photo: (Int, Int), background: SIMD4<Float>,
         library: MTLLibrary? = nil) throws {
        finderSize = (finder.0, finder.1)
        photoSize = (photo.0, photo.1)
        self.background = background
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

        func frames(_ w: Int, _ h: Int, _ n: Int) throws -> [(MTLBuffer, Int, Int32)] {
            var bufs = [UnsafeMutableRawPointer?](repeating: nil, count: n)
            var offs = [Int](repeating: 0, count: n)
            var first: Int32 = 0
            if sr_add_shared_frames(Int32(w), Int32(h), Int32(n), &bufs, &offs, &first) != 0 {
                throw SpirulaError("sharing frames with Metal")
            }
            return (0..<n).map {
                (Unmanaged<MTLBuffer>.fromOpaque(bufs[$0]!).takeUnretainedValue(), offs[$0], first + Int32($0))
            }
        }
        // Four finder frames: the newest, up to two being displayed, one being rendered.
        finderSlots = try frames(finder.0, finder.1, 4).map { ($0.0, $0.1, $0.2) }
        // Exposures render in tiles of the finder's size (memory stays the finder's).
        let p = try frames(finder.0, finder.1, 1)[0]
        photoSlot = (p.0, p.1, p.2)
        // Draw on the GPU Spirula renders on, so the buffers are directly usable.
        let device = p.0.device
        self.device = device
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        accumulatePSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "accumulate")!)
        developPSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "develop")!)
        relightPSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "relight")!)
        negativePSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "negative")!)
        shadowPSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "shadow_vis")!)
        count = model.count
        higherCoeffs = (model.shDegree + 1) * (model.shDegree + 1) - 1
        func upload(_ a: [Float]) -> MTLBuffer {
            a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared)! }
        }
        means = upload(model.means)
        dc0 = upload(model.dc)
        sh0 = upload(model.sh.isEmpty ? [0] : model.sh)
        var cb: UnsafeMutableRawPointer?
        var co = 0
        if sr_color_buffer(&cb, &co) != 0 { throw SpirulaError("sharing colours with Metal") }
        colours = (Unmanaged<MTLBuffer>.fromOpaque(cb!).takeUnretainedValue(), co)
        // Relit colours are view-dependent already: the renderer evaluates base colour only.
        sr_set_render_degree(0)

        let t = Thread { [weak self] in self?.run() }
        t.name = "Spirula render"
        t.qualityOfService = .userInteractive
        t.start()
    }

    // MARK: main-thread side

    /// Lets the render in progress finish and stops the thread: the GPU device
    /// must not be torn down (at exit) under a render.
    func shutdown() {
        cond.lock()
        guard !stopping else { cond.unlock(); return }
        stopping = true
        cond.signal()
        cond.unlock()
        stopped.wait()
    }

    /// Asks for a finder frame of this view (replacing any not yet started).
    func requestFinder(_ job: FinderJob) {
        cond.lock()
        finderRequest = job
        cond.signal()
        cond.unlock()
    }

    /// The newest finder frame, held for display until `release` is called.
    func acquireLatest() -> (buf: MTLBuffer, off: Int, slot: Int, job: FinderJob)? {
        cond.lock()
        defer { cond.unlock() }
        guard let l = latest else { return nil }
        displaying[l.slot] += 1
        let s = finderSlots[l.slot]
        return (s.buf, s.off, l.slot, l.job)
    }

    func release(slot: Int) {
        cond.lock()
        displaying[slot] -= 1
        cond.unlock()
    }

    var pendingExposures: Int {
        cond.lock()
        defer { cond.unlock() }
        return exposures.count
    }

    /// Frame numbers of this roll still being exposed or developed.
    func pendingFrames(roll: Int) -> [Int] {
        cond.lock()
        defer { cond.unlock() }
        return exposures.filter { $0.body.rollNumber == roll }.map(\.frameNumber)
    }

    func makeAccumulator(_ w: Int, _ h: Int) -> MTLBuffer? {
        device.makeBuffer(length: w * h * 16, options: .storageModePrivate)
    }

    func expose(_ job: ExposureJob) {
        cond.lock()
        exposures.append(job)
        cond.signal()
        cond.unlock()
    }

    // MARK: render thread

    private func run() {
        while true {
            cond.lock()
            while finderRequest == nil && exposures.isEmpty && !stopping { cond.wait() }
            if stopping {
                cond.unlock()
                stopped.signal()
                return
            }
            let finder = finderRequest
            finderRequest = nil
            let exposure = exposures.first
            cond.unlock()
            if let finder { renderFinder(finder) }
            if let exposure { step(exposure) }
        }
    }

    /// Fisheye lenses render through Spirula's equidistant camera; all else is pinhole.
    private func setCameraModel(_ fisheye: Bool) {
        if sr_set_camera_model(fisheye ? "FISHEYE" : "PINHOLE") != 0 { print(SpirulaError("camera model")) }
    }

    private func setLens(_ params: [SIMD4<Float>]?) {
        let rc: Int32
        if let p = params {
            rc = p.withUnsafeBytes { sr_set_lens($0.baseAddress!.assumingMemoryBound(to: Float.self), Int32(p.count)) }
        } else {
            rc = sr_set_lens(nil, 0)
        }
        if rc != 0 { print(SpirulaError("lens")) }
    }

    private func render(_ index: Int32, view: [Float], fx: Float, cx: Float, cy: Float) -> Bool {
        let rc = view.withUnsafeBufferPointer {
            sr_render_to_frame(index, $0.baseAddress, fx, fx, cx, cy, "3dgs")
        }
        if rc != 0 { print(SpirulaError("render")) }
        return rc == 0
    }

    /// Brings each light's shadow map and the splats' visibility up to date
    /// for this lighting (only lights that moved, turned or changed beam).
    private func prepareShadows(_ plot: LightingPlot, body: CameraBody, quality q: ShadowQuality) -> MTLBuffer? {
        if visibility[q] == nil {
            visibility[q] = device.makeBuffer(length: max(count * Self.maxLights, 16), options: .storageModePrivate)
        }
        guard let vis = visibility[q] else { return nil }
        let res = q.size
        for (slot, light) in plot.lights.prefix(Self.maxLights).enumerated() {
            let key: [SIMD4<Float>] = [SIMD4(light.position, light.spot), SIMD4(light.aim, Float(light.head)),
                                       SIMD4(plot.up, body.metresPerUnit)]
            var keys = shadowKeys[q] ?? []
            if keys.count > slot && keys[slot] == key { continue }
            // A frame for this slot's map, made the first time it is needed.
            var maps = shadowMaps[q] ?? []
            while maps.count <= slot {
                var b: UnsafeMutableRawPointer?
                var o = 0
                var first: Int32 = 0
                guard sr_add_shared_frames(Int32(res), Int32(res), 1, &b, &o, &first) == 0 else {
                    print(SpirulaError("shadow map"))
                    return nil
                }
                maps.append((Unmanaged<MTLBuffer>.fromOpaque(b!).takeUnretainedValue(), o, first))
            }
            shadowMaps[q] = maps
            // The view from the head, wide enough for the beam's field.
            var cam = FlyCamera()
            cam.up = plot.up
            cam.lookAt(light.position + light.aim, from: light.position)
            let field = min(light.beam.angle(at: 0.1) * 1.15, 120) * .pi / 360
            let fx = Float(res) / 2 / tan(field)
            setLens(nil)
            guard render(maps[slot].index, view: cam.viewMatrix, fx: fx, cx: Float(res) / 2, cy: Float(res) / 2)
            else { return nil }
            let kit = light.kit
            let source = (kit.kind == .softlight ? 0.27 : Photometry.optics(kit).lensR) / body.metresPerUnit
            let V = cam.viewMatrix
            var S: [SIMD4<Float>] = [
                SIMD4(V[0], V[1], V[2], V[3]), SIMD4(V[4], V[5], V[6], V[7]), SIMD4(V[8], V[9], V[10], V[11]),
                SIMD4(fx, Float(res), body.metresPerUnit, source),
                SIMD4(q.taps, Float(slot)),
            ]
            var n = UInt32(count)
            guard let cb = queue.makeCommandBuffer(), let ce = cb.makeComputeCommandEncoder() else { return nil }
            ce.setComputePipelineState(shadowPSO)
            ce.setBuffer(means, offset: 0, index: 0)
            ce.setBuffer(maps[slot].buf, offset: maps[slot].off, index: 1)
            ce.setBytes(&S, length: S.count * 16, index: 2)
            ce.setBuffer(vis, offset: 0, index: 3)
            ce.setBytes(&n, length: 4, index: 4)
            ce.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            ce.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            while keys.count <= slot { keys.append([]) }
            keys[slot] = key
            shadowKeys[q] = keys
            shadowVersion += 1
        }
        return vis
    }

    /// Writes the relit colours for this lighting, seen from `eye`, into
    /// Spirula's colour buffer (skipped when nothing changed).
    private func relight(_ plot: LightingPlot, eye: SIMD3<Float>, body: CameraBody, quality: ShadowQuality) {
        let vis = plot.lights.isEmpty || !shadowsOn ? nil : prepareShadows(plot, body: body, quality: quality)
        var g: [SIMD4<Float>] = [
            SIMD4(eye, plot.ambient),
            SIMD4(Float(min(plot.lights.count, Self.maxLights)), Float(count), Float(higherCoeffs), 0.25),
            SIMD4(plot.ambientTint, vis == nil ? 0 : 1),
            SIMD4(Float(quality.rawValue), Float(shadowVersion), daylightScan ? 1 : 0, 0),
        ]
        let packs = plot.lights.prefix(Self.maxLights).map { $0.packed(metresPerUnit: body.metresPerUnit, sceneEV: body.sceneEV, up: plot.up) }
        var lt: [SIMD4<Float>] = packs.flatMap(\.head)
        let tables: [SIMD4<Float>] = packs.flatMap(\.table)
        let spots: Float = plot.lights.reduce(Float(0)) { $0 + $1.spot }
        var key: [SIMD4<Float>] = g
        key.append(contentsOf: lt)
        key.append(SIMD4<Float>(spots, 0, 0, 0))
        if key == lastRelight { return }
        lastRelight = key
        if lt.isEmpty { lt = [SIMD4<Float>](repeating: .zero, count: 4) }
        let tableBuf = tables.isEmpty
            ? device.makeBuffer(length: 16, options: .storageModeShared)
            : tables.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        guard let cb = queue.makeCommandBuffer(), let ce = cb.makeComputeCommandEncoder() else { return }
        ce.setComputePipelineState(relightPSO)
        ce.setBuffer(means, offset: 0, index: 0)
        ce.setBuffer(dc0, offset: 0, index: 1)
        ce.setBuffer(sh0, offset: 0, index: 2)
        ce.setBuffer(colours.buf, offset: colours.off, index: 3)
        ce.setBytes(&g, length: g.count * 16, index: 4)
        ce.setBytes(&lt, length: lt.count * 16, index: 5)
        ce.setBuffer(tableBuf, offset: 0, index: 6)
        ce.setBuffer(vis ?? tableBuf, offset: 0, index: 7)
        ce.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        ce.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    private func renderFinder(_ job: FinderJob) {
        cond.lock()
        let slot = (0..<finderSlots.count).first { $0 != latest?.slot && displaying[$0] == 0 }
        cond.unlock()
        guard let slot else { return }
        relight(job.lighting, eye: job.position, body: job.body, quality: .finder)
        setLens(job.lens)
        setCameraModel(job.fisheye)
        let t0 = CACurrentMediaTime()
        let ok = render(finderSlots[slot].index, view: job.view, fx: job.fx,
                        cx: Float(finderSize.w) / 2, cy: Float(finderSize.h) / 2)
        setCameraModel(false)
        let ms = (CACurrentMediaTime() - t0) * 1000
        guard ok else { return }
        cond.lock()
        latest = (slot, job)
        cond.unlock()
        DispatchQueue.main.async { [weak self] in self?.onFinderRendered?(ms) }
    }

    /// Optics for the shaders at photo size (layout in Shaders.swift).
    private func photoOptics(_ e: ExposureJob, fx: Float) -> [SIMD4<Float>] {
        let b = e.body, l = b.lens, n = b.takingAperture
        let (w, h) = e.size
        return [
            SIMD4(Float(w), Float(h), fx, fx),
            SIMD4(Float(w) / 2, Float(h) / 2, b.metresPerUnit, b.focusM),
            SIMD4(l.focalMM / 1000, n, l.maxAperture, Float(l.blades)),
            SIMD4(l.catsEye, l.soapBubble, l.bladeRotation, l.vignette),
            background,
            SIMD4(0, 1, Float(b.rollNumber * 100 + e.frameNumber), b.exposureStops),
            SIMD4(l.lateralCA, l.axialCA, l.projection == .circularFisheye ? Float(h) / 2 : 0, l.obstruction),
        ]
    }

    /// One sub-pupil of the exposure: render the view sheared to that lens
    /// point (focus plane fixed), add it to the film; develop after the last.
    private func step(_ e: ExposureJob) {
        let b = e.body
        let (w, h) = e.size
        let n = b.takingAperture
        let fx = b.lens.focalPixels(width: w, height: h)
        let radiusUnits = b.lens.focalMM / 1000 / n / 2 / b.metresPerUnit
        relight(e.lighting, eye: e.camera.position, body: b, quality: .photo)
        // Axial colour: with it, each sub-pupil carries one channel, focused
        // where that colour focuses (red a little beyond green, blue short).
        // Splitting the samples by colour needs enough of them: with fewer, each
        // channel's blur comes from different lens points and blotches.
        let channel = b.lens.axialCA > 0 && e.cells.count >= 64 ? e.next % 3 : -1
        let c = e.cells[e.next]
        var body = b
        var dioptres = 1 / b.focusM
        if channel >= 0 { dioptres += b.lens.axialCA * Float(1 - channel) }
        // Spherical aberration: rays through the rim of the open aperture focus
        // nearer (a soft-focus glow); it fades as the aperture closes.
        let open = b.lens.maxAperture / n
        dioptres += b.lens.sphericalAberration * simd_length_squared(c) * open * open
        body.focusM = 1 / dioptres
        let invFocus = body.metresPerUnit / body.focusM
        // A fisheye has no meaningful depth of field to sample: one look, its own camera.
        setLens(b.lens.isFisheye ? nil : body.lensParams(fNumber: n, focalPx: fx, cells: e.cells.count, table: nil))
        setCameraModel(b.lens.isFisheye)
        defer { setCameraModel(false) }

        let d = c * radiusUnits
        var vm = e.camera.viewMatrix
        vm[3] -= d.x
        vm[7] -= d.y
        var o = photoOptics(e, fx: fx)
        // Each sub-pupil's share of the aperture, as a radius (a colour's
        // sub-pupils are a third as many, so each covers more).
        let share = sqrt(Float(channel < 0 ? 1 : 3) / Float(e.cells.count)) * 1.2
        let mask: SIMD4<Float> = channel < 0 ? [1, 1, 1, share]
            : (channel == 0 ? [1, 0, 0, share] : (channel == 1 ? [0, 1, 0, share] : [0, 0, 1, share]))
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let (tw, th) = finderSize
        // The photo in finder-sized tiles: each a render with the principal
        // point moved so it sees its part of the frame.
        for y0 in stride(from: 0, to: h, by: th) {
            for x0 in stride(from: 0, to: w, by: tw) {
                guard render(photoSlot.index, view: vm, fx: fx,
                             cx: Float(w) / 2 + fx * d.x * invFocus - Float(x0),
                             cy: Float(h) / 2 + fx * d.y * invFocus - Float(y0)),
                      let tcb = queue.makeCommandBuffer(), let te = tcb.makeComputeCommandEncoder() else {
                    finish(e)
                    return
                }
                let first = e.next == 0 ? Float(1) : 0
                var l = [SIMD4<Float>(c.x, c.y, 1, first), mask,
                         SIMD4<Float>(Float(x0), Float(y0), Float(tw), Float(th))]
                te.setComputePipelineState(accumulatePSO)
                te.setBuffer(photoSlot.buf, offset: photoSlot.off, index: 0)
                te.setBytes(&o, length: o.count * 16, index: 1)
                te.setBuffer(e.accum, offset: 0, index: 2)
                te.setBytes(&l, length: 48, index: 3)
                te.dispatchThreads(MTLSize(width: tw, height: th, depth: 1), threadsPerThreadgroup: tg)
                te.endEncoding()
                tcb.commit()
                // The tile frame is rendered into again next: let this read finish.
                tcb.waitUntilCompleted()
            }
        }
        guard let cb = queue.makeCommandBuffer() else {
            finish(e)
            return
        }
        let grid = MTLSize(width: w, height: h, depth: 1)
        let ce = cb.makeComputeCommandEncoder()!
        e.next += 1
        let done = e.next == e.cells.count
        var print: MTLBuffer?
        var negBuf: MTLBuffer?
        if done, let out = device.makeBuffer(length: w * h * 4, options: .storageModeShared) {
            print = out
            // Light through the unclipped centre of the frame sets the scale, per channel.
            var full = SIMD3<Float>(repeating: 0)
            for (k, cell) in e.cells.enumerated() {
                let w = pupilWeight(cell, q: .zero, lens: b.lens, fNumber: n)
                if channel < 0 { full += SIMD3(repeating: w) } else { full[k % 3] += w }
            }
            var dv = SIMD4<Float>(1 / simd_max(full, SIMD3(repeating: 1e-6)), 0)
            var f = b.developed.packed
            ce.setComputePipelineState(developPSO)
            ce.setBuffer(e.accum, offset: 0, index: 0)
            ce.setBytes(&o, length: o.count * 16, index: 1)
            ce.setBytes(&f, length: f.count * 16, index: 2)
            ce.setBytes(&dv, length: 16, index: 3)
            ce.setBuffer(out, offset: 0, index: 4)
            ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
            if e.wantsNegative, let neg = device.makeBuffer(length: w * h * 6, options: .storageModeShared) {
                negBuf = neg
                ce.setComputePipelineState(negativePSO)
                ce.setBuffer(e.accum, offset: 0, index: 0)
                ce.setBytes(&o, length: o.count * 16, index: 1)
                ce.setBytes(&dv, length: 16, index: 3)
                ce.setBuffer(neg, offset: 0, index: 4)
                ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
            }
        }
        ce.endEncoding()
        cb.commit()
        // The photo frame is rendered into again next step: let this read finish.
        cb.waitUntilCompleted()
        if done {
            finish(e)
            if let negBuf { e.negative = Data(bytes: negBuf.contents(), count: negBuf.length) }
            if let print, let image = makeImage(print, w, h) {
                let seconds = CACurrentMediaTime() - e.started
                DispatchQueue.main.async { [weak self] in self?.onDeveloped?(e, image, seconds) }
            }
        }
    }

    private func finish(_ e: ExposureJob) {
        cond.lock()
        exposures.removeAll { $0 === e }
        cond.unlock()
    }

    private func makeImage(_ buf: MTLBuffer, _ w: Int, _ h: Int) -> CGImage? {
        let data = Data(bytes: buf.contents(), count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
