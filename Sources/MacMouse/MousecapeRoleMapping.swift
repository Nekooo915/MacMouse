import Foundation

enum MousecapeRoleMapping {
    // Prefer the general pointer for each role before context-specific variants.
    private static let identifiersByRole: [CursorRole: [String]] = [
        .arrow: named("Arrow", "ArrowS") + core(0) + named("ArrowCtx") + core(24),
        .help: core(40),
        .working: core(4),
        .busy: named("Wait"),
        .crosshair: core(7, 8, 20, 41),
        .text: named("IBeam", "IBeamS") + core(1) + named("IBeamXOR") + core(26),
        .unavailable: named("NotAllowed") + core(3),
        .resizeVertical: core(23, 32, 21, 22, 31, 36),
        .resizeHorizontal: core(19, 28, 17, 18, 27, 38),
        .resizeDiagonalNWSE: core(34, 33, 35),
        .resizeDiagonalNESW: core(30, 29, 37),
        .move: named("Move") + core(11, 12, 39),
        .link: core(2) + named("PointingHand") + core(13)
    ]

    static func preferredIdentifier(for role: CursorRole, from identifiers: [String]) -> String? {
        guard let preferences = identifiersByRole[role] else { return nil }
        let originals = Dictionary(grouping: identifiers.sorted(), by: normalized)
        for preferred in preferences {
            guard let matches = originals[normalized(preferred)] else { continue }
            return matches.first { $0 == preferred } ?? matches.first
        }
        return nil
    }

    private static func normalized(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func named(_ names: String...) -> [String] {
        names.map { "com.apple.coregraphics." + $0 }
    }

    private static func core(_ numbers: Int...) -> [String] {
        numbers.map { "com.apple.cursor.\($0)" }
    }
}
