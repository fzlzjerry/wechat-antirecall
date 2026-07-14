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
