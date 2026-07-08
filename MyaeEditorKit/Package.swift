// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyaeEditorKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    version: "0.1.0",
    products: [
        .library(name: "MyaeEditorKit", targets: ["MyaeEditorKit"]),
    ],
    targets: [
        .target(
            name: "MyaeEditorKit",
            resources: [
                .copy("Resources/mermaid.html"),
                .copy("Resources/mermaid-zoom.html"),
                .copy("Resources/mermaid.min.js"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "MyaeEditorKitTests",
            dependencies: ["MyaeEditorKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
