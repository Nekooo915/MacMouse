import CoreGraphics
import Foundation

struct WindowsCursor: Sendable {
    let frames: [WindowsCursorFrame]
    let pointSize: CGSize?

    init(frames: [WindowsCursorFrame], pointSize: CGSize? = nil) {
        self.frames = frames
        self.pointSize = pointSize
    }

    var isAnimated: Bool { frames.count > 1 }
}

struct WindowsCursorFrame: Sendable {
    let representations: [WindowsCursorRepresentation]
    let duration: TimeInterval
}

struct WindowsCursorRepresentation: Sendable {
    let image: CGImage
    let hotSpot: CGPoint
}

enum WindowsCursorParser {
    enum ParseError: LocalizedError {
        case unsupportedFormat
        case unsupportedBitmap
        case invalidFile
        case invalidImage
        case invalidAnimation
        case sizeLimit

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "请选择 Windows .cur 或 .ani 光标文件。"
            case .unsupportedBitmap: "这个光标使用了暂不支持的位图编码。"
            case .invalidFile: "光标文件的头部或目录不完整。"
            case .invalidImage: "光标的图像或热点数据无效。"
            case .invalidAnimation: "动画光标的帧或播放顺序不完整。"
            case .sizeLimit: "这个光标的文件大小、图像尺寸或帧数超过导入上限。"
            }
        }
    }

    struct DecodeBudget {
        private var remainingPixels = 8_388_608

        mutating func reserve(width: Int, height: Int) throws {
            guard width > 0, height > 0 else { throw ParseError.invalidImage }
            guard width <= 512, height <= 512, width * height <= remainingPixels else {
                throw ParseError.sizeLimit
            }
            remainingPixels -= width * height
        }
    }

    private static let maximumFileSize = 64 * 1024 * 1024
    private static let maximumFrames = 512
    private static let maximumSteps = 8_192

    static func parse(contentsOf url: URL) throws -> WindowsCursor {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= maximumFileSize else { throw ParseError.sizeLimit }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> WindowsCursor {
        guard data.count <= maximumFileSize else { throw ParseError.sizeLimit }
        guard data.count >= 6 else { throw ParseError.invalidFile }
        let bytes = CursorBytes(Array(data)[...])
        var budget = DecodeBudget()

        if bytes.tag(at: 0) == "RIFF" {
            return try parseAnimation(bytes, budget: &budget)
        }
        guard bytes.word(at: 0) == 0, bytes.word(at: 2) == 2 else {
            throw ParseError.unsupportedFormat
        }
        let images = try parseDirectory(bytes, allowIcons: false, budget: &budget)
        return WindowsCursor(frames: [WindowsCursorFrame(representations: images, duration: 0)])
    }

    private static func parseDirectory(
        _ bytes: CursorBytes, allowIcons: Bool, budget: inout DecodeBudget
    ) throws -> [WindowsCursorRepresentation] {
        guard bytes.count >= 6, bytes.word(at: 0) == 0 else { throw ParseError.invalidFile }
        let kind = bytes.word(at: 2)
        guard kind == 2 || (allowIcons && kind == 1) else { throw ParseError.unsupportedFormat }

        let count = bytes.word(at: 4)
        let directoryEnd = 6 + 16 * count
        guard count > 0, directoryEnd <= bytes.count else { throw ParseError.invalidFile }
        guard count <= 128 else { throw ParseError.sizeLimit }

        var images: [WindowsCursorRepresentation] = []
        var firstError: Error?
        for index in 0..<count {
            let entry = 6 + 16 * index
            let storedHeight = Int(bytes[entry + 1])
            let expectedHeight = storedHeight == 0 ? 256 : storedHeight
            let length = Int(bytes.dword(at: entry + 8))
            let offset = Int(bytes.dword(at: entry + 12))
            do {
                guard offset >= directoryEnd, length > 0, offset <= bytes.count,
                      length <= bytes.count - offset else {
                    throw ParseError.invalidImage
                }
                let bitmap = bytes.subrange(offset..<(offset + length))
                let image = try CursorBitmap.decode(bitmap, expectedHeight: expectedHeight, budget: &budget)
                let x = kind == 2 ? bytes.word(at: entry + 4) : image.width / 2
                let y = kind == 2 ? bytes.word(at: entry + 6) : image.height / 2
                guard x < image.width, y < image.height else { throw ParseError.invalidImage }
                images.append(WindowsCursorRepresentation(image: image, hotSpot: CGPoint(x: x, y: y)))
            } catch ParseError.sizeLimit {
                throw ParseError.sizeLimit
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        guard !images.isEmpty else { throw firstError ?? ParseError.invalidImage }
        return images
    }

    private static func parseAnimation(_ bytes: CursorBytes, budget: inout DecodeBudget) throws -> WindowsCursor {
        guard bytes.count >= 12, bytes.tag(at: 8) == "ACON" else { throw ParseError.unsupportedFormat }
        let riffEnd = 8 + Int(bytes.dword(at: 4))
        guard riffEnd >= 12, riffEnd <= bytes.count else { throw ParseError.invalidFile }

        var header: CursorBytes?
        var rates: CursorBytes?
        var sequence: CursorBytes?
        var frameFiles: [CursorBytes] = []
        try bytes.subrange(12..<riffEnd).forEachChunk { tag, body in
            switch tag {
            case "anih":
                guard header == nil, body.count >= 36 else { throw ParseError.invalidAnimation }
                let size = Int(body.dword(at: 0))
                guard size >= 36, size <= body.count else { throw ParseError.invalidAnimation }
                header = body
            case "rate":
                guard rates == nil else { throw ParseError.invalidAnimation }
                rates = body
            case "seq ":
                guard sequence == nil else { throw ParseError.invalidAnimation }
                sequence = body
            case "LIST" where body.count >= 4 && body.tag(at: 0) == "fram":
                try body.subrange(4..<body.count).forEachChunk { tag, frame in
                    guard tag == "icon" else { return }
                    guard frameFiles.count < maximumFrames else { throw ParseError.sizeLimit }
                    frameFiles.append(frame)
                }
            default:
                break
            }
        }

        guard let header, !frameFiles.isEmpty else { throw ParseError.invalidAnimation }
        let frameCount = Int(header.dword(at: 4))
        let stepCount = Int(header.dword(at: 8))
        let defaultRate = header.dword(at: 28)
        let flags = header.dword(at: 32)
        guard stepCount <= maximumSteps, frameCount <= maximumFrames else { throw ParseError.sizeLimit }
        guard stepCount > 0, frameCount == frameFiles.count else { throw ParseError.invalidAnimation }
        if let sequence {
            guard sequence.count >= stepCount * 4 else { throw ParseError.invalidAnimation }
        } else {
            guard flags & 2 == 0, stepCount <= frameCount else { throw ParseError.invalidAnimation }
        }
        if let rates {
            guard rates.count >= stepCount * 4 else { throw ParseError.invalidAnimation }
        }

        var decoded: [Int: [WindowsCursorRepresentation]] = [:]
        var frames: [WindowsCursorFrame] = []
        for step in 0..<stepCount {
            let index = sequence.map { Int($0.dword(at: step * 4)) } ?? step
            guard index < frameCount else { throw ParseError.invalidAnimation }
            if decoded[index] == nil {
                decoded[index] = try parseDirectory(frameFiles[index], allowIcons: true, budget: &budget)
            }
            guard let images = decoded[index] else { throw ParseError.invalidAnimation }
            let rate = rates?.dword(at: step * 4) ?? defaultRate
            let delay = rate > 0 ? rate : max(defaultRate, 1)
            frames.append(WindowsCursorFrame(representations: images, duration: Double(delay) / 60))
        }
        return WindowsCursor(frames: frames)
    }
}

struct CursorBytes {
    let storage: ArraySlice<UInt8>

    init(_ storage: ArraySlice<UInt8>) { self.storage = storage }

    var count: Int { storage.count }

    subscript(_ index: Int) -> UInt8 { storage[storage.startIndex + index] }

    func word(at index: Int) -> Int {
        Int(self[index]) | Int(self[index + 1]) << 8
    }

    func dword(at index: Int) -> UInt32 {
        UInt32(word(at: index)) | UInt32(word(at: index + 2)) << 16
    }

    func signedDword(at index: Int) -> Int { Int(Int32(bitPattern: dword(at: index))) }

    func tag(at index: Int) -> String {
        String(decoding: subrange(index..<(index + 4)).storage, as: UTF8.self)
    }

    func subrange(_ range: Range<Int>) -> CursorBytes {
        CursorBytes(storage[(storage.startIndex + range.lowerBound)..<(storage.startIndex + range.upperBound)])
    }

    func forEachChunk(_ visit: (String, CursorBytes) throws -> Void) throws {
        var offset = 0
        var chunks = 0
        while offset < count {
            guard count - offset >= 8 else { throw WindowsCursorParser.ParseError.invalidAnimation }
            let length = Int(dword(at: offset + 4))
            let start = offset + 8
            let paddedLength = length + length % 2
            guard paddedLength <= count - start else { throw WindowsCursorParser.ParseError.invalidAnimation }
            chunks += 1
            guard chunks <= 8_192 else { throw WindowsCursorParser.ParseError.sizeLimit }
            try visit(tag(at: offset), subrange(start..<(start + length)))
            offset = start + paddedLength
        }
    }
}
