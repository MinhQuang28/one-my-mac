// swift-tools-version: 6.0
import PackageDescription

// OneMac = HiDisplay (display / HiDPI / DDC) + Mousse (mouse) + windows + hardware (battery, fans, keep-awake)
// + eye breaks + clipboard history
// in one menu-bar app. Each part stays its own module so the original code keeps its language mode
// and tests; the OneMac target only composes them.
let package = Package(
    name: "OneMac",
    platforms: [.macOS(.v15)],
    targets: [
        // Shared design tokens + card components used by every feature module.
        .target(name: "OneMacUI", path: "Sources/OneMacUI",
                swiftSettings: [.swiftLanguageMode(.v5)]),

        // ---- Displays (from HiDisplay) ----
        .target(name: "HiDisplayKit", path: "Sources/HiDisplayKit",
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "HiDisplayFeature", dependencies: ["HiDisplayKit", "OneMacUI"],
                path: "Sources/HiDisplayFeature",
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "hidisplay-probe", dependencies: ["HiDisplayKit"],
                          path: "Sources/hidisplay-probe",
                          swiftSettings: [.swiftLanguageMode(.v6)]),

        // ---- Windows: snapping and moving between displays ----
        .target(name: "WindowKit", dependencies: ["OneMacUI"], path: "Sources/WindowKit",
                swiftSettings: [.swiftLanguageMode(.v5)]),

        // ---- Eye breaks: timed rests from the screen ----
        .target(name: "EyeBreakKit", dependencies: ["OneMacUI"], path: "Sources/EyeBreakKit",
                swiftSettings: [.swiftLanguageMode(.v5)]),

        // ---- Clipboard history: text copied earlier, one shortcut away ----
        .target(name: "ClipboardKit", dependencies: ["OneMacUI", "WindowKit"], path: "Sources/ClipboardKit",
                swiftSettings: [.swiftLanguageMode(.v5)]),

        // ---- Mouse (from Mousse) ----
        .target(name: "MousseFeature", dependencies: ["OneMacUI", "WindowKit"], path: "Sources/MousseFeature",
                swiftSettings: [.swiftLanguageMode(.v5)]),

        // ---- Hardware: battery, temperatures, fans, keep-awake ----
        .target(name: "SMCBridge", path: "Sources/SMCBridge", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "HardwareKit", dependencies: ["SMCBridge", "OneMacUI"], path: "Sources/HardwareKit",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // Root-only fan writer, installed once with admin rights (see HardwareKit/FanHelperInstaller).
        .executableTarget(name: "onemac-fan", dependencies: ["SMCBridge"], path: "Sources/onemac-fan",
                          swiftSettings: [.swiftLanguageMode(.v5)]),

        // ---- The app ----
        .executableTarget(name: "OneMac",
                          dependencies: ["HiDisplayFeature", "MousseFeature", "HardwareKit", "WindowKit", "EyeBreakKit",
                                         "ClipboardKit", "OneMacUI"],
                          path: "Sources/OneMac",
                          swiftSettings: [.swiftLanguageMode(.v5)]),

        .testTarget(name: "HiDisplayTests", dependencies: ["HiDisplayKit"], path: "Tests/HiDisplayTests",
                    exclude: ["Fixtures"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MousseTests", dependencies: ["MousseFeature"], path: "Tests/MousseTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "WindowKitTests", dependencies: ["WindowKit"], path: "Tests/WindowKitTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "EyeBreakKitTests", dependencies: ["EyeBreakKit"], path: "Tests/EyeBreakKitTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ClipboardKitTests", dependencies: ["ClipboardKit"], path: "Tests/ClipboardKitTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "HardwareKitTests", dependencies: ["HardwareKit"], path: "Tests/HardwareKitTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
