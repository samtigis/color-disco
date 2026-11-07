// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ColorDisco",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ColorDiscoEngine",
            targets: ["ColorDisco"]
        )
    ],
    targets: [
        .target(
            name: "ColorDisco",
            path: "Sources/ColorDisco"
        )
    ]
)

