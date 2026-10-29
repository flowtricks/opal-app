// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "OpalStudio", platforms: [.macOS(.v14)],
    products: [.library(name: "C1API", targets: ["C1API"]), .library(name: "OpalCore", targets: ["OpalCore"]), .library(name: "CameraBridge", targets: ["CameraBridge"]), .executable(name: "OpalStudio", targets: ["OpalApp"]), .executable(name: "OpalCameraExtension", targets: ["CameraExtension"])],
    targets: [
        .target(name: "C1API", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "OpalCore", resources: [.copy("Resources/ComposerShaders.metallib"), .copy("Resources/ComposerMetalPetal.metal.txt"), .copy("Resources/BlazeFaceScaled.mlmodelc"), .copy("Resources/GoogleMeets.mlmodelc")]),
        .target(name: "CameraBridge"),
        .executableTarget(name: "OpalApp", dependencies: ["OpalCore", "CameraBridge", "C1API"]),
        .executableTarget(name: "CameraExtension"),
        .testTarget(name: "OpalCoreTests", dependencies: ["OpalCore"]),
        .testTarget(name: "CameraBridgeTests", dependencies: ["CameraBridge"])
    ], swiftLanguageVersions: [.v5], cxxLanguageStandard: .cxx14)
