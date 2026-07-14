import XCTest
@testable import WeChatAntiRecall

final class JSONOutputTests: XCTestCase {
    private func appInfo(buildVersion: String) -> AppInfo {
        let appURL = URL(fileURLWithPath: "/Applications/WeChat.app")
        return AppInfo(
            appURL: appURL,
            executableURL: appURL.appendingPathComponent("Contents/MacOS/WeChat"),
            shortVersion: "4.1.10",
            buildVersion: buildVersion,
            bundleIdentifier: "com.tencent.xinWeChat"
        )
    }

    private func loadPatchConfigs() throws -> [VersionConfig] {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("patches.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([VersionConfig].self, from: data)
    }

    // MARK: - versions --json

    func testVersionsReportForSupportedRuntimeTipBuild() throws {
        let configs = try loadPatchConfigs()
        // 268849 is in patches.json AND in RuntimeTipInstaller.supportedBuildVersions.
        let report = VersionsReport(appInfo: appInfo(buildVersion: "268849"), configs: configs)

        XCTAssertEqual(report.schemaVersion, jsonSchemaVersion)
        XCTAssertTrue(report.supported)
        XCTAssertTrue(report.runtimeTipSupported)
        XCTAssertTrue(report.features.silent)          // has `revoke`
        XCTAssertTrue(report.features.customTip)       // gated by supportedBuildVersions
        XCTAssertTrue(report.installedBuildTargets.contains("revoke"))
        XCTAssertTrue(report.installedBuildTargets.contains("runtime-tip"))
        XCTAssertEqual(report.catalog.count, configs.count)

        let entry = try XCTUnwrap(report.catalog.first { $0.build == "268849" })
        XCTAssertTrue(entry.runtimeTipSupported)
    }

    func testVersionsReportRuntimeTipFalseForByteOnlyBuild() throws {
        let configs = try loadPatchConfigs()
        // 268575 is in patches.json but NOT in RuntimeTipInstaller.supportedBuildVersions.
        let report = VersionsReport(appInfo: appInfo(buildVersion: "268575"), configs: configs)

        XCTAssertTrue(report.supported)
        XCTAssertFalse(report.runtimeTipSupported)
        XCTAssertFalse(report.features.customTip)
        XCTAssertTrue(report.features.silent)
        // 268575 is the only build with the legacy multiInstance byte patch.
        XCTAssertTrue(report.features.multiInstance)
    }

    func testVersionsReportForUnsupportedBuild() throws {
        let configs = try loadPatchConfigs()
        let report = VersionsReport(appInfo: appInfo(buildVersion: "999999"), configs: configs)

        XCTAssertFalse(report.supported)
        XCTAssertFalse(report.runtimeTipSupported)
        XCTAssertTrue(report.installedBuildTargets.isEmpty)
        XCTAssertFalse(report.features.silent)
        XCTAssertFalse(report.features.blockUpdate)
        XCTAssertFalse(report.features.customTip)
    }

    func testVersionsReportEncodesToValidJSON() throws {
        let configs = try loadPatchConfigs()
        let report = VersionsReport(appInfo: appInfo(buildVersion: "268849"), configs: configs)
        let data = try JSONOutput.encoder.encode(report)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let root = try XCTUnwrap(object)

        XCTAssertEqual(root["schemaVersion"] as? Int, jsonSchemaVersion)
        XCTAssertEqual(root["supported"] as? Bool, true)
        XCTAssertEqual(root["runtimeTipSupported"] as? Bool, true)
        let app = try XCTUnwrap(root["app"] as? [String: Any])
        XCTAssertEqual(app["installedBuild"] as? String, "268849")
        XCTAssertNotNil(root["catalog"] as? [Any])
    }

    // MARK: - error envelope

    func testErrorDTOMapsBytesMismatch() throws {
        let expected = [try Data(hexString: "E00F0034"), try Data(hexString: "7F000014")]
        let actual = try Data(hexString: "DEADBEEF")
        let dto = ErrorDTO(ToolError.bytesMismatch(address: 0x48f6fec, expected: expected, actual: actual))

        XCTAssertEqual(dto.kind, "bytesMismatch")
        XCTAssertEqual(dto.address, "0x48f6fec")
        XCTAssertEqual(dto.expected, ["E00F0034", "7F000014"])
        XCTAssertEqual(dto.actual, "DEADBEEF")
    }

    func testErrorDTOMapsUnsupportedVersion() throws {
        let dto = ErrorDTO(ToolError.unsupportedVersion(found: "999999", supported: ["268849", "269077"]))
        XCTAssertEqual(dto.kind, "unsupportedVersion")
        XCTAssertEqual(dto.found, "999999")
        XCTAssertEqual(dto.supported, ["268849", "269077"])
    }

    func testErrorDTOMapsNotAWechatApp() throws {
        let dto = ErrorDTO(ToolError.notAWechatApp("/nope/WeChat.app"))
        XCTAssertEqual(dto.kind, "notAWechatApp")
        XCTAssertEqual(dto.path, "/nope/WeChat.app")
    }

    func testErrorEnvelopeEncodesSchemaVersion() throws {
        let envelope = ErrorEnvelope(ToolError.usage("bad"))
        let data = try JSONOutput.encoder.encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let root = try XCTUnwrap(object)
        XCTAssertEqual(root["schemaVersion"] as? Int, jsonSchemaVersion)
        let error = try XCTUnwrap(root["error"] as? [String: Any])
        XCTAssertEqual(error["kind"] as? String, "usage")
    }
}
