import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GeoResult: Codable, Equatable {
    var lat: Double?
    var lon: Double?
    var radius_m: Double?
    var place: String?
    var confidence: String?
    var summary: String?

    var hasCoordinate: Bool { lat != nil && lon != nil }
}

enum AnalysisMode: String, CaseIterable, Identifiable {
    case quick, deep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quick: return "快速（约 5–15 分钟）"
        case .deep: return "深度（可能 30–90 分钟）"
        }
    }
}

enum GoogleMaps {
    static func pinURL(lat: Double, lon: Double) -> URL {
        URL(string: "https://www.google.com/maps/search/?api=1&query=\(fmt(lat)),\(fmt(lon))")!
    }

    static func satelliteURL(lat: Double, lon: Double) -> URL {
        URL(string: "https://www.google.com/maps/@?api=1&map_action=map&center=\(fmt(lat)),\(fmt(lon))&zoom=18&basemap=satellite")!
    }

    static func open(lat: Double, lon: Double, satellite: Bool = false) {
        NSWorkspace.shared.open(satellite ? satelliteURL(lat: lat, lon: lon) : pinURL(lat: lat, lon: lon))
    }

    static func fmt(_ v: Double) -> String { String(format: "%.6f", v) }
}

enum ExifGPS {
    /// Reads GPS coordinates from the photo's EXIF metadata, if present.
    static func read(from url: URL) -> (lat: Double, lon: Double)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { lat = -lat }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { lon = -lon }
        if lat == 0 && lon == 0 { return nil }
        return (lat, lon)
    }
}

enum ClipboardImage {
    static var pasteboard = NSPasteboard.general

    /// True when the general pasteboard holds an image file or raw image data.
    static var available: Bool {
        if imageFileURL() != nil { return true }
        return !hasAnyFileURL && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Finder puts a file's icon on the pasteboard as TIFF, so raw image data is
    /// ignored whenever a (non-image) file was copied.
    private static var hasAnyFileURL: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Returns a file URL for the pasteboard image. Copied image files are used as-is
    /// (keeping their EXIF); raw image data (screenshots, images copied from a browser)
    /// is written to Application Support/GeoSleuth/pasted/.
    static func read() -> URL? {
        if let url = imageFileURL() { return url }
        guard let (data, ext) = imageData() else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeoSleuth/pasted", isDirectory: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("paste-\(stamp.string(from: Date())).\(ext)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func imageFileURL() -> URL? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL])?.first
    }

    private static func imageData() -> (Data, String)? {
        let pb = pasteboard
        if hasAnyFileURL { return nil }
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"),
            (NSPasteboard.PasteboardType(UTType.heic.identifier), "heic"),
            (.png, "png"),
        ]
        for (type, ext) in candidates {
            if let data = pb.data(forType: type) { return (data, ext) }
        }
        // TIFF (and anything else NSImage understands) is converted to PNG.
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return nil
    }
}
