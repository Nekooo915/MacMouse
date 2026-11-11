import AppKit
import Observation

struct CursorAsset: Codable, Identifiable, Sendable {
    enum Format: String, Codable, Sendable { case mousecape }

    var id = UUID()
    let name: String
    let data: Data
    let decodedPixelCount: Int
    var format: Format?

    var fileType: String {
        if format == .mousecape { return "CAPE" }
        return URL(fileURLWithPath: name).pathExtension.uppercased()
    }

    func decode() throws -> WindowsCursor {
        if format == .mousecape { return try MousecapeParser.decodeCursor(data) }
        return try WindowsCursorParser.parse(data)
    }
}

struct CursorTheme: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var assets: [CursorAsset] = []
    var assignments: [CursorRole: UUID] = [:]

    func asset(for role: CursorRole) -> CursorAsset? {
        guard let id = assignments[role] else { return nil }
        return assets.first { $0.id == id }
    }

    var unassigned: [CursorAsset] {
        let assigned = Set(assignments.values)
        return assets.filter { !assigned.contains($0.id) }
    }

    var applicableCount: Int {
        assignments.keys.filter(\.canApply).count
    }
}

@MainActor @Observable
final class CursorThemeStore {
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private struct AppliedTheme: Codable {
        let themeID: UUID
        let assets: [CursorAsset]
        let assignments: [CursorRole: UUID]
    }

    private struct Library: Codable {
        var themes: [CursorTheme]
        var selectedID: UUID
        var applied: AppliedTheme?

        static var empty: Library {
            let theme = CursorTheme(name: "我的光标")
            return Library(themes: [theme], selectedID: theme.id)
        }
    }

    private struct ImportedCursor: Sendable {
        let url: URL
        let asset: CursorAsset
        let cursor: WindowsCursor
    }

    private struct ImportBatch: Sendable {
        let entries: [ImportedCursor]
        let assignments: [CursorRole: URL]
        let errors: [String]
    }

    private struct ImportedTheme: Sendable {
        let theme: CursorTheme
        let previews: [UUID: WindowsCursor]
        let skippedCount: Int
    }

    private struct ImportResult {
        var message: String?
        var errors: [String] = []
    }

    nonisolated private static let themeAssetLimit = 96
    nonisolated private static let themeByteLimit = 48 * 1024 * 1024
    nonisolated private static let themePixelLimit = 32 * 1024 * 1024
    nonisolated private static let fileByteLimit = 32 * 1024 * 1024
    private let applicator = CursorApplicator()
    private let libraryURL: URL
    private var library = Library.empty
    private var decoded: [UUID: WindowsCursor] = [:]
    private var didRestore = false
    var notice: Notice?
    private(set) var status = ""
    private(set) var systemThemeID: UUID?
    private(set) var isImporting = false

    init(libraryURL: URL? = nil) {
        self.libraryURL = libraryURL ?? URL.applicationSupportDirectory
            .appendingPathComponent("MacMouse", isDirectory: true)
            .appendingPathComponent("Library.json")

        do {
            let saved = try Data(contentsOf: self.libraryURL)
            library = try JSONDecoder().decode(Library.self, from: saved)
            if library.themes.isEmpty {
                library = .empty
            } else if !library.themes.contains(where: { $0.id == library.selectedID }) {
                library.selectedID = library.themes[0].id
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // The first launch starts with an empty theme.
        } catch {
            notice = Notice(title: "读取主题库失败", message: error.localizedDescription)
        }
        reloadPreviews()
    }

    var themes: [CursorTheme] { library.themes }
    var theme: CursorTheme { library.themes.first { $0.id == library.selectedID } ?? library.themes[0] }
    var isSystemAvailable: Bool { applicator.isAvailable }

    var matchesAppliedTheme: Bool {
        guard let applied = library.applied, applied.themeID == theme.id else { return false }
        return applied.assignments == theme.assignments.filter { $0.key.canApply }
    }

    func preview(_ asset: CursorAsset) -> WindowsCursor? {
        decoded[asset.id]
    }

    func selectTheme(_ id: UUID) {
        guard id != theme.id, library.themes.contains(where: { $0.id == id }) else { return }
        var next = library
        next.selectedID = id
        if commit(next) { reloadPreviews() }
    }

    func createTheme(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let theme = CursorTheme(name: name)
        var next = library
        next.themes.append(theme)
        next.selectedID = theme.id
        if commit(next) { reloadPreviews() }
    }

    func renameTheme(to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        changeTheme(theme.id) { $0.name = name }
    }

    func deleteTheme() {
        var next = library
        let deleted = theme.id
        next.themes.removeAll { $0.id == deleted }
        if next.themes.isEmpty { next.themes = Library.empty.themes }
        next.selectedID = next.themes[0].id
        if next.applied?.themeID == deleted {
            next.applied = nil
            if updateSystem(next) { reloadPreviews() }
        } else if commit(next) {
            reloadPreviews()
        }
    }

    func assign(_ asset: CursorAsset, to role: CursorRole) {
        if changeTheme(theme.id, change: { $0.assignments[role] = asset.id }) {
            status = "已分配到\(role.displayName)"
        }
    }

    func removeAssignment(for role: CursorRole) {
        changeTheme(theme.id) { $0.assignments.removeValue(forKey: role) }
    }

    func removeAsset(_ asset: CursorAsset) -> Bool {
        let saved = changeTheme(theme.id) { theme in
            theme.assignments = theme.assignments.filter { $0.value != asset.id }
            theme.assets.removeAll { $0.id == asset.id }
        }
        if saved { decoded.removeValue(forKey: asset.id) }
        return saved
    }

    func importFiles(_ urls: [URL], to role: CursorRole? = nil) async {
        guard !isImporting, !urls.isEmpty else { return }
        let selectedThemeID = theme.id
        isImporting = true
        status = "正在读取光标…"
        defer { isImporting = false }

        let capes = role == nil ? urls.filter { $0.pathExtension.lowercased() == "cape" } : []
        let windows = urls.filter { $0.pathExtension.lowercased() != "cape" }
        var result = ImportResult()

        if !windows.isEmpty {
            result = await importWindowsFiles(windows, into: selectedThemeID, to: role)
        }

        var importedCount = 0
        var lastImported: CursorTheme?
        for url in capes {
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try Self.loadMousecapeTheme(url)
                }.value
                var next = library
                next.themes.append(imported.theme)
                next.selectedID = imported.theme.id
                if commit(next) {
                    decoded = imported.previews
                    importedCount += 1
                    lastImported = imported.theme
                    if imported.skippedCount > 0 {
                        result.errors.append("\(url.lastPathComponent) · \(imported.skippedCount) 个光标无法读取或超出主题容量。")
                    }
                } else if let notice {
                    result.errors.append("\(url.lastPathComponent) · \(notice.message)")
                }
            } catch {
                result.errors.append("\(url.lastPathComponent) · \(error.localizedDescription)")
            }
        }

        if let theme = lastImported {
            result.message = importedCount == 1
                ? "已导入「\(theme.name)」 · \(theme.assets.count) 个光标"
                : "已导入 \(importedCount) 个 Mousecape 主题"
        }

        status = result.message ?? "没有导入光标"
        if result.message == nil && result.errors.isEmpty {
            result.errors.append(role == nil
                ? "请选择 .cape、.cur、.ani 文件或 Windows 光标文件夹。"
                : "请为单个角色选择 .cur 或 .ani 文件。")
        }
        if !result.errors.isEmpty {
            presentImportErrors(result.errors, imported: result.message != nil)
        }
    }

    private func importWindowsFiles(_ urls: [URL], into themeID: UUID, to role: CursorRole?) async -> ImportResult {
        let batch = await Task.detached(priority: .userInitiated) {
            Self.loadFiles(urls)
        }.value
        guard let index = library.themes.firstIndex(where: { $0.id == themeID }) else {
            return ImportResult(errors: ["原主题已删除，无法导入 Windows 光标。"])
        }

        var next = library
        var theme = next.themes[index]
        var assetIDs: [URL: UUID] = [:]
        var loaded: [UUID: WindowsCursor] = [:]
        var bytes = theme.assets.reduce(0) { $0 + $1.data.count }
        var pixels = theme.assets.reduce(0) { $0 + $1.decodedPixelCount }
        var errors = batch.errors
        var added = 0

        for entry in batch.entries {
            let asset = entry.asset
            if let existing = theme.assets.first(where: { $0.name == asset.name && $0.data == asset.data }) {
                assetIDs[entry.url] = existing.id
                loaded[existing.id] = entry.cursor
                continue
            }
            guard bytes + asset.data.count <= Self.themeByteLimit,
                  pixels + asset.decodedPixelCount <= Self.themePixelLimit,
                  theme.assets.count < Self.themeAssetLimit else {
                errors.append("\(asset.name) · 主题库容量已满")
                continue
            }
            bytes += asset.data.count
            pixels += asset.decodedPixelCount
            theme.assets.append(asset)
            assetIDs[entry.url] = asset.id
            loaded[asset.id] = entry.cursor
            added += 1
        }

        var assigned = 0
        if let role, let first = batch.entries.first, let id = assetIDs[first.url] {
            theme.assignments[role] = id
            assigned = 1
        } else if role == nil {
            for (role, url) in batch.assignments where theme.assignments[role] == nil {
                if let id = assetIDs[url] {
                    theme.assignments[role] = id
                    assigned += 1
                }
            }
        }

        guard !assetIDs.isEmpty else {
            return ImportResult(errors: errors.isEmpty
                ? ["所选项目中没有找到 .cur 或 .ani 文件。"] : errors)
        }

        next.themes[index] = theme
        guard commit(next) else {
            errors.append(notice?.message ?? "无法保存导入的光标。")
            return ImportResult(errors: errors)
        }
        if library.selectedID == themeID {
            decoded.merge(loaded) { _, new in new }
        }
        let message = added == 0 && assigned == 0
            ? "这些文件已在主题中"
            : "已导入 \(added) 个文件 · 已分配 \(assigned) 个角色"
        return ImportResult(message: message, errors: errors)
    }

    func apply() {
        let assignments = theme.assignments.filter { $0.key.canApply }
        guard !assignments.isEmpty else { return }
        var next = library
        let ids = Set(assignments.values)
        next.applied = AppliedTheme(themeID: theme.id, assets: theme.assets.filter { ids.contains($0.id) },
                                    assignments: assignments)
        if updateSystem(next) {
            status = "已应用「\(theme.name)」"
        }
    }

    func reset() {
        var next = library
        next.applied = nil
        if updateSystem(next) { status = "已恢复 macOS 默认光标" }
    }

    func restoreOnLaunch() {
        guard !didRestore else { return }
        didRestore = true
        guard let applied = library.applied else { return }
        do {
            try setSystem(applied)
            systemThemeID = applied.themeID
            status = "已恢复上次应用的光标"
        } catch {
            present(title: "无法恢复上次的光标", error: error)
        }
    }

    private func updateSystem(_ next: Library) -> Bool {
        do {
            try setSystem(next.applied)
        } catch {
            present(title: "无法更新系统光标", error: error)
            return false
        }
        if commit(next) {
            systemThemeID = next.applied?.themeID
            return true
        }
        do {
            try setSystem(library.applied)
            systemThemeID = library.applied?.themeID
        } catch {
            systemThemeID = nil
            present(title: "保存主题和恢复光标均失败", error: error)
        }
        return false
    }

    private func setSystem(_ applied: AppliedTheme?) throws {
        guard let applied else {
            try applicator.reset()
            return
        }
        let assets = Dictionary(applied.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var replacements: [CursorRole: WindowsCursor] = [:]
        var parsed: [UUID: WindowsCursor] = [:]
        for (role, id) in applied.assignments {
            guard let asset = assets[id] else { throw StoreError.missingAsset }
            if let cursor = decoded[id] ?? parsed[id] {
                replacements[role] = cursor
            } else {
                let cursor = try asset.decode()
                parsed[id] = cursor
                replacements[role] = cursor
            }
        }
        try applicator.apply(replacements)
    }

    @discardableResult
    private func changeTheme(_ id: UUID, change: (inout CursorTheme) -> Void) -> Bool {
        guard let index = library.themes.firstIndex(where: { $0.id == id }) else { return false }
        var next = library
        change(&next.themes[index])
        return commit(next)
    }

    private func commit(_ next: Library) -> Bool {
        do {
            let data = try JSONEncoder().encode(next)
            try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: libraryURL, options: .atomic)
            library = next
            return true
        } catch {
            present(title: "保存主题失败", error: error)
            return false
        }
    }

    private func reloadPreviews() {
        decoded = [:]
        for asset in theme.assets {
            decoded[asset.id] = try? asset.decode()
        }
    }

    private func present(title: String, error: Error) {
        notice = Notice(title: title, message: error.localizedDescription)
    }

    private func presentImportErrors(_ errors: [String], imported: Bool) {
        let details = errors.prefix(6).joined(separator: "\n")
        let extra = errors.count > 6 ? "\n还有 \(errors.count - 6) 项未导入。" : ""
        notice = Notice(title: imported ? "部分光标无法导入" : "导入失败", message: details + extra)
    }

    nonisolated private static func loadFiles(_ urls: [URL]) -> ImportBatch {
        let files = WindowsThemeImport.collect(urls)
        var entries: [ImportedCursor] = []
        var errors: [String] = files.reachedLimit ? ["文件夹内容过多，仅扫描了部分文件。"] : []
        var totalBytes = 0
        var totalPixels = 0

        for url in files.cursors {
            if entries.count >= themeAssetLimit || totalBytes >= themeByteLimit || totalPixels >= themePixelLimit {
                errors.append("已达到单次导入上限。")
                break
            }
            do {
                let data = try readImportFile(url, limit: fileByteLimit)
                let cursor = try WindowsCursorParser.parse(data)
                let pixels = decodedPixelCount(of: cursor)
                guard totalBytes + data.count <= themeByteLimit,
                      totalPixels + pixels <= themePixelLimit else { throw StoreError.batchLimit }
                let asset = CursorAsset(name: url.lastPathComponent, data: data, decodedPixelCount: pixels)
                entries.append(ImportedCursor(url: url, asset: asset, cursor: cursor))
                totalBytes += data.count
                totalPixels += pixels
            } catch {
                errors.append("\(url.lastPathComponent) · \(error.localizedDescription)")
            }
        }
        return ImportBatch(entries: entries, assignments: files.assignments, errors: errors)
    }

    nonisolated private static func loadMousecapeTheme(_ url: URL) throws -> ImportedTheme {
        let data = try readImportFile(url, limit: fileByteLimit)
        let cape = try MousecapeParser.parse(data)
        let name = cape.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var theme = CursorTheme(name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name)
        let identifiers = cape.cursors.keys.sorted()
        let representatives = CursorRole.allCases.compactMap {
            MousecapeRoleMapping.preferredIdentifier(for: $0, from: identifiers)
        }
        let preferred = Set(representatives)
        let orderedIdentifiers = representatives + identifiers.filter { !preferred.contains($0) }
        var assetIDs: [String: UUID] = [:]
        var previews: [UUID: WindowsCursor] = [:]
        var skippedCount = cape.skippedCount
        var totalBytes = 0
        var totalPixels = 0

        for identifier in orderedIdentifiers {
            guard let cursorData = cape.cursors[identifier],
                  theme.assets.count < themeAssetLimit,
                  totalBytes + cursorData.count <= themeByteLimit,
                  let cursor = try? MousecapeParser.decodeCursor(cursorData) else {
                skippedCount += 1
                continue
            }
            let pixels = decodedPixelCount(of: cursor)
            guard totalPixels + pixels <= themePixelLimit else {
                skippedCount += 1
                continue
            }
            let asset = CursorAsset(name: identifier, data: cursorData, decodedPixelCount: pixels, format: .mousecape)
            theme.assets.append(asset)
            assetIDs[identifier] = asset.id
            previews[asset.id] = cursor
            totalBytes += cursorData.count
            totalPixels += pixels
        }
        guard !theme.assets.isEmpty else { throw StoreError.emptyMousecape }

        let importedIdentifiers = orderedIdentifiers.filter { assetIDs[$0] != nil }
        for role in CursorRole.allCases {
            if let identifier = MousecapeRoleMapping.preferredIdentifier(for: role, from: importedIdentifiers) {
                theme.assignments[role] = assetIDs[identifier]
            }
        }
        return ImportedTheme(theme: theme, previews: previews, skippedCount: skippedCount)
    }

    nonisolated private static func readImportFile(_ url: URL, limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size <= limit else { throw StoreError.fileTooLarge(limit) }
        try file.seek(toOffset: 0)
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw StoreError.fileTooLarge(limit) }
        return data
    }

    nonisolated private static func decodedPixelCount(of cursor: WindowsCursor) -> Int {
        var countedImages = Set<ObjectIdentifier>()
        var pixels = 0
        for frame in cursor.frames {
            for representation in frame.representations {
                let image = representation.image
                if countedImages.insert(ObjectIdentifier(image)).inserted {
                    pixels += image.width * image.height
                }
            }
        }
        return pixels
    }

    private enum StoreError: LocalizedError {
        case missingAsset
        case fileTooLarge(Int)
        case batchLimit
        case emptyMousecape

        var errorDescription: String? {
            switch self {
            case .missingAsset: "主题中的光标文件丢失。"
            case .fileTooLarge(let limit): "文件超过 \(limit / (1024 * 1024)) MB。"
            case .batchLimit: "此文件超过单次导入的剩余容量。"
            case .emptyMousecape: "这个 Mousecape 主题没有可读取的光标。"
            }
        }
    }
}
