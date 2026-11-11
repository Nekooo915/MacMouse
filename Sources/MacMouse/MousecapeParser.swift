import CoreGraphics
import Foundation
import ImageIO

struct MousecapeTheme: Sendable {
    let name: String?
    let cursors: [String: Data]
    let skippedCount: Int
}

enum MousecapeParser {
    enum ParseError: LocalizedError {
        case invalidTheme
        case emptyTheme
        case invalidCursor
        case invalidImage
        case sizeLimit

        var errorDescription: String? {
            switch self {
            case .invalidTheme: "无法读取这个 Mousecape .cape 主题。"
            case .emptyTheme: "这个 .cape 主题中没有可读取的光标。"
            case .invalidCursor: "光标的尺寸、热点或动画参数无效。"
            case .invalidImage: "无法读取光标图像，或图像与动画帧数不符。"
            case .sizeLimit: "这个 .cape 主题的大小、图像尺寸或帧数超过导入上限。"
            }
        }
    }

    private static let maximumFileSize = 32 * 1024 * 1024
    private static let maximumCursors = 256
    private static let maximumRepresentations = 16
    private static let maximumFrames = 512
    private static let maximumFrameDimension = 1024
    private static let maximumCursorPixels = 8_388_608

    static func parse(_ data: Data) throws -> MousecapeTheme {
        guard data.count <= maximumFileSize else { throw ParseError.sizeLimit }
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = root as? [String: Any],
              let entries = dictionary["Cursors"] as? [String: Any] else {
            throw ParseError.invalidTheme
        }
        guard entries.count <= maximumCursors else { throw ParseError.sizeLimit }

        var cursors: [String: Data] = [:]
        var remainingBytes = maximumFileSize
        for (identifier, entry) in entries {
            guard !identifier.isEmpty, identifier.utf8.count <= 256,
                  let properties = entry as? [String: Any],
                  let record = try? CursorRecord(properties) else { continue }
            guard record.imageBytes <= remainingBytes else { throw ParseError.sizeLimit }
            let cursor = try PropertyListSerialization.data(
                fromPropertyList: record.properties, format: .binary, options: 0
            )
            guard cursor.count <= remainingBytes else { throw ParseError.sizeLimit }
            remainingBytes -= cursor.count
            cursors[identifier] = cursor
        }
        guard !cursors.isEmpty else { throw ParseError.emptyTheme }

        let name = (dictionary["CapeName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MousecapeTheme(
            name: name.flatMap { $0.isEmpty ? nil : String($0.prefix(256)) },
            cursors: cursors, skippedCount: entries.count - cursors.count
        )
    }

    static func decodeCursor(_ data: Data) throws -> WindowsCursor {
        guard data.count <= maximumFileSize else { throw ParseError.sizeLimit }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let properties = plist as? [String: Any] else { throw ParseError.invalidCursor }
        let cursor = try CursorRecord(properties)
        var images: [[WindowsCursorRepresentation]] = []
        var remainingPixels = maximumCursorPixels
        var firstError: Error?
        for data in cursor.representations {
            do {
                let representation = try decodeRepresentation(data, cursor: cursor, budget: remainingPixels)
                let pixels = representation.reduce(0) { $0 + $1.image.width * $1.image.height }
                remainingPixels -= pixels
                images.append(representation)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        guard !images.isEmpty else { throw firstError ?? ParseError.invalidImage }
        images.sort {
            max($0[0].image.width, $0[0].image.height) < max($1[0].image.width, $1[0].image.height)
        }
        let frames = (0..<cursor.frameCount).map { index in
            WindowsCursorFrame(
                representations: images.map { $0[index] },
                duration: cursor.frameDuration
            )
        }
        return WindowsCursor(frames: frames, pointSize: cursor.size)
    }

    private static func decodeRepresentation(
        _ data: Data, cursor: CursorRecord, budget: Int
    ) throws -> [WindowsCursorRepresentation] {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0 else { throw ParseError.invalidImage }
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, primary, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ParseError.invalidImage }
        guard width <= maximumFrameDimension, height <= maximumFrameDimension * cursor.frameCount,
              width * height <= budget else { throw ParseError.sizeLimit }
        guard let sheet = CGImageSourceCreateImageAtIndex(source, primary, options),
              sheet.width > 0, sheet.height > 0, sheet.height.isMultiple(of: cursor.frameCount) else {
            throw ParseError.invalidImage
        }

        let frameHeight = sheet.height / cursor.frameCount
        guard sheet.width <= maximumFrameDimension, frameHeight <= maximumFrameDimension,
              sheet.width * sheet.height <= budget else { throw ParseError.sizeLimit }
        let hotSpot = CGPoint(x: cursor.hotSpot.x * CGFloat(sheet.width) / cursor.size.width,
                              y: cursor.hotSpot.y * CGFloat(frameHeight) / cursor.size.height)
        if cursor.frameCount == 1 {
            return [WindowsCursorRepresentation(image: sheet, hotSpot: hotSpot)]
        }

        // A Mousecape representation stores a whole animation as a strip, first frame at the top.
        return try (0..<cursor.frameCount).map { index in
            let region = CGRect(x: 0, y: index * frameHeight, width: sheet.width, height: frameHeight)
            guard let image = sheet.cropping(to: region) else { throw ParseError.invalidImage }
            return WindowsCursorRepresentation(image: image, hotSpot: hotSpot)
        }
    }

    private struct CursorRecord {
        let frameCount: Int
        let frameDuration: TimeInterval
        let size: CGSize
        let hotSpot: CGPoint
        let representations: [Data]
        let imageBytes: Int

        init(_ dictionary: [String: Any]) throws {
            guard let count = Self.number(dictionary["FrameCount"]),
                  count > 0, count == count.rounded(),
                  let width = Self.number(dictionary["PointsWide"]), width > 0,
                  let height = Self.number(dictionary["PointsHigh"]), height > 0,
                  let x = Self.number(dictionary["HotSpotX"]), x >= 0, x <= width,
                  let y = Self.number(dictionary["HotSpotY"]), y >= 0, y <= height,
                  let representations = dictionary["Representations"] as? [Data],
                  !representations.isEmpty else {
                throw ParseError.invalidCursor
            }
            guard count <= Double(maximumFrames), width <= Double(maximumFrameDimension),
                  height <= Double(maximumFrameDimension), representations.count <= maximumRepresentations else {
                throw ParseError.sizeLimit
            }
            imageBytes = representations.reduce(0) { $0 + $1.count }
            guard imageBytes <= maximumFileSize else { throw ParseError.sizeLimit }

            frameCount = Int(count)
            if frameCount > 1 {
                guard let duration = Self.number(dictionary["FrameDuration"]),
                      duration > 0, duration <= 3600 else { throw ParseError.invalidCursor }
                frameDuration = duration
            } else {
                frameDuration = 0
            }
            size = CGSize(width: width, height: height)
            hotSpot = CGPoint(x: x, y: y)
            self.representations = representations
        }

        var properties: [String: Any] {
            [
                "FrameCount": frameCount,
                "FrameDuration": frameDuration,
                "PointsWide": Double(size.width),
                "PointsHigh": Double(size.height),
                "HotSpotX": Double(hotSpot.x),
                "HotSpotY": Double(hotSpot.y),
                "Representations": representations
            ]
        }

        private static func number(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
    }
}
