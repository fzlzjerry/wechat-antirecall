#include <sys/mman.h>
#include <unistd.h>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

extern "C" {
extern const uint8_t fixture_start[], fixture_end[];
bool rti_test_install(void *);
unsigned rti_test_events();
unsigned checked_invoke(bool (*)(void *, std::string *, void *), void *, std::string *, void *, bool *);
bool body_entry(void *,std::string *,void *);
}
struct Message {
    std::array<uint8_t,0x1c0> pad{};
    uint64_t before=0x123456789abcdef0ULL;
    uint64_t id=0;
    std::string tip;
    uint64_t after=0xfedcba9876543210ULL;
};
static_assert(offsetof(Message,id)==0x1c8 && offsetof(Message,tip)==0x1d0);
struct Probe {
    void *message;
    std::string *xml;
    std::string tip;
    uint64_t id;
    bool result;
    unsigned calls=0;
};
void check(bool value,const char *message) {
    if (!value) { std::fprintf(stderr,"FAIL %s\n",message);std::exit(1); }
}
extern "C" bool body_impl(void *message,std::string *xml,void *context,uintptr_t alignment) {
    auto *probe=static_cast<Probe *>(context);
    check(message==probe->message && xml==probe->xml && alignment==8,"parser ABI");
    auto *msg=static_cast<Message *>(message);
    msg->id=probe->id;msg->tip=probe->tip; ++probe->calls;
    return probe->result;
}
extern "C" bool wrapper_impl(void *,std::string *,void *,uintptr_t) { std::abort(); }
int main() {
    size_t page=static_cast<size_t>(sysconf(_SC_PAGESIZE));
    auto *memory=static_cast<uint8_t *>(mmap(nullptr,page,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0));
    check(memory!=MAP_FAILED,"mmap");
    size_t size=reinterpret_cast<uintptr_t>(fixture_end)-reinterpret_cast<uintptr_t>(fixture_start);
    std::memcpy(memory,fixture_start,size);
    uint64_t marker=0x1122334455667788ULL;
    uintptr_t destination=reinterpret_cast<uintptr_t>(&body_entry);
    unsigned replaced=0;
    for (size_t i=0;i+8<=size;++i) if (std::memcmp(memory+i,&marker,8)==0) {
        std::memcpy(memory+i,&destination,8); ++replaced;
    }
    check(replaced==1,"one body address");
    check(mprotect(memory,page,PROT_READ|PROT_EXEC)==0,"RX mapping");
    check(rti_test_install(memory),"actual runtime installer");
    check(!rti_test_install(memory),"reject duplicate hook install");
    auto target=reinterpret_cast<bool (*)(void *,std::string *,void *)>(memory);
    for (unsigned i=0;i<100;++i) {
        Message msg;
        std::string xml="<sysmsg type=\"revokemsg\"><revokemsg><newmsgid>12345</newmsgid><replacemsg><![CDATA[张三撤回了一条消息]]></replacemsg></revokemsg></sysmsg>";
        Probe probe{&msg,&xml,"张三撤回了一条消息",12345,true};
        bool changed=true;
        switch (i%5) {
            case 1: probe.tip="你撤回了一条消息";changed=false;break;
            case 2: probe.id=999;changed=false;break;
            case 3: probe.result=false;changed=false;break;
            case 4: probe.tip="\""+std::string(300,'A')+"\" recalled a message";break;
        }
        std::string expected=probe.tip;
        bool result=false;
        check(checked_invoke(target,&msg,&xml,&probe,&result)==0,"registers/stack canaries");
        check(result==probe.result && probe.calls==1,"return preserved/original exactly once");
        check(msg.id==(changed?0:probe.id),"id policy");
        check(msg.tip==(changed?"[已拦截撤回] "+expected:expected),"actual runtime tip wrapper");
        check(msg.before==0x123456789abcdef0ULL && msg.after==0xfedcba9876543210ULL,"adjacent canaries");
    }
    check(rti_test_events()==40,"event count");
    check(munmap(memory,page)==0,"release fixture");
    std::puts("PASS: actual runtime installer/wrapper: 100 cases; ABI, strings, self-recall, mismatch, false result, duplicate install");
}
