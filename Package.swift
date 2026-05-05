// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "wechat-antirecall",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "wechat-antirecall", targets: ["WeChatAntiRecall"])
    ],
    targets: [
        .executableTarget(name: "WeChatAntiRecall")
    ]
)
