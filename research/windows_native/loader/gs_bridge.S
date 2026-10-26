/* x86_64 child-only experiment. Apple private protocol, not a stable API:
 * XNU f6217f891ac0bb64f3d375211650a4c1ff8ca1ea
 * libsyscall/custom/custom.s (__thread_set_tsd_base, x86_64)
 * osfmk/mach/i386/syscall_sw.h (MDEP class 3, shift 24).
 * Own minimal gateway; no Apple test code is copied here.
 */
#include "gs_probe.h"
#if !defined(__APPLE__) || !defined(__x86_64__)
#error "GS research bridge requires Darwin x86_64"
#endif
.text
.p2align 4
.globl _pm_gs_read_host_words
_pm_gs_read_host_words:
    movq %gs:0, %rax
    movq %rax, 0(%rdi)
    movq %gs:8, %rax
    movq %rax, 8(%rdi)
    movq %gs:16, %rax
    movq %rax, 16(%rdi)
    movq %gs:24, %rax
    movq %rax, 24(%rdi)
    ret

/* All live context/restoration addresses are callee-saved or stack-resident.
 * SYSCALL clobbers RCX/R11, and uses RDI for base + ESI=0. CF is recorded,
 * never interpreted as success without observing GS reads afterwards.
 */
.macro SET_BASE offset
    movq \offset(%r12), %rdi
    xorl %esi, %esi
    movl $0x03000003, %eax
    syscall
    movq %rax, GS_SET_RESULT(%r12)
    setc %al
    movzbl %al, %eax
    movq %rax, GS_SET_CARRY(%r12)
.endmacro

.macro CHECK_HOST failure_label
    cmpq $0, GS_SET_CARRY(%r12)
    jne \failure_label
    movq %gs:0, %rax
    cmpq GS_HOST_WORDS(%r12), %rax
    jne \failure_label
    movq %gs:8, %rax
    cmpq GS_HOST_WORDS+8(%r12), %rax
    jne \failure_label
    movq %gs:16, %rax
    cmpq GS_HOST_WORDS+16(%r12), %rax
    jne \failure_label
    movq %gs:24, %rax
    cmpq GS_HOST_WORDS+24(%r12), %rax
    jne \failure_label
.endmacro

.macro SNAPSHOT_REGISTERS
    movq %rbx, GS_REGISTERS(%r12)
    movq %rbp, GS_REGISTERS+8(%r12)
    movq %rdi, GS_REGISTERS+16(%r12)
    movq %rsi, GS_REGISTERS+24(%r12)
    movq %r12, GS_REGISTERS+32(%r12)
    movq %r13, GS_REGISTERS+40(%r12)
    movq %r14, GS_REGISTERS+48(%r12)
    movq %r15, GS_REGISTERS+56(%r12)
    movdqu %xmm6, GS_XMM(%r12)
    movdqu %xmm7, GS_XMM+16(%r12)
    movdqu %xmm8, GS_XMM+32(%r12)
    movdqu %xmm9, GS_XMM+48(%r12)
    movdqu %xmm10, GS_XMM+64(%r12)
    movdqu %xmm11, GS_XMM+80(%r12)
    movdqu %xmm12, GS_XMM+96(%r12)
    movdqu %xmm13, GS_XMM+112(%r12)
    movdqu %xmm14, GS_XMM+128(%r12)
    movdqu %xmm15, GS_XMM+144(%r12)
.endmacro

.p2align 4
.globl _pm_gs_roundtrip
_pm_gs_roundtrip:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $40, %rsp              /* 16-aligned + 32 byte Win64 shadow space */
    movq %rdi, %r12
    movq $1, GS_STAGE(%r12)
    SET_BASE GS_HOST_BASE       /* first, no-op host-base setter qualification */
    CHECK_HOST Lrestore_failed
    movq $2, GS_STAGE(%r12)
    SET_BASE GS_GUEST_BASE
    cmpq $0, GS_SET_CARRY(%r12)
    jne Lguest_unavailable
    movq %gs:GS_TEB_SELF, %rax
    cmpq GS_GUEST_BASE(%r12), %rax
    jne Lguest_unavailable
    movq $3, GS_STAGE(%r12)
    /* Distinct Windows nonvolatile sentinels, including RDI/RSI and XMM6..15. */
    movq $0x1357, %rbx
    movq $0x2468, %rbp
    movq $0x3579, %rdi
    movq $0x468a, %rsi
    movq $0x579b, %r13
    movq $0x68ac, %r14
    movq $0x79bd, %r15
    movdqu Lxmm_sentinels(%rip), %xmm6
    movdqu Lxmm_sentinels+16(%rip), %xmm7
    movdqu Lxmm_sentinels+32(%rip), %xmm8
    movdqu Lxmm_sentinels+48(%rip), %xmm9
    movdqu Lxmm_sentinels+64(%rip), %xmm10
    movdqu Lxmm_sentinels+80(%rip), %xmm11
    movdqu Lxmm_sentinels+96(%rip), %xmm12
    movdqu Lxmm_sentinels+112(%rip), %xmm13
    movdqu Lxmm_sentinels+128(%rip), %xmm14
    movdqu Lxmm_sentinels+144(%rip), %xmm15
Lguest_iteration:
    movq %gs:GS_TEB_SELF, %rax
    cmpq GS_GUEST_BASE(%r12), %rax
    jne Lguest_invalid
    movq %gs:GS_TEB_TLS_VECTOR, %rax
    cmpq GS_TLS_VECTOR(%r12), %rax
    jne Lguest_invalid
    movq 8(%rax), %rax          /* fixture module index 1, real GS-derived path */
    cmpq GS_TLS_BLOCK(%r12), %rax
    jne Lguest_invalid
    incq GS_READS(%r12)
    addq $1, (%rax)
    incq GS_WRITES(%r12)
    movl $0x76543210, %gs:GS_TEB_LAST_ERROR
    SNAPSHOT_REGISTERS
    movq %r12, %rcx
    call *GS_IMPORT(%r12)       /* Win64 import-style indirect call, not a PE */
    cmpq $0, GS_FAILURE(%r12)
    jne Lrestore_host
    SNAPSHOT_REGISTERS
    cmpq $2, GS_CALLBACKS(%r12)
    jb Lguest_iteration
    jmp Lrestore_host
Lguest_unavailable:
    movq $77, GS_FAILURE(%r12)
    jmp Lrestore_host
Lguest_invalid:
    movq $1, GS_FAILURE(%r12)
Lrestore_host:
    movq $7, GS_STAGE(%r12)
    SET_BASE GS_HOST_BASE
    CHECK_HOST Lrestore_failed
Lhost_confirmed:
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

/* A first failed restore gets one raw retry. If it cannot be observed, never
 * return to C, libc, a signal handler, or an instrumented runtime. Raw exit78
 * terminates ONLY this disposable child; the runner records restoration as
 * unconfirmed, not success. SIGILL from the syscall is likewise child-contained.
 */
Lrestore_failed:
    SET_BASE GS_HOST_BASE
    CHECK_HOST Lraw_exit
    movq $77, GS_FAILURE(%r12)
    jmp Lhost_confirmed
Lraw_exit:
    movl $78, %edi
    movl $0x02000001, %eax
    syscall
    ud2

.p2align 4
.globl _pm_gs_import_gateway
_pm_gs_import_gateway:
    pushq %rbp
    pushq %rbx
    pushq %rdi
    pushq %rsi
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $184, %rsp             /* SysV call-aligned; 160 bytes vectors + ctx */
    movdqu %xmm6, 0(%rsp)
    movdqu %xmm7, 16(%rsp)
    movdqu %xmm8, 32(%rsp)
    movdqu %xmm9, 48(%rsp)
    movdqu %xmm10, 64(%rsp)
    movdqu %xmm11, 80(%rsp)
    movdqu %xmm12, 96(%rsp)
    movdqu %xmm13, 112(%rsp)
    movdqu %xmm14, 128(%rsp)
    movdqu %xmm15, 144(%rsp)
    movq %rcx, 160(%rsp)
    movq %rcx, %r12
    movq %rsp, %rax
    andq $15, %rax
    cmpq $0, %rax
    sete %al
    movzbl %al, %eax
    movq %rax, GS_STACK_ALIGNED(%r12)
    SET_BASE GS_HOST_BASE
    CHECK_HOST Lraw_gateway_restore
    movq $4, GS_STAGE(%r12)
    movq %r12, %rdi             /* Win64 RCX input -> SysV RDI input */
    call *GS_CALLBACK(%r12)     /* first and only host call; Darwin GS checked */
    movq 160(%rsp), %r12
    movq $5, GS_STAGE(%r12)
    SET_BASE GS_GUEST_BASE
    cmpq $0, GS_SET_CARRY(%r12)
    jne Lgateway_unavailable
    movq %gs:GS_TEB_SELF, %rax
    cmpq GS_GUEST_BASE(%r12), %rax
    jne Lgateway_unavailable
    jmp Lgateway_return
Lgateway_unavailable:
    movq $77, GS_FAILURE(%r12)
    SET_BASE GS_HOST_BASE
    CHECK_HOST Lraw_gateway_restore
    jmp Lgateway_return
Lraw_gateway_restore:
    SET_BASE GS_HOST_BASE
    CHECK_HOST Lraw_exit
    movq $77, GS_FAILURE(%r12)
Lgateway_return:
    movdqu 0(%rsp), %xmm6
    movdqu 16(%rsp), %xmm7
    movdqu 32(%rsp), %xmm8
    movdqu 48(%rsp), %xmm9
    movdqu 64(%rsp), %xmm10
    movdqu 80(%rsp), %xmm11
    movdqu 96(%rsp), %xmm12
    movdqu 112(%rsp), %xmm13
    movdqu 128(%rsp), %xmm14
    movdqu 144(%rsp), %xmm15
    addq $184, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rsi
    popq %rdi
    popq %rbx
    popq %rbp
    ret

.section __TEXT,__const
.p2align 4
Lxmm_sentinels:
    .fill 16,1,6
    .fill 16,1,7
    .fill 16,1,8
    .fill 16,1,9
    .fill 16,1,10
    .fill 16,1,11
    .fill 16,1,12
    .fill 16,1,13
    .fill 16,1,14
    .fill 16,1,15
.subsections_via_symbols
