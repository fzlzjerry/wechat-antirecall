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

    func testBuild269077SupportsInlineHookRecallPatchesAndUpdateBlock() throws {
        // 269077 (WeChat 4.1.11) is a new marketing version: parseRevokeXML kept its body
        // (prologue + cbz w0 @ entry+0x270 + str x0,[x19,#0x168] @ entry+0xA04) but
        // relocated to 0x48a4d68 — a unique geometry match across the whole arm64 slice.
        let configs = try loadPatchConfigs()
        let config = try XCTUnwrap(configs.first { $0.version == "269077" })

        XCTAssertEqual(config.targets.map(\.identifier), ["revoke", "revoke-tip", "update", "runtime-tip"])

        let revoke = try XCTUnwrap(config.targets.first { $0.identifier == "revoke" })
        XCTAssertEqual(revoke.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(revoke.entries.count, 1)
        XCTAssertEqual(revoke.entries[0].arch, .arm64)
        XCTAssertEqual(revoke.entries[0].address, 0x48a4fd8)
        XCTAssertEqual(revoke.entries[0].expectedBytes, [try Data(hexString: "E00F0034")])
        XCTAssertEqual(revoke.entries[0].patchBytes, try Data(hexString: "7F000014"))

        let revokeTip = try XCTUnwrap(config.targets.first { $0.identifier == "revoke-tip" })
        XCTAssertEqual(revokeTip.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(revokeTip.entries.count, 2)
        XCTAssertEqual(revokeTip.entries[0].arch, .arm64)
        XCTAssertEqual(revokeTip.entries[0].address, 0x48a4fd8)
        XCTAssertEqual(revokeTip.entries[0].expectedBytes, [
            try Data(hexString: "E00F0034"),
            try Data(hexString: "7F000014")
        ])
        XCTAssertEqual(revokeTip.entries[0].patchBytes, try Data(hexString: "E00F0034"))
        XCTAssertEqual(revokeTip.entries[1].arch, .arm64)
        XCTAssertEqual(revokeTip.entries[1].address, 0x48a576c)
        XCTAssertEqual(revokeTip.entries[1].expectedBytes, [try Data(hexString: "60B600F9")])
        XCTAssertEqual(revokeTip.entries[1].patchBytes, try Data(hexString: "7FB600F9"))

        // Update blocking: the 8 sites were located by resolving XAppUpdateManager's ObjC
        // selectors -> IMPs (cross-validated against the 268831 binary, same selectors and
        // prologues). Four trigger methods get `ret` at entry (startUpdater, checkForUpdates:,
        // startBackgroundUpdatesCheck:, enableAutoUpdate:) and the two force-update flag
        // accessors (automaticallyDownloadsUpdates @0x18, canCheckForUpdate @0x19) are forced
        // to return 0 with their setters neutered to `ret`.
        let update = try XCTUnwrap(config.targets.first { $0.identifier == "update" })
        XCTAssertEqual(update.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(update.entries.count, 8)
        XCTAssertTrue(update.entries.allSatisfy { $0.arch == .arm64 })
        // Every update entry neutralizes a function: the patch ends in `ret` (C0035FD6).
        XCTAssertTrue(update.entries.allSatisfy { $0.patchBytes.suffix(4) == (try! Data(hexString: "C0035FD6")) })
        // startUpdater entry -> ret.
        XCTAssertEqual(update.entries[0].address, 0x1d393c)
        XCTAssertEqual(update.entries[0].expectedBytes, [try Data(hexString: "FC6FBBA9")])
        XCTAssertEqual(update.entries[0].patchBytes, try Data(hexString: "C0035FD6"))
        // checkForUpdates: entry -> ret.
        XCTAssertEqual(update.entries[1].address, 0x1d5a74)
        XCTAssertEqual(update.entries[1].expectedBytes, [try Data(hexString: "FFC305D1")])
        // canCheckForUpdate getter -> return 0.
        XCTAssertEqual(update.entries[6].address, 0x1dfffc)
        XCTAssertEqual(update.entries[6].expectedBytes, [try Data(hexString: "00644039C0035FD6")])
        XCTAssertEqual(update.entries[6].patchBytes, try Data(hexString: "00008052C0035FD6"))

        // Inline hook: static entry rewrite (adrp x16, SLOT ; ldr x16,[x16,#0xf00] ; br x16)
        // routing parseRevokeXML through the injected dylib. The SLOT (0x93b3f00) lives in
        // the __DATA tail slack; the asm differs from 268849-268851 only in the adrp page.
        let runtimeTip = try XCTUnwrap(config.targets.first { $0.identifier == "runtime-tip" })
        XCTAssertEqual(runtimeTip.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(runtimeTip.entries.count, 1)
        XCTAssertEqual(runtimeTip.entries[0].address, 0x48a4d68)
        XCTAssertEqual(runtimeTip.entries[0].expectedBytes, [try Data(hexString: "F85FBCA9F65701A9F44F02A9")])
        XCTAssertEqual(runtimeTip.entries[0].patchBytes, try Data(hexString: "705802F0108247F900021FD6"))

        XCTAssertTrue(RuntimeTipInstaller.supportedBuildVersions.contains("269077"))
    }

    func testBuild269079SupportsInlineHookRecallPatchesAndUpdateBlock() throws {
        // 269079 (WeChat 4.1.11 hotfix) is NOT byte-identical to 269077 — the whole slice was
        // rebased, so every site shifted. parseRevokeXML kept its body (prologue + cbz w0 @
        // entry+0x270 + str x0,[x19,#0x168] @ entry+0xA04) and relocated to 0x48a7c4c, a unique
        // geometry match across the arm64 slice. Field offsets 0x168/0x170 were re-decoded from
        // the actual instructions in this binary.
        let configs = try loadPatchConfigs()
        let config = try XCTUnwrap(configs.first { $0.version == "269079" })

        XCTAssertEqual(config.targets.map(\.identifier), ["revoke", "revoke-tip", "update", "runtime-tip"])

        let revoke = try XCTUnwrap(config.targets.first { $0.identifier == "revoke" })
        XCTAssertEqual(revoke.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(revoke.entries.count, 1)
        XCTAssertEqual(revoke.entries[0].arch, .arm64)
        XCTAssertEqual(revoke.entries[0].address, 0x48a7ebc)
        XCTAssertEqual(revoke.entries[0].expectedBytes, [try Data(hexString: "E00F0034")])
        XCTAssertEqual(revoke.entries[0].patchBytes, try Data(hexString: "7F000014"))

        let revokeTip = try XCTUnwrap(config.targets.first { $0.identifier == "revoke-tip" })
        XCTAssertEqual(revokeTip.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(revokeTip.entries.count, 2)
        XCTAssertEqual(revokeTip.entries[0].arch, .arm64)
        XCTAssertEqual(revokeTip.entries[0].address, 0x48a7ebc)
        XCTAssertEqual(revokeTip.entries[0].expectedBytes, [
            try Data(hexString: "E00F0034"),
            try Data(hexString: "7F000014")
        ])
        XCTAssertEqual(revokeTip.entries[0].patchBytes, try Data(hexString: "E00F0034"))
        XCTAssertEqual(revokeTip.entries[1].arch, .arm64)
        XCTAssertEqual(revokeTip.entries[1].address, 0x48a8650)
        XCTAssertEqual(revokeTip.entries[1].expectedBytes, [try Data(hexString: "60B600F9")])
        XCTAssertEqual(revokeTip.entries[1].patchBytes, try Data(hexString: "7FB600F9"))

        // Update blocking: the 8 sites were located by resolving XAppUpdateManager's ObjC
        // selectors -> IMPs (same selectors and prologues as 269077, accessor fields 0x18/0x19).
        let update = try XCTUnwrap(config.targets.first { $0.identifier == "update" })
        XCTAssertEqual(update.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(update.entries.count, 8)
        XCTAssertTrue(update.entries.allSatisfy { $0.arch == .arm64 })
        // Every update entry neutralizes a function: the patch ends in `ret` (C0035FD6).
        XCTAssertTrue(update.entries.allSatisfy { $0.patchBytes.suffix(4) == (try! Data(hexString: "C0035FD6")) })
        // startUpdater entry -> ret.
        XCTAssertEqual(update.entries[0].address, 0x1d3304)
        XCTAssertEqual(update.entries[0].expectedBytes, [try Data(hexString: "FC6FBBA9")])
        XCTAssertEqual(update.entries[0].patchBytes, try Data(hexString: "C0035FD6"))
        // checkForUpdates: entry -> ret.
        XCTAssertEqual(update.entries[1].address, 0x1d543c)
        XCTAssertEqual(update.entries[1].expectedBytes, [try Data(hexString: "FFC305D1")])
        // canCheckForUpdate getter -> return 0.
        XCTAssertEqual(update.entries[6].address, 0x1df9c4)
        XCTAssertEqual(update.entries[6].expectedBytes, [try Data(hexString: "00644039C0035FD6")])
        XCTAssertEqual(update.entries[6].patchBytes, try Data(hexString: "00008052C0035FD6"))

        // Inline hook: static entry rewrite (adrp x16, SLOT ; ldr x16,[x16,#0xf00] ; br x16)
        // routing parseRevokeXML through the injected dylib. The SLOT (0x93b7f00) lives in the
        // __DATA tail slack past __common; the asm differs from 269077 only in the adrp page.
        let runtimeTip = try XCTUnwrap(config.targets.first { $0.identifier == "runtime-tip" })
        XCTAssertEqual(runtimeTip.binaryPath, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(runtimeTip.entries.count, 1)
        XCTAssertEqual(runtimeTip.entries[0].address, 0x48a7c4c)
        XCTAssertEqual(runtimeTip.entries[0].expectedBytes, [try Data(hexString: "F85FBCA9F65701A9F44F02A9")])
        XCTAssertEqual(runtimeTip.entries[0].patchBytes, try Data(hexString: "90580290108247F900021FD6"))

        XCTAssertTrue(RuntimeTipInstaller.supportedBuildVersions.contains("269079"))
    }

    func testBuild269110SupportsInlineHookRecallPatchesAndUpdateBlock() throws {
        let configs = try loadPatchConfigs()
        let config = try XCTUnwrap(configs.first { $0.version == "269110" })

        XCTAssertEqual(config.targets.map(\.identifier), ["revoke", "revoke-tip", "update", "runtime-tip"])
        XCTAssertEqual(config.targets.first { $0.identifier == "revoke" }?.entries.first?.address, 0x450a128)
        XCTAssertEqual(config.targets.first { $0.identifier == "revoke-tip" }?.entries.map(\.address), [0x450a128, 0x450a8bc])

        let update = try XCTUnwrap(config.targets.first { $0.identifier == "update" })
        XCTAssertEqual(update.entries.map(\.address), [
            0x264870, 0x2668e0, 0x266b70, 0x266f5c,
            0x2707c8, 0x2707d0, 0x2707d8, 0x2707e0
        ])
        XCTAssertTrue(update.entries.allSatisfy { $0.patchBytes.suffix(4) == (try! Data(hexString: "C0035FD6")) })

        let runtimeTip = try XCTUnwrap(config.targets.first { $0.identifier == "runtime-tip" })
        XCTAssertEqual(runtimeTip.entries[0].address, 0x4509eb8)
        XCTAssertEqual(runtimeTip.entries[0].expectedBytes, [try Data(hexString: "F85FBCA9F65701A9F44F02A9")])
        XCTAssertEqual(runtimeTip.entries[0].patchBytes, try Data(hexString: "109B02D0108247F900021FD6"))
        XCTAssertTrue(RuntimeTipInstaller.supportedBuildVersions.contains("269110"))
    }

    func testBuild269333SupportsInlineHookRecallPatchesAndUpdateBlock() throws {
        let configs = try loadPatchConfigs()
        let config = try XCTUnwrap(configs.first { $0.version == "269333" })

        XCTAssertEqual(config.targets.map(\.identifier), ["revoke", "revoke-tip", "update", "runtime-tip"])
        XCTAssertEqual(config.targets.first { $0.identifier == "revoke" }?.entries.first?.address, 0x463ef88)
        XCTAssertEqual(config.targets.first { $0.identifier == "revoke-tip" }?.entries.map(\.address), [0x463ef88, 0x463f728])

        let update = try XCTUnwrap(config.targets.first { $0.identifier == "update" })
        XCTAssertEqual(update.entries.map(\.address), [
            0x26e4c0, 0x2706ec, 0x2709bc, 0x270ddc,
            0x27b1c0, 0x27b1c8, 0x27b1d0, 0x27b1d8
        ])
        XCTAssertTrue(update.entries.allSatisfy { $0.patchBytes.suffix(4) == (try! Data(hexString: "C0035FD6")) })

        let runtimeTip = try XCTUnwrap(config.targets.first { $0.identifier == "runtime-tip" })
        XCTAssertEqual(runtimeTip.entries[0].address, 0x463ed18)
        XCTAssertEqual(runtimeTip.entries[0].expectedBytes, [try Data(hexString: "F85FBCA9F65701A9F44F02A9")])
        XCTAssertEqual(runtimeTip.entries[0].patchBytes, try Data(hexString: "70A102B0108247F900021FD6"))
        XCTAssertTrue(RuntimeTipInstaller.supportedBuildVersions.contains("269333"))
    }

    func testBuild269334SupportsInlineHookRecallPatchesAndUpdateBlock() throws {
        let configs = try loadPatchConfigs()
        let config = try XCTUnwrap(configs.first { $0.version == "269334" })

        XCTAssertEqual(config.targets.map(\.identifier), ["revoke", "revoke-tip", "update", "runtime-tip"])
        XCTAssertEqual(config.targets.first { $0.identifier == "revoke" }?.entries.first?.address, 0x461d894)
        XCTAssertEqual(config.targets.first { $0.identifier == "revoke-tip" }?.entries.map(\.address), [0x461d894, 0x461e034])

        let update = try XCTUnwrap(config.targets.first { $0.identifier == "update" })
        XCTAssertEqual(update.entries.map(\.address), [
            0x26c4c0, 0x26e6ec, 0x26e9bc, 0x26eddc,
            0x2791c8, 0x2791d0, 0x2791d8, 0x2791e0
        ])
        XCTAssertTrue(update.entries.allSatisfy { $0.patchBytes.suffix(4) == (try! Data(hexString: "C0035FD6")) })

        let runtimeTip = try XCTUnwrap(config.targets.first { $0.identifier == "runtime-tip" })
        XCTAssertEqual(runtimeTip.entries[0].address, 0x461d624)
        XCTAssertEqual(runtimeTip.entries[0].expectedBytes, [try Data(hexString: "F85FBCA9F65701A9F44F02A9")])
        XCTAssertEqual(runtimeTip.entries[0].patchBytes, try Data(hexString: "50A302D0108247F900021FD6"))
        XCTAssertTrue(RuntimeTipInstaller.supportedBuildVersions.contains("269334"))
    }

    private func loadPatchConfigs() throws -> [VersionConfig] {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("patches.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([VersionConfig].self, from: data)
    }
}
