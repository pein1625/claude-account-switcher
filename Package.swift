// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeSwitcherCore", path: "Sources/ClaudeSwitcherCore"),
        .executableTarget(
            name: "ClaudeSwitcher",
            dependencies: ["ClaudeSwitcherCore"],
            path: "Sources/ClaudeSwitcher"
        ),
        // Command Line Tools ship neither XCTest nor Swift Testing, so checks are a plain executable: `make test`.
        .executableTarget(
            name: "ClaudeSwitcherChecks",
            dependencies: ["ClaudeSwitcherCore"],
            path: "Checks"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
