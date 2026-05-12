#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "WeChatAntiRecallRuntime.h"

namespace {

constexpr uintptr_t parseRevokeXMLHookSlot = 0x92da2c0;
constexpr uintptr_t parseRevokeXMLOriginalBody = 0x4764540;
constexpr ptrdiff_t revokeNewMsgIdOffset = 0x168;
constexpr ptrdiff_t revokeReplaceMsgOffset = 0x170;
constexpr NSUInteger revokeTipMaximumLength = 120;

using ParseRevokeXML = bool (*)(void *, std::string *, void *, uint32_t);

ParseRevokeXML originalParseRevokeXML = nullptr;

std::string trimCopy(const std::string &value) {
    const char *whitespace = " \t\r\n\"'";
    const auto start = value.find_first_not_of(whitespace);
    if (start == std::string::npos) {
        return "";
    }

    const auto end = value.find_last_not_of(whitespace);
    return value.substr(start, end - start + 1);
}

void replaceAll(std::string &value, const std::string &needle, const std::string &replacement) {
    if (needle.empty()) {
        return;
    }

    size_t position = 0;
    while ((position = value.find(needle, position)) != std::string::npos) {
        value.replace(position, needle.length(), replacement);
        position += replacement.length();
    }
}

bool hasSuffix(const std::string &value, const std::string &suffix) {
    return value.size() >= suffix.size() &&
        value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool hasPrefix(const std::string &value, const std::string &prefix) {
    return value.size() >= prefix.size() &&
        value.compare(0, prefix.size(), prefix) == 0;
}

bool isTargetWeChatDylibPath(const char *imageName) {
    if (imageName == nullptr) {
        return false;
    }

    return hasSuffix(std::string(imageName), "/Contents/Resources/wechat.dylib");
}

std::string extractSenderName(const std::string &originalTip) {
    const std::string chineseMarker = "撤回";
    auto position = originalTip.find(chineseMarker);
    if (position != std::string::npos) {
        return trimCopy(originalTip.substr(0, position));
    }

    const std::string englishMarker = " recalled ";
    position = originalTip.find(englishMarker);
    if (position != std::string::npos) {
        auto sender = trimCopy(originalTip.substr(0, position));
        if (sender == "You") {
            return "";
        }
        return sender;
    }

    return "";
}

std::vector<std::string> literalPartsForTemplate(const std::string &configuredPhrase) {
    static const std::string placeholder = "{from}";
    std::vector<std::string> parts;
    size_t cursor = 0;

    while (true) {
        const auto position = configuredPhrase.find(placeholder, cursor);
        if (position == std::string::npos) {
            parts.push_back(configuredPhrase.substr(cursor));
            return parts;
        }

        parts.push_back(configuredPhrase.substr(cursor, position - cursor));
        cursor = position + placeholder.size();
    }
}

bool matchesRenderedTemplate(const std::string &tip, const std::string &configuredPhrase) {
    const auto parts = literalPartsForTemplate(configuredPhrase);
    if (parts.size() <= 1) {
        return tip == configuredPhrase;
    }

    if (!parts.front().empty() && !hasPrefix(tip, parts.front())) {
        return false;
    }
    if (!parts.back().empty() && !hasSuffix(tip, parts.back())) {
        return false;
    }

    size_t cursor = parts.front().empty() ? 0 : parts.front().size();
    for (size_t index = 1; index < parts.size(); index += 1) {
        const auto &part = parts[index];
        if (part.empty()) {
            continue;
        }

        const auto position = tip.find(part, cursor);
        if (position == std::string::npos) {
            return false;
        }
        cursor = position + part.size();
    }

    return true;
}

std::string normalizeRenderedTip(const std::string &tip, const std::string &configuredPhrase) {
    auto normalized = tip;
    const auto parts = literalPartsForTemplate(configuredPhrase);
    if (parts.size() <= 1 || parts.front().empty()) {
        return normalized;
    }

    const auto &prefix = parts.front();
    while (hasPrefix(normalized, prefix + prefix)) {
        auto candidate = normalized.substr(prefix.size());
        if (!matchesRenderedTemplate(candidate, configuredPhrase)) {
            break;
        }
        normalized = candidate;
    }

    return normalized;
}

std::string renderRevokeTip(const std::string &originalTip, const std::string &configuredPhrase) {
    if (configuredPhrase.empty()) {
        return originalTip;
    }

    if (matchesRenderedTemplate(originalTip, configuredPhrase)) {
        return normalizeRenderedTip(originalTip, configuredPhrase);
    }

    auto rendered = configuredPhrase;
    replaceAll(rendered, "{from}", extractSenderName(originalTip));
    return rendered;
}

NSString *revokeTipPreferenceKey() {
    return @"WeChatAntiRecall_RevokeTipPhrase";
}

NSString *defaultRevokeTipPhrase() {
    return @"已拦截一条撤回消息";
}

NSString *validPhraseOrNil(NSString *phrase) {
    if (![phrase isKindOfClass:[NSString class]]) {
        return nil;
    }

    NSString *trimmed = [phrase stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || trimmed.length > revokeTipMaximumLength) {
        return nil;
    }
    if ([trimmed rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound) {
        return nil;
    }
    if ([trimmed containsString:@"]]>"]) {
        return nil;
    }
    return trimmed;
}

NSString *phraseFromDefaults(NSUserDefaults *defaults) {
    if (defaults == nil) {
        return nil;
    }

    return validPhraseOrNil([defaults stringForKey:revokeTipPreferenceKey()]);
}

NSString *phraseFromPlist(NSString *plistPath) {
    if (plistPath.length == 0) {
        return nil;
    }

    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    id phrase = preferences[revokeTipPreferenceKey()];
    if (![phrase isKindOfClass:[NSString class]]) {
        return nil;
    }
    return validPhraseOrNil((NSString *)phrase);
}

NSArray<NSString *> *preferencePlistPaths(NSString *homeDirectory) {
    if (homeDirectory.length == 0) {
        return @[];
    }

    return @[
        [homeDirectory stringByAppendingPathComponent:@"Library/Preferences/com.tencent.xinWeChat.plist"],
        [homeDirectory stringByAppendingPathComponent:@"Library/Containers/com.tencent.xinWeChat/Data/Library/Preferences/com.tencent.xinWeChat.plist"],
    ];
}

NSString *phraseFromPreferencePlists(NSString *homeDirectory) {
    for (NSString *plistPath in preferencePlistPaths(homeDirectory)) {
        NSString *phrase = phraseFromPlist(plistPath);
        if (phrase != nil) {
            return phrase;
        }
    }
    return nil;
}

NSString *configuredPhraseForHomeDirectory(NSString *homeDirectory) {
    NSString *phrase = phraseFromDefaults([NSUserDefaults standardUserDefaults]);
    if (phrase != nil) {
        return phrase;
    }

    NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.tencent.xinWeChat"];
    phrase = phraseFromDefaults(suiteDefaults);
    if (phrase != nil) {
        return phrase;
    }

    NSString *home = homeDirectory.length > 0 ? homeDirectory : NSHomeDirectory();
    phrase = phraseFromPreferencePlists(home);
    if (phrase != nil) {
        return phrase;
    }

    return defaultRevokeTipPhrase();
}

NSString *configuredPhraseFromPreferencePlistsForHomeDirectory(NSString *homeDirectory) {
    NSString *home = homeDirectory.length > 0 ? homeDirectory : NSHomeDirectory();
    NSString *phrase = phraseFromPreferencePlists(home);
    if (phrase != nil) {
        return phrase;
    }

    return defaultRevokeTipPhrase();
}

NSString *configuredPhrase() {
    return configuredPhraseForHomeDirectory(nil);
}

char *copyCString(const char *value) {
    if (value == nullptr) {
        return nullptr;
    }

    const size_t length = std::strlen(value);
    char *copy = static_cast<char *>(std::malloc(length + 1));
    if (copy == nullptr) {
        return nullptr;
    }
    std::memcpy(copy, value, length + 1);
    return copy;
}

char *copyNSString(NSString *value) {
    return copyCString([value UTF8String]);
}

bool hookedParseRevokeXML(void *message, std::string *xml, void *flag, uint32_t msgType) {
    if (originalParseRevokeXML == nullptr) {
        return false;
    }

    const bool result = originalParseRevokeXML(message, xml, flag, msgType);
    if (!result || message == nullptr) {
        return result;
    }

    auto *newMsgId = reinterpret_cast<uint64_t *>(reinterpret_cast<uint8_t *>(message) + revokeNewMsgIdOffset);
    auto *replaceMsg = reinterpret_cast<std::string *>(reinterpret_cast<uint8_t *>(message) + revokeReplaceMsgOffset);

    @autoreleasepool {
        const char *phrase = [configuredPhrase() UTF8String];
        if (phrase != nullptr) {
            *newMsgId = 0;
            replaceMsg->assign(renderRevokeTip(*replaceMsg, phrase));
        }
    }

    return result;
}

uintptr_t findWeChatDylibSlide() {
    const uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index += 1) {
        const char *imageName = _dyld_get_image_name(index);
        if (imageName == nullptr) {
            continue;
        }

        if (isTargetWeChatDylibPath(imageName)) {
            return static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(index));
        }
    }

    return 0;
}

bool writeHookSlot(void **slot, void *replacement) {
    const auto pageSize = static_cast<uintptr_t>(sysconf(_SC_PAGESIZE));
    const auto slotAddress = reinterpret_cast<uintptr_t>(slot);
    const auto pageStart = slotAddress & ~(pageSize - 1);

    const kern_return_t result = vm_protect(
        mach_task_self(),
        static_cast<vm_address_t>(pageStart),
        static_cast<vm_size_t>(pageSize),
        false,
        VM_PROT_READ | VM_PROT_WRITE
    );
    if (result != KERN_SUCCESS) {
        return false;
    }

    *slot = replacement;
    return true;
}

void installRevokeTipHook() {
    const uintptr_t slide = findWeChatDylibSlide();
    if (slide == 0) {
        return;
    }

    auto **hookSlot = reinterpret_cast<void **>(slide + parseRevokeXMLHookSlot);
    if (*hookSlot == reinterpret_cast<void *>(&hookedParseRevokeXML)) {
        return;
    }

    originalParseRevokeXML = reinterpret_cast<ParseRevokeXML>(slide + parseRevokeXMLOriginalBody);
    writeHookSlot(hookSlot, reinterpret_cast<void *>(&hookedParseRevokeXML));
}

} // namespace

char *wechat_antirecall_render_revoke_tip_copy(const char *originalTip, const char *configuredPhrase) {
    const std::string original = originalTip == nullptr ? "" : originalTip;
    const std::string phrase = configuredPhrase == nullptr ? "" : configuredPhrase;
    const auto rendered = renderRevokeTip(original, phrase);

    return copyCString(rendered.c_str());
}

char *wechat_antirecall_load_revoke_tip_phrase_for_home_copy(const char *homeDirectory) {
    @autoreleasepool {
        NSString *home = homeDirectory == nullptr ? nil : [NSString stringWithUTF8String:homeDirectory];
        return copyNSString(configuredPhraseFromPreferencePlistsForHomeDirectory(home));
    }
}

void wechat_antirecall_free(void *pointer) {
    std::free(pointer);
}

int wechat_antirecall_is_target_wechat_dylib_path(const char *imagePath) {
    return isTargetWeChatDylibPath(imagePath) ? 1 : 0;
}

__attribute__((constructor))
static void wechat_antirecall_runtime_init() {
    @autoreleasepool {
        installRevokeTipHook();
    }
}
