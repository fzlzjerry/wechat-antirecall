import XCTest
import WeChatAntiRecallRuntime

/// Tests for the inline-hook engine used on builds (e.g. 268849) whose
/// parseRevokeXML has no WeChat dispatch stub. The engine cannot be exercised
/// against a live WeChat from a unit test, so these validate the mechanism
/// (stub encoding, slot resolution, trampoline dispatch) in isolation.
final class InlineHookEngineTests: XCTestCase {

    /// The encoder must produce an `adrp x16 / ldr x16 / br x16` stub that the
    /// decoder resolves back to exactly the requested slot address, across a
    /// range of page deltas and in-page offsets.
    func testEncodeDecodeEntryStubRoundTrip() throws {
        let cases: [(entry: UInt64, slot: UInt64)] = [
            (0x488c4c4, 0x952bf00),   // the real 268849 entry/slot
            (0x10_0000, 0x10_0008),   // slot just after entry, same page +8
            (0x80_0000, 0x40_0f00),   // slot below entry (negative page delta)
            (0x1_0000_0000, 0x1_0000_2ff8),
        ]
        for c in cases {
            var bytes = [UInt8](repeating: 0, count: 12)
            let ok = wechat_antirecall_encode_entry_stub(c.entry, c.slot, &bytes)
            XCTAssertEqual(ok, 1, "encode failed for entry=\(c.entry) slot=\(c.slot)")
            let resolved = wechat_antirecall_decode_entry_stub_slot(&bytes, c.entry)
            XCTAssertEqual(resolved, c.slot, "round-trip mismatch for entry=\(c.entry)")
        }
    }

    /// The 268849 static patch bytes recorded in patches.json must be exactly what
    /// the encoder produces for entry 0x488c4c4 -> slot 0x952bf00, and must decode
    /// back to that slot. This ties the data file to the engine.
    func testEncoderMatchesRecorded268849StaticPatch() throws {
        var bytes = [UInt8](repeating: 0, count: 12)
        XCTAssertEqual(wechat_antirecall_encode_entry_stub(0x488c4c4, 0x952bf00, &bytes), 1)
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual(hex, "F06402F0108247F900021FD6")
        XCTAssertEqual(wechat_antirecall_decode_entry_stub_slot(&bytes, 0x488c4c4), 0x952bf00)
    }

    /// Non-stub bytes must not decode as a slot (guards against false positives that
    /// would make the runtime treat an unpatched entry as installed).
    func testDecodeRejectsNonStubBytes() throws {
        // original parseRevokeXML prologue: stp x24,x23,[sp,#-0x40]! ...
        var prologue: [UInt8] = [0xF8, 0x5F, 0xBC, 0xA9, 0xF6, 0x57, 0x01, 0xA9, 0xF4, 0x4F, 0x02, 0xA9]
        XCTAssertEqual(wechat_antirecall_decode_entry_stub_slot(&prologue, 0x488c4c4), 0)
    }

    /// End-to-end: build a fake target with the parseRevokeXML prologue, install the
    /// inline hook through the production engine, call it, and confirm the hook fired
    /// AND that invoking the captured original still runs the real body. The fake
    /// body returns 0x11; the hook adds 0x100, so a correct install yields 0x111.
    func testInlineHookSelfTestDispatchesThroughHookAndOriginal() throws {
        XCTAssertEqual(
            wechat_antirecall_inline_hook_selftest(), 1,
            "inline hook engine self-test failed: hook did not fire or original was not preserved"
        )
    }
}
