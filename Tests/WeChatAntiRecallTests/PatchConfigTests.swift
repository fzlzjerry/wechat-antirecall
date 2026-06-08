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

    func testBuild268849SupportsRecallPatchModes() throws {
        let configs = try loadPatchConfigs()
        let config = try XCTUnwrap(configs.first { $0.version == "268849" })

        XCTAssertEqual(config.targets.map(\.identifier), ["revoke", "revoke-tip", "update", "runtime-tip"])

        let revoke = try XCTUnwrap(config.targets.first { $0.identifier == "revoke" })
        XCTAssertEqual(revoke.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(revoke.entries.count, 1)
        XCTAssertEqual(revoke.entries[0].arch, .arm64)
        XCTAssertEqual(revoke.entries[0].address, 0x488c734)
        XCTAssertEqual(revoke.entries[0].expectedBytes, [try Data(hexString: "E00F0034")])
        XCTAssertEqual(revoke.entries[0].patchBytes, try Data(hexString: "7F000014"))

        let revokeTip = try XCTUnwrap(config.targets.first { $0.identifier == "revoke-tip" })
        XCTAssertEqual(revokeTip.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(revokeTip.entries.count, 2)
        XCTAssertEqual(revokeTip.entries[0].arch, .arm64)
        XCTAssertEqual(revokeTip.entries[0].address, 0x488c734)
        XCTAssertEqual(revokeTip.entries[0].expectedBytes, [
            try Data(hexString: "E00F0034"),
            try Data(hexString: "7F000014")
        ])
        XCTAssertEqual(revokeTip.entries[0].patchBytes, try Data(hexString: "E00F0034"))
        XCTAssertEqual(revokeTip.entries[1].arch, .arm64)
        XCTAssertEqual(revokeTip.entries[1].address, 0x488cec8)
        XCTAssertEqual(revokeTip.entries[1].expectedBytes, [try Data(hexString: "60B600F9")])
        XCTAssertEqual(revokeTip.entries[1].patchBytes, try Data(hexString: "7FB600F9"))

        let update = try XCTUnwrap(config.targets.first { $0.identifier == "update" })
        XCTAssertEqual(update.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(update.entries.count, 9)
        XCTAssertTrue(update.entries.allSatisfy { $0.arch == .arm64 })
        // Every update entry neutralizes a function: the patch ends in `ret` (C0035FD6).
        XCTAssertTrue(update.entries.allSatisfy { $0.patchBytes.suffix(4) == (try! Data(hexString: "C0035FD6")) })
        // Spot-check the first prologue and a getter rewrite against the reference build 268601 mapping.
        XCTAssertEqual(update.entries[0].address, 0x1cd5bc)
        XCTAssertEqual(update.entries[0].expectedBytes, [try Data(hexString: "FC6FBBA9")])
        XCTAssertEqual(update.entries[5].address, 0x1d9514)
        XCTAssertEqual(update.entries[5].expectedBytes, [try Data(hexString: "00604039C0035FD6")])
        XCTAssertEqual(update.entries[5].patchBytes, try Data(hexString: "00008052C0035FD6"))

        // 268849 has no WeChat dispatch stub, so runtime-tip is delivered via the inline
        // hook: a static entry rewrite at parseRevokeXML's entry that routes through the
        // injected dylib. The rewrite overwrites the 3-instruction prologue with a
        // 12-byte adrp/ldr/br stub.
        let runtimeTip = try XCTUnwrap(config.targets.first { $0.identifier == "runtime-tip" })
        XCTAssertEqual(runtimeTip.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(runtimeTip.entries.count, 1)
        XCTAssertEqual(runtimeTip.entries[0].address, 0x488c4c4)
        XCTAssertEqual(runtimeTip.entries[0].expectedBytes, [try Data(hexString: "F85FBCA9F65701A9F44F02A9")])
        XCTAssertEqual(runtimeTip.entries[0].patchBytes, try Data(hexString: "F06402F0108247F900021FD6"))
    }

    func testBuild268850MirrorsBuild268849() throws {
        // 268850 is a +1 hotfix of 268849, byte-identical across every patch site and the
        // SLOT slack, so its config must be an exact copy (same targets/addresses/bytes).
        let configs = try loadPatchConfigs()
        let c849 = try XCTUnwrap(configs.first { $0.version == "268849" })
        let c850 = try XCTUnwrap(configs.first { $0.version == "268850" })

        XCTAssertEqual(c849.targets.map(\.identifier), c850.targets.map(\.identifier))
        for (t849, t850) in zip(c849.targets, c850.targets) {
            XCTAssertEqual(t849.identifier, t850.identifier)
            XCTAssertEqual(t849.binaryPath, t850.binaryPath)
            XCTAssertEqual(t849.entries, t850.entries)
        }
        XCTAssertTrue(RuntimeTipInstaller.supportedBuildVersions.contains("268850"))
    }

    func testRuntimeTipSupportedBuildsIncludeInlineHookBuild() throws {
        // 268849 is supported via the inline hook, so it must be advertised; and it must
        // carry the runtime-tip static-patch target that the inline hook depends on.
        XCTAssertTrue(RuntimeTipInstaller.supportedBuildVersions.contains("268849"))
        let configs = try loadPatchConfigs()
        let config = try XCTUnwrap(configs.first { $0.version == "268849" })
        XCTAssertNotNil(config.targets.first { $0.identifier == "runtime-tip" })
    }

    private func loadPatchConfigs() throws -> [VersionConfig] {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("patches.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([VersionConfig].self, from: data)
    }
}
