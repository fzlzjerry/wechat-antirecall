// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "wechat-antirecall",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "wechat-antirecall", targets: ["WeChatAntiRecall"]),
        .executable(name: "WeChatAntiRecallGUI", targets: ["WeChatAntiRecallGUI"]),
        .library(name: "WeChatAntiRecallRuntime", type: .dynamic, targets: ["WeChatAntiRecallRuntime"])
    ],
    targets: [
        .executableTarget(name: "WeChatAntiRecall"),
        // SwiftUI GUI shell. It shells out to the prebuilt `wechat-antirecall` CLI (bundled
        // in the .app's Resources), so it has NO dependency on the CLI target. Packaged into
        // a proper .app bundle by Scripts/make-app.sh.
        .executableTarget(name: "WeChatAntiRecallGUI"),
        .target(
            name: "WeChatAntiRecallRuntime",
            // Runtime.mm is Objective-C++ using constexpr/auto/using. Without an explicit
            // standard SwiftPM emits no -std, so the toolchain's clang default decides: locally
            // it accepts these as extensions, but the CI runner's clang rejects constexpr as a
            // hard error. cxxLanguageStandard does NOT reach .mm files, so force it here.
            cxxSettings: [
                .unsafeFlags(["-std=gnu++17"])
            ],
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        ),
        .testTarget(
            name: "WeChatAntiRecallTests",
            dependencies: [
                "WeChatAntiRecall",
                "WeChatAntiRecallRuntime"
            ]
        )
    ]
)
