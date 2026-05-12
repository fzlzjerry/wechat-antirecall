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
char *wechat_antirecall_load_revoke_tip_phrase_for_home_copy(const char *homeDirectory);
void wechat_antirecall_clear_revoke_tip_time_cache(void);
int wechat_antirecall_is_target_wechat_dylib_path(const char *imagePath);
void wechat_antirecall_free(void *pointer);

#ifdef __cplusplus
}
#endif
