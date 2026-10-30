// swift-tools-version:5.9
// Clipwell by Naveen Mathews Renji — MIT License
import PackageDescription

let package = Package(
    name: "Clipwell",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clipwell",
            path: "Sources/Clipwell",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
