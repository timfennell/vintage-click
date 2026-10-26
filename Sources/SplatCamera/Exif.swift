import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The camera the photographer carries. Ohi Kor S2 for now; more may come.
struct CameraModel: Codable {
    let make: String
    let model: String
    let serial: String
    let year: Int
    var fullName: String { "\(make) \(model)" }

    static let ohiKorS2 = CameraModel(make: "Ohi Kor", model: "S2", serial: "7392051", year: 1974)
    /// Inspired by the 1973 Canon EF: shutter-priority automatic, the meter's
    /// needle on an aperture scale at the right of the finder.
    static let kwanonEF = CameraModel(make: "Kwanon", model: "EF", serial: "0213874", year: 1973)

    /// Inspired by the early-1970s Leica M5: a rangefinder, its own small lenses.
    static let lahntalR5 = CameraModel(make: "Lahntal", model: "R5", serial: "1287415", year: 1971)

    /// The bodies in the bag.
    static let all: [CameraModel] = [ohiKorS2, kwanonEF, lahntalR5]
    var rangefinder: Bool { make == "Lahntal" }

    /// How each one works (looked up by model, so saved shots keep only the name).
    var shutterPriority: Bool { make == "Kwanon" && model == "EF" }
    /// The fastest speed it has (index into shutterSpeeds; the slowest is 1 s).
    var fastestShutter: Int {
        shutterPriority || rangefinder ? (shutterSpeeds.firstIndex { $0.label == "1000" } ?? shutterSpeeds.count - 1) : shutterSpeeds.count - 1
    }
    var about: String {
        if rangefinder { return "1971 · rangefinder: bright frames, a focusing patch, its own lenses, 1 s to 1/1000" }
        return shutterPriority ? "1973 · shutter-priority auto, needle on an aperture scale, 1 s to 1/1000"
                               : "1974 · manual, needle on a speed scale, LED readouts, 1 s to 1/4000"
    }
}

/// What a camera of the day would have written on the frame, had it had
/// EXIF: the body, the lens and its settings, as the tags real files carry.
enum PhotoMetadata {
    /// "2026:10:19 14:05:33", EXIF's own date form.
    static func exifDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.string(from: d)
    }

    /// The lens's maker: the first word of its name ("Ohi Micro-Kor 55mm" → "Ohi").
    static func lensMake(_ lens: Lens) -> String {
        String(lens.name.split(separator: " ").first ?? "")
    }

    static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return v.map { "Vintage Click \($0)" } ?? "Vintage Click"
    }

    /// The film, filter and the rest no EXIF tag holds, as a line of text.
    static func notes(_ b: CameraBody) -> String {
        var s = "\(b.model.fullName) (\(b.model.year)) - \(b.rollName)"
        if b.filterIndex != 0 { s += " - filter: \(b.filter.name)" }
        return s
    }

    /// ImageIO properties for a print (PNG, eXIf chunk).
    static func properties(_ b: CameraBody, shotAt date: Date, description: String) -> [CFString: Any] {
        let l = b.lens, n = b.takingAperture, t = b.shutter.seconds
        let when = exifDate(date)
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: b.model.make,
            kCGImagePropertyTIFFModel: b.model.model,
            kCGImagePropertyTIFFSoftware: appVersion,
            kCGImagePropertyTIFFDateTime: when,
            kCGImagePropertyTIFFImageDescription: description,
        ]
        let exif: [CFString: Any] = [
            kCGImagePropertyExifVersion: [2, 3, 2],
            kCGImagePropertyExifDateTimeOriginal: when,
            kCGImagePropertyExifDateTimeDigitized: when,
            kCGImagePropertyExifExposureTime: Double(t),
            kCGImagePropertyExifFNumber: Double(n),
            kCGImagePropertyExifApertureValue: Double(2 * log2(n)),
            kCGImagePropertyExifShutterSpeedValue: Double(-log2(t)),
            kCGImagePropertyExifMaxApertureValue: Double(2 * log2(l.maxAperture)),
            kCGImagePropertyExifExposureProgram: 1,        // manual
            kCGImagePropertyExifMeteringMode: 2,           // centre-weighted average
            kCGImagePropertyExifFlash: 0,                  // no flash
            kCGImagePropertyExifISOSpeedRatings: [Int(b.ratedEI.rounded())],
            kCGImagePropertyExifSensitivityType: 3,        // ISO speed (the roll as rated)
            kCGImagePropertyExifFocalLength: Double(l.focalMM),
            kCGImagePropertyExifFocalLenIn35mmFilm: Int(l.focalMM.rounded()),
            kCGImagePropertyExifSubjectDistance: Double(b.focusM),
            kCGImagePropertyExifBodySerialNumber: b.model.serial,
            kCGImagePropertyExifLensMake: lensMake(l),
            kCGImagePropertyExifLensModel: l.name,
            kCGImagePropertyExifLensSpecification: [Double(l.focalMM), Double(l.focalMM),
                                                    Double(l.maxAperture), Double(l.maxAperture)],
            kCGImagePropertyExifUserComment: notes(b),
            kCGImagePropertyExifFileSource: 1,             // film scanner
            kCGImagePropertyExifCustomRendered: 1,         // developed and printed: custom
        ]
        return [kCGImagePropertyTIFFDictionary: tiff, kCGImagePropertyExifDictionary: exif,
                kCGImagePropertyOrientation: 1]
    }

    /// Writes the print as a PNG carrying that EXIF.
    static func writePNG(_ image: CGImage, to url: URL, properties: [CFString: Any]) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
