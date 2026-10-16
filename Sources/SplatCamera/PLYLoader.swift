import Foundation
import simd

/// A trained 3DGS model in the renderer's layout (see spirula_render.h).
struct SplatModel {
    var count = 0
    var shDegree = 0
    var means: [Float] = []        // [N,3]
    var quats: [Float] = []        // [N,4] w x y z
    var scales: [Float] = []       // [N,3] log
    var opacities: [Float] = []    // [N] logit
    var dc: [Float] = []           // [N,3]
    var sh: [Float] = []           // [N,K,3] coefficient-major

    /// Robust centre and radius of the splat cloud (median, 90th-percentile
    /// distance), so the camera starts on the subject and not on stray floaters.
    func bounds() -> (center: SIMD3<Float>, radius: Float) {
        let stride = max(1, count / 20000)
        var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
        for i in Swift.stride(from: 0, to: count, by: stride) {
            xs.append(means[3 * i]); ys.append(means[3 * i + 1]); zs.append(means[3 * i + 2])
        }
        func median(_ a: [Float]) -> Float { a.sorted()[a.count / 2] }
        let c = SIMD3(median(xs), median(ys), median(zs))
        var d = (0..<xs.count).map { simd_length(SIMD3(xs[$0], ys[$0], zs[$0]) - c) }
        d.sort()
        return (c, d[Int(Float(d.count - 1) * 0.9)])
    }
}

enum PLYError: Error, CustomStringConvertible {
    case format(String)
    var description: String { if case .format(let s) = self { return s }; return "" }
}

/// Reads a binary little-endian 3DGS PLY (the INRIA / gsplat property names).
func loadPLY(_ url: URL) throws -> SplatModel {
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    guard let endRange = data.range(of: Data("end_header\n".utf8)) else {
        throw PLYError.format("no PLY header")
    }
    let header = String(decoding: data[..<endRange.lowerBound], as: UTF8.self)
    var count = 0
    var props: [String: Int] = [:]   // float property name -> index in the vertex
    var nprops = 0
    var inVertex = false
    for line in header.split(separator: "\n") {
        let w = line.split(separator: " ")
        if w.first == "format", w.count > 1, w[1] != "binary_little_endian" {
            throw PLYError.format("only binary little-endian PLY is supported")
        }
        if w.first == "element" {
            inVertex = w.count > 2 && w[1] == "vertex"
            if inVertex { count = Int(w[2]) ?? 0 }
        } else if w.first == "property", inVertex {
            guard w.count == 3, w[1] == "float" else {
                throw PLYError.format("unsupported vertex property: \(line)")
            }
            props[String(w[2])] = nprops
            nprops += 1
        }
    }
    func idx(_ name: String) throws -> Int {
        guard let i = props[name] else { throw PLYError.format("PLY has no \(name)") }
        return i
    }
    let ix = try idx("x"), iy = try idx("y"), iz = try idx("z")
    let irot = try (0..<4).map { try idx("rot_\($0)") }
    let iscale = try (0..<3).map { try idx("scale_\($0)") }
    let iop = try idx("opacity")
    let idc = try (0..<3).map { try idx("f_dc_\($0)") }
    var nrest = 0
    while props["f_rest_\(nrest)"] != nil { nrest += 1 }
    let K = nrest / 3
    var degree = 0
    while (degree + 1) * (degree + 1) - 1 < K { degree += 1 }
    guard (degree + 1) * (degree + 1) - 1 == K else {
        throw PLYError.format("\(nrest) f_rest values is not a whole SH degree")
    }
    let irest = (0..<nrest).map { props["f_rest_\($0)"]! }

    var m = SplatModel()
    m.count = count
    m.shDegree = degree
    m.means = .init(repeating: 0, count: count * 3)
    m.quats = .init(repeating: 0, count: count * 4)
    m.scales = .init(repeating: 0, count: count * 3)
    m.opacities = .init(repeating: 0, count: count)
    m.dc = .init(repeating: 0, count: count * 3)
    m.sh = .init(repeating: 0, count: count * K * 3)
    let body = endRange.upperBound
    guard data.count - body >= count * nprops * 4 else { throw PLYError.format("PLY is truncated") }

    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let base = raw.baseAddress!.advanced(by: body)
        m.means.withUnsafeMutableBufferPointer { means in
        m.quats.withUnsafeMutableBufferPointer { quats in
        m.scales.withUnsafeMutableBufferPointer { scales in
        m.opacities.withUnsafeMutableBufferPointer { ops in
        m.dc.withUnsafeMutableBufferPointer { dc in
        m.sh.withUnsafeMutableBufferPointer { sh in
            DispatchQueue.concurrentPerform(iterations: 64) { chunk in
                let lo = count * chunk / 64, hi = count * (chunk + 1) / 64
                for i in lo..<hi {
                    let v = base.advanced(by: i * nprops * 4)
                    @inline(__always) func f(_ p: Int) -> Float { v.loadUnaligned(fromByteOffset: p * 4, as: Float.self) }
                    means[3 * i] = f(ix); means[3 * i + 1] = f(iy); means[3 * i + 2] = f(iz)
                    for j in 0..<4 { quats[4 * i + j] = f(irot[j]) }
                    for j in 0..<3 { scales[3 * i + j] = f(iscale[j]); dc[3 * i + j] = f(idc[j]) }
                    ops[i] = f(iop)
                    // PLY stores f_rest channel-major (all of R, then G, then B).
                    for k in 0..<K {
                        for c in 0..<3 { sh[(i * K + k) * 3 + c] = f(irest[c * K + k]) }
                    }
                }
            }
        }}}}}}
    }
    return m
}
