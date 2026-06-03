import XCTest
@testable import WeChatAntiRecall

final class PatchConfigTests: XCTestCase {
    func testBuild268831SupportsOnlyRecallPatchModes() throws {
        let configs = try loadPatchConfigs()
        let config = try XCTUnwrap(configs.first { $0.version == "268831" })

        XCTAssertEqual(config.targets.map(\.identifier), ["revoke", "revoke-tip"])

        let revoke = try XCTUnwrap(config.targets.first { $0.identifier == "revoke" })
        XCTAssertEqual(revoke.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(revoke.entries.count, 1)
        XCTAssertEqual(revoke.entries[0].arch, .arm64)
        XCTAssertEqual(revoke.entries[0].address, 0x48f6fec)
        XCTAssertEqual(revoke.entries[0].expectedBytes, [try Data(hexString: "E00F0034")])
        XCTAssertEqual(revoke.entries[0].patchBytes, try Data(hexString: "7F000014"))

        let revokeTip = try XCTUnwrap(config.targets.first { $0.identifier == "revoke-tip" })
        XCTAssertEqual(revokeTip.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(revokeTip.entries.count, 2)
        XCTAssertEqual(revokeTip.entries[0].arch, .arm64)
        XCTAssertEqual(revokeTip.entries[0].address, 0x48f6fec)
        XCTAssertEqual(revokeTip.entries[0].expectedBytes, [
            try Data(hexString: "E00F0034"),
            try Data(hexString: "7F000014")
        ])
        XCTAssertEqual(revokeTip.entries[0].patchBytes, try Data(hexString: "E00F0034"))
        XCTAssertEqual(revokeTip.entries[1].arch, .arm64)
        XCTAssertEqual(revokeTip.entries[1].address, 0x48f7780)
        XCTAssertEqual(revokeTip.entries[1].expectedBytes, [try Data(hexString: "60B600F9")])
        XCTAssertEqual(revokeTip.entries[1].patchBytes, try Data(hexString: "7FB600F9"))
    }

    private func loadPatchConfigs() throws -> [VersionConfig] {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("patches.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([VersionConfig].self, from: data)
    }
}
