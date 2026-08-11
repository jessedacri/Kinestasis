// swift-tools-version: 5.10
import PackageDescription

// Kinestasis — burst-mode stills → footage, macOS.
//
// Module layout is layered: low-level building blocks at the top, the app
// shell at the bottom. Each module depends only on modules above it; no
// cycles. Keep it that way — it's how we'll stay sane at M3+.
//
//   PolymergeKit        shared media-engine libraries (MediaModel, Ingest,
//                       Audio, Playback), consumed via local-path dep from
//                       ../PolymergeKit. Replaces the 2026-05-27 in-tree
//                       fork. Library changes go in the Kit repo; verify
//                       with Polymerge's `swift test` too.
//   KineCore           pure data: Project, Sequence, Track, Clip, time
//   KineMedia          decode/encode + VT session pool + proxy manager
//   KineRender         Metal compositor + render graph
//   KineEffects        starter effect arsenal (xfade, HPF/LPF, transform, …)
//   KineTimelineUI     AppKit NSView timeline + pen/blade/select tools
//   KineAppUI          SwiftUI shells: bins, viewer, inspector
//   KineApp            @main, AppDelegate, window scenes

let package = Package(
    name: "Kinestasis",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kinestasis", targets: ["KineApp"]),
    ],
    dependencies: [
        .package(path: "../PolymergeKit"),
    ],
    targets: [
        // ── Kinestasis ────────────────────────────────────────────────────
        .target(name: "KineCore"),

        .target(
            name: "KineMedia",
            dependencies: [
                "KineCore",
                .product(name: "PolymergeMediaModel", package: "PolymergeKit"),
                .product(name: "PolymergeIngest", package: "PolymergeKit"),
                .product(name: "PolymergeAudio", package: "PolymergeKit"),
                .product(name: "PolymergePlayback", package: "PolymergeKit"),
            ]
        ),

        .target(
            name: "KineRender",
            dependencies: [
                "KineCore",
                "KineMedia",
                .product(name: "PolymergePlayback", package: "PolymergeKit"),
            ],
            resources: [.process("Resources")]
        ),

        .target(
            name: "KineEffects",
            dependencies: ["KineCore", "KineRender"]
        ),

        .target(
            name: "KineTimelineUI",
            dependencies: ["KineCore", "KineRender", "KineEffects"]
        ),

        .target(
            name: "KineAppUI",
            dependencies: [
                "KineCore",
                "KineMedia",
                "KineRender",
                "KineEffects",
                "KineTimelineUI",
                .product(name: "PolymergeMediaModel", package: "PolymergeKit"),
                .product(name: "PolymergeAudio", package: "PolymergeKit"),
                .product(name: "PolymergePlayback", package: "PolymergeKit"),
            ]
        ),

        .executableTarget(
            name: "KineApp",
            dependencies: ["KineAppUI"],
            resources: [.process("Resources")]
        ),

        .testTarget(
            name: "KineCoreTests",
            dependencies: ["KineCore"]
        ),

        .testTarget(
            name: "KineMediaTests",
            dependencies: ["KineMedia"]
        ),

        .testTarget(
            name: "KineRenderTests",
            dependencies: ["KineRender", "KineCore"]
        ),
    ]
)
