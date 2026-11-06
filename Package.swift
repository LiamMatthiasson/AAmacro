// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AAMacro",
    platforms: [.macOS(.v14)],   // ScreenCaptureKit screenshot API needs macOS 14+
    targets: [
        .executableTarget(
            name: "AAMacro",
            path: "Sources/AAMacro"
        )
    ]
)
