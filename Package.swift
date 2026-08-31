// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EveryNoise",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "EveryNoise",
            path: "Sources/EveryNoise",
            swiftSettings: [
                // Весь UI-слой по умолчанию на главном акторе, всё остальное помечено nonisolated явно.
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6),
            ]
        )
    ]
)
