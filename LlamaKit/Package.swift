// swift-tools-version: 5.9
import PackageDescription

// Prebuilt llama.cpp (GPU kernels already compiled in), so building the app
// does not need Xcode's separate Metal toolchain download.
let package = Package(
    name: "LlamaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LlamaKit", targets: ["LlamaKit"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11565/llama-b11565-xcframework.zip",
            checksum: "865afb6d9a535b93445dcf89acd3f64002d609909faeeca4da75d83d19620584"
        ),
        .target(name: "LlamaKit", dependencies: ["llama"]),
    ]
)
