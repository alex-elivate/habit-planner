// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HabitKit",
    // Deliberately permissive. HabitKit is Foundation-only value code, and the
    // watchOS target must be able to consume it without dragging the whole app's
    // deployment target upward.
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "HabitKit", targets: ["HabitKit"])
    ],
    targets: [
        .target(
            name: "HabitKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HabitKitTests",
            dependencies: ["HabitKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
