/* Dedicated disposable-child wrapper. Reuses the unchanged gs_bridge gateway.
 * Apple private Machdep3 protocol/source/limits documented in GS_PROBE.md. */
#include "gs_pe_probe.h"
#if !defined(__APPLE__) || !defined(__x86_64__)
#error "Darwin AMD64 only"
#endif
.text
.macro PE_SET_BASE offset
    movq \offset(%r12), %rdi
    xorl %esi, %esi
    movl $0x03000003, %eax
    syscall
    movq %rax, GS_SET_RESULT(%r12)
    setc %al
    movzbl %al, %eax
    movq %rax, GS_SET_CARRY(%r12)
.endmacro
.macro PE_CHECK_HOST failure
    cmpq $0, GS_SET_CARRY(%r12)
    jne \failure
    movq %gs:0, %rax
    cmpq GS_HOST_WORDS(%r12), %rax
    jne \failure
    movq %gs:8, %rax
    cmpq GS_HOST_WORDS+8(%r12), %rax
    jne \failure
    movq %gs:16, %rax
    cmpq GS_HOST_WORDS+16(%r12), %rax
    jne \failure
    movq %gs:24, %rax
    cmpq GS_HOST_WORDS+24(%r12), %rax
    jne \failure
.endmacro
.p2align 4
.globl _pm_gs_invoke_pe
_pm_gs_invoke_pe:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $40, %rsp              /* aligned CALL + Win64 shadow space */
    movq %rdi, %r12
    movq %rsi, %r13             /* save mapping entry before setter clobbers RSI */
    movq $1, GS_STAGE(%r12)
    PE_SET_BASE GS_HOST_BASE
    PE_CHECK_HOST Lpe_retry
    movq $2, GS_STAGE(%r12)
    PE_SET_BASE GS_GUEST_BASE
    cmpq $0, GS_SET_CARRY(%r12)
    jne Lpe_unsupported
    movq %gs:GS_TEB_SELF, %rax
    cmpq GS_GUEST_BASE(%r12), %rax
    jne Lpe_unsupported
    movq $3, GS_STAGE(%r12)
    incq GS_PE_ENTRY_CALLS(%r12)
    movq %r12, %rcx
    call *%r13                 /* actual RX entry in the loader-owned PE mapping */
    movq %rax, GS_PE_ENTRY_RESULT(%r12)
    jmp Lpe_restore
Lpe_unsupported:
    movq $77, GS_FAILURE(%r12)
Lpe_restore:
    movq $7, GS_STAGE(%r12)
    PE_SET_BASE GS_HOST_BASE
    PE_CHECK_HOST Lpe_retry
Lpe_confirmed:
    movq $1, GS_RESTORED(%r12)
    movq $8, GS_STAGE(%r12)
    movq GS_FAILURE(%r12), %rax
    addq $40, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
Lpe_retry:
    PE_SET_BASE GS_HOST_BASE
    PE_CHECK_HOST Lpe_raw_exit
    movq $77, GS_FAILURE(%r12)
    jmp Lpe_confirmed
Lpe_raw_exit:
    movl $78, %edi
    movl $0x02000001, %eax
    syscall
    ud2
.subsections_via_symbols
