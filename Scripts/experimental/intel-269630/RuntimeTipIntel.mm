#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <unistd.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <string>

#if !defined(__x86_64__)
#error 此实验只支持 Intel x86_64
#endif

namespace {
using Parser = bool (*)(void *, std::string *, void *);
Parser original = nullptr;
constexpr std::array<uint8_t, 13> expected = {0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x41,0x55,0x41,0x54,0x53};
constexpr uint8_t expectedUUID[] = {0x93,0xfc,0xf1,0x37,0x72,0xe5,0x34,0xa1,0x82,0xfe,0x91,0x10,0xef,0x54,0xc3,0xc3};
std::atomic<unsigned> events{0};

void logStatus(const char *status) {
    // 只记录状态，不记录 XML、消息内容、账号或消息 ID。
    std::fprintf(stderr, "[RuntimeTipIntel] pid=%d %s\n", getpid(), status);
    std::fflush(stderr);
}

bool accessible(const void *pointer, size_t length, vm_prot_t required) {
    if (!pointer || !length) return false;
    mach_vm_address_t cursor = reinterpret_cast<mach_vm_address_t>(pointer);
    if (length > std::numeric_limits<mach_vm_address_t>::max() - cursor) return false;
    const auto end = cursor + length;
    while (cursor < end) {
        mach_vm_address_t address = cursor;
        mach_vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info{};
        while (true) {
            mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
            auto result = mach_vm_region_recurse(mach_task_self(), &address, &size, &depth,
                                      reinterpret_cast<vm_region_recurse_info_t>(&info), &count);
            if (result != KERN_SUCCESS || address > cursor || size == 0) return false;
            if (!info.is_submap) break;
            if (++depth > 32) return false;
        }
        if ((info.protection & required) != required || size > UINT64_MAX-address) return false;
        auto next = address+size;
        if (next <= cursor) return false;
        cursor = next;
    }
    return true;
}

bool copyString(const void *object, std::string &output, bool writable = false) {
    // 先按已核对的 libc++ 默认布局检查，不直接调用陌生对象的 size()/data()。
    if (!accessible(object, 24, VM_PROT_READ | (writable ? VM_PROT_WRITE : 0))) return false;
    uint64_t words[3];
    std::memcpy(words, object, sizeof(words));
    const auto *bytes = reinterpret_cast<const uint8_t *>(words);
    const char *data = nullptr;
    size_t length = 0;
    if (bytes[0] & 1) {
        uint64_t capacity = words[0] & ~uint64_t(1);
        length = words[1];
        if (capacity < 24 || capacity > (1u<<22) || length >= capacity || length > (1u<<20)) return false;
        data = reinterpret_cast<const char *>(words[2]);
        if (!accessible(data, length+1, VM_PROT_READ | (writable ? VM_PROT_WRITE : 0))) return false;
    } else {
        length = bytes[0] >> 1;
        if (length > 22) return false;
        data = static_cast<const char *>(object)+1;
    }
    if (data[length] != '\0') return false;
    output.assign(data, length);
    return true;
}

bool localABI() {
    if (sizeof(std::string) != 24) return false;
    std::string shortValue = "abc", longValue(100, 'x'), value;
    return copyString(&shortValue, value) && value == shortValue &&
           copyString(&longValue, value) && value == longValue;
}

bool xmlID(const std::string &xml, uint64_t &value) {
    const std::string open = "<newmsgid>", close = "</newmsgid>";
    auto start = xml.find(open);
    if (start == std::string::npos || xml.find(open, start+open.size()) != std::string::npos) return false;
    start += open.size();
    auto end = xml.find(close, start);
    if (end == std::string::npos || end == start || end-start > 20) return false;
    uint64_t n = 0;
    for (size_t i = start; i < end; ++i) {
        char c = xml[i];
        if (c < '0' || c > '9' || n > (UINT64_MAX-static_cast<unsigned>(c-'0'))/10) return false;
        n = n*10 + static_cast<unsigned>(c-'0');
    }
    value = n;
    return n != 0;
}

bool selfTip(const std::string &tip) {
    // 与仓库一致地保留本人撤回；只匹配起始文案，降低昵称误匹配。
    for (const char *prefix : {"You recalled ", "你撤回", "你收回", "你回收"}) {
        if (tip.rfind(prefix, 0) == 0) return true;
    }
    return false;
}

bool wrapper(void *message, std::string *xmlObject, void *flag) {
    const bool result = original(message, xmlObject, flag);
    if (!result || !message || !xmlObject) return result;
    try {
        std::string xml, tip;
        auto *base = static_cast<uint8_t *>(message);
        if (!copyString(xmlObject, xml) ||
            (xml.find("<revokemsg>") == std::string::npos && xml.find("<revokemsg ") == std::string::npos) ||
            !accessible(base+0x1c8, 8, VM_PROT_READ | VM_PROT_WRITE) ||
            !copyString(base+0x1d0, tip, true)) return result;
        if (selfTip(tip)) return result;
        // 本人提示在 XML 中出现时也保留，不修改 flag 或原始 XML。
        if (xml.find("你撤回") != std::string::npos || xml.find("You recalled ") != std::string::npos ||
            xml.find("你收回") != std::string::npos || xml.find("你回收") != std::string::npos) return result;
        uint64_t parsed = 0, actual = 0;
        std::memcpy(&actual, base+0x1c8, sizeof(actual));
        if (!xmlID(xml, parsed) || parsed != actual || tip.empty() ||
            (tip.find("撤回") == std::string::npos && tip.find(" recalled ") == std::string::npos)) return result;
        // 先完成可能分配内存的字符串写入，再清零 ID；失败时保留原始删除语义。
        auto *replace = reinterpret_cast<std::string *>(base+0x1d0);
        replace->assign("[已拦截撤回] " + tip);
        uint64_t zero = 0;
        std::memcpy(base+0x1c8, &zero, sizeof(zero));
        if (events.fetch_add(1) < 10) logStatus("recall intercepted; tip replaced (content not logged)");
    } catch (...) {
        logStatus("wrapper allocation/validation failure; keeping native result");
    }
    return result;
}

bool install(void *entry) {
    if (original) { logStatus("refused: already installed in this runtime instance"); return false; }
    if (!localABI()) { logStatus("refused: local libc++ layout mismatch"); return false; }
    if (!accessible(entry, expected.size(), VM_PROT_READ | VM_PROT_EXECUTE)) {
        logStatus("refused: entry unreadable or not executable"); return false;
    }
    if (std::memcmp(entry, expected.data(), expected.size()) != 0) {
        logStatus("refused: entry expected bytes mismatch"); return false;
    }
    size_t pageSize = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    auto start = reinterpret_cast<uintptr_t>(entry);
    auto page = start & ~(pageSize-1);
    if (start+expected.size() > page+pageSize) return false;
    // trampoline 在入口发布之前完成初始化；不支持运行中异步热安装。
    void *memory = mmap(nullptr, pageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (memory == MAP_FAILED) { logStatus("refused: mmap RW failed"); return false; }
    uint8_t buffer[27]{};
    std::memcpy(buffer, expected.data(), expected.size());
    const uint8_t jump[] = {0xff,0x25,0,0,0,0};
    std::memcpy(buffer+13, jump, sizeof(jump));
    uintptr_t continuation = start+13;
    std::memcpy(buffer+19, &continuation, sizeof(continuation));
    std::memcpy(memory, buffer, sizeof(buffer));
    if (mprotect(memory, pageSize, PROT_READ | PROT_EXEC) != 0) {
        logStatus("refused: trampoline RX protection failed"); munmap(memory,pageSize); return false;
    }
    if (!accessible(memory,sizeof(buffer),VM_PROT_READ | VM_PROT_EXECUTE)) {
        munmap(memory,pageSize); return false;
    }
    uint8_t patch[13] = {0x48,0xb8};
    uintptr_t replacement = reinterpret_cast<uintptr_t>(&wrapper);
    std::memcpy(patch+2,&replacement,sizeof(replacement));
    patch[10]=0xff; patch[11]=0xe0; patch[12]=0x90;
    if (std::memcmp(entry,expected.data(),expected.size()) != 0 ||
        mach_vm_protect(mach_task_self(),page,pageSize,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS) {
        logStatus("refused: target code COW write permission failed"); munmap(memory,pageSize); return false;
    }
    original = reinterpret_cast<Parser>(memory);
    std::memcpy(entry,patch,sizeof(patch));
    __builtin___clear_cache(static_cast<char *>(entry),static_cast<char *>(entry)+sizeof(patch));
    if (mach_vm_protect(mach_task_self(),page,pageSize,FALSE,VM_PROT_READ|VM_PROT_EXECUTE)!=KERN_SUCCESS) {
        // 无法恢复代码页权限时不允许继续启动实验 App。
        logStatus("fatal: cannot restore RX protection");
        _exit(78);
    }
    if (!accessible(entry,expected.size(),VM_PROT_READ|VM_PROT_EXECUTE) ||
        std::memcmp(entry,patch,sizeof(patch))!=0) {
        logStatus("fatal: hook readback failed"); _exit(78);
    }
    logStatus("hook installed; expected bytes, trampoline and RX readback verified");
    return true;
}

#ifndef RTI_SELFTEST
void imageAdded(const mach_header *raw, intptr_t slide) {
    if (raw->magic!=MH_MAGIC_64 || raw->cputype!=CPU_TYPE_X86_64) return;
    auto *header = reinterpret_cast<const mach_header_64 *>(raw);
    const uint8_t *cursor = reinterpret_cast<const uint8_t *>(header)+sizeof(*header);
    bool uuidOK=false, textOK=false;
    for (uint32_t i=0; i<header->ncmds; ++i) {
        auto *lc = reinterpret_cast<const load_command *>(cursor);
        if (lc->cmd==LC_UUID) {
            auto *uuid = reinterpret_cast<const uuid_command *>(cursor);
            uuidOK=std::memcmp(uuid->uuid,expectedUUID,sizeof(expectedUUID))==0;
        }
        if (lc->cmd==LC_SEGMENT_64) {
            auto *seg=reinterpret_cast<const segment_command_64 *>(cursor);
            auto *sections=reinterpret_cast<const section_64 *>(seg+1);
            for (uint32_t j=0; j<seg->nsects; ++j) {
                auto &s=sections[j];
                if (std::strncmp(s.sectname,"__text",16)==0 && s.addr<=0x512c510 && 0x512cd79<s.addr+s.size) textOK=true;
            }
        }
        cursor+=lc->cmdsize;
    }
    if (!uuidOK || !textOK || original) return;
    auto *entry=reinterpret_cast<uint8_t *>(slide+0x512c510);
    const uint8_t store[]={0x48,0x89,0x83,0xc8,0x01,0,0};
    if (!accessible(reinterpret_cast<void *>(slide+0x512cd72),sizeof(store),VM_PROT_READ) ||
        std::memcmp(reinterpret_cast<void *>(slide+0x512cd72),store,sizeof(store))!=0) {
        logStatus("refused: newmsgid anchor mismatch"); return;
    }
    if (!install(entry)) logStatus("refused: hook installation preconditions failed");
}
#endif
}

#ifdef RTI_SELFTEST
extern "C" bool rti_test_install(void *entry) { return install(entry); }
extern "C" unsigned rti_test_events() { return events.load(); }
#else
__attribute__((constructor)) static void initialize() {
    // 仅输出映像、函数地址和调用链，不记录业务参数或消息。
    Dl_info own{};
    constexpr const char *runtimePath="/Applications/WeChat.app/Contents/Resources/RuntimeTipIntel.dylib";
    if (!dladdr(reinterpret_cast<const void *>(&initialize), &own) || !own.dli_fname ||
        std::strcmp(own.dli_fname,runtimePath)!=0) {
        logStatus("refused: runtime image outside exact experiment Resources path"); return;
    }
    if (std::getenv("RTI_TRACE_INIT") != nullptr) {
    std::fprintf(stderr,"[RuntimeTipIntel] pid=%d init-trace base=%p state=%p original=%p path=%s\n",
                 getpid(),own.dli_fbase,static_cast<void *>(&original),reinterpret_cast<void *>(original),
                 own.dli_fname ? own.dli_fname : "unknown");
    void *frames[16];
    int count=backtrace(frames,16);
    for (int i=0;i<count;++i) {
        Dl_info info{};
        if (dladdr(frames[i],&info)) {
            const char *name=info.dli_fname ? std::strrchr(info.dli_fname,'/') : nullptr;
            std::fprintf(stderr,"[RuntimeTipIntel] pid=%d init-frame=%d image=%s offset=0x%llx symbol=%s\n",
                         getpid(),i,name ? name+1 : "unknown",
                         static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(frames[i])-reinterpret_cast<uintptr_t>(info.dli_fbase)),
                         info.dli_sname ? info.dli_sname : "unknown");
        }
    }
    }
    @autoreleasepool {
        NSBundle *bundle=[NSBundle mainBundle];
        NSString *expectedPath=@"/Applications/WeChat.app";
        if (![[bundle bundlePath] isEqualToString:expectedPath] ||
            ![[bundle bundleIdentifier] isEqualToString:@"com.tencent.xinWeChat"] ||
            ![[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqualToString:@"269630"]) {
            logStatus("refused: experiment bundle identity/path/build mismatch"); return;
        }
        logStatus("runtime loaded in exact experiment bundle");
        _dyld_register_func_for_add_image(imageAdded);
    }
}
#endif
