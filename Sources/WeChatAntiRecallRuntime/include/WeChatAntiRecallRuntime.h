#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

char *wechat_antirecall_render_revoke_tip_copy(const char *originalTip, const char *configuredPhrase);
char *wechat_antirecall_render_revoke_tip_for_event_copy(
    const char *originalTip,
    const char *configuredPhrase,
    uint64_t newMsgId,
    const char *xml,
    const char *fallbackTime
);

// As above, but also substitutes {content} with the recalled message's preview (the
// text captured for the message on the receive path, or a type placeholder like
// "[图片]"). Pass NULL/empty for a cold-cache miss; {content} and a single leading
// separator are then stripped so the tip never ends on a dangling "撤回：".
char *wechat_antirecall_render_revoke_tip_for_event_with_content_copy(
    const char *originalTip,
    const char *configuredPhrase,
    uint64_t newMsgId,
    const char *xml,
    const char *fallbackTime,
    const char *contentPreview
);
char *wechat_antirecall_load_revoke_tip_phrase_for_home_copy(const char *homeDirectory);
char *wechat_antirecall_load_revoke_tip_phrase_for_home_and_bundle_copy(const char *homeDirectory, const char *bundleIdentifier);
void wechat_antirecall_clear_revoke_tip_time_cache(void);

// Recalled-content cache (newmsgid -> preview). The 269340/269341/269574/269575 receive-path hook fills it
// and the revoke hook reads it to substitute {content}. Exposed for unit testing the
// join and preview mapping without a running WeChat.
void wechat_antirecall_clear_revoke_content_cache(void);
void wechat_antirecall_remember_revoke_content_for_test(uint64_t newMsgId, const char *preview);
// Returns the cached preview for newMsgId (caller frees with wechat_antirecall_free), or
// NULL if absent. Test-only window into the cache the receive hook fills.
char *wechat_antirecall_lookup_revoke_content_for_test(uint64_t newMsgId);

// Build the cached preview for a received message: trimmed/truncated text for the
// plain-text type (1), or a localized type placeholder ("[图片]"/"[语音]"/…) for media. Caller
// owns the returned buffer (free with wechat_antirecall_free).
char *wechat_antirecall_content_preview_for_received_message_copy(uint32_t contentMsgType, const char *rawContent);

// Exercises the production Message-finalizer capture path with the same 269340/269341/269574/269575 field
// layout (serverId=+0xF8, msgType=+0x0C, content=+0x130).
void wechat_antirecall_capture_received_content_for_test(
    uint64_t serverId,
    uint32_t msgType,
    const char *rawContent
);
int wechat_antirecall_is_target_wechat_dylib_path(const char *imagePath);
uintptr_t wechat_antirecall_revoke_hook_original_body_for_build(const char *buildVersion);
int wechat_antirecall_should_inspect_revoke_message_fields(const char *xml);

// The newmsgid carried by a revoke XML (used to restore the id for self-recalls so
// they delete natively instead of leaving a duplicate kept line). Returns 0 if the
// XML carries no usable newmsgid. Exposed for unit testing the tag extraction.
uint64_t wechat_antirecall_revoke_newmsgid_from_xml(const char *xml);
uintptr_t wechat_antirecall_resolve_parse_revoke_xml_hook_slot(
    uintptr_t originalBodyAddress,
    uintptr_t imageStart,
    uintptr_t imageSize
);
int wechat_antirecall_is_address_range_readable(uintptr_t address, uintptr_t length);
void wechat_antirecall_free(void *pointer);

// Key export (KeyExport.mm). The runtime scans its own heap for WeChat 4.x SQLCipher
// raw keys (x'<64 hex key><32 hex salt>') and writes a snapshot the CLI can hand to
// local database readers, without task_for_pid or re-signing. Callers own the copy
// buffers returned below (free with wechat_antirecall_free).
const char *wechat_antirecall_key_export_runtime_version(void);
int wechat_antirecall_key_export_enabled_for_plist(const char *plistPath);
char *wechat_antirecall_key_export_scan_buffer_for_test(const uint8_t *buffer, size_t length);
char *wechat_antirecall_key_export_scan_self_for_test(void);
int wechat_antirecall_key_export_write_for_test(const char *directory, const char *json);
int wechat_antirecall_key_export_scan_and_write_for_test(const char *directory);
int wechat_antirecall_key_export_reset_throttle_for_test(void);

// Inline-hook engine (used for builds whose parseRevokeXML has no WeChat dispatch
// stub, e.g. 268849). Exposed for unit testing without a running WeChat.

// Encode the 3-instruction entry stub: adrp x16, SLOT ; ldr x16,[x16,#off] ; br x16.
// Writes 12 little-endian bytes into `out`. Returns 1 on success, 0 if SLOT is not
// reachable by adrp+unsigned-offset ldr from entryAddr.
int wechat_antirecall_encode_entry_stub(uint64_t entryAddr, uint64_t slotAddr, uint8_t out[12]);

// Decode the SLOT address that an entry stub (as above) resolves to. Returns 0 if
// the 12 bytes at `entry` are not a recognizable `adrp x16/ldr x16/br x16` stub.
uint64_t wechat_antirecall_decode_entry_stub_slot(const uint8_t *entry, uint64_t entryAddr);

// End-to-end self-test of the inline-hook engine WITHOUT WeChat: builds a fake
// target carrying the parseRevokeXML prologue, installs the inline hook through the
// exact production path (encode stub -> overwrite entry -> build trampoline ->
// write slot), calls it, and returns 1 iff the hook fired AND calling the captured
// original still runs the real body and returns its value. Returns 0 on any failure.
int wechat_antirecall_inline_hook_selftest(void);

// End-to-end test using the 269340/269341/269574/269575 Message-finalizer ldrb/cmp/ccmp prefix shape.
// Verifies that the trampoline preserves NZCV before jumping to the original b.eq.
int wechat_antirecall_message_capture_inline_hook_selftest(void);

// Offline checks: these never look up a WeChat service or send a request.
const char *wechat_antirecall_red_packet_runtime_version(void);
int wechat_antirecall_red_packet_parse(const char *xml);
int wechat_antirecall_red_packet_can_open(int code, int sender, int received, int status, int type, const char *timing);
int wechat_antirecall_red_packet_fresh(uint64_t created, uint64_t activated, uint64_t now);
int wechat_antirecall_red_packet_policy_selftest(void);
int wechat_antirecall_red_packet_native_abi_selftest(void);

// Recall log (opt-in). Offline helpers: they only touch the paths passed in.
const char *wechat_antirecall_recall_log_runtime_version(void);
// 1 iff the plist holds a WeChatAntiRecall_RecallLog dictionary with a strict boolean enabled=true.
int wechat_antirecall_recall_log_enabled_for_plist(const char *plistPath);
// One JSON line (no trailing newline) for a revoke XML; `content` may be NULL for "unknown".
// Caller frees with wechat_antirecall_free.
char *wechat_antirecall_recall_log_encode_copy(const char *xml, const char *notice, const char *content, uint64_t loggedAt);
int wechat_antirecall_recall_log_append_for_test(const char *directory, const char *line, uint64_t rotateBytes);
// Production build + de-duplicate + append, run synchronously against `directory`.
// Returns 1 iff a line was written, 0 for a duplicate or a failure.
int wechat_antirecall_recall_log_record_for_test(const char *directory, const char *xml, const char *notice, const char *content, uint64_t loggedAt);
// Production path including the real opt-in preference check, run against `directory`.
void wechat_antirecall_recall_log_observe_for_test(const char *directory, const char *xml, const char *notice, const char *content);
// Waits for pending background writes started by the observe call above.
void wechat_antirecall_recall_log_flush_for_test(void);
void wechat_antirecall_recall_log_reset_for_test(void);

// Keyword alert (opt-in). Offline helpers; none of them touch WeChat or the notification center.
const char *wechat_antirecall_keyword_alert_runtime_version(void);
// "on"/"off" on the first line, then one keyword per line; NULL if the plist value is invalid.
char *wechat_antirecall_keyword_alert_settings_for_plist_copy(const char *plistPath);
// "keyword\nsnippet" for the first keyword (one per line in `keywordsOnePerLine`) found in a
// text message (type 1), else NULL. Caller frees with wechat_antirecall_free.
char *wechat_antirecall_keyword_alert_match_copy(uint32_t type, const char *from, const char *content, const char *keywordsOnePerLine);
int wechat_antirecall_keyword_alert_addressed_to_others(const char *account, const char *from, const char *to, const char *content);

// Window privacy (opt-in). Offline helpers; the sweep runs one enforcement pass over windows
// the caller owns and must be called on the main thread.
const char *wechat_antirecall_window_privacy_runtime_version(void);
int wechat_antirecall_window_privacy_enabled_for_plist(const char *plistPath);
void wechat_antirecall_window_privacy_sweep_for_test(const void *const *windows, size_t count, int enabled);

#ifdef __cplusplus
}
#endif
