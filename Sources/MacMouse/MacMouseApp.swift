import SwiftUI

@main
struct MacMouseApp: App {
    @State private var store = CursorThemeStore()

    var body: some Scene {
        Window("MacMouse", id: "main") {
            CursorWorkspaceView(store: store)
                .frame(minWidth: 900, minHeight: 640)
                .task { store.restoreOnLaunch() }
        }
        .defaultSize(width: 1060, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("光标") {
                Button("应用当前主题") { store.apply() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(store.theme.applicableCount == 0 || !store.isSystemAvailable)
                Button("恢复 macOS 默认光标") { store.reset() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(!store.isSystemAvailable)
            }
        }
    }
}
