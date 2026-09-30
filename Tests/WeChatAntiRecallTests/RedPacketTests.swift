import XCTest
import Foundation
import WeChatAntiRecallRuntime
@testable import WeChatAntiRecall

final class RedPacketTests: XCTestCase {
    private let nativeURL = "wxpay://c2cbizmessagehandler/hongbao/receivehongbao?sendid=123456789&channelid=1&msgtype=1"

    private func xml(type: String = "2001", url: String? = nil) -> String {
        "<msg><appmsg><type>\(type)</type><wcpayinfo><nativeurl><![CDATA[\(url ?? nativeURL)]]></nativeurl></wcpayinfo></appmsg></msg>"
    }

    func testRecognizesDirectAndGroupPacketXML() {
        XCTAssertEqual(wechat_antirecall_red_packet_parse(xml()), 1)
        XCTAssertEqual(wechat_antirecall_red_packet_parse("wxid_fixture:\n" + xml()), 1)
        XCTAssertEqual(wechat_antirecall_red_packet_parse(xml().replacingOccurrences(of: "<msg>", with: "").replacingOccurrences(of: "</msg>", with: "")), 1)
        let escaped = xml().replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "").replacingOccurrences(of: "&", with: "&amp;")
        XCTAssertEqual(wechat_antirecall_red_packet_parse(escaped), 1)
    }

    func testRejectsTransfersLinksAndAmbiguousPackets() {
        for input in [xml(type: "2000"), xml(type: "5"), xml(url: "https://example.com/?sendid=1"),
                      xml(url: nativeURL + "&sendid=222"), xml(url: nativeURL + "&msgtype=1"),
                      xml(url: nativeURL.replacingOccurrences(of: "msgtype=1", with: "msgtype=2")),
                      xml(url: nativeURL.replacingOccurrences(of: "sendid=123456789", with: "sendid=")),
                      xml(url: nativeURL + "#fragment"),
                      xml().replacingOccurrences(of: "<type>2001</type>", with: "<type>2001</type><type>2001</type>"),
                      xml().replacingOccurrences(of: "<type>2001</type>", with: "<type><nested>2001</nested></type>"),
                      xml().replacingOccurrences(of: "</msg>", with: ""),
                      "<other>" + xml() + "</other>"] {
            XCTAssertEqual(wechat_antirecall_red_packet_parse(input), 0, input)
        }
    }

    func testRejectsEntitiesOversizeAndConflictingSender() {
        XCTAssertEqual(wechat_antirecall_red_packet_parse("<!DOCTYPE msg [<!ENTITY x SYSTEM 'file:///not-read'>]>" + xml()), 0)
        XCTAssertEqual(wechat_antirecall_red_packet_parse(String(repeating: " ", count: 65537) + xml()), 0)
        let conflicting = xml().replacingOccurrences(of: "</appmsg>", with: "<fromusername>someone_else</fromusername></appmsg>")
        XCTAssertEqual(wechat_antirecall_red_packet_parse("wxid_fixture:\n" + conflicting), 0)
    }

    func testOnlyNativeEligibleStatesCanOpen() {
        for type in [Int32]([0, 1, 3]) {
            for status in [Int32]([2, 3]) {
                XCTAssertEqual(wechat_antirecall_red_packet_can_open(0, 0, 0, status, type, "fixture-timing"), 1)
            }
        }
        XCTAssertEqual(wechat_antirecall_red_packet_can_open(1, 0, 0, 2, 1, "fixture"), 0)
        XCTAssertEqual(wechat_antirecall_red_packet_can_open(0, 1, 0, 2, 1, "fixture"), 0)
        for received in [Int32]([1, 2, 3]) {
            XCTAssertEqual(wechat_antirecall_red_packet_can_open(0, 0, received, 2, 1, "fixture"), 0)
        }
        for status in [Int32]([0, 1, 4, 5, 6]) {
            XCTAssertEqual(wechat_antirecall_red_packet_can_open(0, 0, 0, status, 1, "fixture"), 0)
        }
        XCTAssertEqual(wechat_antirecall_red_packet_can_open(0, 0, 0, 2, 99, "fixture"), 0)
        XCTAssertEqual(wechat_antirecall_red_packet_can_open(0, 0, 0, 2, 1, nil), 0)
        XCTAssertEqual(wechat_antirecall_red_packet_can_open(0, 0, 0, 2, 1, ""), 0)
    }

    func testRejectsHistoryFutureAndExpiredMessages() {
        XCTAssertEqual(wechat_antirecall_red_packet_fresh(100, 100, 100), 1)
        XCTAssertEqual(wechat_antirecall_red_packet_fresh(100, 100, 160), 1)
        XCTAssertEqual(wechat_antirecall_red_packet_fresh(100, 100, 161), 0)
        XCTAssertEqual(wechat_antirecall_red_packet_fresh(99, 100, 100), 0)
        XCTAssertEqual(wechat_antirecall_red_packet_fresh(101, 100, 100), 0)
        XCTAssertEqual(wechat_antirecall_red_packet_fresh(0, 0, 0), 0)
    }

    func testDuplicateAndLateCallbacksDoNotProduceAnotherOpen() {
        XCTAssertEqual(wechat_antirecall_red_packet_policy_selftest(), 1)
    }

    func testNativeSRetCallbackAndOwnershipABIWithoutWeChat() throws {
        #if arch(arm64)
        XCTAssertEqual(wechat_antirecall_red_packet_native_abi_selftest(), 1)
        #else
        throw XCTSkip("The native adapter supports arm64 only")
        #endif
    }

    func testStrictCLIOptions() throws {
        let defaults = try RedPacketOptions(["get", "--json"])
        XCTAssertNil(defaults.enabled)
        XCTAssertTrue(defaults.json)
        let enabled = try RedPacketOptions(["on", "--delay-ms", "0", "--app", "/tmp/WeChat.app"])
        XCTAssertEqual(enabled.enabled, true)
        XCTAssertEqual(enabled.delayMilliseconds, 0)
        // Explicit false (not nil) is what lets "on --delay-ms" switch a
        // notify-only configuration back to automatic grabbing.
        XCTAssertEqual(enabled.notifyOnly, false)
        XCTAssertEqual(enabled.appPath, "/tmp/WeChat.app")
        let notifyOnly = try RedPacketOptions(["on", "--notify-only", "--app", "/tmp/WeChat.app"])
        XCTAssertEqual(notifyOnly.enabled, true)
        XCTAssertEqual(notifyOnly.notifyOnly, true)
        XCTAssertNil(notifyOnly.delayMilliseconds)
        for args in [[], ["enable"], ["get", "--delay-ms", "500"], ["off", "--delay-ms", "500"],
                     ["on", "--delay-ms", "-1"], ["on", "--delay-ms", "5001"], ["on", "--delay-ms", "1.5"],
                     ["on", "--app"], ["get", "--json", "--json"], ["on", "--unknown"],
                     ["on", "--notify-only", "--delay-ms", "500"], ["get", "--notify-only"],
                     ["off", "--notify-only"]] {
            XCTAssertThrowsError(try RedPacketOptions(args), "\(args)")
        }
    }

    func testRuntimeMarkerMatchesRuntimeExport() {
        XCTAssertEqual(String(cString: wechat_antirecall_red_packet_runtime_version()),
                       RedPacketSettings.runtimeMarker)
        XCTAssertEqual(RedPacketSettings.runtimeMarker, "WeChatAntiRecallRedPacket:6",
                       "270102 needs the new native address table; older runtimes must require an update")
    }

    func testBuild270102RedPacketSupportRequiresRecallMessageHook() {
        XCTAssertTrue(RedPacketSettings.supportedBuilds.contains("270102"))
        XCTAssertTrue(RuntimeTipInstaller.supportedBuildVersions.contains("270102"))
        XCTAssertFalse(RedPacketSettings.supportedBuilds.contains("270103"),
                       "Unverified neighboring builds must not inherit native offsets")
    }

    func testPreferenceRoundTripPreservesWeChatSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RedPacketPreferenceStore(
            preferences: RecallTipPreferenceStore(homeDirectory: folder, domain: "com.tencent.xinWeChat"))
        XCTAssertEqual(try store.load(), RedPacketSettings())
        try FileManager.default.createDirectory(
            at: store.preferenceFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = ["Unrelated": "preserve", "WeChatAntiRecall_RevokeTipPhrase": "custom"]
        try PropertyListSerialization.data(fromPropertyList: existing, format: .binary, options: 0).write(to: store.preferenceFileURL)
        try store.save(RedPacketSettings(enabled: true, delayMilliseconds: 300, notifyOnly: true))
        XCTAssertEqual(try store.load(), RedPacketSettings(enabled: true, delayMilliseconds: 300, notifyOnly: true))
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: store.preferenceFileURL), format: nil) as? [String: Any])
        XCTAssertEqual(saved["Unrelated"] as? String, "preserve")
        XCTAssertEqual(saved["WeChatAntiRecall_RevokeTipPhrase"] as? String, "custom")
        let packet = try XCTUnwrap(saved["WeChatAntiRecall_RedPacket"] as? [String: Any])
        XCTAssertEqual(packet["enabled"] as? Bool, true)
        XCTAssertEqual(packet["delayMilliseconds"] as? Int, 300)
        XCTAssertEqual(packet["notifyOnly"] as? Bool, true)
        let before = try Data(contentsOf: store.preferenceFileURL)
        XCTAssertThrowsError(try store.save(RedPacketSettings(enabled: true, delayMilliseconds: 9999)))
        XCTAssertEqual(try Data(contentsOf: store.preferenceFileURL), before)
        try Data("broken plist".utf8).write(to: store.preferenceFileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(RedPacketSettings()))
        XCTAssertEqual(try String(contentsOf: store.preferenceFileURL), "broken plist")
    }

    func testLegacyPreferenceWithoutNotifyOnlyLoadsAsAutoGrabMode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RedPacketPreferenceStore(
            preferences: RecallTipPreferenceStore(homeDirectory: folder, domain: "com.tencent.xinWeChat"))
        try FileManager.default.createDirectory(
            at: store.preferenceFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Settings written by the :3 runtime era carry no notifyOnly key.
        let legacy: [String: Any] = ["WeChatAntiRecall_RedPacket": ["enabled": true, "delayMilliseconds": 250]]
        try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
            .write(to: store.preferenceFileURL)
        XCTAssertEqual(try store.load(), RedPacketSettings(enabled: true, delayMilliseconds: 250, notifyOnly: false))
        // Missing required keys are rejected, matching the runtime loader.
        let incomplete: [String: Any] = ["WeChatAntiRecall_RedPacket": ["enabled": true]]
        try PropertyListSerialization.data(fromPropertyList: incomplete, format: .binary, options: 0)
            .write(to: store.preferenceFileURL)
        XCTAssertThrowsError(try store.load())
    }
}
