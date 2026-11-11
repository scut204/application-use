// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ApplicationUseBackground",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ApplicationUseBackground", targets: ["ApplicationUseBackground"])],
    dependencies: [.package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.6.0")],
    targets: [
        .target(name: "OpenComputerUseVirtualDisplayShim", path: "packages/OpenComputerUseVirtualDisplayShim",
                publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "LockedUseNative", path: "packages/LockedUseNative",
                publicHeadersPath: "include", linkerSettings: [.linkedLibrary("bsm")]),
        .target(name: "OpenComputerUseKit",
                dependencies: ["OpenComputerUseVirtualDisplayShim", "LockedUseNative",
                               .product(name: "libwebp", package: "libwebp-Xcode")],
                path: "packages/OpenComputerUseKit/Sources/OpenComputerUseKit"),
        .executableTarget(name: "ApplicationUseBackground", dependencies: ["OpenComputerUseKit"],
                          path: "apps/ApplicationUseBackground"),
        .testTarget(name: "OpenComputerUseKitTests", dependencies: ["OpenComputerUseKit"],
                    path: "Tests/OpenComputerUseKitTests"),
    ]
)
