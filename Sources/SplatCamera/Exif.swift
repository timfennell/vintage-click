import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The camera the photographer carries. Ohi Kor S2 for now; more may come.
struct CameraModel {
    let make: String
    let model: String
    let serial: String
    let year: Int
    var fullName: String { "\(make) \(model)" }

    static let ohiKorS2 = CameraModel(make: "Ohi Kor", model: "S2", serial: "7392051", year: 1974)
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
