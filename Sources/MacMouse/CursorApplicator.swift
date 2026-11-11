import AppKit
import CoreGraphics
import Darwin

enum CursorRole: String, CaseIterable, Identifiable, Codable {
    case arrow, help, working, busy, crosshair, text, handwriting, unavailable
    case resizeVertical, resizeHorizontal, resizeDiagonalNWSE, resizeDiagonalNESW
    case move, upArrow, link

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .arrow: "普通指针"
        case .help: "帮助选择"
        case .working: "后台运行"
        case .busy: "忙碌"
        case .crosshair: "精确选择"
        case .text: "文本选择"
        case .handwriting: "手写"
        case .unavailable: "不可用"
        case .resizeVertical: "垂直调整"
        case .resizeHorizontal: "水平调整"
        case .resizeDiagonalNWSE: "西北－东南调整"
        case .resizeDiagonalNESW: "东北－西南调整"
        case .move: "移动"
        case .upArrow: "备用选择"
        case .link: "链接选择"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow: "cursorarrow"
        case .help: "questionmark.circle"
        case .working: "cursorarrow.rays"
        case .busy: "hourglass"
        case .crosshair: "scope"
        case .text: "text.cursor"
        case .handwriting: "pencil.tip"
        case .unavailable: "nosign"
        case .resizeVertical: "arrow.up.and.down"
        case .resizeHorizontal: "arrow.left.and.right"
        case .resizeDiagonalNWSE: "arrow.up.left.and.arrow.down.right"
        case .resizeDiagonalNESW: "arrow.up.right.and.arrow.down.left"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .upArrow: "arrow.up"
        case .link: "hand.point.up.left"
        }
    }

    var canApply: Bool { !cursorNames.isEmpty }

    fileprivate var cursorNames: [String] {
        let systemNames: [String]
        let coreIDs: [Int]
        switch self {
        case .arrow:
            if #available(macOS 26.0, *) {
                systemNames = ["Arrow", "ArrowCtx", "ArrowS"]
            } else {
                systemNames = ["Arrow", "ArrowCtx"]
            }
            coreIDs = [0, 24]
        case .help:
            systemNames = []
            coreIDs = [40]
        case .working:
            systemNames = []
            coreIDs = [4]
        case .busy:
            systemNames = []
            coreIDs = []
        case .crosshair:
            systemNames = []
            coreIDs = [7, 8, 20, 41]
        case .text:
            if #available(macOS 26.0, *) {
                systemNames = ["IBeam", "IBeamXOR", "IBeamS"]
            } else {
                systemNames = ["IBeam", "IBeamXOR"]
            }
            coreIDs = [1, 26]
        case .handwriting, .upArrow:
            systemNames = []
            coreIDs = []
        case .unavailable:
            systemNames = ["NotAllowed"]
            coreIDs = [3]
        case .resizeVertical:
            systemNames = []
            coreIDs = [21, 22, 23, 31, 32, 36]
        case .resizeHorizontal:
            systemNames = []
            coreIDs = [17, 18, 19, 27, 28, 38]
        case .resizeDiagonalNWSE:
            systemNames = []
            coreIDs = [33, 34, 35]
        case .resizeDiagonalNESW:
            systemNames = []
            coreIDs = [29, 30, 37]
        case .move:
            systemNames = ["Move"]
            coreIDs = [11, 12, 39]
        case .link:
            systemNames = ["PointingHand"]
            coreIDs = [2, 13]
        }
        return systemNames.map { "com.apple.coregraphics." + $0 }
            + coreIDs.map { "com.apple.cursor.\($0)" }
    }
}

@MainActor
final class CursorApplicator {
    private let services = WindowServerCursors()
    private var active: [String: CursorRegistration] = [:]
    private var originals: [String: OriginalCursor] = [:]
    private var loadedBackups = false

    var isAvailable: Bool { services != nil }

    func apply(_ replacements: [CursorRole: WindowsCursor]) throws {
        let (services, connection) = try windowServer()
        let prepared = try CursorRole.allCases.compactMap { role -> (CursorRole, CursorRegistration)? in
            guard role.canApply, let cursor = replacements[role] else { return nil }
            return (role, try CursorRegistration(cursor: cursor, role: role))
        }
        guard !prepared.isEmpty else { throw CursorApplicationError.emptyTheme }
        loadBackups(services: services, connection: connection)

        let previous = active
        var applied: [String: CursorRegistration] = [:]
        var changed = Set<String>()
        do {
            for (role, cursor) in prepared {
                var roleApplied = false
                var lastError: Int32 = 0
                for name in role.cursorNames {
                    if originals[name] == nil {
                        guard let original = services.originalCursor(name, connection: connection) else {
                            lastError = CGError.failure.rawValue
                            continue
                        }
                        // WindowServer can remove numeric overrides directly. A named Apple
                        // cursor needs its original registration to be restored safely.
                        if case .systemDefault = original, name.hasPrefix("com.apple.coregraphics.") {
                            lastError = CGError.noneAvailable.rawValue
                            continue
                        }
                        let status = services.backUp(original, as: name, connection: connection)
                        guard status == 0 else {
                            lastError = status
                            continue
                        }
                        originals[name] = original
                    }
                    let status = services.register(cursor, as: name, connection: connection)
                    if status == 0 {
                        roleApplied = true
                        applied[name] = cursor
                        changed.insert(name)
                    } else {
                        lastError = status
                    }
                }
                guard roleApplied else {
                    throw CursorApplicationError.registration(role, lastError)
                }
            }
            for name in previous.keys.sorted() where applied[name] == nil {
                let status = restore(name, services: services, connection: connection)
                guard status == 0 else { throw CursorApplicationError.restoration(status) }
                changed.insert(name)
            }
            active = applied
            discardInactiveBackups(services: services, connection: connection)
        } catch {
            var rollbackError: Int32?
            for name in changed.sorted() {
                let status: Int32
                if let previousCursor = previous[name] {
                    status = services.register(previousCursor, as: name, connection: connection)
                } else {
                    status = restore(name, services: services, connection: connection)
                }
                if status == 0 {
                    active[name] = previous[name]
                } else {
                    active[name] = applied[name] ?? previous[name]
                    rollbackError = status
                }
            }
            discardInactiveBackups(services: services, connection: connection)
            if let rollbackError { throw CursorApplicationError.rollback(error, rollbackError) }
            throw error
        }
    }

    func reset() throws {
        let (services, connection) = try windowServer()
        loadBackups(services: services, connection: connection)
        var firstFailure: Int32?
        var restored: [String] = []
        for name in originals.keys.sorted() {
            let status = restore(name, services: services, connection: connection)
            if status == 0 {
                active.removeValue(forKey: name)
                restored.append(name)
            } else if firstFailure == nil {
                firstFailure = status
            }
        }
        discardBackups(restored, services: services, connection: connection)
        if let firstFailure { throw CursorApplicationError.restoration(firstFailure) }
    }

    private func loadBackups(services: WindowServerCursors, connection: Int32) {
        guard !loadedBackups else { return }
        loadedBackups = true
        for name in CursorRole.allCases.flatMap(\.cursorNames) {
            guard let original = services.backup(for: name, connection: connection) else { continue }
            originals[name] = original
            if case let .registered(cursor) = services.originalCursor(name, connection: connection) {
                active[name] = cursor
            }
        }
    }

    private func discardInactiveBackups(services: WindowServerCursors, connection: Int32) {
        let inactive = originals.keys.filter { active[$0] == nil }
        discardBackups(inactive, services: services, connection: connection)
    }

    private func discardBackups(_ names: [String], services: WindowServerCursors, connection: Int32) {
        for name in names {
            guard let original = originals[name] else { continue }
            let status = services.removeBackup(for: name, original: original, connection: connection)
            if status == 0 {
                originals.removeValue(forKey: name)
            }
        }
    }

    private func restore(_ name: String, services: WindowServerCursors, connection: Int32) -> Int32 {
        if case let .registered(cursor) = originals[name] {
            return services.register(cursor, as: name, connection: connection)
        }
        return services.remove(name, connection: connection)
    }

    private func windowServer() throws -> (WindowServerCursors, Int32) {
        guard let services else { throw CursorApplicationError.unavailable }
        let connection = services.connectionID()
        guard connection != 0 else { throw CursorApplicationError.noDesktopSession }
        return (services, connection)
    }
}

private enum CursorApplicationError: LocalizedError {
    case unavailable
    case noDesktopSession
    case emptyTheme
    case invalidArtwork(CursorRole)
    case registration(CursorRole, Int32)
    case restoration(Int32)
    case rollback(Error, Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "当前 macOS 缺少替换系统光标所需的接口。"
        case .noDesktopSession:
            "无法连接到 macOS 图形会话。请从已登录的桌面打开 MacMouse。"
        case .emptyTheme:
            "请至少为一个可应用的光标类型分配文件。"
        case let .invalidArtwork(role):
            "无法生成「\(role.displayName)」的光标图像。"
        case let .registration(role, code):
            "系统拒绝替换「\(role.displayName)」光标（错误 \(code)）。"
        case let .restoration(code):
            "部分系统光标未能恢复（错误 \(code)）。请重试恢复。"
        case let .rollback(error, code):
            "\(error.localizedDescription) 部分光标未能回退（错误 \(code)）。请使用恢复默认光标。"
        }
    }
}

private enum OriginalCursor {
    case registered(CursorRegistration)
    case systemDefault

    var backupPrefix: String {
        switch self {
        case .registered: "app.macmouse.backup.image."
        case .systemDefault: "app.macmouse.backup.default."
        }
    }
}

private struct CursorRegistration {
    let size: CGSize
    let hotSpot: CGPoint
    let count: UInt
    let duration: CGFloat
    let images: CFArray

    init(size: CGSize, hotSpot: CGPoint, count: UInt, duration: CGFloat, images: CFArray) {
        self.size = size
        self.hotSpot = hotSpot
        self.count = count
        self.duration = duration
        self.images = images
    }

    init(cursor: WindowsCursor, role: CursorRole) throws {
        let (timeline, frameDuration) = Self.timeline(for: cursor.frames)
        let sourceFrames = timeline.map { $0.representations.sorted { Self.longEdge($0) < Self.longEdge($1) } }
        guard !sourceFrames.isEmpty, sourceFrames.allSatisfy({ !$0.isEmpty }) else {
            throw CursorApplicationError.invalidArtwork(role)
        }

        // WindowServer uses one canvas, hotspot and interval for every frame at each display scale.
        let sourceEdge = sourceFrames.compactMap(\.first).map(Self.longEdge).max() ?? 32
        let nominalEdge = cursor.pointSize.map { max($0.width, $0.height) } ?? CGFloat(sourceEdge)
        let edge = Int(min(32, max(1, nominalEdge.rounded())))
        let scales = [1, 2]
        let representations = scales.map { scale in
            sourceFrames.map { Self.representation(for: $0, edge: edge * scale) }
        }
        let bounds = representations.joined().reduce(CGRect.null) { bounds, source in
            let fit = CGFloat(edge) / CGFloat(Self.longEdge(source))
            let rect = CGRect(
                x: -source.hotSpot.x * fit,
                y: -source.hotSpot.y * fit,
                width: CGFloat(source.image.width) * fit,
                height: CGFloat(source.image.height) * fit
            )
            return bounds.union(rect)
        }
        let fit = min(1, 32 / max(bounds.width, bounds.height))
        let points = CGSize(width: min(32, ceil(bounds.width * fit)), height: min(32, ceil(bounds.height * fit)))
        let hotSpot = CGPoint(x: -bounds.minX * fit, y: -bounds.minY * fit)
        var sheets: [CGImage] = []
        for (scale, frames) in zip(scales, representations) {
            guard let image = Self.spriteSheet(
                frames, size: points, scale: scale, edge: CGFloat(edge) * fit, hotSpot: hotSpot
            ) else {
                throw CursorApplicationError.invalidArtwork(role)
            }
            sheets.append(image)
        }
        self.init(
            size: points,
            hotSpot: hotSpot,
            count: UInt(timeline.count),
            duration: frameDuration,
            images: sheets as CFArray
        )
    }

    private static func longEdge(_ representation: WindowsCursorRepresentation) -> Int {
        max(representation.image.width, representation.image.height)
    }

    private static func representation(
        for representations: [WindowsCursorRepresentation], edge: Int
    ) -> WindowsCursorRepresentation {
        representations.first { longEdge($0) >= edge } ?? representations[representations.count - 1]
    }

    private static func timeline(for frames: [WindowsCursorFrame]) -> ([WindowsCursorFrame], TimeInterval) {
        guard frames.count > 1 else { return (frames, 0) }

        let durations = frames.map { max(1.0 / 60.0, $0.duration) }
        let total = durations.reduce(0, +)
        let shortest = durations.min() ?? 1.0 / 60.0
        let count = Int(min(24, max(2, (total / shortest).rounded())))
        let interval = total / Double(count)
        var index = 0
        var end = durations[0]
        let uniform = (0..<count).map { step in
            let time = Double(step) * interval
            while time + 1e-9 >= end && index < frames.count - 1 {
                index += 1
                end += durations[index]
            }
            return frames[index]
        }
        return (uniform, interval)
    }

    private static func spriteSheet(
        _ frames: [WindowsCursorRepresentation], size: CGSize, scale: Int, edge: CGFloat, hotSpot: CGPoint
    ) -> CGImage? {
        let pixelWidth = Int(size.width) * scale
        let pixelHeight = Int(size.height) * scale
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight * frames.count,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        let target = CGPoint(x: hotSpot.x * CGFloat(scale), y: hotSpot.y * CGFloat(scale))
        for (index, source) in frames.enumerated() {
            let fit = edge * CGFloat(scale) / CGFloat(longEdge(source))
            let width = CGFloat(source.image.width)
            let height = CGFloat(source.image.height)
            let frameTop = CGFloat((frames.count - index) * pixelHeight)
            let rect = CGRect(
                x: target.x - source.hotSpot.x * fit,
                y: frameTop - target.y - (height - source.hotSpot.y) * fit,
                width: width * fit,
                height: height * fit
            )
            context.interpolationQuality = fit == 1 ? .none : .high
            context.draw(source.image, in: rect)
        }
        return context.makeImage()
    }
}

private struct WindowServerCursors {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Register = @convention(c) (
        Int32, UnsafePointer<CChar>, Bool, Bool, CGSize, CGPoint, UInt, CGFloat, CFArray, UnsafeMutablePointer<Int32>
    ) -> Int32
    private typealias Copy = @convention(c) (
        Int32, UnsafePointer<CChar>, UnsafeMutablePointer<CGSize>, UnsafeMutablePointer<CGPoint>,
        UnsafeMutablePointer<UInt>, UnsafeMutablePointer<CGFloat>, UnsafeMutablePointer<Unmanaged<CFArray>?>
    ) -> Int32
    private typealias Remove = @convention(c) (Int32, UnsafePointer<CChar>, Bool) -> Int32

    private let mainConnection: Connection
    private let registerImages: Register
    private let copyImages: Copy
    private let removeCursor: Remove

    init?() {
        let processSymbols = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(processSymbols, "CGSMainConnectionID"),
              let register = dlsym(processSymbols, "CGSRegisterCursorWithImages"),
              let copy = dlsym(processSymbols, "CGSCopyRegisteredCursorImages"),
              let remove = dlsym(processSymbols, "CGSRemoveRegisteredCursor") else { return nil }
        mainConnection = unsafeBitCast(connection, to: Connection.self)
        registerImages = unsafeBitCast(register, to: Register.self)
        copyImages = unsafeBitCast(copy, to: Copy.self)
        removeCursor = unsafeBitCast(remove, to: Remove.self)
    }

    func connectionID() -> Int32 { mainConnection() }

    func register(_ cursor: CursorRegistration, as name: String, connection: Int32) -> Int32 {
        register(cursor, as: name, connection: connection, instantly: true)
    }

    private func register(
        _ cursor: CursorRegistration, as name: String, connection: Int32, instantly: Bool
    ) -> Int32 {
        var seed: Int32 = 0
        return name.withCString { name in
            registerImages(
                connection, name, true, instantly,
                cursor.size, cursor.hotSpot, cursor.count, cursor.duration, cursor.images, &seed
            )
        }
    }

    func originalCursor(_ name: String, connection: Int32) -> OriginalCursor? {
        var size = CGSize.zero
        var hotSpot = CGPoint.zero
        var count: UInt = 0
        var duration: CGFloat = 0
        var copied: Unmanaged<CFArray>?
        let result = name.withCString {
            copyImages(connection, $0, &size, &hotSpot, &count, &duration, &copied)
        }
        let images = copied?.takeRetainedValue()
        // This private lookup reports kCGErrorRangeCheck when a name has no entry.
        if result == CGError.rangeCheck.rawValue { return .systemDefault }
        guard result == 0, let images, CFArrayGetCount(images) > 0 else { return nil }
        return .registered(CursorRegistration(size: size, hotSpot: hotSpot, count: count, duration: duration, images: images))
    }

    func remove(_ name: String, connection: Int32) -> Int32 {
        let result = name.withCString { removeCursor(connection, $0, true) }
        if result != 0, case .systemDefault = originalCursor(name, connection: connection) { return 0 }
        return result
    }

    func backup(for name: String, connection: Int32) -> OriginalCursor? {
        let imageName = "app.macmouse.backup.image." + name
        let defaultName = OriginalCursor.systemDefault.backupPrefix + name
        if case let .registered(cursor) = originalCursor(imageName, connection: connection) {
            return .registered(cursor)
        }
        if case .registered = originalCursor(defaultName, connection: connection) {
            return .systemDefault
        }
        return nil
    }

    func backUp(_ original: OriginalCursor, as name: String, connection: Int32) -> Int32 {
        let cursor: CursorRegistration
        switch original {
        case let .registered(registration):
            cursor = registration
        case .systemDefault:
            guard let context = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage() else { return CGError.failure.rawValue }
            cursor = CursorRegistration(size: CGSize(width: 1, height: 1), hotSpot: .zero,
                                        count: 1, duration: 0, images: [image] as CFArray)
        }
        // A global but undisplayed alias keeps the original available on the next launch
        // and disappears naturally when this WindowServer session ends.
        return register(cursor, as: original.backupPrefix + name, connection: connection, instantly: false)
    }

    func removeBackup(for name: String, original: OriginalCursor, connection: Int32) -> Int32 {
        remove(original.backupPrefix + name, connection: connection)
    }
}
