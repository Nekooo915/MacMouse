import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CursorWorkspaceView: View {
    private enum Selection: Equatable {
        case role(CursorRole)
        case asset(UUID)
    }

    private enum NameAction: String, Identifiable {
        case create = "新建主题"
        case rename = "重命名主题"

        var id: Self { self }
    }

    private struct ThemeRemoval {
        enum Action {
            case delete, clearCursors, keepOnly
        }

        let action: Action
        let themeID: UUID
        let title: String
        let buttonTitle: String
        let message: String
    }

    @Bindable var store: CursorThemeStore
    @State private var selection: Selection = .role(.arrow)
    @State private var nameAction: NameAction?
    @State private var themeRemoval: ThemeRemoval?
    @State private var isDropTarget = false

    private var selectedRole: CursorRole? {
        if case let .role(role) = selection { return role }
        return nil
    }

    private var selectedAsset: CursorAsset? {
        switch selection {
        case .role(let role): store.theme.asset(for: role)
        case .asset(let id): store.theme.assets.first { $0.id == id }
        }
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(
            get: { themeRemoval != nil },
            set: { if !$0 { themeRemoval = nil } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                roleBrowser
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                previewPanel
                    .frame(width: 348)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget, perform: receiveDrop)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $nameAction) { action in
            ThemeNameSheet(title: action.rawValue, initialName: action == .rename ? store.theme.name : "") { name in
                switch action {
                case .create: store.createTheme(named: name)
                case .rename: store.renameTheme(to: name)
                }
            }
        }
        .alert(item: $store.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message),
                  dismissButton: .default(Text("好")))
        }
        .confirmationDialog(themeRemoval?.title ?? "", isPresented: isConfirmingRemoval,
                            titleVisibility: .visible, presenting: themeRemoval) { removal in
            Button(removal.buttonTitle, role: .destructive) { confirmThemeRemoval(removal) }
            Button("取消", role: .cancel) {}
        } message: { removal in
            Text(removal.message)
        }
        .onChange(of: store.theme.id) { _, _ in
            if let role = CursorRole.allCases.first(where: { store.theme.assignments[$0] != nil }) {
                selection = .role(role)
            } else if let asset = store.theme.assets.first {
                selection = .asset(asset.id)
            } else {
                selection = .role(.arrow)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(Color(red: 0.48, green: 0.98, blue: 0.81))
                .frame(width: 48, height: 48)
                .background(Color(red: 0.08, green: 0.15, blue: 0.21),
                            in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Menu {
                    ForEach(store.themes) { theme in
                        Button {
                            store.selectTheme(theme.id)
                        } label: {
                            if theme.id == store.theme.id {
                                Label(theme.name, systemImage: "checkmark")
                            } else {
                                Text(theme.name)
                            }
                        }
                    }
                    Divider()
                    Button("新建主题…", systemImage: "plus") { nameAction = .create }
                    Button("重命名…", systemImage: "pencil") { nameAction = .rename }
                    Divider()
                    Button("清空当前主题的光标…", systemImage: "eraser", role: .destructive) {
                        requestThemeRemoval(.clearCursors)
                    }
                    .disabled(store.isImporting || !store.canClearThemeCursors)
                    Button("只保留当前主题…", systemImage: "square.on.square", role: .destructive) {
                        requestThemeRemoval(.keepOnly)
                    }
                    .disabled(store.isImporting || store.themes.count < 2)
                    Button("删除主题…", systemImage: "trash", role: .destructive) {
                        requestThemeRemoval(.delete)
                    }
                    .disabled(store.isImporting)
                } label: {
                    Text(store.theme.name)
                        .font(.system(size: 26, weight: .semibold))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 335, alignment: .leading)

                Text("\(store.theme.assignments.count) / \(CursorRole.allCases.count) 个角色已分配")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.systemThemeID == store.theme.id {
                Label(store.matchesAppliedTheme ? "已应用" : "有未应用的更改",
                      systemImage: store.matchesAppliedTheme ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(store.matchesAppliedTheme ? Color.green : Color.secondary)
            }

            Button("恢复默认", systemImage: "arrow.counterclockwise") { store.reset() }
                .help("恢复 macOS 默认光标")
                .disabled(!store.isSystemAvailable)

            Button("应用主题", systemImage: "checkmark.circle") { store.apply() }
                .buttonStyle(.borderedProminent)
                .help("将当前主题应用到 macOS")
                .disabled(store.theme.applicableCount == 0 || !store.isSystemAvailable)
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 19)
    }

    private var roleBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("光标角色")
                        .font(.headline)
                    Spacer()
                    Button("导入光标…", systemImage: "plus") { chooseFiles() }
                        .disabled(store.isImporting)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    ForEach(CursorRole.allCases) { role in
                        roleTile(role)
                    }
                }
                if !store.theme.unassigned.isEmpty {
                    Divider().padding(.top, 4)
                    Text("待分配的文件")
                        .font(.headline)
                    ForEach(store.theme.unassigned) { asset in
                        unassignedRow(asset)
                    }
                }
            }
            .padding(22)
        }
    }

    private func roleTile(_ role: CursorRole) -> some View {
        let asset = store.theme.asset(for: role)
        let selected = selection == .role(role)

        return Button {
            selection = .role(role)
        } label: {
            HStack(spacing: 10) {
                thumbnail(for: asset, fallback: role.systemImage)
                VStack(alignment: .leading, spacing: 4) {
                    Text(role.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(asset?.name ?? (role.canApply ? "系统默认" : "仅预览"))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if asset != nil {
                    Circle()
                        .fill(role.canApply ? Color.accentColor : Color.secondary)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 42)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.68) : Color.secondary.opacity(0.15))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("选择文件…") { chooseFiles(for: role) }
                .disabled(store.isImporting)
            if asset != nil {
                Button("移除分配") { store.removeAssignment(for: role) }
            }
        }
    }

    private func unassignedRow(_ asset: CursorAsset) -> some View {
        HStack {
            Button {
                selection = .asset(asset.id)
            } label: {
                HStack(spacing: 8) {
                    thumbnail(for: asset, fallback: "doc")
                    Text(asset.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                assignmentButtons(for: asset)
                Divider()
                Button("删除文件", role: .destructive) { deleteAsset(asset) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("管理 \(asset.name)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selection == .asset(asset.id) ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func thumbnail(for asset: CursorAsset?, fallback: String) -> some View {
        Group {
            if let asset, let image = store.preview(asset)?.frames.first?.representations.first?.image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 27, height: 27)
            } else {
                Image(systemName: fallback)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private var previewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(selectedRole?.displayName ?? "待分配的光标")
                        .font(.title2.weight(.semibold))
                    Spacer(minLength: 10)
                    if let asset = selectedAsset {
                        Text(asset.fileType)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let asset = selectedAsset, let cursor = store.preview(asset) {
                    CursorArtworkPreview(cursor: cursor)
                        .id(asset.id)
                    Text(asset.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if let role = selectedRole {
                        if !role.canApply {
                            Text(role == .busy ? "macOS 的系统忙碌光标仅支持预览。" : "macOS 没有对应的系统光标角色。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("替换文件…") { chooseFiles(for: role) }
                                .disabled(store.isImporting)
                            Button("移除分配") { store.removeAssignment(for: role) }
                        }
                    } else {
                        Menu("分配到角色") { assignmentButtons(for: asset) }
                    }
                } else {
                    previewPlaceholder
                    if let role = selectedRole {
                        Text(role.canApply ? "此角色使用 macOS 默认光标。" : "此 Windows 角色可导入预览。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("选择光标文件…", systemImage: "plus") { chooseFiles(for: role) }
                            .disabled(store.isImporting)
                        if !store.theme.assets.isEmpty {
                            Menu("从主题文件选取") {
                                ForEach(store.theme.assets) { asset in
                                    Button(asset.name) { store.assign(asset, to: role) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private var previewPlaceholder: some View {
        ZStack {
            PreviewBackdrop()
            VStack(spacing: 12) {
                Image(systemName: selectedRole?.systemImage ?? "cursorarrow")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Color(red: 0.48, green: 0.98, blue: 0.81))
                    .accessibilityHidden(true)
                Text("尚未导入")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if store.isImporting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: store.status.isEmpty ? "arrow.down.document" : "info.circle")
                    .accessibilityHidden(true)
            }
            Text(store.status.isEmpty ? "将 .cape、.cur、.ani 或 Windows 光标文件夹拖到此窗口" : store.status)
                .lineLimit(1)
            Spacer()
            if !store.isSystemAvailable {
                Text("当前系统不支持光标替换")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 23)
        .frame(height: 35)
    }

    private func assignmentButtons(for asset: CursorAsset) -> some View {
        ForEach(CursorRole.allCases) { role in
            Button(role.displayName, systemImage: role.systemImage) {
                store.assign(asset, to: role)
                selection = .role(role)
            }
        }
    }

    private func deleteAsset(_ asset: CursorAsset) {
        if store.removeAsset(asset), selection == .asset(asset.id) {
            selection = .role(.arrow)
        }
    }

    private func requestThemeRemoval(_ action: ThemeRemoval.Action) {
        let theme = store.theme
        let resetsCursor: Bool
        let title: String
        let buttonTitle: String
        let message: String

        switch action {
        case .delete:
            title = "删除「\(theme.name)」？"
            buttonTitle = "删除主题"
            message = "此主题中的光标文件将一同删除。"
            resetsCursor = store.savedAppliedThemeID == theme.id
        case .clearCursors:
            title = "清空「\(theme.name)」的光标？"
            buttonTitle = "清空光标"
            message = "将移除 \(theme.assets.count) 个光标和所有角色分配，主题仍可继续使用。"
            resetsCursor = store.savedAppliedThemeID == theme.id
        case .keepOnly:
            title = "只保留「\(theme.name)」？"
            buttonTitle = "删除其他主题"
            message = "将删除其他 \(store.themes.count - 1) 套主题和其中的光标。"
            resetsCursor = store.savedAppliedThemeID.map { $0 != theme.id } ?? false
        }
        themeRemoval = ThemeRemoval(
            action: action, themeID: theme.id, title: title, buttonTitle: buttonTitle,
            message: message + (resetsCursor ? "\n系统将恢复应用该主题前的光标。" : "")
        )
    }

    private func confirmThemeRemoval(_ removal: ThemeRemoval) {
        guard !store.isImporting else { return }
        switch removal.action {
        case .delete:
            if store.theme.id == removal.themeID { store.deleteTheme() }
        case .clearCursors:
            store.clearThemeCursors(removal.themeID)
            if store.theme.id == removal.themeID, store.theme.assets.isEmpty {
                selection = .role(.arrow)
            }
        case .keepOnly:
            store.keepOnlyTheme(removal.themeID)
        }
    }

    private func chooseFiles(for role: CursorRole? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = role == nil
        panel.allowsMultipleSelection = role == nil
        panel.allowedContentTypes = (role == nil ? ["cape", "cur", "ani", "inf"] : ["cur", "ani"])
            .compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "导入"
        panel.message = role == nil
            ? "请选择 Mousecape .cape 主题、Windows 光标文件或已解压的光标文件夹。"
            : "为\(role?.displayName ?? "")选择 .cur 或 .ani 文件。"
        let onResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { await store.importFiles(urls, to: role) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: onResponse)
        } else {
            panel.begin(completionHandler: onResponse)
        }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !store.isImporting, !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL {
                            continuation.resume(returning: url)
                        } else if let data = item as? Data {
                            continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            await store.importFiles(urls)
        }
        return true
    }
}

private struct ThemeNameSheet: View {
    let title: String
    let onSave: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            TextField("主题名称", text: $name)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 330)
    }
}
