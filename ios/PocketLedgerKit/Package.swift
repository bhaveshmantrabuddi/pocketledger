// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PocketLedgerKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "LedgerCore", targets: ["LedgerCore"]),
        .library(name: "ReceiptKit", targets: ["ReceiptKit"])
    ],
    targets: [
        .target(name: "LedgerCore"),
        .target(name: "ReceiptKit", publicHeadersPath: "include", cSettings: [
            .unsafeFlags(["-fobjc-arc"], .when(platforms: [.iOS, .macOS]))
        ], linkerSettings: [
            .linkedFramework("Foundation"), .linkedFramework("Vision"), .linkedFramework("CoreGraphics")
        ]),
        .testTarget(name: "LedgerCoreTests", dependencies: ["LedgerCore"]),
        .testTarget(name: "ReceiptKitTests", dependencies: ["ReceiptKit"])
    ]
)
