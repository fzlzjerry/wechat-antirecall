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

    func testRendersPureSenderPlaceholderTemplate() throws {
        let rendered = try render(original: "张三撤回了一条消息", phrase: "{from}")

        XCTAssertEqual(rendered, "张三")
    }

    func testRendersPureTimePlaceholderTemplate() throws {
        let rendered = try renderEvent(
            original: "张三撤回了一条消息",
            phrase: "{time}",
            newMsgId: 44,
            xml: nil,
            fallbackTime: "09:32"
        )

        XCTAssertEqual(rendered, "09:32")
    }

    func testRendersAdjacentPurePlaceholdersTemplate() throws {
        let rendered = try renderEvent(
            original: "张三撤回了一条消息",
            phrase: "{from}{time}",
            newMsgId: 45,
            xml: nil,
            fallbackTime: "09:32"
        )

        XCTAssertEqual(rendered, "张三09:32")
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

    func testUsesXmlTimestampInsteadOfFallbackTime() throws {
        wechat_antirecall_clear_revoke_tip_time_cache()
        defer {
            wechat_antirecall_clear_revoke_tip_time_cache()
        }

        let phrase = "已拦截 {from} 于 {time} 撤回的一条消息"
        let xml = "<sysmsg><revokemsg><createtime>1715563800</createtime></revokemsg></sysmsg>"
        let expectedTime = Self.clockText(forUnixTimestamp: 1715563800)

        XCTAssertEqual(
            try renderEvent(original: "Benjamin撤回了一条消息", phrase: phrase, newMsgId: 42, xml: xml, fallbackTime: "09:32"),
            "已拦截 Benjamin 于 \(expectedTime) 撤回的一条消息"
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

    func testRepeatedRuntimeRewriteWithTimeDoesNotNestRenderedPhrase() throws {
        let phrase = "已拦截 {from} 于 {time} 撤回的一条消息"
        let rendered = "已拦截 molder 于 09:30 撤回的一条消息"

        XCTAssertEqual(
            try renderEvent(original: rendered, phrase: phrase, newMsgId: 0, xml: nil, fallbackTime: "09:32"),
            rendered
        )
    }

    func testRenderingCollapsesPreviouslyDuplicatedPrefix() throws {
        let rendered = try render(
            original: "已拦截 已拦截 Benjamin 撤回的一条消息",
            phrase: "已拦截 {from} 撤回的一条消息"
        )

        XCTAssertEqual(rendered, "已拦截 Benjamin 撤回的一条消息")
    }

    func testRenderingCollapsesNestedRuntimeTipWithTime() throws {
        let rendered = try render(
            original: "已拦截 已拦截 molder 于 09:30 于 09:32 撤回的一条消息",
            phrase: "已拦截 {from} 于 {time} 撤回的一条消息"
        )

        XCTAssertEqual(rendered, "已拦截 molder 于 09:30 撤回的一条消息")
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

    func testWechatContainerPlistWinsOverUserPreferencePlist() throws {
        let homeDirectory = try makeTemporaryDirectory()
        let userPhrase = "用户目录短语"
        let containerPhrase = "容器目录短语"
        try writePhrase(
            userPhrase,
            to: homeDirectory
                .appendingPathComponent("Library/Preferences")
                .appendingPathComponent("com.tencent.xinWeChat.plist")
        )
        try writePhrase(
            containerPhrase,
            to: homeDirectory
                .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Preferences")
                .appendingPathComponent("com.tencent.xinWeChat.plist")
        )

        XCTAssertEqual(try loadConfiguredPhrase(homeDirectory: homeDirectory), containerPhrase)
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

    func testHookSlotResolverRejectsOriginalBodyOutsideImageBounds() throws {
        let buffer = try makeExecutableStubBuffer()
        defer {
            munmap(buffer.baseAddress, buffer.length)
        }

        let originalBody = UInt(bitPattern: buffer.baseAddress.advanced(by: 16))
        let slot = wechat_antirecall_resolve_parse_revoke_xml_hook_slot(
            originalBody,
            UInt(bitPattern: buffer.baseAddress.advanced(by: 16)),
            UInt(buffer.length - 16)
        )

        XCTAssertEqual(slot, 0)
    }

    func testHookSlotResolverFindsSlotInsideReadableImageBounds() throws {
        let buffer = try makeExecutableStubBuffer()
        defer {
            munmap(buffer.baseAddress, buffer.length)
        }

        let originalBody = UInt(bitPattern: buffer.baseAddress.advanced(by: 16))
        let slot = wechat_antirecall_resolve_parse_revoke_xml_hook_slot(
            originalBody,
            UInt(bitPattern: buffer.baseAddress),
            UInt(buffer.length)
        )

        XCTAssertEqual(slot, UInt(bitPattern: buffer.baseAddress.advanced(by: 0x80)))
    }

    func testWriteHookSlotRejectsNullSlot() {
        XCTAssertEqual(wechat_antirecall_try_write_hook_slot(nil, UnsafeMutableRawPointer(bitPattern: 0x1234)), 0)
    }

    func testReadableRangeRejectsUnmappedGapBeforeMappedRegion() throws {
        let pageSize = Int(getpagesize())
        guard let mapping = mmap(nil, pageSize * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
              mapping != MAP_FAILED
        else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let secondPage = mapping.advanced(by: pageSize)
        XCTAssertEqual(munmap(mapping, pageSize), 0)
        defer {
            munmap(secondPage, pageSize)
        }

        XCTAssertEqual(wechat_antirecall_is_address_range_readable(UInt(bitPattern: mapping), 16), 0)
        XCTAssertEqual(wechat_antirecall_is_address_range_readable(UInt(bitPattern: secondPage), 16), 1)
    }

    func testRewriteMessageRejectsNonRevokeXml() throws {
        let rendered = try rewriteMessage(
            original: "张三撤回了一条消息",
            phrase: "已拦截 {from} 撤回的一条消息",
            newMsgId: 46,
            xml: "<sysmsg><notrevokemsg /></sysmsg>",
            msgType: 10002,
            fallbackTime: "09:32"
        )

        XCTAssertEqual(rendered, "张三撤回了一条消息")
    }

    func testRewriteMessageRejectsNonRevokeReplaceMsg() throws {
        let rendered = try rewriteMessage(
            original: "普通文本消息",
            phrase: "已拦截 {from} 撤回的一条消息",
            newMsgId: 47,
            xml: "<sysmsg><revokemsg><newmsgid>47</newmsgid></revokemsg></sysmsg>",
            msgType: 10002,
            fallbackTime: "09:32"
        )

        XCTAssertEqual(rendered, "普通文本消息")
    }

    func testRewriteMessageAcceptsRevokeXmlAndReplaceMsg() throws {
        let rendered = try rewriteMessage(
            original: "张三撤回了一条消息",
            phrase: "已拦截 {from} 撤回的一条消息",
            newMsgId: 48,
            xml: "<sysmsg><revokemsg><newmsgid>48</newmsgid></revokemsg></sysmsg>",
            msgType: 10002,
            fallbackTime: "09:32"
        )

        XCTAssertEqual(rendered, "已拦截 张三 撤回的一条消息")
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

    private func rewriteMessage(
        original: String,
        phrase: String,
        newMsgId: UInt64,
        xml: String?,
        msgType: UInt32,
        fallbackTime: String
    ) throws -> String {
        let pointer: UnsafeMutablePointer<CChar>?
        if let xml {
            pointer = xml.withCString { xmlPointer in
                wechat_antirecall_rewrite_revoke_message_copy(
                    original,
                    phrase,
                    newMsgId,
                    xmlPointer,
                    msgType,
                    fallbackTime
                )
            }
        } else {
            pointer = wechat_antirecall_rewrite_revoke_message_copy(original, phrase, newMsgId, nil, msgType, fallbackTime)
        }

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

    private func makeExecutableStubBuffer() throws -> (baseAddress: UnsafeMutableRawPointer, length: Int) {
        let pageSize = Int(getpagesize())
        guard let baseAddress = mmap(nil, pageSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
              baseAddress != MAP_FAILED
        else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let instructions = baseAddress.bindMemory(to: UInt32.self, capacity: 4)
        instructions[0] = 0x90000008
        instructions[1] = 0xF9400000 | 8 | (8 << 5) | (0x10 << 10)
        instructions[2] = 0xB4000000 | (2 << 5) | 8
        instructions[3] = 0xD61F0000 | (8 << 5)

        return (baseAddress, pageSize)
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

    private static func clockText(forUnixTimestamp timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
