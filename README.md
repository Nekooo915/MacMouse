# MacMouse

MacMouse 是一款使用 SwiftUI 构建的 macOS 光标自定义工具。支持导入 Mousecape 的 `.cape` 主题和 Windows 的 `.cur` 静态光标、`.ani` 动画光标，保留文件中的点击热点。

## 使用

1. 点击「导入光标」选择 `.cape` 文件，或将文件拖入窗口。每个文件会建立一套主题。可识别的光标按角色自动分配，同一角色的其他变体和未知角色可在「待分配的文件」中预览或手动分配。
2. 导入 Windows 光标包时，先解压再选择文件夹。MacMouse 会尝试按 `.inf` 配置或文件名匹配角色。也可以直接导入单个 `.cur` 或 `.ani` 文件。
3. 选择普通指针、文本选择、链接等角色可以预览光标、动画和点击热点。点击「应用主题」启用，点击「恢复默认」撤销系统光标替换。

MacMouse 将主题保存在本机。登录或重新启动 Mac 后，打开 MacMouse 即可重新应用上次启用的主题。「恢复默认」会恢复 MacMouse 应用主题前的光标；如果之前使用了其他光标工具，恢复结果会保留当时的光标。

## 从源码构建

需要 macOS 14 或更新版本，以及 Xcode 15 或相应的 Command Line Tools。

```sh
./scripts/build-app.sh
open dist/MacMouse.app
```

生成的 `dist/MacMouse.app` 可以拖到「应用程序」文件夹。默认构建本机架构。要生成同时包含 Apple Silicon 与 Intel 可执行文件的通用版本，使用 `./scripts/build-app.sh --universal`。

## 系统兼容性

系统光标替换依赖 macOS 的私有图形接口，系统升级可能改变可用的光标类型或替换效果。手写、备用选择和忙碌角色仅用于预览。可以把忙碌动画分配给「后台运行」等可替换的角色。应用到系统的动画最多使用 24 帧，预览使用导入文件中的播放顺序和时长。部分应用会显示自己的光标。若只在部分位置显示自定义光标，可在「系统设置 → 辅助功能 → 显示 → 指针」恢复系统指针的默认颜色，然后再次应用方案。

支持常见的 DIB/PNG 光标和以 CUR/ICO 嵌入帧的 ANI 动画。使用裸位图帧的少见 ANI 文件无法导入。旧式单色光标的屏幕颜色反相效果不会保留。

项目参考了 Mousecape 的系统光标替换方式，以及 Mousecape-swiftUI 的 Windows 光标导入流程。[Mousecape](https://github.com/alexzielenski/Mousecape) · [Mousecape-swiftUI](https://github.com/sdmj76/Mousecape-swiftUI)
