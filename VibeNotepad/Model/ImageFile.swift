import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Pictures open in the image viewer instead of the text editor.
nonisolated enum ImageFile {
    private static let knownExtensions = Mutex<[String: Bool]>([:])

    /// Whether the file's extension names a picture (PNG, JPEG, GIF, HEIC, WebP, TIFF, PSD, ICNS, camera
    /// raw…). SVG stays text: it's XML that people edit.
    static func isImage(_ url: URL) -> Bool { isImage(path: url.path) }

    static func isImage(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if let known = knownExtensions.withLock({ $0[ext] }) { return known }
        let isImage = UTType(filenameExtension: ext).map { $0.conforms(to: .image) && !$0.conforms(to: .svg) } ?? false
        knownExtensions.withLock { $0[ext] = isImage }
        return isImage
    }

    /// Whether the file holds a picture macOS can decode, whatever its name (a PNG without an extension).
    static func decodes(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier) else { return false }
        // ImageIO reads PDFs too, which aren't pictures.
        return type.conforms(to: .image)
    }

    /// The largest size the GPU takes as one picture.
    static let maximumPixelSize = 16_384

    /// Decodes the picture (its largest image: an icon's biggest size), upright, at most
    /// `maximumPixelSize` across. Done off the main thread, so showing it costs nothing more.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var best = 0, bestArea = 0, bestSide = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            if width * height > bestArea { (best, bestArea, bestSide) = (index, width * height, max(width, height)) }
        }
        guard bestSide > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(bestSide, maximumPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary)
    }
}

/// What the status bar and the info panel say about an image.
nonisolated struct ImageDetails: Equatable, Sendable {
    /// As shown (EXIF rotations of 90° swap the stored width and height).
    var pixelWidth = 0
    var pixelHeight = 0
    /// "PNG image", "HEIF image"…
    var format: String?
    /// "PNG", "JPEG"…
    var shortFormat: String?
    var dpi: Double?
    var colorModel: String?
    var bitsPerComponent: Int?
    var hasAlpha = false
    var colorProfile: String?
    /// Frames of an animation, an icon's sizes, a TIFF's pages…
    var frameCount = 1
    /// The frames play (GIF, APNG, WebP, HEICS), rather than being an icon's sizes or a TIFF's pages.
    var isAnimated = false
    /// EXIF orientation (1 is upright).
    var orientation = 1
    var camera: String?
    var lens: String?
    var exposure: String?
    var dateTaken: String?
    var fileSize: Int?
    var created: Date?
    var modified: Date?

    /// Reads the header and metadata (the pixels aren't decoded).
    static func read(data: Data, url: URL) -> ImageDetails? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        var details = ImageDetails()
        details.frameCount = CGImageSourceGetCount(source)
        if let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier) {
            details.format = type.localizedDescription
            details.shortFormat = type.preferredFilenameExtension?.uppercased()
            let animatable = [UTType.gif, .png, .webP, UTType("public.heics")].compactMap { $0 }
            details.isAnimated = details.frameCount > 1 && animatable.contains { type.conforms(to: $0) }
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        details.orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(details.orientation)
        details.pixelWidth = rotated ? height : width
        details.pixelHeight = rotated ? width : height
        details.dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil }
        details.colorModel = properties[kCGImagePropertyColorModel] as? String
        details.bitsPerComponent = properties[kCGImagePropertyDepth] as? Int
        details.hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        details.colorProfile = properties[kCGImagePropertyProfileName] as? String

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model, !model.isEmpty {
            // Most models already start with the make ("Canon EOS R6"); iPhones don't ("iPhone 15 Pro").
            details.camera = make.map { !$0.isEmpty && !model.localizedCaseInsensitiveContains($0) ? "\($0) \(model)" : model } ?? model
        }
        details.lens = (exif[kCGImagePropertyExifLensModel] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var exposure: [String] = []
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            exposure.append(time >= 1 ? "\(time.formatted(.number.precision(.fractionLength(0...1)))) s" : "1/\(Int((1 / time).rounded())) s")
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double {
            exposure.append("ƒ/\(aperture.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            exposure.append("\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm")
        }
        details.exposure = exposure.isEmpty ? nil : exposure.joined(separator: " · ")
        details.dateTaken = (exif[kCGImagePropertyExifDateTimeOriginal] as? String).map(formatExifDate)

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        details.fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? data.count
        details.created = attributes?[.creationDate] as? Date
        details.modified = attributes?[.modificationDate] as? Date
        return details
    }

    /// "2026:10:03 14:22:05" → the date in the user's format.
    private static func formatExifDate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "1920 × 1080"
    var dimensions: String { "\(pixelWidth) × \(pixelHeight)" }

    /// "RGB · 8 bits · alpha"
    var colorSummary: String? {
        var parts: [String] = []
        if let colorModel { parts.append(colorModel) }
        if let bitsPerComponent { parts.append("\(bitsPerComponent) bits") }
        if hasAlpha { parts.append("alpha") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What EXIF orientation 2…8 does to the stored picture.
    var orientationDescription: String? {
        switch orientation {
        case 2: "Flipped horizontally"
        case 3: "Rotated 180°"
        case 4: "Flipped vertically"
        case 5: "Rotated 90° and flipped"
        case 6: "Rotated 90° clockwise"
        case 7: "Rotated 90° and flipped"
        case 8: "Rotated 90° counterclockwise"
        default: nil
        }
    }
}
