// swift-tools-version: 5.10
import PackageDescription

// Preem — macOS NLE.
//
// Module layout is layered: low-level building blocks at the top, the app
// shell at the bottom. Each module depends only on modules above it; no
// cycles. Keep it that way — it's how we'll stay sane at M3+.
//
//   PolymergeKit        shared media-engine libraries (MediaModel, Ingest,
//                       Audio, Playback), consumed via local-path dep from
//                       ../PolymergeKit. Replaces the 2026-05-27 in-tree
//                       fork: Preem's post-fork improvements were merged
//                       upstream on 2026-07-12 and both apps now consume
//                       the same package. Library changes go in the Kit
//                       repo; verify with Polymerge's `swift test` too.
//   PreemCore           pure data: Project, Sequence, Track, Clip, time
//   PreemMedia          decode/encode + VT session pool + proxy manager
//   PreemRender         Metal compositor + render graph
//   PreemEffects        starter effect arsenal (xfade, HPF/LPF, transform, …)
//   PreemML             slate OCR, shot classifier, transcription (ANE)
//   PreemTimelineUI     AppKit NSView timeline + pen/blade/select tools
//   PreemAppUI          SwiftUI shells: bins, viewer, inspector
//   PreemApp            @main, AppDelegate, window scenes

let package = Package(
    name: "Preem",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Preem", targets: ["PreemApp"]),
    ],
    dependencies: [
        .package(path: "../PolymergeKit"),
    ],
    targets: [
        // ── Preem ────────────────────────────────────────────────────
        .target(name: "PreemCore"),

        .target(
            name: "PreemMedia",
            dependencies: [
                "PreemCore",
                .product(name: "PolymergeMediaModel", package: "PolymergeKit"),
                .product(name: "PolymergeIngest", package: "PolymergeKit"),
                .product(name: "PolymergeAudio", package: "PolymergeKit"),
                .product(name: "PolymergePlayback", package: "PolymergeKit"),
            ]
        ),

        .target(
            name: "PreemRender",
            dependencies: [
                "PreemCore",
                "PreemMedia",
                .product(name: "PolymergePlayback", package: "PolymergeKit"),
            ],
            resources: [.process("Resources")]
        ),

        .target(
            name: "PreemEffects",
            dependencies: ["PreemCore", "PreemRender"]
        ),

        .target(
            name: "PreemML",
            dependencies: ["PreemCore", "PreemMedia"]
        ),

        .target(
            name: "PreemTimelineUI",
            dependencies: ["PreemCore", "PreemRender", "PreemEffects"]
        ),

        .target(
            name: "PreemAppUI",
            dependencies: [
                "PreemCore",
                "PreemMedia",
                "PreemRender",
                "PreemEffects",
                "PreemML",
                "PreemTimelineUI",
                .product(name: "PolymergeMediaModel", package: "PolymergeKit"),
                .product(name: "PolymergeAudio", package: "PolymergeKit"),
                .product(name: "PolymergePlayback", package: "PolymergeKit"),
            ]
        ),

        .executableTarget(
            name: "PreemApp",
            dependencies: ["PreemAppUI"],
            resources: [.process("Resources")]
        ),

        .testTarget(
            name: "PreemCoreTests",
            dependencies: ["PreemCore"]
        ),

        .testTarget(
            name: "PreemMLTests",
            dependencies: ["PreemML"]
        ),

        .testTarget(
            name: "PreemMediaTests",
            dependencies: ["PreemMedia"]
        ),

        .testTarget(
            name: "PreemRenderTests",
            dependencies: ["PreemRender", "PreemCore"]
        ),
    ]
)
