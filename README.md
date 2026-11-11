# MacMouse

MacMouse 是一款适用于 macOS 的光标主题管理器。可以导入 Mousecape 主题和 Windows 光标，预览动画与点击热点，并为普通指针、文本选择等系统光标角色分配图案。

## 下载与安装

需要 **macOS 14 或更新版本**。Release 中的通用版同时支持 Apple Silicon 和 Intel Mac。

1. 打开 [GitHub Releases](https://github.com/Nekooo915/MacMouse/releases/latest)，在「Assets」中下载文件名以 `-universal.zip` 结尾的安装包。
2. 解压后，把 `MacMouse.app` 拖到「应用程序」文件夹，再打开它。升级前先退出正在运行的旧版。

发布包使用 ad hoc 签名，未经过 Apple 公证。如果首次打开时 macOS 提示无法验证开发者，可参阅 [Apple 的 App 安全说明](https://support.apple.com/zh-cn/102445)。

## 导入光标

点击「导入光标」选取文件或文件夹，也可以直接拖入窗口。

| 格式 | 导入结果 |
| --- | --- |
| Mousecape `.cape` | 每个文件建立一套主题。自动分配可识别的角色，同一角色的其他变体保留在「待分配的文件」。 |
| Windows `.cur` / `.ani` | 加入当前主题。`.cur` 是静态光标，多帧 `.ani` 可以播放动画。 |
| Windows 光标包文件夹 | 先解压，再选中包含光标的文件夹。MacMouse 优先读取附带的 `.inf`，也会尝试按文件名为未分配的角色匹配光标。支持 GB18030 编码的 `.inf`。 |

想把 Windows 光标包单独保存为一组，可以先点左上角的主题名，选择「新建主题」。重复导入时，同名且内容相同的文件只保存一份。

## 应用和整理主题

- **预览与分配**。点击角色可查看图案、动画和热点。可以从「待分配的文件」中手动分配，也可以在角色详情里选择或替换光标文件。
- **应用主题**。点击「应用主题」或按 `⌘↩`。主题保存在本机，重新打开 MacMouse 时会尝试重新应用上次启用的主题。
- **恢复光标**。点击「恢复默认」或按 `⌘R`，恢复应用该主题前的光标。
- **批量整理**。从左上角的主题菜单选择「清空当前主题的光标」，可清除这组的文件和角色分配并保留主题。选择「只保留当前主题」，可批量删除其他主题。

## 常见问题

**光标只在程序坞或 MacMouse 窗口中生效**

如果设置过自定义指针颜色，请前往「系统设置 → 辅助功能 → 显示 → 指针」，点「重设颜色」，然后回到 MacMouse 重新应用主题。部分应用会绘制自己的光标。系统光标替换依赖 macOS 的私有图形接口，系统版本也可能影响替换效果。[Apple 指针设置说明](https://support.apple.com/zh-cn/guide/mac-help/mchlp2920/mac) · [Mousecape 故障排除](https://github.com/sdmj76/Mousecape-swiftUI#troubleshooting)

**动画能预览，但分配后没有在系统中播放**

「手写」「备用选择」「忙碌」仅支持预览。可将忙碌动画分配给「后台运行」等可替换角色。预览按原文件的顺序和时长播放，应用到系统时最多使用 24 帧，较长的动画会重新采样。

**导入时提示超过容量**

单个文件最多 32 MiB。每套主题最多保存 256 个光标，文件合计最多 256 MiB，解码后的图像合计最多约 6,711 万像素。动画的各帧和多分辨率图像也计入总像素。导入光标包时，请以解压后的光标文件大小为准。可选取部分文件，分批导入不同主题。

**某个光标文件无法读取**

支持常见的 DIB 和 PNG 光标、使用内嵌 CUR 或 ICO 帧的 ANI，以及含 PNG、TIFF 或 HEIF 图像的 Mousecape 主题。使用裸位图帧的少见 ANI 暂不支持。旧式单色光标的屏幕颜色反相效果不会保留。

## 从源码构建

需要 macOS 14 或更新版本，以及 Xcode 15 或对应的 Command Line Tools。

```sh
# 构建当前 Mac 的架构
./scripts/build-app.sh

# 构建 Apple Silicon 和 Intel 通用版
./scripts/build-app.sh --universal
```

构建完成后，运行 `open dist/MacMouse.app` 打开应用。

## 参考项目

系统光标替换方式参考 [Mousecape](https://github.com/alexzielenski/Mousecape)，Windows 光标导入流程参考 [Mousecape-swiftUI](https://github.com/sdmj76/Mousecape-swiftUI)。
