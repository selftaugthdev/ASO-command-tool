// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ASOCommandCenter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ASOCommandCenter", targets: ["ASOApp"]),
        .library(name: "ASCKit", targets: ["ASCKit"]),
    ],
    targets: [
        .target(name: "ASOCore"),
        .target(name: "ASOStore", dependencies: ["ASOCore"]),
        .target(name: "ASCKit", dependencies: ["ASOCore"]),
        .target(name: "ASAKit", dependencies: ["ASOCore"]),
        .target(name: "KeywordKit", dependencies: ["ASOCore", "ASAKit", "ASOStore"]),
        .target(name: "RevenueKit", dependencies: ["ASOCore", "ASOStore"]),
        .executableTarget(
            name: "ASOApp",
            dependencies: ["ASOCore", "ASOStore", "ASCKit", "ASAKit", "KeywordKit", "RevenueKit"]
        ),
        .testTarget(
            name: "ASOTests",
            dependencies: ["ASOCore", "ASCKit", "ASOStore", "KeywordKit", "ASAKit",
                           "RevenueKit"]
        ),
    ]
)
