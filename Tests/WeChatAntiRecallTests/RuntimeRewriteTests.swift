import XCTest
import WeChatAntiRecallRuntime

final class RuntimeRewriteTests: XCTestCase {
    func testRendersConfiguredPhraseWithSenderPlaceholder() throws {
        let rendered = try render(original: "张三撤回了一条消息", phrase: "已拦截 {from} 撤回的一条消息")

        XCTAssertEqual(rendered, "已拦截 张三 撤回的一条消息")
    }

    func testRendersConfiguredPhraseWithTimePlaceholder() throws {
        let rendered = try render(original: "张三撤回了一条消息", phrase: "已拦截 {from} 于 {time} 撤回的一条消息")

        XCTAssertNotNil(
            rendered.range(
                of: #"^已拦截 张三 于 \d{2}:\d{2} 撤回的一条消息$"#,
                options: .regularExpression
            )
        )
    }

    func testReusesFirstFallbackTimeForSameRevokeEvent() throws {
        wechat_antirecall_clear_revoke_tip_time_cache()
        defer {
            wechat_antirecall_clear_revoke_tip_time_cache()
        }

        let phrase = "已拦截 {from} 于 {time} 撤回的一条消息"
        let first = try renderEvent(
            original: "Benjamin撤回了一条消息",
            phrase: phrase,
            newMsgId: 42,
            xml: nil,
            fallbackTime: "00:42"
        )
        let second = try renderEvent(
            original: "Benjamin撤回了一条消息",
            phrase: phrase,
            newMsgId: 42,
            xml: nil,
            fallbackTime: "00:43"
        )

        XCTAssertEqual(first, "已拦截 Benjamin 于 00:42 撤回的一条消息")
        XCTAssertEqual(second, "已拦截 Benjamin 于 00:42 撤回的一条消息")
    }

    func testUsesIndependentFallbackTimeForDifferentRevokeEvents() throws {
        wechat_antirecall_clear_revoke_tip_time_cache()
        defer {
            wechat_antirecall_clear_revoke_tip_time_cache()
        }

        let phrase = "已拦截 {from} 于 {time} 撤回的一条消息"

        XCTAssertEqual(
            try renderEvent(original: "Benjamin撤回了一条消息", phrase: phrase, newMsgId: 42, xml: nil, fallbackTime: "00:42"),
            "已拦截 Benjamin 于 00:42 撤回的一条消息"
        )
        XCTAssertEqual(
            try renderEvent(original: "Aida撤回了一条消息", phrase: phrase, newMsgId: 43, xml: nil, fallbackTime: "00:43"),
            "已拦截 Aida 于 00:43 撤回的一条消息"
        )
    }

    func testRenderingConfiguredPhraseIsIdempotent() throws {
        let phrase = "已拦截 {from} 撤回的一条消息"
        let rendered = try render(original: "Benjamin撤回了一条消息", phrase: phrase)

        XCTAssertEqual(try render(original: rendered, phrase: phrase), rendered)
    }

    func testRenderingConfiguredPhraseWithTimeIsIdempotent() throws {
        let phrase = "已拦截 {from} 于 {time} 撤回的一条消息"
        let rendered = "已拦截 Benjamin 于 00:47 撤回的一条消息"

        XCTAssertEqual(try render(original: rendered, phrase: phrase), rendered)
    }

    func testRenderingCollapsesPreviouslyDuplicatedPrefix() throws {
        let rendered = try render(
            original: "已拦截 已拦截 Benjamin 撤回的一条消息",
            phrase: "已拦截 {from} 撤回的一条消息"
        )

        XCTAssertEqual(rendered, "已拦截 Benjamin 撤回的一条消息")
    }

    func testRendersConfiguredPhraseWithoutSenderWhenSenderIsUnknown() throws {
        let rendered = try render(original: "You recalled a message.", phrase: "已拦截 {from} 撤回的一条消息")

        XCTAssertEqual(rendered, "已拦截  撤回的一条消息")
    }

    func testLoadsConfiguredPhraseFromWechatContainerPlist() throws {
        let homeDirectory = try makeTemporaryDirectory()
        let phrase = "已拦截 {from} 撤回的一条消息"
        try writePhrase(
            phrase,
            to: homeDirectory
                .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Preferences")
                .appendingPathComponent("com.tencent.xinWeChat.plist")
        )

        XCTAssertEqual(try loadConfiguredPhrase(homeDirectory: homeDirectory), phrase)
    }

    func testLoadsConfiguredPhraseFromSandboxDataHome() throws {
        let homeDirectory = try makeTemporaryDirectory()
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data", isDirectory: true)
        let phrase = "已拦截 {from} 撤回的一条消息"
        try writePhrase(
            phrase,
            to: homeDirectory
                .appendingPathComponent("Library/Preferences")
                .appendingPathComponent("com.tencent.xinWeChat.plist")
        )

        XCTAssertEqual(try loadConfiguredPhrase(homeDirectory: homeDirectory), phrase)
    }

    func testFallsBackToNaturalDefaultPhraseWhenPreferenceIsMissing() throws {
        let homeDirectory = try makeTemporaryDirectory()

        XCTAssertEqual(try loadConfiguredPhrase(homeDirectory: homeDirectory), "已拦截一条撤回消息")
    }

    func testFallsBackToNaturalDefaultPhraseWhenPreferenceIsInvalid() throws {
        let homeDirectory = try makeTemporaryDirectory()
        try writePhrase(
            "无效\n短语",
            to: homeDirectory
                .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Preferences")
                .appendingPathComponent("com.tencent.xinWeChat.plist")
        )

        XCTAssertEqual(try loadConfiguredPhrase(homeDirectory: homeDirectory), "已拦截一条撤回消息")
    }

    func testTargetsResourcesWechatDylibInsteadOfFrameworksStub() {
        XCTAssertEqual(
            wechat_antirecall_is_target_wechat_dylib_path("/Applications/WeChat.app/Contents/Resources/wechat.dylib"),
            1
        )
        XCTAssertEqual(
            wechat_antirecall_is_target_wechat_dylib_path("/Applications/WeChat.app/Contents/Frameworks/wechat.dylib"),
            0
        )
    }

    private func render(original: String, phrase: String) throws -> String {
        let pointer = wechat_antirecall_render_revoke_tip_copy(original, phrase)
        let unwrapped = try XCTUnwrap(pointer)
        defer {
            wechat_antirecall_free(unwrapped)
        }
        return String(cString: unwrapped)
    }

    private func renderEvent(
        original: String,
        phrase: String,
        newMsgId: UInt64,
        xml: String?,
        fallbackTime: String
    ) throws -> String {
        let pointer: UnsafeMutablePointer<CChar>?
        if let xml {
            pointer = xml.withCString { xmlPointer in
                wechat_antirecall_render_revoke_tip_for_event_copy(original, phrase, newMsgId, xmlPointer, fallbackTime)
            }
        } else {
            pointer = wechat_antirecall_render_revoke_tip_for_event_copy(original, phrase, newMsgId, nil, fallbackTime)
        }

        let unwrapped = try XCTUnwrap(pointer)
        defer {
            wechat_antirecall_free(unwrapped)
        }
        return String(cString: unwrapped)
    }

    private func loadConfiguredPhrase(homeDirectory: URL) throws -> String {
        let pointer = wechat_antirecall_load_revoke_tip_phrase_for_home_copy(homeDirectory.path)
        let unwrapped = try XCTUnwrap(pointer)
        defer {
            wechat_antirecall_free(unwrapped)
        }
        return String(cString: unwrapped)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePhrase(_ phrase: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["WeChatAntiRecall_RevokeTipPhrase": phrase],
            format: .binary,
            options: 0
        )
        try data.write(to: url)
    }
}
