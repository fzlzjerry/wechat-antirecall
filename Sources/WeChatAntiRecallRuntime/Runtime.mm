#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "WeChatAntiRecallRuntime.h"

namespace {

constexpr NSUInteger revokeTipMaximumLength = 120;
constexpr size_t revokeTimeCacheMaximumCount = 512;

struct RevokeHookConfig {
    const char *buildVersion;
    uintptr_t parseRevokeXMLOriginalBody;
    ptrdiff_t revokeNewMsgIdOffset;
    ptrdiff_t revokeReplaceMsgOffset;
};

constexpr RevokeHookConfig revokeHookConfigs[] = {
    {"268597", 0x4764540, 0x168, 0x170},
    {"268599", 0x47775cc, 0x168, 0x170},
};

using ParseRevokeXML = bool (*)(void *, std::string *, void *, uint32_t);

ParseRevokeXML originalParseRevokeXML = nullptr;
std::mutex revokeTimeCacheMutex;
std::unordered_map<std::string, std::string> revokeTimeCache;

NSString *mainBundleBuildVersion() {
    @autoreleasepool {
        id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
        return [value isKindOfClass:[NSString class]] ? static_cast<NSString *>(value) : nil;
    }
}

const RevokeHookConfig *revokeHookConfigForBuildVersionCString(const char *utf8) {
    if (utf8 == nullptr) {
        return nullptr;
    }

    for (const auto &config : revokeHookConfigs) {
        if (std::strcmp(config.buildVersion, utf8) == 0) {
            return &config;
        }
    }

    return nullptr;
}

const RevokeHookConfig *revokeHookConfigForBuildVersion(NSString *buildVersion) {
    if (buildVersion == nil) {
        return nullptr;
    }

    return revokeHookConfigForBuildVersionCString([buildVersion UTF8String]);
}

const RevokeHookConfig *currentRevokeHookConfig() {
    return revokeHookConfigForBuildVersion(mainBundleBuildVersion());
}

bool decodeADRPPage(uint32_t instruction, uintptr_t instructionAddress, uintptr_t &pageAddress) {
    if ((instruction & 0x9F000000) != 0x90000000) {
        return false;
    }

    int64_t imm = static_cast<int64_t>(((instruction >> 5) & 0x7ffff) << 2 | ((instruction >> 29) & 0x3));
    if ((imm & (1 << 20)) != 0) {
        imm -= (1 << 21);
    }

    pageAddress = (instructionAddress & ~static_cast<uintptr_t>(0xfff)) + (static_cast<uintptr_t>(imm) << 12);
    return true;
}

bool decodeLDRUnsignedImmediate64(uint32_t instruction, uint32_t &targetRegister, uint32_t &baseRegister, uintptr_t &offset) {
    if ((instruction & 0xFFC00000) != 0xF9400000) {
        return false;
    }

    targetRegister = instruction & 0x1f;
    baseRegister = (instruction >> 5) & 0x1f;
    offset = static_cast<uintptr_t>((instruction >> 10) & 0xfff) << 3;
    return true;
}

bool decodeCBZTarget64(uint32_t instruction, uintptr_t instructionAddress, uint32_t &targetRegister, uintptr_t &targetAddress) {
    if ((instruction & 0xFF000000) != 0xB4000000) {
        return false;
    }

    int64_t imm = static_cast<int64_t>((instruction >> 5) & 0x7ffff);
    if ((imm & (1 << 18)) != 0) {
        imm -= (1 << 19);
    }

    targetRegister = instruction & 0x1f;
    targetAddress = instructionAddress + static_cast<uintptr_t>(imm << 2);
    return true;
}

bool isBranchRegister(uint32_t instruction, uint32_t targetRegister) {
    return instruction == (0xD61F0000 | (targetRegister << 5));
}

bool checkedRangeEnd(uintptr_t start, size_t length, uintptr_t &end) {
    if (length == 0 || start > UINTPTR_MAX - length) {
        return false;
    }

    end = start + length;
    return true;
}

bool rangeContains(uintptr_t outerStart, size_t outerLength, uintptr_t innerStart, size_t innerLength) {
    uintptr_t outerEnd = 0;
    uintptr_t innerEnd = 0;
    if (!checkedRangeEnd(outerStart, outerLength, outerEnd) ||
        !checkedRangeEnd(innerStart, innerLength, innerEnd)) {
        return false;
    }

    return innerStart >= outerStart && innerEnd <= outerEnd;
}

bool isAddressRangeReadable(uintptr_t address, size_t length) {
    uintptr_t end = 0;
    if (!checkedRangeEnd(address, length, end)) {
        return false;
    }

    mach_vm_address_t cursor = static_cast<mach_vm_address_t>(address);
    while (cursor < end) {
        const uintptr_t requested = static_cast<uintptr_t>(cursor);
        mach_vm_size_t regionSize = 0;
        vm_region_basic_info_data_64_t info = {};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t objectName = MACH_PORT_NULL;
        mach_vm_address_t regionAddress = cursor;
        const kern_return_t result = mach_vm_region(
            mach_task_self(),
            &regionAddress,
            &regionSize,
            VM_REGION_BASIC_INFO_64,
            reinterpret_cast<vm_region_info_t>(&info),
            &count,
            &objectName
        );

        if (objectName != MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self(), objectName);
        }
        uintptr_t regionEnd = 0;
        if (result != KERN_SUCCESS ||
            !checkedRangeEnd(static_cast<uintptr_t>(regionAddress), static_cast<size_t>(regionSize), regionEnd) ||
            static_cast<uintptr_t>(regionAddress) > requested ||
            requested >= regionEnd ||
            (info.protection & VM_PROT_READ) == 0) {
            return false;
        }

        if (regionEnd >= end) {
            return true;
        }
        cursor = static_cast<mach_vm_address_t>(regionEnd);
    }

    return true;
}

bool imageAddressRangeForHeader(const mach_header *header, intptr_t slide, uintptr_t &imageStart, size_t &imageSize) {
    if (header == nullptr || header->magic != MH_MAGIC_64) {
        return false;
    }

    const auto *header64 = reinterpret_cast<const mach_header_64 *>(header);
    const uint8_t *cursor = reinterpret_cast<const uint8_t *>(header64) + sizeof(mach_header_64);
    uintptr_t lowest = UINTPTR_MAX;
    uintptr_t highest = 0;

    for (uint32_t index = 0; index < header64->ncmds; index += 1) {
        const auto *command = reinterpret_cast<const load_command *>(cursor);
        if (command->cmd == LC_SEGMENT_64) {
            const auto *segment = reinterpret_cast<const segment_command_64 *>(cursor);
            if (segment->vmsize != 0) {
                const uintptr_t start = static_cast<uintptr_t>(slide + segment->vmaddr);
                const uintptr_t end = start + static_cast<uintptr_t>(segment->vmsize);
                lowest = std::min(lowest, start);
                highest = std::max(highest, end);
            }
        }
        cursor += command->cmdsize;
    }

    if (lowest == UINTPTR_MAX || highest <= lowest) {
        return false;
    }

    imageStart = lowest;
    imageSize = highest - lowest;
    return true;
}

uintptr_t resolveParseRevokeXMLHookSlotInImage(uintptr_t originalBodyAddress, uintptr_t imageStart, size_t imageSize) {
    if (originalBodyAddress < 16 || imageSize == 0) {
        return 0;
    }

    const uintptr_t stubAddress = originalBodyAddress - 16;
    if (!rangeContains(imageStart, imageSize, stubAddress, sizeof(uint32_t) * 4) ||
        !isAddressRangeReadable(stubAddress, sizeof(uint32_t) * 4)) {
        return 0;
    }

    const auto *instructions = reinterpret_cast<const uint32_t *>(stubAddress);

    uintptr_t pageAddress = 0;
    if (!decodeADRPPage(instructions[0], stubAddress, pageAddress)) {
        return 0;
    }

    uint32_t ldrTargetRegister = 0;
    uint32_t ldrBaseRegister = 0;
    uintptr_t ldrOffset = 0;
    if (!decodeLDRUnsignedImmediate64(instructions[1], ldrTargetRegister, ldrBaseRegister, ldrOffset)) {
        return 0;
    }

    uintptr_t cbzTarget = 0;
    uint32_t cbzRegister = 0;
    if (!decodeCBZTarget64(instructions[2], stubAddress + 8, cbzRegister, cbzTarget)) {
        return 0;
    }

    if (ldrTargetRegister != ldrBaseRegister || cbzRegister != ldrTargetRegister || cbzTarget != originalBodyAddress) {
        return 0;
    }

    if (!isBranchRegister(instructions[3], ldrTargetRegister)) {
        return 0;
    }

    const uintptr_t hookSlot = pageAddress + ldrOffset;
    if (!rangeContains(imageStart, imageSize, hookSlot, sizeof(void *)) ||
        !isAddressRangeReadable(hookSlot, sizeof(void *))) {
        return 0;
    }

    return hookSlot;
}

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

bool isDigit(char character) {
    return character >= '0' && character <= '9';
}

bool isClockTextAt(const std::string &value, size_t position) {
    return position + 5 <= value.size() &&
        isDigit(value[position]) &&
        isDigit(value[position + 1]) &&
        value[position + 2] == ':' &&
        isDigit(value[position + 3]) &&
        isDigit(value[position + 4]);
}

size_t findTimeMarker(const std::string &value, size_t cursor) {
    const std::string marker = " 于 ";
    while (true) {
        const auto position = value.find(marker, cursor);
        if (position == std::string::npos) {
            return std::string::npos;
        }

        if (isClockTextAt(value, position + marker.size())) {
            return position;
        }
        cursor = position + marker.size();
    }
}

std::string collapseDuplicateTimeMarkers(std::string value) {
    const std::string marker = " 于 ";
    size_t cursor = 0;

    while (true) {
        const auto first = findTimeMarker(value, cursor);
        if (first == std::string::npos) {
            return value;
        }

        const auto firstEnd = first + marker.size() + 5;
        const auto second = findTimeMarker(value, firstEnd);
        const auto revoke = value.find(" 撤回", firstEnd);
        if (second != std::string::npos && (revoke == std::string::npos || second < revoke)) {
            value.erase(second, marker.size() + 5);
            cursor = firstEnd;
            continue;
        }

        cursor = firstEnd;
    }
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

bool looksLikeKnownRenderedTip(const std::string &tip) {
    return hasPrefix(tip, "已拦截") && tip.find("撤回") != std::string::npos;
}

bool looksLikeSourceRevokeTip(const std::string &tip) {
    return tip.find("撤回") != std::string::npos
        || tip.find(" recalled ") != std::string::npos
        || tip.find("recalled a message") != std::string::npos;
}

const std::vector<std::string> &revokeTipPlaceholders() {
    static const std::vector<std::string> placeholders = {
        "{from}",
        "{time}",
    };
    return placeholders;
}

std::vector<std::string> literalPartsForTemplate(const std::string &configuredPhrase) {
    std::vector<std::string> parts;
    size_t cursor = 0;

    while (true) {
        size_t nextPosition = std::string::npos;
        size_t nextLength = 0;
        for (const auto &placeholder : revokeTipPlaceholders()) {
            const auto position = configuredPhrase.find(placeholder, cursor);
            if (position != std::string::npos && (nextPosition == std::string::npos || position < nextPosition)) {
                nextPosition = position;
                nextLength = placeholder.size();
            }
        }

        if (nextPosition == std::string::npos) {
            parts.push_back(configuredPhrase.substr(cursor));
            return parts;
        }

        parts.push_back(configuredPhrase.substr(cursor, nextPosition - cursor));
        cursor = nextPosition + nextLength;
    }
}

bool matchesRenderedTemplate(const std::string &tip, const std::string &configuredPhrase) {
    const auto parts = literalPartsForTemplate(configuredPhrase);
    if (parts.size() <= 1) {
        return tip == configuredPhrase;
    }

    bool hasLiteralPart = false;
    for (const auto &part : parts) {
        if (!part.empty()) {
            hasLiteralPart = true;
            break;
        }
    }
    if (!hasLiteralPart) {
        return !looksLikeSourceRevokeTip(tip);
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
        return collapseDuplicateTimeMarkers(normalized);
    }

    const auto &prefix = parts.front();
    while (hasPrefix(normalized, prefix + prefix)) {
        auto candidate = normalized.substr(prefix.size());
        if (!matchesRenderedTemplate(candidate, configuredPhrase)) {
            break;
        }
        normalized = candidate;
    }

    return collapseDuplicateTimeMarkers(normalized);
}

std::string currentTimeText() {
    @autoreleasepool {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"HH:mm";
        NSString *value = [formatter stringFromDate:[NSDate date]];
        const char *utf8 = [value UTF8String];
        return utf8 == nullptr ? "" : std::string(utf8);
    }
}

bool parseUnsignedInteger(const std::string &value, uint64_t &result) {
    const auto trimmed = trimCopy(value);
    if (trimmed.empty()) {
        return false;
    }

    uint64_t parsed = 0;
    for (const char character : trimmed) {
        if (character < '0' || character > '9') {
            return false;
        }

        const uint64_t digit = static_cast<uint64_t>(character - '0');
        if (parsed > (UINT64_MAX - digit) / 10) {
            return false;
        }
        parsed = parsed * 10 + digit;
    }

    result = parsed;
    return true;
}

std::string xmlTagValue(const std::string &xml, const std::string &tagName) {
    const auto startTag = "<" + tagName + ">";
    const auto endTag = "</" + tagName + ">";
    const auto start = xml.find(startTag);
    if (start == std::string::npos) {
        return "";
    }

    const auto valueStart = start + startTag.size();
    const auto end = xml.find(endTag, valueStart);
    if (end == std::string::npos) {
        return "";
    }

    return xml.substr(valueStart, end - valueStart);
}

std::string formatUnixTimestamp(uint64_t timestamp) {
    if (timestamp > 10'000'000'000ULL) {
        timestamp /= 1000;
    }

    @autoreleasepool {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:static_cast<NSTimeInterval>(timestamp)];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"HH:mm";
        NSString *value = [formatter stringFromDate:date];
        const char *utf8 = [value UTF8String];
        return utf8 == nullptr ? "" : std::string(utf8);
    }
}

std::string timeTextFromXML(const std::string *xml) {
    if (xml == nullptr || xml->empty()) {
        return "";
    }

    static const std::vector<std::string> timeTags = {
        "createtime",
        "createTime",
        "CreateTime",
        "time",
    };

    for (const auto &tag : timeTags) {
        uint64_t timestamp = 0;
        if (parseUnsignedInteger(xmlTagValue(*xml, tag), timestamp)) {
            return formatUnixTimestamp(timestamp);
        }
    }

    return "";
}

std::string revokeTimeCacheKey(uint64_t newMsgId, const std::string *xml, const std::string &originalTip) {
    if (newMsgId != 0) {
        return "id:" + std::to_string(newMsgId);
    }
    if (xml != nullptr && !xml->empty()) {
        return "xml:" + std::to_string(std::hash<std::string>{}(*xml));
    }
    return "tip:" + std::to_string(std::hash<std::string>{}(originalTip));
}

std::string stableRevokeTimeText(
    uint64_t newMsgId,
    const std::string *xml,
    const std::string &originalTip,
    const std::string &fallbackTime
) {
    const auto xmlTime = timeTextFromXML(xml);
    if (!xmlTime.empty()) {
        return xmlTime;
    }

    const auto key = revokeTimeCacheKey(newMsgId, xml, originalTip);
    std::lock_guard<std::mutex> lock(revokeTimeCacheMutex);

    const auto found = revokeTimeCache.find(key);
    if (found != revokeTimeCache.end()) {
        return found->second;
    }

    if (revokeTimeCache.size() >= revokeTimeCacheMaximumCount) {
        revokeTimeCache.clear();
    }

    revokeTimeCache[key] = fallbackTime;
    return fallbackTime;
}

void replaceTimePlaceholder(std::string &rendered, const std::string &timeText) {
    if (!timeText.empty()) {
        replaceAll(rendered, "{time}", timeText);
        return;
    }

    static const std::vector<std::string> emptyTimePatterns = {
        " 于 {time}",
        " 于{time}",
        "于 {time}",
        "于{time}",
    };

    for (const auto &pattern : emptyTimePatterns) {
        const auto position = rendered.find(pattern);
        if (position != std::string::npos) {
            rendered.erase(position, pattern.size());
            break;
        }
    }

    replaceAll(rendered, "{time}", "");
}

std::string renderRevokeTip(
    const std::string &originalTip,
    const std::string &configuredPhrase,
    const std::string &timeText
) {
    if (configuredPhrase.empty()) {
        return originalTip;
    }

    if (matchesRenderedTemplate(originalTip, configuredPhrase)) {
        return normalizeRenderedTip(originalTip, configuredPhrase);
    }
    if (looksLikeKnownRenderedTip(originalTip)) {
        return collapseDuplicateTimeMarkers(originalTip);
    }

    auto rendered = configuredPhrase;
    replaceAll(rendered, "{from}", extractSenderName(originalTip));
    replaceTimePlaceholder(rendered, timeText);
    return rendered;
}

std::string renderRevokeTip(const std::string &originalTip, const std::string &configuredPhrase) {
    return renderRevokeTip(originalTip, configuredPhrase, currentTimeText());
}

NSString *revokeTipPreferenceKey() {
    return @"WeChatAntiRecall_RevokeTipPhrase";
}

NSString *revokeTipDebugProbePreferenceKey() {
    return @"WeChatAntiRecall_RevokeTipDebugProbe";
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

NSNumber *probeFlagFromValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return (NSNumber *)value;
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSString *normalized = [(NSString *)value lowercaseString];
        if ([normalized isEqualToString:@"1"] || [normalized isEqualToString:@"true"] || [normalized isEqualToString:@"yes"] || [normalized isEqualToString:@"on"]) {
            return @YES;
        }
        if ([normalized isEqualToString:@"0"] || [normalized isEqualToString:@"false"] || [normalized isEqualToString:@"no"] || [normalized isEqualToString:@"off"]) {
            return @NO;
        }
    }

    return nil;
}

NSNumber *probeFlagFromDefaults(NSUserDefaults *defaults) {
    if (defaults == nil) {
        return nil;
    }

    return probeFlagFromValue([defaults objectForKey:revokeTipDebugProbePreferenceKey()]);
}

NSNumber *probeFlagFromPlist(NSString *plistPath) {
    if (plistPath.length == 0) {
        return nil;
    }

    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    return probeFlagFromValue(preferences[revokeTipDebugProbePreferenceKey()]);
}

NSArray<NSString *> *preferencePlistPaths(NSString *homeDirectory) {
    if (homeDirectory.length == 0) {
        return @[];
    }

    NSString *sandboxDataSuffix = @"Library/Containers/com.tencent.xinWeChat/Data";
    if ([homeDirectory hasSuffix:sandboxDataSuffix]) {
        return @[
            [homeDirectory stringByAppendingPathComponent:@"Library/Preferences/com.tencent.xinWeChat.plist"],
        ];
    }

    return @[
        [homeDirectory stringByAppendingPathComponent:@"Library/Containers/com.tencent.xinWeChat/Data/Library/Preferences/com.tencent.xinWeChat.plist"],
        [homeDirectory stringByAppendingPathComponent:@"Library/Preferences/com.tencent.xinWeChat.plist"],
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

NSNumber *probeFlagFromPreferencePlists(NSString *homeDirectory) {
    for (NSString *plistPath in preferencePlistPaths(homeDirectory)) {
        NSNumber *probeEnabled = probeFlagFromPlist(plistPath);
        if (probeEnabled != nil) {
            return probeEnabled;
        }
    }
    return nil;
}

NSString *configuredPhraseForHomeDirectory(NSString *homeDirectory) {
    NSString *home = homeDirectory.length > 0 ? homeDirectory : NSHomeDirectory();
    NSString *phrase = phraseFromPreferencePlists(home);
    if (phrase != nil) {
        return phrase;
    }

    NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.tencent.xinWeChat"];
    phrase = phraseFromDefaults(suiteDefaults);
    if (phrase != nil) {
        return phrase;
    }

    phrase = phraseFromDefaults([NSUserDefaults standardUserDefaults]);
    if (phrase != nil) {
        return phrase;
    }

    return defaultRevokeTipPhrase();
}

bool debugProbeEnabledForHomeDirectory(NSString *homeDirectory) {
    NSString *home = homeDirectory.length > 0 ? homeDirectory : NSHomeDirectory();
    NSNumber *probeEnabled = probeFlagFromPreferencePlists(home);
    if (probeEnabled != nil) {
        return [probeEnabled boolValue];
    }

    NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.tencent.xinWeChat"];
    probeEnabled = probeFlagFromDefaults(suiteDefaults);
    if (probeEnabled != nil) {
        return [probeEnabled boolValue];
    }

    probeEnabled = probeFlagFromDefaults([NSUserDefaults standardUserDefaults]);
    if (probeEnabled != nil) {
        return [probeEnabled boolValue];
    }

    return false;
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

bool debugProbeEnabled() {
    return debugProbeEnabledForHomeDirectory(nil);
}

std::string previewString(const std::string &value) {
    auto preview = value;
    replaceAll(preview, "\n", "\\n");
    replaceAll(preview, "\r", "\\r");

    constexpr size_t maximumLength = 512;
    if (preview.size() > maximumLength) {
        preview = preview.substr(0, maximumLength) + "...";
    }
    return preview;
}

NSString *nsStringFromStdString(const std::string &value) {
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string == nil ? @"<non-utf8>" : string;
}

void logRevokeProbe(uint32_t msgType, uint64_t newMsgId, const std::string &replaceMsg, const std::string *xml) {
    @autoreleasepool {
        NSString *replacePreview = nsStringFromStdString(previewString(replaceMsg));
        NSString *xmlPreview = xml == nullptr ? @"<nil>" : nsStringFromStdString(previewString(*xml));
        NSLog(
            @"[WeChatAntiRecall] revoke probe msgType=%u newmsgid=%llu replaceMsg=%@ xml=%@",
            msgType,
            newMsgId,
            replacePreview,
            xmlPreview
        );
    }
}

bool looksLikeRevokeXML(const std::string *xml) {
    if (xml == nullptr || xml->empty()) {
        return false;
    }

    return xml->find("<revokemsg") != std::string::npos &&
        xml->find("</revokemsg>") != std::string::npos;
}

bool shouldInspectRevokeMessageFields(const std::string *xml) {
    return looksLikeRevokeXML(xml);
}

bool looksLikeRevokeReplaceMsg(const std::string &replaceMsg) {
    if (replaceMsg.empty()) {
        return false;
    }

    return replaceMsg.find("撤回") != std::string::npos ||
        replaceMsg.find(" recalled ") != std::string::npos ||
        replaceMsg.find(" recalled a message") != std::string::npos;
}

bool shouldRewriteRevokeMessage(uint32_t, uint64_t, const std::string &replaceMsg, const std::string *xml) {
    return looksLikeRevokeXML(xml) && looksLikeRevokeReplaceMsg(replaceMsg);
}

std::string rewriteRevokeMessage(
    const std::string &originalTip,
    const std::string &configuredPhrase,
    uint64_t newMsgId,
    const std::string *xml,
    uint32_t msgType,
    const std::string &fallbackTime
) {
    if (!shouldRewriteRevokeMessage(msgType, newMsgId, originalTip, xml)) {
        return originalTip;
    }

    const auto timeText = stableRevokeTimeText(newMsgId, xml, originalTip, fallbackTime);
    return renderRevokeTip(originalTip, configuredPhrase, timeText);
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

    const auto *hookConfig = currentRevokeHookConfig();
    if (hookConfig == nullptr) {
        return false;
    }

    const bool result = originalParseRevokeXML(message, xml, flag, msgType);
    if (!result || message == nullptr) {
        return result;
    }
    // 268599 routes non-revoke XML through this parser; keep those paths away from the revoke message layout.
    if (xml == nullptr ||
        !isAddressRangeReadable(reinterpret_cast<uintptr_t>(xml), sizeof(std::string)) ||
        !shouldInspectRevokeMessageFields(xml)) {
        return result;
    }

    auto *newMsgId = reinterpret_cast<uint64_t *>(reinterpret_cast<uint8_t *>(message) + hookConfig->revokeNewMsgIdOffset);
    auto *replaceMsg = reinterpret_cast<std::string *>(reinterpret_cast<uint8_t *>(message) + hookConfig->revokeReplaceMsgOffset);
    if (!isAddressRangeReadable(reinterpret_cast<uintptr_t>(newMsgId), sizeof(*newMsgId)) ||
        !isAddressRangeReadable(reinterpret_cast<uintptr_t>(replaceMsg), sizeof(*replaceMsg))) {
        return result;
    }

    const uint64_t originalNewMsgId = *newMsgId;
    const std::string originalReplaceMsg = *replaceMsg;

    @autoreleasepool {
        if (debugProbeEnabled()) {
            logRevokeProbe(msgType, originalNewMsgId, originalReplaceMsg, xml);
        }

        const char *phrase = [configuredPhrase() UTF8String];
        if (phrase != nullptr && shouldRewriteRevokeMessage(msgType, originalNewMsgId, originalReplaceMsg, xml)) {
            *newMsgId = 0;
            replaceMsg->assign(rewriteRevokeMessage(originalReplaceMsg, phrase, originalNewMsgId, xml, msgType, currentTimeText()));
        }
    }

    return result;
}

struct WeChatDylibImage {
    uintptr_t slide;
    uintptr_t start;
    size_t size;
};

bool findWeChatDylibImage(WeChatDylibImage &image) {
    const uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index += 1) {
        const char *imageName = _dyld_get_image_name(index);
        if (imageName == nullptr) {
            continue;
        }

        if (isTargetWeChatDylibPath(imageName)) {
            const auto slide = _dyld_get_image_vmaddr_slide(index);
            uintptr_t start = 0;
            size_t size = 0;
            if (!imageAddressRangeForHeader(_dyld_get_image_header(index), slide, start, size)) {
                return false;
            }

            image = {
                static_cast<uintptr_t>(slide),
                start,
                size,
            };
            return true;
        }
    }

    return false;
}

bool writeHookSlot(void **slot, void *replacement) {
    if (slot == nullptr || replacement == nullptr || !isAddressRangeReadable(reinterpret_cast<uintptr_t>(slot), sizeof(void *))) {
        return false;
    }

    mach_vm_address_t regionAddress = reinterpret_cast<mach_vm_address_t>(slot);
    mach_vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info = {};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    const kern_return_t regionResult = mach_vm_region(
        mach_task_self(),
        &regionAddress,
        &regionSize,
        VM_REGION_BASIC_INFO_64,
        reinterpret_cast<vm_region_info_t>(&info),
        &count,
        &objectName
    );
    if (objectName != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), objectName);
    }
    if (regionResult != KERN_SUCCESS) {
        return false;
    }

    const auto pageSize = static_cast<uintptr_t>(sysconf(_SC_PAGESIZE));
    const auto slotAddress = reinterpret_cast<uintptr_t>(slot);
    const auto pageStart = slotAddress & ~(pageSize - 1);
    void *originalValue = *slot;

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
    const bool wroteReplacement = *slot == replacement;
    if (!wroteReplacement) {
        *slot = originalValue;
    }

    vm_protect(
        mach_task_self(),
        static_cast<vm_address_t>(pageStart),
        static_cast<vm_size_t>(pageSize),
        false,
        info.protection
    );

    return wroteReplacement;
}

void installRevokeTipHook() {
    const auto *hookConfig = currentRevokeHookConfig();
    if (hookConfig == nullptr) {
        return;
    }

    WeChatDylibImage image = {};
    if (!findWeChatDylibImage(image)) {
        return;
    }

    const uintptr_t originalBodyAddress = image.slide + hookConfig->parseRevokeXMLOriginalBody;
    const uintptr_t hookSlotAddress = resolveParseRevokeXMLHookSlotInImage(originalBodyAddress, image.start, image.size);
    if (hookSlotAddress == 0) {
        return;
    }

    auto **hookSlot = reinterpret_cast<void **>(hookSlotAddress);
    if (*hookSlot == reinterpret_cast<void *>(&hookedParseRevokeXML)) {
        return;
    }

    originalParseRevokeXML = reinterpret_cast<ParseRevokeXML>(originalBodyAddress);
    if (!writeHookSlot(hookSlot, reinterpret_cast<void *>(&hookedParseRevokeXML))) {
        originalParseRevokeXML = nullptr;
    }
}

} // namespace

char *wechat_antirecall_render_revoke_tip_copy(const char *originalTip, const char *configuredPhrase) {
    const std::string original = originalTip == nullptr ? "" : originalTip;
    const std::string phrase = configuredPhrase == nullptr ? "" : configuredPhrase;
    const auto rendered = renderRevokeTip(original, phrase);

    return copyCString(rendered.c_str());
}

char *wechat_antirecall_render_revoke_tip_for_event_copy(
    const char *originalTip,
    const char *configuredPhrase,
    uint64_t newMsgId,
    const char *xml,
    const char *fallbackTime
) {
    const std::string original = originalTip == nullptr ? "" : originalTip;
    const std::string phrase = configuredPhrase == nullptr ? "" : configuredPhrase;
    const std::string xmlString = xml == nullptr ? "" : xml;
    const std::string fallback = fallbackTime == nullptr ? currentTimeText() : fallbackTime;
    const auto timeText = stableRevokeTimeText(newMsgId, xml == nullptr ? nullptr : &xmlString, original, fallback);
    const auto rendered = renderRevokeTip(original, phrase, timeText);

    return copyCString(rendered.c_str());
}

char *wechat_antirecall_rewrite_revoke_message_copy(
    const char *originalTip,
    const char *configuredPhrase,
    uint64_t newMsgId,
    const char *xml,
    uint32_t msgType,
    const char *fallbackTime
) {
    const std::string original = originalTip == nullptr ? "" : originalTip;
    const std::string phrase = configuredPhrase == nullptr ? "" : configuredPhrase;
    const std::string xmlString = xml == nullptr ? "" : xml;
    const std::string fallback = fallbackTime == nullptr ? currentTimeText() : fallbackTime;
    const auto rendered = rewriteRevokeMessage(
        original,
        phrase,
        newMsgId,
        xml == nullptr ? nullptr : &xmlString,
        msgType,
        fallback
    );

    return copyCString(rendered.c_str());
}

char *wechat_antirecall_load_revoke_tip_phrase_for_home_copy(const char *homeDirectory) {
    @autoreleasepool {
        NSString *home = homeDirectory == nullptr ? nil : [NSString stringWithUTF8String:homeDirectory];
        return copyNSString(configuredPhraseFromPreferencePlistsForHomeDirectory(home));
    }
}

void wechat_antirecall_clear_revoke_tip_time_cache(void) {
    std::lock_guard<std::mutex> lock(revokeTimeCacheMutex);
    revokeTimeCache.clear();
}

void wechat_antirecall_free(void *pointer) {
    std::free(pointer);
}

int wechat_antirecall_is_target_wechat_dylib_path(const char *imagePath) {
    return isTargetWeChatDylibPath(imagePath) ? 1 : 0;
}

uintptr_t wechat_antirecall_revoke_hook_original_body_for_build(const char *buildVersion) {
    const auto *hookConfig = revokeHookConfigForBuildVersionCString(buildVersion);
    return hookConfig == nullptr ? 0 : hookConfig->parseRevokeXMLOriginalBody;
}

int wechat_antirecall_should_inspect_revoke_message_fields(const char *xml) {
    const std::string xmlString = xml == nullptr ? "" : xml;
    return shouldInspectRevokeMessageFields(xml == nullptr ? nullptr : &xmlString) ? 1 : 0;
}

uintptr_t wechat_antirecall_resolve_parse_revoke_xml_hook_slot(
    uintptr_t originalBodyAddress,
    uintptr_t imageStart,
    uintptr_t imageSize
) {
    return resolveParseRevokeXMLHookSlotInImage(originalBodyAddress, imageStart, static_cast<size_t>(imageSize));
}

int wechat_antirecall_try_write_hook_slot(void **slot, void *replacement) {
    return writeHookSlot(slot, replacement) ? 1 : 0;
}

int wechat_antirecall_is_address_range_readable(uintptr_t address, uintptr_t length) {
    return isAddressRangeReadable(address, static_cast<size_t>(length)) ? 1 : 0;
}

__attribute__((constructor))
static void wechat_antirecall_runtime_init() {
    @autoreleasepool {
        installRevokeTipHook();
    }
}
