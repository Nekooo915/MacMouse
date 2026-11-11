// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacMouse",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacMouse", targets: ["MacMouse"])],
    targets: [.executableTarget(name: "MacMouse")]
)
