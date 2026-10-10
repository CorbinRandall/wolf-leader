// swift-tools-version:5.9
// Open this folder in Xcode (File > Open > Package.swift) or build the .app and .dmg with
// installer/mac/build-app.sh.
import PackageDescription

let package = Package(
    name: "WolfLeader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WolfLeader",
            path: "Sources/WolfLeader"
        ),
    ]
)
