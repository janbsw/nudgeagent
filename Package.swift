// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NudgeAgent",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NudgeAgent",
            path: "Sources/NudgeAgent",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
