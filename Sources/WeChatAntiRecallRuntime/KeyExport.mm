#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <cerrno>
#include <cctype>
#include <fcntl.h>
#include <os/log.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

#include "KeyExportInternal.h"
#include "WeChatAntiRecallRuntime.h"

// Opt-in export of the SQLCipher raw keys WeChat 4.x keeps in its own heap, as the
// ASCII blobs WCDB derives: x'<64 hex key><32 hex salt>' (99 bytes). Database tools
// normally reach these with task_for_pid + memory scanning, which drags in ad-hoc
// re-signing and TCC prompts; this runtime already lives inside WeChat, so it scans
// mach_task_self() with no extra privileges and drops a snapshot the CLI can read.
// WeChat is sandboxed, so NSHomeDirectory() is the app container and the CLI reads
// the same file from ~/Library/Containers/<bundle>/Data/Library/Application Support/
// WeChatAntiRecall/keys.json.
namespace {

constexpr const char *runtimeVersion = "WeChatAntiRecallKeyExport:1";
constexpr const char *settingsKey = "WeChatAntiRecall_KeyExport";
constexpr const char *keysFileName = "keys.json";
// The raw key pattern: x' + 64 key hex + 32 salt hex + ' = 99 bytes.
constexpr size_t hexPatternLength = 96;
constexpr size_t patternTotalLength = hexPatternLength + 3;
constexpr size_t chunkSize = 2 * 1024 * 1024;
constexpr uint64_t scanIntervalSeconds = 30;
constexpr int64_t throttleAfterSuccessSeconds = 10 * 60;
constexpr int64_t throttleAfterAttemptSeconds = 60;
// VM_REGION_BASIC_INFO_COUNT_64 is 9. Hard-coded like the reference scanners: the
// count has its own historical quirk and must not be derived from sizeof.
constexpr mach_msg_type_number_t regionInfoCount = 9;

std::mutex throttleMutex;
int64_t lastAttemptAt = 0;
int64_t lastSuccessAt = 0;

dispatch_queue_t writerQueue() {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.wechat-antirecall.key-export", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

char *copyCString(const std::string &value) {
    char *copy = static_cast<char *>(std::malloc(value.size() + 1));
    if (copy == nullptr) return nullptr;
    std::memcpy(copy, value.c_str(), value.size() + 1);
    return copy;
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

bool exportEnabled() {
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

inline bool isHexDigit(uint8_t character) {
    return (character >= '0' && character <= '9') ||
        (character >= 'a' && character <= 'f') ||
        (character >= 'A' && character <= 'F');
}

// Finds every x'<96 hex>' blob in `buffer` and appends (key, salt) pairs, lowercased
// and deduplicated. Same matcher external scanners run against a foreign task; here
// it only ever sees our own address space.
void searchPattern(const uint8_t *buffer, size_t length,
                   std::vector<std::pair<std::string, std::string>> &results,
                   std::unordered_set<std::string> &seen) {
    if (length < patternTotalLength) return;
    size_t index = 0;
    while (index + patternTotalLength <= length) {
        if (buffer[index] != 'x' || buffer[index + 1] != '\'') {
            index += 1;
            continue;
        }
        const size_t hexStart = index + 2;
        bool allHex = true;
        for (size_t offset = 0; offset < hexPatternLength; offset += 1) {
            if (!isHexDigit(buffer[hexStart + offset])) {
                allHex = false;
                break;
            }
        }
        if (!allHex || buffer[hexStart + hexPatternLength] != '\'') {
            index += 1;
            continue;
        }
        std::string key(reinterpret_cast<const char *>(buffer + hexStart), 64);
        std::string salt(reinterpret_cast<const char *>(buffer + hexStart + 64), 32);
        for (char &character : key) {
            character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
        }
        for (char &character : salt) {
            character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
        }
        if (seen.insert(key + salt).second) {
            results.emplace_back(key, salt);
        }
        index += patternTotalLength;
    }
}

// Enumerates this task's readable-and-writable regions (the key blobs live on the
// heap) and pattern-matches them in chunks with a full-pattern overlap so a blob
// straddling a chunk boundary is never missed.
std::vector<std::pair<std::string, std::string>> scanSelfMemory() {
    std::vector<std::pair<std::string, std::string>> results;
    std::unordered_set<std::string> seen;
    mach_vm_address_t address = 0;
    while (true) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = regionInfoCount;
        mach_port_t objectName = 0;
        const kern_return_t status = mach_vm_region(
            mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
            reinterpret_cast<vm_region_info_t>(&info), &count, &objectName);
        if (status != KERN_SUCCESS) break;
        if (objectName != MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self(), objectName);
        }
        if (size != 0 && (info.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE)) {
            mach_vm_address_t cursor = address;
            const mach_vm_address_t end = address + size;
            while (cursor < end) {
                mach_vm_size_t readSize = end - cursor;
                if (readSize > chunkSize) readSize = chunkSize;
                vm_offset_t data = 0;
                mach_msg_type_number_t dataCount = 0;
                if (mach_vm_read(mach_task_self(), cursor, readSize, &data, &dataCount) == KERN_SUCCESS) {
                    searchPattern(reinterpret_cast<const uint8_t *>(data), dataCount, results, seen);
                    mach_vm_deallocate(mach_task_self(), data, dataCount);
                }
                cursor += readSize > patternTotalLength ? readSize - patternTotalLength : readSize;
            }
        }
        if (size == 0) break;
        address += size;
    }
    return results;
}

NSData *encodeKeys(const std::vector<std::pair<std::string, std::string>> &keys, uint64_t dumpedAt) {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:keys.size()];
    for (const auto &entry : keys) {
        [array addObject:@{
            @"key": @(entry.first.c_str()),
            @"salt": @(entry.second.c_str()),
        }];
    }
    NSDictionary *object = @{@"v": @1, @"dumpedAt": @(dumpedAt), @"keys": array};
    return [NSJSONSerialization dataWithJSONObject:object
                                           options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                             error:nil];
}

NSString *productionDirectory() {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/WeChatAntiRecall"];
}

// Atomic snapshot write: create the 0700 directory, write a unique temporary file
// (0600, never following symlinks) and rename it over keys.json, so a reader either
// sees the previous complete file or the new one.
bool writeKeysFile(NSString *directory, NSData *payload) {
    if (directory.length == 0 || payload.length == 0) return false;
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:@{NSFilePosixPermissions: @0700}
                                                         error:&error]) {
        os_log_error(OS_LOG_DEFAULT, "[WeChatAntiRecall] key-export: cannot create directory (%{public}@)", error.localizedDescription);
        return false;
    }

    NSString *temporaryName = [NSString stringWithFormat:@".keys.json.tmp.%d", getpid()];
    const char *temporaryPath = [directory stringByAppendingPathComponent:temporaryName].fileSystemRepresentation;
    const int descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        os_log_error(OS_LOG_DEFAULT, "[WeChatAntiRecall] key-export: cannot open temporary file (errno %d)", errno);
        return false;
    }
    const ssize_t written = write(descriptor, payload.bytes, payload.length);
    close(descriptor);
    if (written != static_cast<ssize_t>(payload.length)) {
        unlink(temporaryPath);
        return false;
    }

    const char *finalPath = [directory stringByAppendingPathComponent:@(keysFileName)].fileSystemRepresentation;
    if (rename(temporaryPath, finalPath) != 0) {
        os_log_error(OS_LOG_DEFAULT, "[WeChatAntiRecall] key-export: cannot replace keys.json (errno %d)", errno);
        unlink(temporaryPath);
        return false;
    }
    return true;
}

// Runs on writerQueue. Rescans only when the user opted in and the throttle lets us:
// a successful dump keeps the file fresh for ten minutes, a failed attempt is retried
// at most once a minute, and a disabled setting costs nothing but a preference read.
void scanAndWriteIfDue() {
    @autoreleasepool {
        const int64_t now = static_cast<int64_t>(std::time(nullptr));
        {
            std::lock_guard<std::mutex> lock(throttleMutex);
            if (now - lastSuccessAt < throttleAfterSuccessSeconds) return;
            if (now - lastAttemptAt < throttleAfterAttemptSeconds) return;
            lastAttemptAt = now;
        }
        if (!exportEnabled()) return;

        const auto keys = scanSelfMemory();
        NSData *payload = encodeKeys(keys, static_cast<uint64_t>(now));
        if (payload == nil) return;
        if (writeKeysFile(productionDirectory(), payload)) {
            std::lock_guard<std::mutex> lock(throttleMutex);
            lastSuccessAt = now;
        }
    }
}

}  // namespace

__attribute__((constructor))
static void wechat_antirecall_key_export_init() {
    // The timer only reads a preference and hands work to a serial queue, so it is
    // safe to arm from a constructor before WeChat initializes (unlike hooks that
    // depend on library load order). A long leeway lets the system coalesce fires.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, writerQueue());
    if (timer == nullptr) return;
    dispatch_source_set_timer(
        timer,
        dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(scanIntervalSeconds) * NSEC_PER_SEC),
        scanIntervalSeconds * NSEC_PER_SEC,
        5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            scanAndWriteIfDue();
        }
    });
    // Keep the source alive for the process lifetime (a released suspended or idle
    // source would never fire again).
    static dispatch_source_t retainedTimer = nullptr;
    retainedTimer = timer;
    dispatch_resume(timer);
}

extern "C" {

const char *wechat_antirecall_key_export_runtime_version(void) {
    return runtimeVersion;
}

int wechat_antirecall_key_export_enabled_for_plist(const char *plistPath) {
    @autoreleasepool {
        return plistPath != nullptr && enabledFromPlist(@(plistPath)) ? 1 : 0;
    }
}

// Pattern matcher on an explicit buffer, for unit tests.
char *wechat_antirecall_key_export_scan_buffer_for_test(const uint8_t *buffer, size_t length) {
    @autoreleasepool {
        if (buffer == nullptr && length != 0) return nullptr;
        std::vector<std::pair<std::string, std::string>> results;
        std::unordered_set<std::string> seen;
        searchPattern(buffer, length, results, seen);
        NSData *payload = encodeKeys(results, 0);
        if (payload == nil) return nullptr;
        return copyCString(std::string(static_cast<const char *>(payload.bytes), payload.length));
    }
}

// Full self-scan in the calling process (the offline test host), so tests can drop a
// pattern into their own heap and verify the real mach_vm_region/mach_vm_read path
// finds it end to end.
char *wechat_antirecall_key_export_scan_self_for_test(void) {
    @autoreleasepool {
        const auto keys = scanSelfMemory();
        NSData *payload = encodeKeys(keys, static_cast<uint64_t>(std::time(nullptr)));
        if (payload == nil) return nullptr;
        return copyCString(std::string(static_cast<const char *>(payload.bytes), payload.length));
    }
}

int wechat_antirecall_key_export_write_for_test(const char *directory, const char *json) {
    @autoreleasepool {
        if (directory == nullptr || json == nullptr) return 0;
        NSData *payload = [NSData dataWithBytes:json length:std::strlen(json)];
        return writeKeysFile(@(directory), payload) ? 1 : 0;
    }
}

int wechat_antirecall_key_export_reset_throttle_for_test(void) {
    std::lock_guard<std::mutex> lock(throttleMutex);
    lastAttemptAt = 0;
    lastSuccessAt = 0;
    return 1;
}

}  // extern "C"
