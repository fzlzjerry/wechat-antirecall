#if !defined(__x86_64__)
#error 此自测只支持 x86_64
#endif

.text
.p2align 4
.globl _fixture_start
.globl _fixture_end
_fixture_start:
    // 与只读样本一致的 13 字节完整序言，不包含相对寻址指令。
    pushq %rbp
    movq %rsp, %rbp
    pushq %r15
    pushq %r14
    pushq %r13
    pushq %r12
    pushq %rbx
    subq $8, %rsp
    // 主动改写非易失寄存器，确保测试能检测到漏恢复。
    movq $101, %rbp
    movq $102, %rbx
    movq $103, %r12
    movq $104, %r13
    movq $105, %r14
    movq $106, %r15
    // 复制到匿名内存后，将此唯一占位值替换为自测 body_entry 地址。
    movabsq $0x1122334455667788, %rax
    callq *%rax
    addq $8, %rsp
    popq %rbx
    popq %r12
    popq %r13
    popq %r14
    popq %r15
    popq %rbp
    retq
_fixture_end:

.p2align 4
.globl _wrapper_entry
_wrapper_entry:
    // 在编译器序言之前捕获真实入口栈对齐，作为第四参数传递。
    movq %rsp, %rcx
    andq $15, %rcx
    jmp _wrapper_impl

.p2align 4
.globl _body_entry
_body_entry:
    movq %rsp, %rcx
    andq $15, %rcx
    jmp _body_impl

.p2align 4
.globl _checked_invoke
_checked_invoke:
    // 参数为 target、message、xml、probe、resultOut。
    pushq %rbp
    pushq %r15
    pushq %r14
    pushq %r13
    pushq %r12
    pushq %rbx
    subq $40, %rsp
    movq %r8, 0(%rsp)
    movq %rsp, 8(%rsp)
    movq $0x654321, 24(%rsp)
    movq %rdi, %rax
    movq %rsi, %rdi
    movq %rdx, %rsi
    movq %rcx, %rdx
    movq $0x1234501, %rbp
    movq $0x1234502, %rbx
    movq $0x1234503, %r12
    movq $0x1234504, %r13
    movq $0x1234505, %r14
    movq $0x1234506, %r15
    callq *%rax
    movq 0(%rsp), %rcx
    movb %al, (%rcx)
    xorl %eax, %eax
    cmpq $0x1234501, %rbp
    setne %dl
    movzbl %dl, %edx
    orl %edx, %eax
    cmpq $0x1234502, %rbx
    setne %dl
    movzbl %dl, %edx
    shll $1, %edx
    orl %edx, %eax
    cmpq $0x1234503, %r12
    setne %dl
    movzbl %dl, %edx
    shll $2, %edx
    orl %edx, %eax
    cmpq $0x1234504, %r13
    setne %dl
    movzbl %dl, %edx
    shll $3, %edx
    orl %edx, %eax
    cmpq $0x1234505, %r14
    setne %dl
    movzbl %dl, %edx
    shll $4, %edx
    orl %edx, %eax
    cmpq $0x1234506, %r15
    setne %dl
    movzbl %dl, %edx
    shll $5, %edx
    orl %edx, %eax
    cmpq 8(%rsp), %rsp
    setne %dl
    movzbl %dl, %edx
    shll $6, %edx
    orl %edx, %eax
    cmpq $0x654321, 24(%rsp)
    setne %dl
    movzbl %dl, %edx
    shll $7, %edx
    orl %edx, %eax
    testq $15, %rsp
    setne %dl
    movzbl %dl, %edx
    shll $8, %edx
    orl %edx, %eax
    addq $40, %rsp
    popq %rbx
    popq %r12
    popq %r13
    popq %r14
    popq %r15
    popq %rbp
    retq

.p2align 4
.globl _rip_fixture_start
.globl _rip_fixture_end
_rip_fixture_start:
    // 前 13 字节包含一个 RIP-relative load，随后保留 rax 与 ZF。
    movq L_rip_value(%rip), %rax
    addq %rsi, %rax
    nop
    nop
    nop
    jz L_rip_zero
    addq $1, %rax
    retq
L_rip_zero:
    movq $0x77, %rax
    retq
.p2align 3
L_rip_value:
    .quad 0x12345678
_rip_fixture_end:
