// swift-tools-version: 5.10
import PackageDescription

// Preem — macOS NLE.
//
// Module layout is layered: low-level building blocks at the top, the app
// shell at the bottom. Each module depends only on modules above it; no
// cycles. Keep it that way — it's how we'll stay sane at M3+.
//
//   Polymerge{MediaModel,Ingest,Audio,Playback}
//                       forked in-tree on 2026-05-27 from Polymerge's
//                       feature/spm-library-targets working tree. The
//                       fork severed the cross-product coupling so PPE,
//                       audio, and ingest can be modified freely for
//                       NLE-specific needs (pull-mode rendering, etc.)
//                       without touching the Polymerge product.
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
    targets: [
        // ── Forked from Polymerge (see top-of-file note) ─────────────
        .target(name: "PolymergeMediaModel"),

        .target(
            name: "PolymergeIngest",
            dependencies: ["PolymergeMediaModel"]
        ),

        .target(
            name: "PolymergeAudio",
            dependencies: ["PolymergeMediaModel", "PolymergeIngest"]
        ),

        .target(
            name: "PolymergePlayback",
            dependencies: ["PolymergeMediaModel", "PolymergeIngest"]
        ),

        // ── Preem ────────────────────────────────────────────────────
        .target(name: "PreemCore"),

        .target(
            name: "PreemMedia",
            dependencies: [
                "PreemCore",
                "PolymergeMediaModel",
                "PolymergeIngest",
                "PolymergeAudio",
                "PolymergePlayback",
            ]
        ),

        .target(
            name: "PreemRender",
            dependencies: ["PreemCore", "PreemMedia", "PolymergePlayback"],
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
                "PolymergeMediaModel",
                "PolymergeAudio",
                "PolymergePlayback",
            ]
        ),

        .executableTarget(
            name: "PreemApp",
            dependencies: ["PreemAppUI"]
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
