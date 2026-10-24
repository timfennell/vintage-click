import Foundation

// Everything about a shot that the enlarger needs to make it again: the camera
// where it stood, its settings, the lights, the scan and the print's size.
// Written beside the proof as frame-NN.shot.json.
// (FlyCamera, CameraBody, CameraModel, PlacedLight and LightingPlot are
// Codable in their own files.)

struct ShotRecord: Codable {
    var scene: String
    var camera: FlyCamera
    var body: CameraBody
    var lighting: LightingPlot
    var frameNumber: Int
    var cells: Int
    var width: Int, height: Int         // the print, in pixels
    var negative: Bool
    var filterThreshold: Float

    static func url(for print: URL) -> URL {
        print.deletingPathExtension().appendingPathExtension("shot.json")
    }
    static func load(for print: URL) -> ShotRecord? {
        guard let d = try? Data(contentsOf: url(for: print)) else { return nil }
        return try? JSONDecoder().decode(ShotRecord.self, from: d)
    }
    func save(for print: URL) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: Self.url(for: print))
    }
}
