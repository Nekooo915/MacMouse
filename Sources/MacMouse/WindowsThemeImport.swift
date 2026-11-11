import CoreFoundation
import Foundation

enum WindowsThemeImport {
    struct Files {
        let cursors: [URL]
        let assignments: [CursorRole: URL]
        let reachedLimit: Bool
    }

    private static let candidateLimit = 512

    private static let schemeOrder: [CursorRole] = [
        .arrow, .help, .working, .busy, .crosshair, .text, .handwriting, .unavailable,
        .resizeVertical, .resizeHorizontal, .resizeDiagonalNWSE, .resizeDiagonalNESW,
        .move, .upArrow, .link
    ]

    private static let registryNames = Dictionary(uniqueKeysWithValues: zip(
        ["arrow", "help", "appstarting", "wait", "crosshair", "ibeam", "nwpen", "no",
         "sizens", "sizewe", "sizenwse", "sizenesw", "sizeall", "uparrow", "hand"],
        schemeOrder
    ))

    private static let filenameAliases: [(CursorRole, [String])] = [
        (.arrow, ["arrow", "normal", "normalselect", "pointer", "default", "普通选择", "正常选择", "标准指针"]),
        (.help, ["help", "helpsel", "helpselect", "帮助选择", "帮助"]),
        (.working, ["appstarting", "working", "workinginbackground", "workinginbg", "work", "后台运行", "后台工作"]),
        (.busy, ["wait", "busy", "loading", "忙碌", "等待"]),
        (.crosshair, ["cross", "crosshair", "prec", "precision", "precisionselect", "精准选择", "精确选择", "十字"]),
        (.text, ["ibeam", "text", "textselect", "select", "文本选择", "文字选择", "文本"]),
        (.handwriting, ["nwpen", "pen", "handwriting", "手写"]),
        (.unavailable, ["no", "unavail", "unavailable", "unavailiable", "forbidden", "notallowed", "禁用", "不可用"]),
        (.resizeVertical, ["sizens", "ns", "vertical", "vert", "verticalresize", "垂直调整", "垂直"]),
        (.resizeHorizontal, ["sizewe", "sizeew", "ew", "we", "horizontal", "horz", "horizontalresize", "水平调整", "水平"]),
        (.resizeDiagonalNWSE, ["sizenwse", "nwse", "dgn1", "diagonalresize1", "diagonal1", "对角线1"]),
        (.resizeDiagonalNESW, ["sizenesw", "nesw", "dgn2", "diagonalresize2", "diagonal2", "对角线2"]),
        (.move, ["sizeall", "move", "移动"]),
        (.upArrow, ["uparrow", "up", "alternate", "alternateselect", "候选选择", "备用选择"]),
        (.link, ["hand", "link", "linkselect", "链接选择", "链接"])
    ]

    static func collect(_ urls: [URL]) -> Files {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var candidates = Set<URL>()
        var inspected = 0
        var reachedLimit = false

        for input in urls {
            let url = input.standardizedFileURL
            guard let info = try? url.resourceValues(forKeys: keys) else { continue }
            if info.isDirectory == true {
                let entries = manager.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = entries?.nextObject() as? URL {
                    inspected += 1
                    if inspected > 6_000 || candidates.count >= candidateLimit {
                        reachedLimit = true
                        break
                    }
                    let info = try? file.resourceValues(forKeys: keys)
                    guard info?.isRegularFile == true, info?.isSymbolicLink != true else { continue }
                    if ["cur", "ani", "inf"].contains(file.pathExtension.lowercased()) {
                        candidates.insert(file.standardizedFileURL)
                    }
                }
            } else if info.isRegularFile == true {
                if candidates.count >= candidateLimit {
                    reachedLimit = true
                    break
                }
                candidates.insert(url)
                // A selected INF also brings in cursor files from its folder.
                if url.pathExtension.lowercased() == "inf",
                   let siblings = try? manager.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                                    includingPropertiesForKeys: Array(keys),
                                                                    options: .skipsHiddenFiles) {
                    for sibling in siblings where isCursor(sibling) {
                        guard candidates.count < candidateLimit else {
                            reachedLimit = true
                            break
                        }
                        let info = try? sibling.resourceValues(forKeys: keys)
                        if info?.isRegularFile == true, info?.isSymbolicLink != true {
                            candidates.insert(sibling.standardizedFileURL)
                        }
                    }
                }
            }
        }

        let sorted = candidates.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let cursors = sorted.filter(isCursor)
        let byName = Dictionary(grouping: cursors) { $0.lastPathComponent.lowercased() }
        var assignments: [CursorRole: URL] = [:]
        for inf in sorted where inf.pathExtension.lowercased() == "inf" {
            assignments.merge(readINFAssignments(inf, cursorsByName: byName)) { existing, _ in existing }
        }

        let mappedFiles = Set(assignments.values)
        for cursor in cursors where !mappedFiles.contains(cursor) {
            guard let role = inferredRole(for: cursor), assignments[role] == nil else { continue }
            assignments[role] = cursor
        }
        return Files(cursors: cursors, assignments: assignments, reachedLimit: reachedLimit)
    }

    private static func matchScore(_ url: URL, reference: String, parent: String) -> Int {
        let path = url.path
        let local = path.hasPrefix(parent + "/") ? 100 : 0
        let localParts = path.lowercased().split(separator: "/").reversed()
        let referenceParts = reference.split(separator: "/").reversed()
        let matched = zip(localParts, referenceParts).prefix { $0.0 == $0.1 }.count
        return local + matched
    }

    static func isCursor(_ url: URL) -> Bool {
        ["cur", "ani"].contains(url.pathExtension.lowercased())
    }

    private static func inferredRole(for url: URL) -> CursorRole? {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let pieces = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let joined = pieces.joined()
        if let match = filenameAliases.first(where: { $0.1.contains(joined) }) {
            return match.0
        }

        // The pack name and a numeric ordering prefix are common before the role.
        let suffixes = pieces.indices.map { pieces[$0...].joined() }
        let prefixes = pieces.indices.map { pieces[...$0].joined() }
        let matches = filenameAliases.compactMap { role, aliases -> (CursorRole, Int)? in
            let score = aliases.filter { alias in
                suffixes.contains(alias) || prefixes.contains(alias)
            }.map(\.count).max()
            return score.map { (role, $0) }
        }
        return matches.max { $0.1 < $1.1 }?.0
    }

    private static func readINFAssignments(_ url: URL, cursorsByName: [String: [URL]]) -> [CursorRole: URL] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_048_576,
              let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return [:] }

        let parent = url.deletingLastPathComponent().path
        var best: [CursorRole: URL] = [:]
        for source in decodeINF(data) {
            let assignments = parseINF(source).compactMapValues { path -> URL? in
                let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
                guard let name = normalized.split(separator: "/").last,
                      let matches = cursorsByName[String(name)] else { return nil }
                return matches.max { first, second in
                    matchScore(first, reference: normalized, parent: parent)
                        < matchScore(second, reference: normalized, parent: parent)
                }
            }
            // Both legacy encodings can decode the same bytes. Prefer the filenames that actually exist.
            if assignments.count > best.count { best = assignments }
            if best.count == schemeOrder.count { break }
        }
        return best
    }

    private static func parseINF(_ source: String) -> [CursorRole: String] {
        var strings: [String: String] = [:]
        var registry: [[String]] = []
        var section = ""
        var continued = ""
        for raw in source.components(separatedBy: .newlines) {
            let part = split(raw, separator: ";", maxSplits: 1, stripQuotes: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            if part.hasSuffix("\\") {
                continued += part.dropLast()
                continue
            }
            let line = continued + part
            continued = ""
            if line.first == "[", line.last == "]" {
                section = String(line.dropFirst().dropLast()).lowercased()
                continue
            }
            if section == "strings" || section.hasPrefix("strings.") {
                let fields = split(line, separator: "=", maxSplits: 1)
                if fields.count == 2 {
                    let key = fields[0].lowercased()
                    if section == "strings" || strings[key] == nil { strings[key] = fields[1] }
                }
            } else if line.first == "H" || line.first == "h" {
                let fields = split(line, separator: ",")
                if let hive = fields.first?.uppercased(), hive == "HKCU" || hive == "HKLM" {
                    registry.append(fields)
                }
            }
        }

        var scheme: [CursorRole: String] = [:]
        var direct: [CursorRole: String] = [:]
        for row in registry where row.count >= 5 {
            let key = expand(row[1], strings: strings).lowercased()
            if key.hasSuffix("control panel\\cursors\\schemes") {
                let values = row.dropFirst(4).flatMap {
                    split(expand($0, strings: strings), separator: ",")
                }
                for (role, path) in zip(schemeOrder, values) where scheme[role] == nil && hasCursorExtension(path) {
                    scheme[role] = path
                }
            } else if key.hasSuffix("control panel\\cursors"),
                      let role = registryNames[expand(row[2], strings: strings).lowercased()] {
                let path = expand(row[4], strings: strings)
                if hasCursorExtension(path) { direct[role] = path }
            }
        }
        return scheme.merging(direct) { _, directValue in directValue }
    }

    private static func hasCursorExtension(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".cur") || path.lowercased().hasSuffix(".ani")
    }

    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    ))

    private static func decodeINF(_ data: Data) -> [String] {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16).map { [$0] } ?? []
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8).map { [$0] } ?? []
        }
        if let source = String(data: data, encoding: .utf8) { return [source] }
        var seen = Set<String>()
        return [String.Encoding.windowsCP1252, gb18030, .isoLatin1].compactMap { encoding in
            guard let source = String(data: data, encoding: encoding),
                  seen.insert(source).inserted else { return nil }
            return source
        }
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: "%([^%]+)%")

    private static func expand(_ field: String, strings: [String: String]) -> String {
        var output = field
        for _ in 0..<6 {
            let text = output as NSString
            var next = output
            for match in tokenPattern.matches(in: output, range: NSRange(location: 0, length: text.length)).reversed() {
                let key = text.substring(with: match.range(at: 1)).lowercased()
                if let replacement = strings[key], let range = Range(match.range, in: next) {
                    next.replaceSubrange(range, with: replacement)
                }
                if next.utf16.count > 16_384 { return output }
            }
            if next == output { return output }
            output = next
        }
        return output
    }

    private static func split(_ line: String, separator: Character,
                              maxSplits: Int = .max, stripQuotes: Bool = true) -> [String] {
        var fields: [String] = []
        var field = ""
        var insideQuotes = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            index = line.index(after: index)
            if character == "\"" {
                if insideQuotes, index < line.endIndex, line[index] == "\"" {
                    field.append("\"")
                    if !stripQuotes { field.append("\"") }
                    index = line.index(after: index)
                } else {
                    insideQuotes.toggle()
                    if !stripQuotes { field.append(character) }
                }
            } else if character == separator && !insideQuotes && fields.count < maxSplits {
                fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else {
                field.append(character)
            }
        }
        fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        return fields
    }
}
