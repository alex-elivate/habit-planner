// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HabitKit",
    // Deliberately permissive. HabitKit is Foundation-only value code, and the
    // watchOS target must be able to consume it without dragging the whole app's
    // deployment target upward. HabitStore raises the real floor: SwiftData needs
    // iOS 17, macOS 14 and watchOS 10, which is exactly what is declared here.
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "HabitKit", targets: ["HabitKit"]),
        .library(name: "HabitStore", targets: ["HabitStore"])
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
        ),
        // Kept a separate target rather than folded into HabitKit so the domain layer
        // stays free of SwiftData. That preserves the exit path to raw CloudKit, and it
        // is enforced by the dependency arrow rather than by discipline.
        .target(
            name: "HabitStore",
            dependencies: ["HabitKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HabitStoreTests",
            dependencies: ["HabitStore", "HabitKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
