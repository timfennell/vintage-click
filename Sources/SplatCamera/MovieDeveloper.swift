import AVFoundation
import CoreImage
import Foundation
import Metal
import VideoToolbox

/// Develops a take into a movie: frames come back from the darkroom one at a
/// time (half-float prints) and go into a QuickTime file, in order. A preview
/// also lays poster frames beside it, so the take lies on the light table as a
/// strip of film.
final class MovieDeveloper {
    enum Kind: String, Codable, CaseIterable {
        case preview, prores, hevc
        /// The final's choices, as the menu names them.
        var name: String {
            switch self {
            case .preview: return "preview (HEVC)"
            case .prores: return "ProRes 422 HQ"
            case .hevc: return "HEVC 10-bit"
            }
        }
        var fileName: String {
            switch self {
            case .preview: return "preview.mov"
            case .prores: return "final-prores.mov"
            case .hevc: return "final-hevc.mov"
            }
        }
    }

    let take: MotionTake
    let folder: URL
    let kind: Kind
    let width: Int, height: Int
    /// Poster frames for the light table: every this many frames.
    static let posterEvery = 12

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var transfer: VTPixelTransferSession?
    private var source: CVPixelBufferPool?
    private(set) var next = 0              // the next frame to expose
    private(set) var written = 0           // frames in the file
    private(set) var cancelled = false
    /// A preview's posters are already beside this final.
    private let postersKept: Bool
    var url: URL { folder.appendingPathComponent(kind.fileName) }
    var total: Int { take.frameCount }
    var done: Bool { written >= total || cancelled }

    init(take: MotionTake, folder: URL, kind: Kind, width: Int, height: Int) throws {
        self.take = take
        self.folder = folder
        self.kind = kind
        // Codecs want even sizes.
        self.width = width & ~1
        self.height = height & ~1
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        postersKept = FileManager.default.fileExists(atPath: folder.appendingPathComponent("poster-0000.png").path)
        let out = folder.appendingPathComponent(kind.fileName)
        try? FileManager.default.removeItem(at: out)
        writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let colour: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        var settings: [String: Any] = [
            AVVideoWidthKey: self.width, AVVideoHeightKey: self.height,
            AVVideoColorPropertiesKey: colour,
        ]
        let format: OSType
        switch kind {
        case .preview:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: 0.7]
            format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .prores:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
            format = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoQualityKey: 0.9,
            ]
            format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: self.width, kCVPixelBufferHeightKey as String: self.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        guard writer.canAdd(input) else { throw Self.failure("can't write \(kind.name)") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Self.failure("can't write \(kind.name): \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        if let transfer {
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                                 value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                                 value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
                                 value: kCVImageBufferTransferFunction_ITU_R_709_2)
        }
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferWidthKey as String: self.width, kCVPixelBufferHeightKey as String: self.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary, &source)
    }

    /// Takes the next frame to expose (nil when all are out or it was stopped).
    func takeFrame() -> Int? {
        guard !cancelled, next < total else { return nil }
        next += 1
        return next - 1
    }

    /// Hands back the frame just taken (it couldn't be exposed yet: tried again later).
    func putBack(_ frame: Int) {
        if frame == next - 1 { next = frame }
    }

    /// Appends a developed frame: `print` is rgba half floats, the render's own
    /// size (`w` x `h`, cropped to the movie's even size). Any thread.
    func append(_ print: MTLBuffer, w: Int, h: Int, frame: Int) {
        guard !cancelled, writer.status == .writing, let source, let pool = adaptor.pixelBufferPool else { return }
        var rgb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, source, &rgb)
        var yuv: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &yuv)
        guard let rgb, let yuv, let transfer else { return }
        CVPixelBufferLockBaseAddress(rgb, [])
        let dst = CVPixelBufferGetBaseAddress(rgb)!
        let row = CVPixelBufferGetBytesPerRow(rgb)
        let src = print.contents()
        for y in 0..<height { memcpy(dst + y * row, src + y * w * 8, width * 8) }
        CVPixelBufferUnlockBaseAddress(rgb, [])
        // The print is display-referred: tag it so, for the conversion to video YCbCr.
        CVBufferSetAttachment(rgb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(rgb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        guard VTPixelTransferSessionTransferImage(transfer, from: rgb, to: yuv) == noErr else {
            fputs("Movie: frame \(frame) didn't convert\n", stderr)
            return
        }
        while !input.isReadyForMoreMediaData && writer.status == .writing { usleep(2000) }
        let t = CMTime(value: CMTimeValue(frame) * 1000, timescale: CMTimeScale((take.frameRate * 1000).rounded()))
        if !adaptor.append(yuv, withPresentationTime: t) {
            fputs("Movie: frame \(frame) not written: \(writer.error?.localizedDescription ?? "?")\n", stderr)
        }
        written += 1
        // Posters for the light table (a final made straight from the camera
        // lays its own, when there is no preview's to keep).
        if frame % Self.posterEvery == 0 && (kind == .preview || !postersKept) { poster(rgb, frame: frame) }
    }

    /// A frame as a PNG beside the clip (the light table's strip).
    private func poster(_ rgb: CVPixelBuffer, frame: Int) {
        let image = CIImage(cvPixelBuffer: rgb)
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let cg = ctx.createCGImage(image, from: image.extent, format: .RGBA8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return }
        let u = folder.appendingPathComponent(String(format: "poster-%04d.png", frame))
        guard let d = CGImageDestinationCreateWithURL(u as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, cg, nil)
        CGImageDestinationFinalize(d)
    }

    /// Stops taking frames; what was written is kept.
    func cancel() { cancelled = true }

    /// Closes the file.
    func finish(_ then: @escaping (Bool) -> Void) {
        input.markAsFinished()
        writer.finishWriting { [writer] in then(writer.status == .completed) }
    }

    private static func failure(_ s: String) -> NSError {
        NSError(domain: "VintageClick.Movie", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }

    // MARK: takes on disk

    /// The next free take in a sitting: "Take NN - stock", beside its rolls.
    static func newTakeFolder(session: URL, stock: String) -> (URL, Int) {
        let used = (try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? []
        let n = (used.compactMap { $0.hasPrefix("Take ") ? Int($0.dropFirst(5).prefix(2)) : nil }.max() ?? 0) + 1
        return (session.appendingPathComponent(String(format: "Take %02d - %@", n, stock), isDirectory: true), n)
    }
}
