// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pdfmeta",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "PDFMetadataCore"),
        .executableTarget(
            name: "pdfmeta",
            dependencies: [
                "PDFMetadataCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "PDFMetadataCoreTests", dependencies: ["PDFMetadataCore"]),
    ]
)
