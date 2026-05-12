#pragma once

#ifdef __cplusplus
extern "C" {
#endif

char *wechat_antirecall_render_revoke_tip_copy(const char *originalTip, const char *configuredPhrase);
char *wechat_antirecall_load_revoke_tip_phrase_for_home_copy(const char *homeDirectory);
int wechat_antirecall_is_target_wechat_dylib_path(const char *imagePath);
void wechat_antirecall_free(void *pointer);

#ifdef __cplusplus
}
#endif
