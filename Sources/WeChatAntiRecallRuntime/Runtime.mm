#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <unistd.h>
#include <pthread.h>
#include <libkern/OSCacheControl.h>
#include <os/log.h>

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "WeChatAntiRecallRuntime.h"

namespace {

constexpr NSUInteger revokeTipMaximumLength = 120;
constexpr size_t revokeTimeCacheMaximumCount = 512;
constexpr size_t revokeContentCacheMaximumCount = 512;
// Recalled-content previews are truncated to this many UTF-8 bytes before being cached,
// so a single recalled message can never blow past the 120-char tip budget on its own.
constexpr size_t revokeContentPreviewMaximumBytes = 240;
constexpr size_t arm64StubLength = 16;

using ParseRevokeXML = bool (*)(void *, std::string *, void *, uint32_t);

struct RevokeHookConfig {
    const char *buildVersion;
    uintptr_t originalBody;
    ptrdiff_t newMsgIdOffset;
    ptrdiff_t replaceMsgOffset;
};

constexpr RevokeHookConfig revokeHookConfigs[] = {
    {"268597", 0x4764540, 0x168, 0x170},
    {"268599", 0x47775cc, 0x168, 0x170},
    {"268601", 0x47813f0, 0x168, 0x170},
    {"268602", 0x47856a0, 0x168, 0x170},
    {"268831", 0x48f6d7c, 0x168, 0x170},
};

// Builds whose parseRevokeXML has NO WeChat dispatch stub (the compiler dropped the
// hot-patch trampolines). These are hooked with a static entry rewrite + a runtime
// trampoline instead. `savedInstructions` are the original first 3 instruction words
// at `entryOffset` (overwritten by the static `adrp/ldr/br` stub at install time);
// the trampoline replays them and jumps to `continuationOffset` (= entryOffset + 12).
constexpr size_t inlineSavedInstructionCount = 3;

struct InlineRevokeHookConfig {
    const char *buildVersion;
    uintptr_t entryOffset;
    uint32_t savedInstructions[inlineSavedInstructionCount];
    uintptr_t continuationOffset;
    ptrdiff_t newMsgIdOffset;
    ptrdiff_t replaceMsgOffset;
};

constexpr InlineRevokeHookConfig inlineRevokeHookConfigs[] = {
    // 268849 (WeChat 4.1.10): entry stp x24,x23,[sp,#-0x40]! / stp x22,x21 / stp x20,x19.
    {"268849", 0x488c4c4, {0xA9BC5FF8, 0xA90157F6, 0xA9024FF4}, 0x488c4d0, 0x168, 0x170},
    // 268850 (WeChat 4.1.10 hotfix): byte-identical to 268849 across every patch site
    // and the SLOT slack, so the same inline-hook geometry applies unchanged.
    {"268850", 0x488c4c4, {0xA9BC5FF8, 0xA90157F6, 0xA9024FF4}, 0x488c4d0, 0x168, 0x170},
    // 268851 (WeChat 4.1.10 hotfix): verified byte-identical to 268850 at every patch
    // site (entry prologue, str-xzr at 0x488cec8, all update sites) with the SLOT at
    // 0x952bf00 still in __DATA zero-fill, so the same geometry applies unchanged.
    {"268851", 0x488c4c4, {0xA9BC5FF8, 0xA90157F6, 0xA9024FF4}, 0x488c4d0, 0x168, 0x170},
    // 269077 (WeChat 4.1.11): new marketing version. parseRevokeXML kept the same body
    // (prologue stp x24,x23 / stp x22,x21 / stp x20,x19, then cbz w0 at entry+0x270 and
    // str x0,[x19,#0x168] at entry+0xA04) but relocated to 0x48a4d68 — a unique geometry
    // match across the whole arm64 slice. The static runtime-tip stub points at a fresh
    // SLOT (0x93b3f00) in the __DATA tail slack (past __common, inside the segment's
    // zero-fill); the runtime self-locates it by decoding the patched entry. Update
    // blocking (patches.json "update" target) was located via XAppUpdateManager's ObjC
    // selector->IMP table by method name (no 268849-class reference binary existed), and
    // cross-checked against the 268831 binary.
    {"269077", 0x48a4d68, {0xA9BC5FF8, 0xA90157F6, 0xA9024FF4}, 0x48a4d74, 0x168, 0x170},
    // 269079 (WeChat 4.1.11 hotfix): NOT byte-identical to 269077 — the whole slice was
    // rebased, so every site shifted. parseRevokeXML kept the same body (identical prologue,
    // cbz w0 at entry+0x270, str x0,[x19,#0x168] at entry+0xA04) and relocated to 0x48a7c4c,
    // again a unique geometry match across the arm64 slice. Field offsets 0x168/0x170 were
    // re-decoded from the actual str/ldr instructions in this binary (not copied). The
    // runtime-tip stub points at a fresh SLOT (0x93b7f00) in the __DATA tail slack past
    // __common; the runtime self-locates it by decoding the patched entry. Update blocking
    // was re-derived from XAppUpdateManager's ObjC selector->IMP table by method name, and
    // every site's entry bytes matched 269077's semantics (same prologues, accessor fields
    // 0x18/0x19).
    {"269079", 0x48a7c4c, {0xA9BC5FF8, 0xA90157F6, 0xA9024FF4}, 0x48a7c58, 0x168, 0x170},
    // 269110 (WeChat 4.1.11): parseRevokeXML relocated to 0x4509eb8 while retaining
    // the inline-hook geometry and 0x168/0x170 message field offsets. The entry stub
    // targets zero-fill slack at 0x986bf00 near the end of __DATA.
    {"269110", 0x4509eb8, {0xA9BC5FF8, 0xA90157F6, 0xA9024FF4}, 0x4509ec4, 0x168, 0x170},
    // 269332 (WeChat 4.1.12): new marketing version. parseRevokeXML was RECOMPILED, so the
    // old geometry (cbz w0 at entry+0x270, str at entry+0xA04) no longer holds verbatim and
    // the whole slice rebased — it was relocated by diffing the identical function against a
    // 269111 (4.1.11) reference binary (masked-instruction shape match, ratio 0.76 vs 0.17 for
    // the runner-up; entry prologue still stp x24,x23 / stp x22,x21 / stp x20,x19). The cbz w0
    // guard stayed at entry+0x270 (0x462f690), but a compiler-inserted call after it pushed the
    // newmsgid store down to entry+0xA10 (0x462fe30). CRITICAL: the message-struct layout moved
    // — newMsgId is now at 0x198 and replaceMsg (std::string) at 0x1A0 (was 0x168/0x170 on every
    // prior build). Both offsets were re-decoded from THIS binary's str/ldr instructions: the
    // newmsgid str is str x0,[x19,#0x198], and the four replaceMsg ldr x0,[x19,#0x1A0] sites map
    // 1:1 onto the reference's four ldr x0,[x19,#0x170] sites. The runtime-tip stub targets fresh
    // zero-fill slack at 0x9a53f00 (between __common end 0x9a53718 and __DATA end 0x9a54000); the
    // runtime self-locates it by decoding the patched entry. Update blocking was re-resolved via
    // XAppUpdateManager's ObjC selector->IMP table (all 8 sites byte-identical to the reference,
    // only relocated).
    {"269332", 0x462f420, {0xA9BC5FF8, 0xA90157F6, 0xA9024FF4}, 0x462f42c, 0x198, 0x1a0},
};

ParseRevokeXML originalParseRevokeXML = nullptr;
const RevokeHookConfig *activeRevokeHookConfig = nullptr;
// Backing storage for the offsets used by hookedParseRevokeXML when the active hook
// is an inline hook (the InlineRevokeHookConfig builds a compatible RevokeHookConfig).
RevokeHookConfig activeInlineRevokeHookConfig = {nullptr, 0, 0, 0};
std::mutex revokeTimeCacheMutex;
std::unordered_map<std::string, std::string> revokeTimeCache;
// Maps a recalled message's newmsgid -> a short content preview captured when the
// message first arrived (the receive-path hook fills this; see installRevokeTipHook).
// The revoke hook reads it back to substitute {content} in the configured tip. Keyed by
// "id:<newmsgid>", the same scheme revokeTimeCacheKey uses, so receive and revoke agree.
std::mutex revokeContentCacheMutex;
std::unordered_map<std::string, std::string> revokeContentCache;

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

const RevokeHookConfig *revokeHookConfigForBuild(const char *buildVersion) {
    if (buildVersion == nullptr) {
        return nullptr;
    }

    for (const auto &config : revokeHookConfigs) {
        if (std::strcmp(config.buildVersion, buildVersion) == 0) {
            return &config;
        }
    }
    return nullptr;
}

uintptr_t revokeHookOriginalBodyForBuild(const char *buildVersion) {
    const auto *config = revokeHookConfigForBuild(buildVersion);
    return config == nullptr ? 0 : config->originalBody;
}

std::string currentBundleBuildVersion() {
    @autoreleasepool {
        id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
        if (![value isKindOfClass:[NSString class]]) {
            return "";
        }

        const char *utf8 = [(NSString *)value UTF8String];
        return utf8 == nullptr ? "" : std::string(utf8);
    }
}

bool shouldInspectRevokeMessageFields(const std::string *xml) {
    if (xml == nullptr) {
        return false;
    }

    return xml->find("<revokemsg>") != std::string::npos ||
        xml->find("<revokemsg ") != std::string::npos;
}

bool isAddressRangeReadable(const void *address, size_t length) {
    if (address == nullptr || length == 0) {
        return false;
    }

    mach_vm_address_t current = reinterpret_cast<mach_vm_address_t>(address);
    const mach_vm_address_t end = current + length;
    if (end < current) {
        return false;
    }

    while (current < end) {
        // Descend into submaps to read the LEAF mapping's real protection. The dyld shared
        // cache nests unreadable (`---`) guard pages inside a readable top-level region, so
        // plain mach_vm_region reports the wrapper as readable — a bare pointer chase into
        // such a hole then passes this check and faults on access (the crash this fixes).
        // mach_vm_region_recurse returns the actual leaf mapping's protection.
        mach_vm_address_t regionAddress = current;
        mach_vm_size_t regionSize = 0;
        vm_region_submap_info_data_64_t info = {};
        natural_t depth = 0;
        kern_return_t result = KERN_SUCCESS;
        for (;;) {
            regionAddress = current;
            regionSize = 0;
            mach_msg_type_number_t infoCount = VM_REGION_SUBMAP_INFO_COUNT_64;
            result = mach_vm_region_recurse(
                mach_task_self(),
                &regionAddress,
                &regionSize,
                &depth,
                reinterpret_cast<vm_region_recurse_info_t>(&info),
                &infoCount
            );
            if (result != KERN_SUCCESS || !info.is_submap) {
                break;
            }
            depth += 1;
        }
        if (result != KERN_SUCCESS || regionAddress > current || regionSize == 0) {
            return false;
        }
        if ((info.protection & VM_PROT_READ) == 0) {
            return false;
        }

        const mach_vm_address_t next = regionAddress + regionSize;
        if (next <= current) {
            return false;
        }
        current = next;
    }

    return true;
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

int64_t signExtend(uint64_t value, unsigned bitCount) {
    const uint64_t signBit = 1ULL << (bitCount - 1);
    const uint64_t mask = (1ULL << bitCount) - 1;
    value &= mask;
    return static_cast<int64_t>((value ^ signBit) - signBit);
}

bool decodeADRPPage(uint32_t instruction, uintptr_t instructionAddress, uintptr_t &pageAddress) {
    if ((instruction & 0x9f000000) != 0x90000000) {
        return false;
    }

    const uint64_t immLo = (instruction >> 29) & 0x3;
    const uint64_t immHi = (instruction >> 5) & 0x7ffff;
    const int64_t pageOffset = signExtend((immHi << 2) | immLo, 21) << 12;
    const auto page = static_cast<intptr_t>(instructionAddress & ~uintptr_t(0xfff));
    pageAddress = static_cast<uintptr_t>(page + pageOffset);
    return true;
}

bool decodeLDRUnsignedImmediate64(uint32_t instruction, uint32_t &targetRegister, uint32_t &baseRegister, uintptr_t &offset) {
    if ((instruction & 0xffc00000) != 0xf9400000) {
        return false;
    }

    targetRegister = instruction & 0x1f;
    baseRegister = (instruction >> 5) & 0x1f;
    offset = static_cast<uintptr_t>((instruction >> 10) & 0xfff) << 3;
    return true;
}

bool decodeCBZTarget64(uint32_t instruction, uintptr_t instructionAddress, uint32_t &targetRegister, uintptr_t &targetAddress) {
    if ((instruction & 0xff000000) != 0xb4000000) {
        return false;
    }

    const int64_t offset = signExtend((instruction >> 5) & 0x7ffff, 19) << 2;
    targetRegister = instruction & 0x1f;
    targetAddress = static_cast<uintptr_t>(static_cast<intptr_t>(instructionAddress) + offset);
    return true;
}

bool isBranchRegister(uint32_t instruction, uint32_t targetRegister) {
    return instruction == (0xd61f0000 | (targetRegister << 5));
}

uintptr_t resolveParseRevokeXMLHookSlot(uintptr_t originalBodyAddress, uintptr_t imageStart, size_t imageSize) {
    if (originalBodyAddress < arm64StubLength || imageSize == 0) {
        return 0;
    }

    const uintptr_t stubAddress = originalBodyAddress - arm64StubLength;
    if (!rangeContains(imageStart, imageSize, stubAddress, arm64StubLength) ||
        !isAddressRangeReadable(reinterpret_cast<const void *>(stubAddress), arm64StubLength)) {
        return 0;
    }

    const auto *instructions = reinterpret_cast<const uint32_t *>(stubAddress);
    const uint32_t adrp = instructions[0];
    const uint32_t ldr = instructions[1];
    const uint32_t cbz = instructions[2];
    const uint32_t br = instructions[3];

    uintptr_t pageAddress = 0;
    if (!decodeADRPPage(adrp, stubAddress, pageAddress)) {
        return 0;
    }

    uint32_t ldrTargetRegister = 0;
    uint32_t ldrBaseRegister = 0;
    uintptr_t ldrOffset = 0;
    if (!decodeLDRUnsignedImmediate64(ldr, ldrTargetRegister, ldrBaseRegister, ldrOffset)) {
        return 0;
    }

    uint32_t cbzRegister = 0;
    uintptr_t cbzTargetAddress = 0;
    if (!decodeCBZTarget64(cbz, stubAddress + 8, cbzRegister, cbzTargetAddress)) {
        return 0;
    }

    if (ldrTargetRegister != ldrBaseRegister ||
        cbzRegister != ldrTargetRegister ||
        cbzTargetAddress != originalBodyAddress ||
        !isBranchRegister(br, ldrTargetRegister)) {
        return 0;
    }

    const uintptr_t hookSlot = pageAddress + ldrOffset;
    if (!rangeContains(imageStart, imageSize, hookSlot, sizeof(void *)) ||
        !isAddressRangeReadable(reinterpret_cast<const void *>(hookSlot), sizeof(void *))) {
        return 0;
    }

    return hookSlot;
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
                if (start < lowest) {
                    lowest = start;
                }
                if (end > highest) {
                    highest = end;
                }
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

// True when the recall was performed by the local user (you recalled your own
// message). WeChat shows its own "You recalled a message" affordance for these, so
// the anti-recall tip must not fire — there is nothing to "intercept". Matches the
// self-recall wording WeChat emits across locales; works on either the rendered tip
// text or the raw <replacemsg> CDATA from the revoke XML.
bool tipIndicatesSelfRecall(const std::string &tip) {
    if (tip.empty()) {
        return false;
    }
    static const char *const selfMarkers[] = {
        "You recalled ",  // English
        "你撤回",          // Simplified Chinese
        "你收回",          // Traditional Chinese variants
        "你回收",
    };
    for (const char *marker : selfMarkers) {
        if (tip.find(marker) != std::string::npos) {
            return true;
        }
    }
    return false;
}

const std::vector<std::string> &revokeTipPlaceholders() {
    static const std::vector<std::string> placeholders = {
        "{from}",
        "{time}",
        "{content}",
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

// The real newmsgid carried by the revoke XML. The static str-xzr patch forces
// message+0x168 to 0 (to keep the original message); for the user's own recalls we
// restore this real id so WeChat deletes the original natively. Returns false if the
// XML carries no usable newmsgid.
bool revokeNewMsgIdFromXML(const std::string *xml, uint64_t &result) {
    if (xml == nullptr || xml->empty()) {
        return false;
    }

    static const std::vector<std::string> idTags = {
        "newmsgid",
        "newMsgId",
        "NewMsgId",
        "newmsgId",
    };

    for (const auto &tag : idTags) {
        uint64_t value = 0;
        if (parseUnsignedInteger(xmlTagValue(*xml, tag), value) && value != 0) {
            result = value;
            return true;
        }
    }

    return false;
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

// Truncate `value` to at most `maxBytes` bytes without splitting a UTF-8 code point,
// appending an ellipsis when anything was dropped. Continuation bytes are 0b10xxxxxx.
std::string truncateUTF8Preview(const std::string &value, size_t maxBytes) {
    if (value.size() <= maxBytes) {
        return value;
    }

    size_t end = maxBytes;
    while (end > 0 && (static_cast<unsigned char>(value[end]) & 0xc0) == 0x80) {
        end -= 1;
    }
    return value.substr(0, end) + "\xE2\x80\xA6";  // U+2026 HORIZONTAL ELLIPSIS
}

// Localized type placeholder for a recalled message whose content cannot be shown as
// plain text (image, voice, …). These strings are NOT present in wechat.dylib, so they
// are hardcoded here. Returns an empty string for the plain-text type (1), whose raw
// text is shown directly, and a generic "[消息]" for anything unrecognized.
std::string messageKindPlaceholder(uint32_t contentMsgType) {
    switch (contentMsgType) {
        case 1:  return "";            // text — caller shows the raw text instead
        case 3:  return "[图片]";
        case 34: return "[语音]";
        case 43: return "[视频]";
        case 42: return "[名片]";
        case 47: return "[动画表情]";
        case 48: return "[位置]";
        case 49: return "[链接]";       // appmsg: file/link/quote/etc. coarse bucket
        case 50: return "[音视频通话]";
        case 10000:
        case 10002: return "[系统消息]";
        default: return "[消息]";
    }
}

// Build the cached preview for a freshly received message: trimmed/truncated text for
// plain-text messages, a type placeholder for media. `rawContent` is ignored for media.
std::string contentPreviewForReceivedMessage(uint32_t contentMsgType, const std::string &rawContent) {
    if (contentMsgType == 1) {
        return truncateUTF8Preview(trimCopy(rawContent), revokeContentPreviewMaximumBytes);
    }
    return messageKindPlaceholder(contentMsgType);
}

std::string revokeContentCacheKey(uint64_t newMsgId) {
    return "id:" + std::to_string(newMsgId);
}

void rememberRevokeContentPreview(uint64_t newMsgId, const std::string &preview) {
    if (newMsgId == 0 || preview.empty()) {
        return;
    }

    std::lock_guard<std::mutex> lock(revokeContentCacheMutex);
    if (revokeContentCache.size() >= revokeContentCacheMaximumCount) {
        revokeContentCache.clear();
    }
    revokeContentCache[revokeContentCacheKey(newMsgId)] = preview;
}

bool lookupRevokeContentPreview(uint64_t newMsgId, std::string &out) {
    if (newMsgId == 0) {
        return false;
    }

    std::lock_guard<std::mutex> lock(revokeContentCacheMutex);
    const auto found = revokeContentCache.find(revokeContentCacheKey(newMsgId));
    if (found == revokeContentCache.end()) {
        return false;
    }
    out = found->second;
    return true;
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

// Substitute the recalled-message content. When no content was captured (cold cache,
// media we chose not to preview, …) the placeholder and a single leading separator are
// dropped so the tip does not end on a dangling "撤回：". Mirrors replaceTimePlaceholder.
void replaceContentPlaceholder(std::string &rendered, const std::string &contentText) {
    if (!contentText.empty()) {
        replaceAll(rendered, "{content}", contentText);
        return;
    }

    static const std::vector<std::string> emptyContentPatterns = {
        "：{content}",
        ": {content}",
        ":{content}",
        " {content}",
    };

    for (const auto &pattern : emptyContentPatterns) {
        const auto position = rendered.find(pattern);
        if (position != std::string::npos) {
            rendered.erase(position, pattern.size());
            break;
        }
    }

    replaceAll(rendered, "{content}", "");
}

std::string renderRevokeTip(
    const std::string &originalTip,
    const std::string &configuredPhrase,
    const std::string &timeText,
    const std::string &contentPreview
) {
    if (configuredPhrase.empty()) {
        return originalTip;
    }

    // Never rewrite the local user's own recalls — leave WeChat's native tip intact.
    if (tipIndicatesSelfRecall(originalTip)) {
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
    replaceContentPlaceholder(rendered, contentPreview);
    return rendered;
}

std::string renderRevokeTip(
    const std::string &originalTip,
    const std::string &configuredPhrase,
    const std::string &timeText
) {
    return renderRevokeTip(originalTip, configuredPhrase, timeText, "");
}

std::string renderRevokeTip(const std::string &originalTip, const std::string &configuredPhrase) {
    return renderRevokeTip(originalTip, configuredPhrase, currentTimeText(), "");
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

NSString *originalWechatBundleIdentifier() {
    return @"com.tencent.xinWeChat";
}

NSString *currentBundleIdentifier() {
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleIdentifier.length == 0) {
        return originalWechatBundleIdentifier();
    }
    return bundleIdentifier;
}

bool isAntiRecallCloneBundleIdentifier(NSString *bundleIdentifier) {
    return [bundleIdentifier hasPrefix:@"com.tencent.xinWeChat.antirecall.clone"];
}

NSArray<NSString *> *preferencePlistPathsForBundle(NSString *homeDirectory, NSString *bundleIdentifier) {
    if (homeDirectory.length == 0) {
        return @[];
    }
    if (bundleIdentifier.length == 0) {
        return @[];
    }

    return @[
        [homeDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", bundleIdentifier]],
        [homeDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Containers/%@/Data/Library/Preferences/%@.plist", bundleIdentifier, bundleIdentifier]],
    ];
}

NSArray<NSString *> *preferencePlistPaths(NSString *homeDirectory) {
    return preferencePlistPathsForBundle(homeDirectory, originalWechatBundleIdentifier());
}

NSString *phraseFromPreferencePlistsForBundle(NSString *homeDirectory, NSString *bundleIdentifier) {
    for (NSString *plistPath in preferencePlistPathsForBundle(homeDirectory, bundleIdentifier)) {
        NSString *phrase = phraseFromPlist(plistPath);
        if (phrase != nil) {
            return phrase;
        }
    }
    return nil;
}

NSString *phraseFromPreferencePlists(NSString *homeDirectory) {
    return phraseFromPreferencePlistsForBundle(homeDirectory, originalWechatBundleIdentifier());
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

NSNumber *probeFlagFromPreferencePlistsForBundle(NSString *homeDirectory, NSString *bundleIdentifier) {
    for (NSString *plistPath in preferencePlistPathsForBundle(homeDirectory, bundleIdentifier)) {
        NSNumber *probeEnabled = probeFlagFromPlist(plistPath);
        if (probeEnabled != nil) {
            return probeEnabled;
        }
    }
    return nil;
}

NSString *configuredPhraseForHomeDirectoryAndBundle(NSString *homeDirectory, NSString *bundleIdentifier) {
    NSString *phrase = phraseFromDefaults([NSUserDefaults standardUserDefaults]);
    if (phrase != nil) {
        return phrase;
    }

    NSString *effectiveBundleIdentifier = bundleIdentifier.length > 0 ? bundleIdentifier : originalWechatBundleIdentifier();
    NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:effectiveBundleIdentifier];
    phrase = phraseFromDefaults(suiteDefaults);
    if (phrase != nil) {
        return phrase;
    }

    NSString *home = homeDirectory.length > 0 ? homeDirectory : NSHomeDirectory();
    phrase = phraseFromPreferencePlistsForBundle(home, effectiveBundleIdentifier);
    if (phrase != nil) {
        return phrase;
    }

    if (isAntiRecallCloneBundleIdentifier(effectiveBundleIdentifier)) {
        return defaultRevokeTipPhrase();
    }

    return defaultRevokeTipPhrase();
}

NSString *configuredPhraseForHomeDirectory(NSString *homeDirectory) {
    return configuredPhraseForHomeDirectoryAndBundle(homeDirectory, currentBundleIdentifier());
}

bool debugProbeEnabledForHomeDirectoryAndBundle(NSString *homeDirectory, NSString *bundleIdentifier) {
    NSNumber *probeEnabled = probeFlagFromDefaults([NSUserDefaults standardUserDefaults]);
    if (probeEnabled != nil) {
        return [probeEnabled boolValue];
    }

    NSString *effectiveBundleIdentifier = bundleIdentifier.length > 0 ? bundleIdentifier : originalWechatBundleIdentifier();
    NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:effectiveBundleIdentifier];
    probeEnabled = probeFlagFromDefaults(suiteDefaults);
    if (probeEnabled != nil) {
        return [probeEnabled boolValue];
    }

    NSString *home = homeDirectory.length > 0 ? homeDirectory : NSHomeDirectory();
    probeEnabled = probeFlagFromPreferencePlistsForBundle(home, effectiveBundleIdentifier);
    if (probeEnabled != nil) {
        return [probeEnabled boolValue];
    }

    return false;
}

bool debugProbeEnabledForHomeDirectory(NSString *homeDirectory) {
    return debugProbeEnabledForHomeDirectoryAndBundle(homeDirectory, currentBundleIdentifier());
}

NSString *configuredPhraseFromPreferencePlistsForHomeDirectory(NSString *homeDirectory) {
    NSString *home = homeDirectory.length > 0 ? homeDirectory : NSHomeDirectory();
    NSString *phrase = phraseFromPreferencePlists(home);
    if (phrase != nil) {
        return phrase;
    }

    return defaultRevokeTipPhrase();
}

NSString *configuredPhraseFromPreferencePlistsForHomeDirectoryAndBundle(NSString *homeDirectory, NSString *bundleIdentifier) {
    NSString *home = homeDirectory.length > 0 ? homeDirectory : NSHomeDirectory();
    NSString *effectiveBundleIdentifier = bundleIdentifier.length > 0 ? bundleIdentifier : originalWechatBundleIdentifier();
    NSString *phrase = phraseFromPreferencePlistsForBundle(home, effectiveBundleIdentifier);
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
        // The probe is opt-in (debugProbeEnabled) and exists precisely to show this data
        // to whoever turned it on, so log it as public — NSLog/%@ would otherwise redact
        // every dynamic field to <private> in unified logging.
        const std::string replacePreview = previewString(replaceMsg);
        const std::string xmlPreview = xml == nullptr ? "<nil>" : previewString(*xml);
        os_log(
            OS_LOG_DEFAULT,
            "[WeChatAntiRecall] revoke probe msgType=%u newmsgid=%llu replaceMsg=%{public}s xml=%{public}s",
            msgType,
            newMsgId,
            replacePreview.c_str(),
            xmlPreview.c_str()
        );
    }
}

std::string hexAsciiDump(const uint8_t *bytes, size_t length) {
    static const char *const hexDigits = "0123456789abcdef";
    std::string out;
    std::string ascii;
    out.reserve(length * 3 + length + 2);
    for (size_t index = 0; index < length; index += 1) {
        const uint8_t byte = bytes[index];
        out.push_back(hexDigits[byte >> 4]);
        out.push_back(hexDigits[byte & 0x0f]);
        out.push_back(' ');
        ascii.push_back((byte >= 0x20 && byte < 0x7f) ? static_cast<char>(byte) : '.');
    }
    out.push_back('|');
    out.append(ascii);
    return out;
}

// Dump the revoke message object so the recalled-content source can be located by hand.
// The revoke XML carries no content, so the content must be joined from the receive path
// (see the cache helpers); this probe is the investigation aid for finding the receive
// object's field offsets. Off by default — gated by the same debug-probe switch as
// logRevokeProbe — and every read is bounds-checked, so it never faults on partial maps.
void logRevokeMessageStructProbe(const void *message, const RevokeHookConfig *config) {
    if (message == nullptr) {
        return;
    }

    @autoreleasepool {
        if (config != nullptr) {
            os_log(
                OS_LOG_DEFAULT,
                "[WeChatAntiRecall] struct probe known fields newMsgId=+0x%lx replaceMsg=+0x%lx",
                static_cast<unsigned long>(config->newMsgIdOffset),
                static_cast<unsigned long>(config->replaceMsgOffset)
            );
        }

        const uint8_t *base = reinterpret_cast<const uint8_t *>(message);
        constexpr size_t dumpStart = 0x140;
        constexpr size_t dumpEnd = 0x300;

        for (size_t offset = dumpStart; offset < dumpEnd; offset += 16) {
            const uint8_t *row = base + offset;
            if (!isAddressRangeReadable(row, 16)) {
                continue;
            }
            os_log(OS_LOG_DEFAULT, "[WeChatAntiRecall] struct probe +0x%zx  %{public}s", offset, hexAsciiDump(row, 16).c_str());
        }

        // Any 8-byte slot holding a readable pointer might be a libc++ long-string data
        // pointer or a nested object — preview the first bytes at the target so recalled
        // text shows up in Console even when it is stored out of line.
        for (size_t offset = dumpStart; offset < dumpEnd; offset += 8) {
            const uint8_t *slot = base + offset;
            if (!isAddressRangeReadable(slot, sizeof(void *))) {
                continue;
            }
            const uint8_t *target = *reinterpret_cast<const uint8_t *const *>(slot);
            if (target == nullptr || !isAddressRangeReadable(target, 48)) {
                continue;
            }
            os_log(
                OS_LOG_DEFAULT,
                "[WeChatAntiRecall] struct probe +0x%zx -> %p  %{public}s",
                offset,
                reinterpret_cast<const void *>(target),
                hexAsciiDump(target, 48).c_str()
            );
        }
    }
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
    if (!result || message == nullptr || xml == nullptr) {
        return result;
    }
    if (!shouldInspectRevokeMessageFields(xml)) {
        return result;
    }

    const auto *config = activeRevokeHookConfig;
    if (config == nullptr) {
        return result;
    }

    auto *newMsgId = reinterpret_cast<uint64_t *>(reinterpret_cast<uint8_t *>(message) + config->newMsgIdOffset);
    auto *replaceMsg = reinterpret_cast<std::string *>(reinterpret_cast<uint8_t *>(message) + config->replaceMsgOffset);
    if (!isAddressRangeReadable(newMsgId, sizeof(*newMsgId)) ||
        !isAddressRangeReadable(replaceMsg, sizeof(*replaceMsg))) {
        return result;
    }

    const uint64_t originalNewMsgId = *newMsgId;
    const std::string originalReplaceMsg = *replaceMsg;

    // The local user's own recalls must look native (just WeChat's "You recalled a
    // message" affordance). The static str-xzr patch unconditionally zeroed newMsgId,
    // which keeps the original message and produces a duplicate line; restore the real
    // newmsgid so WeChat deletes it normally, and leave the tip text untouched. Detect
    // self-recalls from both the rendered tip and the raw <replacemsg> XML.
    const bool selfRecall =
        tipIndicatesSelfRecall(originalReplaceMsg) ||
        tipIndicatesSelfRecall(xmlTagValue(*xml, "replacemsg"));

    @autoreleasepool {
        if (debugProbeEnabled()) {
            logRevokeProbe(msgType, originalNewMsgId, originalReplaceMsg, xml);
            logRevokeMessageStructProbe(message, config);
        }

        if (selfRecall) {
            uint64_t realNewMsgId = 0;
            if (revokeNewMsgIdFromXML(xml, realNewMsgId)) {
                *newMsgId = realNewMsgId;
            }
            return result;
        }

        const char *phrase = [configuredPhrase() UTF8String];
        if (phrase != nullptr) {
            *newMsgId = 0;
            const auto timeText = stableRevokeTimeText(originalNewMsgId, xml, originalReplaceMsg, currentTimeText());
            // message+0x168 was already zeroed by the static str-xzr patch before this
            // hook ran, so use the real newmsgid carried by the XML to join against the
            // content captured on the receive path. Empty on a cold-cache miss → {content}
            // strips cleanly.
            uint64_t contentKey = 0;
            revokeNewMsgIdFromXML(xml, contentKey);
            std::string contentPreview;
            lookupRevokeContentPreview(contentKey, contentPreview);
            replaceMsg->assign(renderRevokeTip(originalReplaceMsg, phrase, timeText, contentPreview));
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
    if (slot == nullptr || replacement == nullptr || !isAddressRangeReadable(slot, sizeof(void *))) {
        return false;
    }

    mach_vm_address_t regionAddress = reinterpret_cast<mach_vm_address_t>(slot);
    mach_vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info = {};
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    const kern_return_t regionResult = mach_vm_region(
        mach_task_self(),
        &regionAddress,
        &regionSize,
        VM_REGION_BASIC_INFO_64,
        reinterpret_cast<vm_region_info_t>(&info),
        &infoCount,
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

// --- inline hook engine (for stub-less builds, e.g. 268849) -----------------

// Encode the 3-instruction entry stub: adrp x16, SLOT ; ldr x16,[x16,#off] ; br x16.
// Returns false if SLOT is unreachable by adrp + 64-bit unsigned-offset ldr.
bool encodeEntryStub(uint64_t entryAddress, uint64_t slotAddress, uint32_t out[3]) {
    const int64_t pageDelta =
        static_cast<int64_t>(slotAddress & ~uint64_t(0xfff)) -
        static_cast<int64_t>(entryAddress & ~uint64_t(0xfff));
    if (pageDelta % 0x1000 != 0) {
        return false;
    }
    const int64_t pages = pageDelta >> 12;
    if (pages < -(int64_t(1) << 20) || pages >= (int64_t(1) << 20)) {
        return false;
    }
    const uint32_t imm = static_cast<uint32_t>(pages) & 0x1fffff;
    const uint32_t immlo = imm & 0x3;
    const uint32_t immhi = (imm >> 2) & 0x7ffff;
    out[0] = 0x90000000u | (immlo << 29) | (immhi << 5) | 16u;  // adrp x16

    const uint64_t offset = slotAddress & 0xfff;
    if (offset & 0x7) {
        return false;  // 64-bit ldr unsigned immediate must be 8-byte aligned
    }
    out[1] = 0xf9400000u | (static_cast<uint32_t>(offset >> 3) << 10) | (16u << 5) | 16u;  // ldr x16,[x16,#off]
    out[2] = 0xd61f0000u | (16u << 5);  // br x16
    return true;
}

// Inverse of encodeEntryStub: returns the resolved SLOT address, or 0 if the three
// instruction words are not a recognizable adrp x16 / ldr x16 / br x16 stub.
uint64_t decodeEntryStubSlot(const uint32_t insns[3], uint64_t entryAddress) {
    const uint32_t adrp = insns[0];
    const uint32_t ldr = insns[1];
    const uint32_t branch = insns[2];
    if ((adrp & 0x9f00001f) != (0x90000000u | 16u)) {
        return 0;
    }
    if ((ldr & 0xffc003ff) != (0xf9400000u | (16u << 5) | 16u)) {
        return 0;
    }
    if (branch != (0xd61f0000u | (16u << 5))) {
        return 0;
    }
    const uint32_t immlo = (adrp >> 29) & 0x3;
    const uint32_t immhi = (adrp >> 5) & 0x7ffff;
    const int64_t pages = signExtend((immhi << 2) | immlo, 21);
    const uint64_t page = (entryAddress & ~uint64_t(0xfff)) + static_cast<uint64_t>(pages << 12);
    const uint64_t offset = (static_cast<uint64_t>((ldr >> 10) & 0xfff)) << 3;
    return page + offset;
}

// Map an executable copy of `byteCount` bytes from `bytes`. Prefers RW->mprotect(RX)
// (works for non-hardened processes), falling back to MAP_JIT. Returns nullptr on
// failure. `allocSize` receives the rounded page size for later munmap.
void *allocExecutableBytes(const void *bytes, size_t byteCount, size_t &allocSize) {
    const size_t pageSize = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    allocSize = (byteCount + pageSize - 1) & ~(pageSize - 1);

    void *region = mmap(nullptr, allocSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (region != MAP_FAILED) {
        std::memcpy(region, bytes, byteCount);
        if (mprotect(region, allocSize, PROT_READ | PROT_EXEC) == 0) {
            sys_icache_invalidate(region, byteCount);
            return region;
        }
        munmap(region, allocSize);
    }

    region = mmap(nullptr, allocSize, PROT_READ | PROT_WRITE | PROT_EXEC,
                  MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (region == MAP_FAILED) {
        allocSize = 0;
        return nullptr;
    }
    pthread_jit_write_protect_np(0);
    std::memcpy(region, bytes, byteCount);
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(region, byteCount);
    return region;
}

// Build a trampoline that replays the saved prologue then jumps to continuationAddress.
constexpr size_t inlineTrampolineByteCount = 6 * 4 + 8;  // 6 words + .quad

void *buildInlineTrampoline(const uint32_t saved[inlineSavedInstructionCount], uint64_t continuationAddress, size_t &allocSize) {
    uint8_t buffer[inlineTrampolineByteCount];
    uint32_t *words = reinterpret_cast<uint32_t *>(buffer);
    words[0] = saved[0];
    words[1] = saved[1];
    words[2] = saved[2];
    words[3] = 0x58000000u | (3u << 5) | 17u;  // ldr x17, #12  (-> .quad at offset 24)
    words[4] = 0xd61f0000u | (17u << 5);        // br  x17
    words[5] = 0xd503201fu;                      // nop  (pad .quad to 8-byte alignment)
    std::memcpy(buffer + 24, &continuationAddress, sizeof(continuationAddress));
    return allocExecutableBytes(buffer, sizeof(buffer), allocSize);
}

const InlineRevokeHookConfig *inlineRevokeHookConfigForBuild(const char *buildVersion) {
    if (buildVersion == nullptr) {
        return nullptr;
    }
    for (const auto &config : inlineRevokeHookConfigs) {
        if (std::strcmp(config.buildVersion, buildVersion) == 0) {
            return &config;
        }
    }
    return nullptr;
}

void installRevokeTipStubHook(const WeChatDylibImage &image, const RevokeHookConfig *config) {
    const uintptr_t originalBodyAddress = image.slide + config->originalBody;
    const uintptr_t hookSlotAddress = resolveParseRevokeXMLHookSlot(originalBodyAddress, image.start, image.size);
    if (hookSlotAddress == 0) {
        return;
    }

    auto **hookSlot = reinterpret_cast<void **>(hookSlotAddress);
    if (!isAddressRangeReadable(hookSlot, sizeof(*hookSlot))) {
        return;
    }
    if (*hookSlot == reinterpret_cast<void *>(&hookedParseRevokeXML)) {
        return;
    }

    originalParseRevokeXML = reinterpret_cast<ParseRevokeXML>(originalBodyAddress);
    activeRevokeHookConfig = config;
    if (!writeHookSlot(hookSlot, reinterpret_cast<void *>(&hookedParseRevokeXML))) {
        originalParseRevokeXML = nullptr;
        activeRevokeHookConfig = nullptr;
    }
}

void installRevokeTipInlineHook(const WeChatDylibImage &image, const InlineRevokeHookConfig *config) {
    const uintptr_t entryAddress = image.slide + config->entryOffset;
    if (!rangeContains(image.start, image.size, entryAddress, 3 * sizeof(uint32_t)) ||
        !isAddressRangeReadable(reinterpret_cast<const void *>(entryAddress), 3 * sizeof(uint32_t))) {
        return;
    }

    // Self-locate the SLOT by decoding the static entry stub. If the static patch is
    // absent (entry still holds the original prologue) we bail safely: WeChat keeps
    // running the unmodified function, so the dylib degrades to a no-op.
    uint32_t entryWords[3];
    std::memcpy(entryWords, reinterpret_cast<const void *>(entryAddress), sizeof(entryWords));
    const uint64_t slotAddress = decodeEntryStubSlot(entryWords, entryAddress);
    if (slotAddress == 0) {
        return;
    }
    if (!rangeContains(image.start, image.size, slotAddress, sizeof(void *)) ||
        !isAddressRangeReadable(reinterpret_cast<const void *>(slotAddress), sizeof(void *))) {
        return;
    }

    auto **slot = reinterpret_cast<void **>(slotAddress);
    if (*slot == reinterpret_cast<void *>(&hookedParseRevokeXML)) {
        return;  // already installed
    }

    size_t trampolineAllocSize = 0;
    void *trampoline = buildInlineTrampoline(
        config->savedInstructions,
        image.slide + config->continuationOffset,
        trampolineAllocSize
    );
    if (trampoline == nullptr) {
        return;  // could not allocate executable memory; leave slot untouched
    }

    originalParseRevokeXML = reinterpret_cast<ParseRevokeXML>(trampoline);
    activeInlineRevokeHookConfig = RevokeHookConfig{
        config->buildVersion,
        config->entryOffset,
        config->newMsgIdOffset,
        config->replaceMsgOffset,
    };
    activeRevokeHookConfig = &activeInlineRevokeHookConfig;

    if (!writeHookSlot(slot, reinterpret_cast<void *>(&hookedParseRevokeXML))) {
        originalParseRevokeXML = nullptr;
        activeRevokeHookConfig = nullptr;
        munmap(trampoline, trampolineAllocSize);
    }
}

void installRevokeTipHook() {
    WeChatDylibImage image = {};
    if (!findWeChatDylibImage(image)) {
        return;
    }

    const std::string buildVersion = currentBundleBuildVersion();
    if (const auto *config = revokeHookConfigForBuild(buildVersion.c_str())) {
        installRevokeTipStubHook(image, config);
        return;
    }
    if (const auto *inlineConfig = inlineRevokeHookConfigForBuild(buildVersion.c_str())) {
        installRevokeTipInlineHook(image, inlineConfig);
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
    return wechat_antirecall_render_revoke_tip_for_event_with_content_copy(
        originalTip,
        configuredPhrase,
        newMsgId,
        xml,
        fallbackTime,
        nullptr
    );
}

char *wechat_antirecall_render_revoke_tip_for_event_with_content_copy(
    const char *originalTip,
    const char *configuredPhrase,
    uint64_t newMsgId,
    const char *xml,
    const char *fallbackTime,
    const char *contentPreview
) {
    const std::string original = originalTip == nullptr ? "" : originalTip;
    const std::string phrase = configuredPhrase == nullptr ? "" : configuredPhrase;
    const std::string xmlString = xml == nullptr ? "" : xml;
    const std::string fallback = fallbackTime == nullptr ? currentTimeText() : fallbackTime;
    const std::string content = contentPreview == nullptr ? "" : contentPreview;
    const auto timeText = stableRevokeTimeText(newMsgId, xml == nullptr ? nullptr : &xmlString, original, fallback);
    const auto rendered = renderRevokeTip(original, phrase, timeText, content);

    return copyCString(rendered.c_str());
}

char *wechat_antirecall_load_revoke_tip_phrase_for_home_copy(const char *homeDirectory) {
    @autoreleasepool {
        NSString *home = homeDirectory == nullptr ? nil : [NSString stringWithUTF8String:homeDirectory];
        return copyNSString(configuredPhraseFromPreferencePlistsForHomeDirectory(home));
    }
}

char *wechat_antirecall_load_revoke_tip_phrase_for_home_and_bundle_copy(const char *homeDirectory, const char *bundleIdentifier) {
    @autoreleasepool {
        NSString *home = homeDirectory == nullptr ? nil : [NSString stringWithUTF8String:homeDirectory];
        NSString *bundle = bundleIdentifier == nullptr ? nil : [NSString stringWithUTF8String:bundleIdentifier];
        return copyNSString(configuredPhraseFromPreferencePlistsForHomeDirectoryAndBundle(home, bundle));
    }
}

void wechat_antirecall_clear_revoke_tip_time_cache(void) {
    std::lock_guard<std::mutex> lock(revokeTimeCacheMutex);
    revokeTimeCache.clear();
}

void wechat_antirecall_clear_revoke_content_cache(void) {
    std::lock_guard<std::mutex> lock(revokeContentCacheMutex);
    revokeContentCache.clear();
}

void wechat_antirecall_remember_revoke_content_for_test(uint64_t newMsgId, const char *preview) {
    rememberRevokeContentPreview(newMsgId, preview == nullptr ? "" : preview);
}

char *wechat_antirecall_lookup_revoke_content_for_test(uint64_t newMsgId) {
    std::string out;
    if (!lookupRevokeContentPreview(newMsgId, out)) {
        return nullptr;
    }
    return copyCString(out.c_str());
}

char *wechat_antirecall_content_preview_for_received_message_copy(uint32_t contentMsgType, const char *rawContent) {
    const std::string raw = rawContent == nullptr ? "" : rawContent;
    return copyCString(contentPreviewForReceivedMessage(contentMsgType, raw).c_str());
}

void wechat_antirecall_free(void *pointer) {
    std::free(pointer);
}

int wechat_antirecall_is_target_wechat_dylib_path(const char *imagePath) {
    return isTargetWeChatDylibPath(imagePath) ? 1 : 0;
}

uintptr_t wechat_antirecall_revoke_hook_original_body_for_build(const char *buildVersion) {
    return revokeHookOriginalBodyForBuild(buildVersion);
}

int wechat_antirecall_should_inspect_revoke_message_fields(const char *xml) {
    if (xml == nullptr) {
        return 0;
    }

    const std::string xmlString = xml;
    return shouldInspectRevokeMessageFields(&xmlString) ? 1 : 0;
}

uint64_t wechat_antirecall_revoke_newmsgid_from_xml(const char *xml) {
    if (xml == nullptr) {
        return 0;
    }
    const std::string xmlString = xml;
    uint64_t value = 0;
    return revokeNewMsgIdFromXML(&xmlString, value) ? value : 0;
}

uintptr_t wechat_antirecall_resolve_parse_revoke_xml_hook_slot(
    uintptr_t originalBodyAddress,
    uintptr_t imageStart,
    uintptr_t imageSize
) {
    return resolveParseRevokeXMLHookSlot(originalBodyAddress, imageStart, static_cast<size_t>(imageSize));
}

int wechat_antirecall_is_address_range_readable(uintptr_t address, uintptr_t length) {
    return isAddressRangeReadable(reinterpret_cast<const void *>(address), static_cast<size_t>(length)) ? 1 : 0;
}

int wechat_antirecall_encode_entry_stub(uint64_t entryAddr, uint64_t slotAddr, uint8_t out[12]) {
    uint32_t words[3];
    if (!encodeEntryStub(entryAddr, slotAddr, words)) {
        return 0;
    }
    std::memcpy(out, words, sizeof(words));
    return 1;
}

uint64_t wechat_antirecall_decode_entry_stub_slot(const uint8_t *entry, uint64_t entryAddr) {
    if (entry == nullptr) {
        return 0;
    }
    uint32_t words[3];
    std::memcpy(words, entry, sizeof(words));
    return decodeEntryStubSlot(words, entryAddr);
}

namespace {
int (*selftestOriginalFunction)(void) = nullptr;
int selftestHookedFunction(void) {
    if (selftestOriginalFunction == nullptr) {
        return -1;
    }
    return selftestOriginalFunction() + 0x100;
}
} // namespace

int wechat_antirecall_inline_hook_selftest(void) {
    const size_t pageSize = static_cast<size_t>(sysconf(_SC_PAGESIZE));

    // One 2-page allocation: page 0 becomes the executable fake target, page 1 stays
    // writable and holds the slot. Adjacent pages guarantee the entry stub's adrp/ldr
    // can reach the slot.
    void *region = mmap(nullptr, 2 * pageSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (region == MAP_FAILED) {
        return 0;
    }
    void *codeRegion = region;
    void *slotRegion = static_cast<uint8_t *>(region) + pageSize;
    const uint64_t entryAddress = reinterpret_cast<uint64_t>(codeRegion);
    const uint64_t slotAddress = reinterpret_cast<uint64_t>(slotRegion);

    uint32_t stub[3];
    if (!encodeEntryStub(entryAddress, slotAddress, stub)) {
        munmap(region, 2 * pageSize);
        return 0;
    }

    // Fake target: the static entry stub (overwriting the prologue) followed by a body
    // that returns 0x11, with an epilogue matching the saved prologue.
    const uint32_t savedPrologue[inlineSavedInstructionCount] = {0xA9BC5FF8u, 0xA90157F6u, 0xA9024FF4u};
    const uint32_t fakeWords[8] = {
        stub[0], stub[1], stub[2],
        0x52800220u,  // mov  w0, #0x11
        0xA9424FF4u,  // ldp  x20, x19, [sp, #0x20]
        0xA94157F6u,  // ldp  x22, x21, [sp, #0x10]
        0xA8C45FF8u,  // ldp  x24, x23, [sp], #0x40
        0xd65f03c0u,  // ret
    };
    std::memcpy(codeRegion, fakeWords, sizeof(fakeWords));
    if (mprotect(codeRegion, pageSize, PROT_READ | PROT_EXEC) != 0) {
        munmap(region, 2 * pageSize);
        return 0;
    }
    sys_icache_invalidate(codeRegion, sizeof(fakeWords));

    size_t trampolineAllocSize = 0;
    void *trampoline = buildInlineTrampoline(savedPrologue, entryAddress + 12, trampolineAllocSize);
    if (trampoline == nullptr) {
        munmap(region, 2 * pageSize);
        return 0;
    }

    selftestOriginalFunction = reinterpret_cast<int (*)(void)>(trampoline);
    *reinterpret_cast<void **>(slotRegion) = reinterpret_cast<void *>(&selftestHookedFunction);

    int (*fakeTarget)(void) = reinterpret_cast<int (*)(void)>(codeRegion);
    const int result = fakeTarget();

    selftestOriginalFunction = nullptr;
    munmap(region, 2 * pageSize);
    if (trampolineAllocSize > 0) {
        munmap(trampoline, trampolineAllocSize);
    }

    return result == 0x111 ? 1 : 0;
}

__attribute__((constructor))
static void wechat_antirecall_runtime_init() {
    @autoreleasepool {
        installRevokeTipHook();
    }
}
