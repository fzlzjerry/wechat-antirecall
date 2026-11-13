#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <functional>
#include <mutex>
#include <optional>
#include <os/log.h>
#include <string>
#include <vector>

#include "KeywordAlertInternal.h"
#include "MessageProbe.h"
#include "RedPacketPolicy.hpp"
#include "WeChatAntiRecallRuntime.h"

// Opt-in local notifications for incoming text messages that contain a configured keyword,
// including chats WeChat itself keeps silent. Matching happens in WeChat's process and the
// message text is never written anywhere except the notification the user asked for.
namespace {

constexpr const char *runtimeVersion = "WeChatAntiRecallKeywordAlert:2";
constexpr const char *settingsKey = "WeChatAntiRecall_KeywordAlert";
constexpr size_t maximumKeywords = 20;
constexpr NSUInteger maximumKeywordLength = 32;
constexpr NSUInteger snippetMaximumCharacters = 80;
// "wxid_abc:\n" in front of a group message; real ids are short ASCII.
constexpr size_t senderPrefixMaximumBytes = 256;

struct Settings {
    bool enabled = false;
    std::vector<std::string> keywords;
};

struct Match {
    std::string keyword;
    std::string snippet;
};

NSString *nsString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
}

bool validKeyword(NSString *keyword) {
    if (![keyword isKindOfClass:NSString.class] || keyword.length == 0 || keyword.length > maximumKeywordLength) return false;
    NSString *trimmed = [keyword stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![trimmed isEqualToString:keyword]) return false;
    return [keyword rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

// A dictionary with a strict boolean `enabled` and an array of valid keywords. Anything
// else, including a single bad keyword, is invalid: the runtime then stays off instead of guessing.
std::optional<Settings> parseSettings(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return std::nullopt;
    NSDictionary *dictionary = value;
    id enabled = dictionary[@"enabled"];
    id keywords = dictionary[@"keywords"];
    if (![enabled isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)enabled) != CFBooleanGetTypeID() ||
        ![keywords isKindOfClass:NSArray.class] || [keywords count] > maximumKeywords) return std::nullopt;
    Settings settings;
    settings.enabled = [enabled boolValue];
    for (id keyword in keywords) {
        if (!validKeyword(keyword)) return std::nullopt;
        settings.keywords.emplace_back([(NSString *)keyword UTF8String]);
    }
    return settings;
}

Settings settingsFromValue(id value) {
    return parseSettings(value).value_or(Settings{});
}

Settings settingsFromPlist(NSString *path) {
    if (path.length == 0) return {};
    return settingsFromValue([NSDictionary dictionaryWithContentsOfFile:path][@(settingsKey)]);
}

Settings loadSettings() {
    @autoreleasepool {
        CFPropertyListRef value = CFPreferencesCopyAppValue(
            (__bridge CFStringRef)@(settingsKey), kCFPreferencesCurrentApplication);
        if (value != nullptr) {
            const Settings settings = settingsFromValue((__bridge id)value);
            CFRelease(value);
            return settings;
        }
        // The sandbox data home holds the same preferences; it is the fallback for a plist
        // that cfprefsd has not picked up.
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (bundle.length == 0) return {};
        return settingsFromPlist([NSHomeDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Library/Preferences/%@.plist", bundle]]);
    }
}

const uint64_t loadTime = static_cast<uint64_t>(std::time(nullptr));

// Settings are re-read at most once a second so a busy chat costs one lookup, not one
// per message. Messages created before the feature was switched on are never alerted:
// at launch the baseline is the time the runtime loaded, so offline history stays quiet.
struct Snapshot {
    Settings settings;
    uint64_t activated = 0;
};

Snapshot currentSnapshot() {
    static std::mutex mutex;
    static Snapshot snapshot;
    static uint64_t checkedAt = 0;
    static bool initialized = false;
    std::lock_guard<std::mutex> lock(mutex);
    const auto now = static_cast<uint64_t>(std::time(nullptr));
    if (initialized && now == checkedAt) return snapshot;
    Settings next = loadSettings();
    if (next.enabled && !snapshot.settings.enabled) snapshot.activated = initialized ? now : loadTime;
    snapshot.settings = std::move(next);
    checkedAt = now;
    initialized = true;
    return snapshot;
}

bool hasSuffix(const std::string &value, const char *suffix) {
    const size_t length = std::strlen(suffix);
    return value.size() >= length && value.compare(value.size() - length, length, suffix) == 0;
}

struct Text {
    std::string sender;  // empty when unknown or for a direct chat
    std::string body;
};

// Group messages arrive as "sender:\nbody"; a direct chat is the body alone, so a colon
// and newline inside a direct message must not be mistaken for a prefix.
Text splitContent(const std::string &from, const std::string &content) {
    if (hasSuffix(from, "@chatroom")) {
        const auto split = content.find(":\n");
        if (split != std::string::npos && split > 0 && split <= senderPrefixMaximumBytes &&
            content.find('\n') == split + 1) {
            return {content.substr(0, split), content.substr(split + 2)};
        }
    }
    return {"", content};
}

// One line, at most `snippetMaximumCharacters` composed characters, never cut inside one.
std::string snippetFrom(NSString *text) {
    NSString *flat = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    flat = [flat stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSUInteger end = 0;
    NSUInteger characters = 0;
    while (end < flat.length && characters < snippetMaximumCharacters) {
        end = NSMaxRange([flat rangeOfComposedCharacterSequenceAtIndex:end]);
        characters += 1;
    }
    NSString *cut = [flat substringToIndex:end];
    if (end < flat.length) cut = [cut stringByAppendingString:@"…"];
    return cut.UTF8String ?: "";
}

// The first configured keyword found in a text message. Case and full/half width are
// ignored so "ABC" and "ａｂｃ" both match "abc".
std::optional<Match> findMatch(uint32_t type, const std::string &from, const std::string &content,
                               const std::vector<std::string> &keywords) {
    if (type != 1 || keywords.empty() || from.empty()) return {};
    const Text text = splitContent(from, content);
    NSString *body = nsString(text.body);
    if (body == nil) return {};
    body = [body stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (body.length == 0) return {};
    for (const auto &keyword : keywords) {
        NSString *needle = nsString(keyword);
        if (needle.length == 0) continue;
        if ([body rangeOfString:needle options:NSCaseInsensitiveSearch | NSWidthInsensitiveSearch].location != NSNotFound) {
            return Match{keyword, snippetFrom(body)};
        }
    }
    return {};
}

// A message addressed to `account` that the account did not send itself (a message sent
// from another device is synced back with the account as sender).
bool addressedToOthers(const std::string &account, const std::string &from, const std::string &to,
                       const std::string &content) {
    if (account.empty() || to != account || from.empty() || from == account) return false;
    return splitContent(from, content).sender != account;
}

red_packet::Ledger &ledger() {
    static red_packet::Ledger value;
    return value;
}

// Posts the banner through WeChat's own notification identity. Authorization is requested
// on first use; a denial only logs a status. `stillValid` is re-checked on the main queue
// because the authorization round trip can outlast the freshness window or a settings change.
void deliver(const Match &match, std::function<bool()> stillValid) {
    @autoreleasepool {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        if (!center) {
            os_log_error(OS_LOG_DEFAULT, "[WeChatAntiRecall] keyword-alert: notification center unavailable");
            return;
        }
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = [NSString stringWithFormat:@"关键词提醒：%@", nsString(match.keyword) ?: @""];
        content.body = nsString(match.snippet) ?: @"";
        content.sound = [UNNotificationSound defaultSound];
        UNNotificationRequest *request = [UNNotificationRequest
            requestWithIdentifier:[@"wxar-keyword-" stringByAppendingString:NSUUID.UUID.UUIDString]
            content:content trigger:nil];
        void (^post)(void) = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!stillValid()) return;
                [center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
                    if (error) os_log_error(OS_LOG_DEFAULT, "[WeChatAntiRecall] keyword-alert: notification failed: %{public}@", error);
                }];
            });
        };
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *status) {
            switch (status.authorizationStatus) {
                case UNAuthorizationStatusAuthorized:
                case UNAuthorizationStatusProvisional:
                    post();
                    return;
                case UNAuthorizationStatusNotDetermined: {
                    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                                          completionHandler:^(BOOL granted, NSError *error) {
                        if (granted) post();
                        else os_log_info(OS_LOG_DEFAULT, "[WeChatAntiRecall] keyword-alert: notification authorization denied");
                        (void)error;
                    }];
                    return;
                }
                default:
                    os_log_info(OS_LOG_DEFAULT, "[WeChatAntiRecall] keyword-alert: notification authorization denied");
                    return;
            }
        }];
    }
}

char *copyCString(const std::string &value) {
    char *copy = static_cast<char *>(std::malloc(value.size() + 1));
    if (copy == nullptr) return nullptr;
    std::memcpy(copy, value.c_str(), value.size() + 1);
    return copy;
}

std::vector<std::string> splitLines(const char *joined) {
    std::vector<std::string> lines;
    if (joined == nullptr) return lines;
    std::string current;
    for (const char *cursor = joined; *cursor; ++cursor) {
        if (*cursor == '\n') { lines.push_back(current); current.clear(); }
        else current.push_back(*cursor);
    }
    if (!current.empty()) lines.push_back(current);
    return lines;
}

}  // namespace

void wechat_antirecall_keyword_alert_observe(void *message, int mode) {
    try {
        const Snapshot snapshot = currentSnapshot();
        if (!snapshot.settings.enabled) return;

        message_probe::Received received;
        if (!message_probe::readReceived(message, mode, received)) return;
        const auto now = static_cast<uint64_t>(std::time(nullptr));
        if (!red_packet::fresh(received.created, snapshot.activated, now)) return;
        const auto match = findMatch(received.type, received.from, received.content, snapshot.settings.keywords);
        if (!match) return;

        // WeChat's account lookup is only safe on the main queue, so the remaining checks
        // run there with everything copied out of the Message first.
        const auto created = received.created;
        const auto serverId = received.serverId;
        const auto from = received.from;
        const auto to = received.to;
        const auto content = received.content;
        const auto activated = snapshot.activated;
        const auto found = *match;
        dispatch_async(dispatch_get_main_queue(), ^{
            const auto current = currentSnapshot();
            if (!current.settings.enabled) return;
            const auto when = static_cast<uint64_t>(std::time(nullptr));
            if (!red_packet::fresh(created, activated, when)) return;
            if (!addressedToOthers(message_probe::currentAccount(), from, to, content)) return;
            if (serverId == 0 || !ledger().reserve(std::to_string(serverId), when)) return;
            deliver(found, [created, activated] {
                return currentSnapshot().settings.enabled &&
                    red_packet::fresh(created, activated, static_cast<uint64_t>(std::time(nullptr)));
            });
        });
    } catch (...) {
        os_log_error(OS_LOG_DEFAULT, "[WeChatAntiRecall] keyword-alert: observe failed");
    }
}

extern "C" {

const char *wechat_antirecall_keyword_alert_runtime_version(void) {
    return runtimeVersion;
}

// "on" or "off" on the first line, then one keyword per line. NULL when the stored value
// is not valid (the runtime treats that as off).
char *wechat_antirecall_keyword_alert_settings_for_plist_copy(const char *plistPath) {
    @autoreleasepool {
        if (plistPath == nullptr) return nullptr;
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:@(plistPath)];
        const auto settings = parseSettings(plist[@(settingsKey)]);
        if (!settings) return nullptr;
        std::string text = settings->enabled ? "on" : "off";
        for (const auto &keyword : settings->keywords) { text += "\n"; text += keyword; }
        return copyCString(text);
    }
}

// "keyword\nsnippet" for the first configured keyword found in a text message, or NULL.
char *wechat_antirecall_keyword_alert_match_copy(uint32_t type, const char *from, const char *content,
                                                 const char *keywordsOnePerLine) {
    @autoreleasepool {
        if (from == nullptr || content == nullptr) return nullptr;
        const auto match = findMatch(type, from, content, splitLines(keywordsOnePerLine));
        if (!match) return nullptr;
        return copyCString(match->keyword + "\n" + match->snippet);
    }
}

// 1 when the message is addressed to `account` and was not sent by it.
int wechat_antirecall_keyword_alert_addressed_to_others(const char *account, const char *from, const char *to,
                                                        const char *content) {
    if (account == nullptr || from == nullptr || to == nullptr || content == nullptr) return 0;
    return addressedToOthers(account, from, to, content) ? 1 : 0;
}

}  // extern "C"
