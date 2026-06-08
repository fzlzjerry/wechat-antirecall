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
char *wechat_antirecall_load_revoke_tip_phrase_for_home_copy(const char *homeDirectory);
char *wechat_antirecall_load_revoke_tip_phrase_for_home_and_bundle_copy(const char *homeDirectory, const char *bundleIdentifier);
void wechat_antirecall_clear_revoke_tip_time_cache(void);
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

#ifdef __cplusplus
}
#endif
