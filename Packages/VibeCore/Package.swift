// swift-tools-version: 6.2
import PackageDescription

// VibeCore holds everything that is not tied to a UI framework: language detection,
// the incremental syntax engine and its lexers, the Markdown renderer, themes and
// text-file helpers. It builds for macOS and iOS so a future iPad/iPhone app can share it.
let package = Package(
    name: "VibeCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "VibeCore", targets: ["VibeCore"]),
    ],
    targets: [
        .target(name: "VibeCore"),
        .testTarget(name: "VibeCoreTests", dependencies: ["VibeCore"]),
    ],
    swiftLanguageModes: [.v6]
)
