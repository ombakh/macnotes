// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macnotes",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "macnotes",
            targets: ["macnotes"]
        )
    ],
    targets: [
        .executableTarget(
            name: "macnotes"
        ),
    ]
)
