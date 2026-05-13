// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "wechat-antirecall",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "wechat-antirecall", targets: ["WeChatAntiRecall"]),
        .library(name: "WeChatAntiRecallRuntime", type: .dynamic, targets: ["WeChatAntiRecallRuntime"])
    ],
    targets: [
        .executableTarget(name: "WeChatAntiRecall"),
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
    ],
    cxxLanguageStandard: .cxx17
)
