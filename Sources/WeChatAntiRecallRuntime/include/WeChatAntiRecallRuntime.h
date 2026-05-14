#pragma once

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
char *wechat_antirecall_rewrite_revoke_message_copy(
    const char *originalTip,
    const char *configuredPhrase,
    uint64_t newMsgId,
    const char *xml,
    uint32_t msgType,
    const char *fallbackTime
);
char *wechat_antirecall_load_revoke_tip_phrase_for_home_copy(const char *homeDirectory);
void wechat_antirecall_clear_revoke_tip_time_cache(void);
int wechat_antirecall_is_target_wechat_dylib_path(const char *imagePath);
uintptr_t wechat_antirecall_resolve_parse_revoke_xml_hook_slot(
    uintptr_t originalBodyAddress,
    uintptr_t imageStart,
    uintptr_t imageSize
);
int wechat_antirecall_try_write_hook_slot(void **slot, void *replacement);
int wechat_antirecall_is_address_range_readable(uintptr_t address, uintptr_t length);
void wechat_antirecall_free(void *pointer);

#ifdef __cplusplus
}
#endif
