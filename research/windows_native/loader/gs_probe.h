#ifndef PM_GS_PROBE_H
#define PM_GS_PROBE_H

/* Research child ONLY. Not a loader interface, complete TEB, Windows TLS
 * initialization, signal trampoline, or generally reentrant import bridge.
 * The process running this experiment must be a disposable dedicated child.
 * All recoverable asynchronous signals are masked over the assembly interval.
 * Synchronous faults terminate that child; no C handler runs with guest GS.
 * Only the assembly bridge and a raw private Apple machdep syscall execute
 * while guest GS is installed. All host C executes after checked restoration.
 * Win64 nonvolatile GPRs and XMM6..15 are preserved by the assembly gateway;
 * arithmetic flags/volatile registers are not preserved by the Win64 ABI.
 * No AVX upper halves, SEH, callbacks/reentrancy, or second thread is qualified.
 */
#define GS_HOST_BASE 0
#define GS_GUEST_BASE 8
#define GS_TLS_VECTOR 16
#define GS_TLS_BLOCK 24
#define GS_IMPORT 32
#define GS_CALLBACK 40
#define GS_HOST_WORDS 48
#define GS_PTHREAD 80
#define GS_ERRNO_POINTER 88
#define GS_ERRNO_VALUE 96
#define GS_FAILURE 104
#define GS_STAGE 112
#define GS_CALLBACKS 120
#define GS_READS 128
#define GS_WRITES 136
#define GS_SET_RESULT 144
#define GS_SET_CARRY 152
#define GS_REGISTERS 160
#define GS_XMM 224
#define GS_STACK_ALIGNED 384
#define GS_RESTORED 392
#define GS_CONTEXT_SIZE 400
#define GS_TEB_SELF 0x30
#define GS_TEB_TLS_VECTOR 0x58
#define GS_TEB_LAST_ERROR 0x68

#ifndef __ASSEMBLER__
#include <stddef.h>
#include <stdint.h>
typedef struct pm_gs_context {
    uint64_t host_base, guest_base, tls_vector, tls_block;
    uint64_t import_entry, callback;
    uint64_t host_words[4];
    uint64_t expected_pthread, errno_pointer, errno_value;
    uint64_t failure, stage, callbacks, reads, writes;
    uint64_t set_result, set_carry;
    uint64_t registers[8];
    uint8_t xmm[160];
    uint64_t stack_aligned, restored;
} pm_gs_context;
_Static_assert(sizeof(pm_gs_context)==GS_CONTEXT_SIZE,"context assembly size");
#define GS_OFFSET(field,constant) _Static_assert(offsetof(pm_gs_context,field)==constant,"assembly offset " #field)
GS_OFFSET(host_base,GS_HOST_BASE); GS_OFFSET(guest_base,GS_GUEST_BASE);
GS_OFFSET(tls_vector,GS_TLS_VECTOR); GS_OFFSET(tls_block,GS_TLS_BLOCK);
GS_OFFSET(import_entry,GS_IMPORT); GS_OFFSET(callback,GS_CALLBACK);
GS_OFFSET(host_words,GS_HOST_WORDS); GS_OFFSET(expected_pthread,GS_PTHREAD);
GS_OFFSET(errno_pointer,GS_ERRNO_POINTER); GS_OFFSET(errno_value,GS_ERRNO_VALUE);
GS_OFFSET(failure,GS_FAILURE); GS_OFFSET(stage,GS_STAGE);
GS_OFFSET(callbacks,GS_CALLBACKS); GS_OFFSET(reads,GS_READS);
GS_OFFSET(writes,GS_WRITES); GS_OFFSET(set_result,GS_SET_RESULT);
GS_OFFSET(set_carry,GS_SET_CARRY); GS_OFFSET(registers,GS_REGISTERS);
GS_OFFSET(xmm,GS_XMM); GS_OFFSET(stack_aligned,GS_STACK_ALIGNED);
GS_OFFSET(restored,GS_RESTORED);
#undef GS_OFFSET

/* No pointer arguments originate in a file, UI, other process, or real PE.
 * Context and buffers are initialized by this one host test and stay live.
 */
void pm_gs_read_host_words(uint64_t words[4]);
uint64_t pm_gs_roundtrip(pm_gs_context *context);
uint64_t __attribute__((ms_abi)) pm_gs_import_gateway(pm_gs_context *context);
#endif
#endif
