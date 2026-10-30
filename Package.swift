// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MurmurCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MurmurCore", targets: ["MurmurCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7")
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11960/llama-b11960-xcframework.zip",
            checksum: "feba05e0b7cb5e682ae3354abb455bf9723ae2cc95c69e24d073264e6a34d759"
        ),
        .target(name: "MurmurCore", dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), "llama"]),
        .testTarget(name: "MurmurCoreTests", dependencies: ["MurmurCore"])
    ],
    swiftLanguageModes: [.v5]
)
