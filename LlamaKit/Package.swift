// swift-tools-version: 5.9
import PackageDescription

// Prebuilt llama.cpp (GPU kernels already compiled in), so building the app
// does not need Xcode's separate Metal toolchain download. fetch-llama.sh downloads it
// and adds a stub iOS Simulator slice; `xcodegen generate` runs that script first.
let package = Package(
    name: "LlamaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LlamaKit", targets: ["LlamaKit"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            path: "llama.xcframework"
        ),
        .target(name: "LlamaKit", dependencies: ["llama"]),
    ]
)
