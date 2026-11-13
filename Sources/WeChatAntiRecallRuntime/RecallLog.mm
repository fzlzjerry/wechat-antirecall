#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <cerrno>
#include <fcntl.h>
#include <os/log.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <mutex>
#include <string>
#include <unordered_set>

#include "RecallLogInternal.h"
#include "WeChatAntiRecallRuntime.h"

// Opt-in log of intercepted recalls, one JSON object per line. WeChat is sandboxed, so
// NSHomeDirectory() is the app container and the CLI/GUI read the same file from
// ~/Library/Containers/<bundle>/Data/Library/Application Support/WeChatAntiRecall/.
namespace {

constexpr const char *runtimeVersion = "WeChatAntiRecallRecallLog:2";
constexpr const char *settingsKey = "WeChatAntiRecall_RecallLog";
constexpr const char *logFileName = "recall-log.jsonl";
constexpr const char *rotatedLogFileName = "recall-log.1.jsonl";
// The log rotates once into recall-log.1.jsonl, so at most about twice this is kept.
constexpr off_t defaultRotateBytes = 2 * 1024 * 1024;
constexpr size_t recentIdCapacity = 256;
constexpr size_t sessionMaximumBytes = 256;
constexpr size_t noticeMaximumBytes = 512;
constexpr size_t contentMaximumBytes = 512;

std::mutex recentMutex;
std::deque<std::string> recentOrder;
std::unordered_set<std::string> recentKeys;

std::string trimmed(const std::string &value) {
    const char *whitespace = " \t\r\n";
    const auto start = value.find_first_not_of(whitespace);
    if (start == std::string::npos) return "";
    return value.substr(start, value.find_last_not_of(whitespace) - start + 1);
}

std::string unescapeXMLEntities(std::string value) {
    static const std::pair<const char *, const char *> entities[] = {
        {"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&apos;", "'"}, {"&amp;", "&"},
    };
    for (const auto &entity : entities) {
        size_t position = 0;
        const size_t needleLength = std::strlen(entity.first);
        while ((position = value.find(entity.first, position)) != std::string::npos) {
            value.replace(position, needleLength, entity.second);
            position += std::strlen(entity.second);
        }
    }
    return value;
}

// Text of the first <tag>…</tag>, with a CDATA wrapper removed or entities decoded.
std::string tagText(const std::string &xml, const char *tag) {
    const std::string open = std::string("<") + tag + ">";
    const std::string close = std::string("</") + tag + ">";
    const auto start = xml.find(open);
    if (start == std::string::npos) return "";
    const auto valueStart = start + open.size();
    const auto end = xml.find(close, valueStart);
    if (end == std::string::npos) return "";
    const std::string raw = trimmed(xml.substr(valueStart, end - valueStart));
    static const std::string cdataOpen = "<![CDATA[";
    static const std::string cdataClose = "]]>";
    if (raw.size() >= cdataOpen.size() + cdataClose.size() &&
        raw.compare(0, cdataOpen.size(), cdataOpen) == 0 &&
        raw.compare(raw.size() - cdataClose.size(), cdataClose.size(), cdataClose) == 0) {
        return raw.substr(cdataOpen.size(), raw.size() - cdataOpen.size() - cdataClose.size());
    }
    return unescapeXMLEntities(raw);
}

bool parseDecimal(const std::string &value, uint64_t &result) {
    const std::string text = trimmed(value);
    if (text.empty()) return false;
    uint64_t parsed = 0;
    for (const char character : text) {
        if (character < '0' || character > '9') return false;
        const uint64_t digit = static_cast<uint64_t>(character - '0');
        if (parsed > (UINT64_MAX - digit) / 10) return false;
        parsed = parsed * 10 + digit;
    }
    result = parsed;
    return true;
}

// Cut on a UTF-8 code point boundary so truncation never produces invalid text.
std::string truncatedUTF8(const std::string &value, size_t maximumBytes) {
    if (value.size() <= maximumBytes) return value;
    size_t end = maximumBytes;
    while (end > 0 && (static_cast<unsigned char>(value[end]) & 0xc0) == 0x80) end -= 1;
    return value.substr(0, end) + "\xE2\x80\xA6";
}

NSString *jsonString(const std::string &value, size_t maximumBytes) {
    const std::string limited = truncatedUTF8(value, maximumBytes);
    NSString *string = [[NSString alloc] initWithBytes:limited.data()
                                                length:limited.size()
                                              encoding:NSUTF8StringEncoding];
    return string != nil ? string : @"<non-utf8>";
}

struct Event {
    uint64_t loggedAt = 0;
    bool hasCreateTime = false;
    uint64_t createTime = 0;
    std::string session;
    std::string msgId;
    std::string newMsgId;
    std::string notice;
    bool hasContent = false;
    std::string content;
};

std::string decimalOrEmpty(const std::string &value) {
    uint64_t parsed = 0;
    return parseDecimal(value, parsed) ? std::to_string(parsed) : "";
}

Event makeEvent(const std::string &xml, const std::string &notice, const std::string *content, uint64_t loggedAt) {
    Event event;
    event.loggedAt = loggedAt;
    event.session = tagText(xml, "session");
    event.msgId = decimalOrEmpty(tagText(xml, "msgid"));
    event.newMsgId = decimalOrEmpty(tagText(xml, "newmsgid"));
    event.notice = notice.empty() ? tagText(xml, "replacemsg") : notice;
    event.hasCreateTime = parseDecimal(tagText(xml, "createtime"), event.createTime);
    if (content != nullptr) {
        event.hasContent = true;
        event.content = *content;
    }
    return event;
}

NSData *encodeEvent(const Event &event) {
    NSMutableDictionary *object = [NSMutableDictionary dictionary];
    object[@"v"] = @1;
    object[@"loggedAt"] = @(event.loggedAt);
    object[@"createTime"] = event.hasCreateTime ? (id)@(event.createTime) : (id)[NSNull null];
    object[@"session"] = jsonString(event.session, sessionMaximumBytes);
    object[@"msgId"] = jsonString(event.msgId, 32);
    object[@"newMsgId"] = jsonString(event.newMsgId, 32);
    object[@"notice"] = jsonString(event.notice, noticeMaximumBytes);
    object[@"content"] = event.hasContent ? (id)jsonString(event.content, contentMaximumBytes) : (id)[NSNull null];
    // NSJSONSerialization escapes control characters, so one event is always one line.
    return [NSJSONSerialization dataWithJSONObject:object
                                           options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                             error:nil];
}

// True the first time an event is seen. WeChat can deliver the same revoke more than
// once (sync, retries), and the log should list each recall a single time.
bool claimEvent(const Event &event, const std::string &xml) {
    std::string key;
    if (!event.newMsgId.empty()) key = "n:" + event.newMsgId;
    else if (!event.msgId.empty()) key = "m:" + event.msgId;
    else key = "x:" + std::to_string(std::hash<std::string>{}(xml));

    std::lock_guard<std::mutex> lock(recentMutex);
    if (!recentKeys.insert(key).second) return false;
    recentOrder.push_back(key);
    while (recentOrder.size() > recentIdCapacity) {
        recentKeys.erase(recentOrder.front());
        recentOrder.pop_front();
    }
    return true;
}

bool appendLine(NSString *directory, NSData *line, off_t rotateBytes) {
    if (directory.length == 0 || line.length == 0) return false;
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:@{NSFilePosixPermissions: @0700}
                                                         error:&error]) {
        os_log_error(OS_LOG_DEFAULT, "[WeChatAntiRecall] recall-log: cannot create directory (%{public}@)", error.localizedDescription);
        return false;
    }

    const char *path = [directory stringByAppendingPathComponent:@(logFileName)].fileSystemRepresentation;
    const char *rotatedPath = [directory stringByAppendingPathComponent:@(rotatedLogFileName)].fileSystemRepresentation;
    struct stat info;
    if (lstat(path, &info) == 0) {
        if (!S_ISREG(info.st_mode)) return false;
        if (info.st_size >= rotateBytes) rename(path, rotatedPath);
    }

    const int descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        os_log_error(OS_LOG_DEFAULT, "[WeChatAntiRecall] recall-log: cannot open log (errno %d)", errno);
        return false;
    }
    NSMutableData *record = [line mutableCopy];
    [record appendBytes:"\n" length:1];
    // O_APPEND makes the single write atomic with respect to other appenders.
    const ssize_t written = write(descriptor, record.bytes, record.length);
    close(descriptor);
    return written == static_cast<ssize_t>(record.length);
}

NSString *productionDirectory() {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/WeChatAntiRecall"];
}

// The setting is a dictionary with a strict boolean `enabled`; anything else is off.
bool enabledFromValue(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return false;
    id enabled = ((NSDictionary *)value)[@"enabled"];
    return [enabled isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)enabled) == CFBooleanGetTypeID() &&
        [enabled boolValue];
}

bool enabledFromPlist(NSString *path) {
    if (path.length == 0) return false;
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    return enabledFromValue(plist[@(settingsKey)]);
}

bool loggingEnabled() {
    @autoreleasepool {
        CFPropertyListRef value = CFPreferencesCopyAppValue(
            (__bridge CFStringRef)@(settingsKey), kCFPreferencesCurrentApplication);
        if (value != nullptr) {
            const bool enabled = enabledFromValue((__bridge id)value);
            CFRelease(value);
            return enabled;
        }
        // Mirrors the other runtime settings: a plist in the sandbox data home is the fallback.
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (bundle.length == 0) return false;
        return enabledFromPlist([NSHomeDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Library/Preferences/%@.plist", bundle]]);
    }
}

dispatch_queue_t writerQueue() {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.wechat-antirecall.recall-log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

char *copyCString(const std::string &value) {
    char *copy = static_cast<char *>(std::malloc(value.size() + 1));
    if (copy == nullptr) return nullptr;
    std::memcpy(copy, value.c_str(), value.size() + 1);
    return copy;
}

const std::string *optionalString(const char *value, std::string &storage) {
    if (value == nullptr) return nullptr;
    storage = value;
    return &storage;
}

// Opt-in check, de-duplication and the background append, against an explicit directory.
void recordInto(NSString *directory, const std::string &xml, const std::string &notice, const std::string *content) {
    @autoreleasepool {
        if (!loggingEnabled()) return;
        const Event event = makeEvent(xml, notice, content, static_cast<uint64_t>(std::time(nullptr)));
        if (!claimEvent(event, xml)) return;
        NSData *line = encodeEvent(event);
        if (line == nil) return;
        dispatch_async(writerQueue(), ^{
            @autoreleasepool {
                appendLine(directory, line, defaultRotateBytes);
            }
        });
    }
}

}  // namespace

namespace recall_log {

void record(const std::string &xml, const std::string &notice, const std::string *content) {
    recordInto(productionDirectory(), xml, notice, content);
}

}  // namespace recall_log

extern "C" {

const char *wechat_antirecall_recall_log_runtime_version(void) {
    return runtimeVersion;
}

int wechat_antirecall_recall_log_enabled_for_plist(const char *plistPath) {
    @autoreleasepool {
        return plistPath != nullptr && enabledFromPlist(@(plistPath)) ? 1 : 0;
    }
}

char *wechat_antirecall_recall_log_encode_copy(
    const char *xml,
    const char *notice,
    const char *content,
    uint64_t loggedAt
) {
    @autoreleasepool {
        std::string contentStorage;
        const Event event = makeEvent(xml != nullptr ? xml : "", notice != nullptr ? notice : "",
                                      optionalString(content, contentStorage), loggedAt);
        NSData *line = encodeEvent(event);
        if (line == nil) return nullptr;
        return copyCString(std::string(static_cast<const char *>(line.bytes), line.length));
    }
}

int wechat_antirecall_recall_log_append_for_test(const char *directory, const char *line, uint64_t rotateBytes) {
    @autoreleasepool {
        if (directory == nullptr || line == nullptr) return 0;
        NSData *data = [NSData dataWithBytes:line length:std::strlen(line)];
        return appendLine(@(directory), data, static_cast<off_t>(rotateBytes)) ? 1 : 0;
    }
}

// Runs the production build + dedup + append path synchronously against `directory`.
int wechat_antirecall_recall_log_record_for_test(
    const char *directory,
    const char *xml,
    const char *notice,
    const char *content,
    uint64_t loggedAt
) {
    @autoreleasepool {
        if (directory == nullptr || xml == nullptr) return 0;
        std::string contentStorage;
        const std::string xmlText = xml;
        const Event event = makeEvent(xmlText, notice != nullptr ? notice : "",
                                      optionalString(content, contentStorage), loggedAt);
        if (!claimEvent(event, xmlText)) return 0;
        NSData *line = encodeEvent(event);
        return line != nil && appendLine(@(directory), line, defaultRotateBytes) ? 1 : 0;
    }
}

// Exercises the production path (real preference check, de-duplication, background write)
// against `directory`; call wechat_antirecall_recall_log_flush_for_test before reading it.
void wechat_antirecall_recall_log_observe_for_test(const char *directory, const char *xml, const char *notice, const char *content) {
    @autoreleasepool {
        if (directory == nullptr || xml == nullptr) return;
        std::string contentStorage;
        recordInto(@(directory), xml, notice != nullptr ? notice : "", optionalString(content, contentStorage));
    }
}

void wechat_antirecall_recall_log_flush_for_test(void) {
    dispatch_sync(writerQueue(), ^{});
}

void wechat_antirecall_recall_log_reset_for_test(void) {
    std::lock_guard<std::mutex> lock(recentMutex);
    recentOrder.clear();
    recentKeys.clear();
}

}  // extern "C"
