import XCTest
@testable import WeChatAntiRecallGUI

@MainActor
final class AppStateCapabilityTests: XCTestCase {
    func testDetectsDownloadedCatalogWithOutdatedBundledRuntime() {
        let state = AppState(defaults: isolatedDefaults())
        state.versions = makeReport(
            runtimeTipSupported: false,
            targets: ["revoke", "revoke-tip", "runtime-tip"])

        XCTAssertFalse(state.customTipAvailable)
        XCTAssertTrue(state.customTipRuntimeOutdated)
    }

    func testDoesNotCallRuntimeOutdatedWhenCatalogLacksRuntimeTipTarget() {
        let state = AppState(defaults: isolatedDefaults())
        state.versions = makeReport(
            runtimeTipSupported: false,
            targets: ["revoke", "revoke-tip"])

        XCTAssertFalse(state.customTipAvailable)
        XCTAssertFalse(state.customTipRuntimeOutdated)
    }

    func testCurrentRuntimeKeepsCustomTipAvailable() {
        let state = AppState(defaults: isolatedDefaults())
        state.versions = makeReport(
            runtimeTipSupported: true,
            targets: ["revoke", "revoke-tip", "runtime-tip"])

        XCTAssertTrue(state.customTipAvailable)
        XCTAssertFalse(state.customTipRuntimeOutdated)
    }

    private func makeReport(runtimeTipSupported: Bool, targets: [String]) -> VersionsReport {
        VersionsReport(
            schemaVersion: 1,
            app: CLIAppInfo(
                path: "/Applications/WeChat.app",
                bundleIdentifier: "com.tencent.xinWeChat",
                marketingVersion: "4.1.15",
                installedBuild: "270100",
                executable: "/Applications/WeChat.app/Contents/MacOS/WeChat"),
            supported: true,
            runtimeTipSupported: runtimeTipSupported,
            installedBuildTargets: targets,
            features: .init(
                silent: true,
                tip: true,
                blockUpdate: true,
                multiInstance: false,
                customTip: runtimeTipSupported),
            catalog: [])
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "com.wechat-antirecall.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
