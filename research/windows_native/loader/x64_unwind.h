#ifndef PLAYMELT_X64_UNWIND_H
#define PLAYMELT_X64_UNWIND_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PM_UNWIND_MAX_IMAGE (1024u * 1024u)
#define PM_UNWIND_MAX_STACK (1024u * 1024u)
#define PM_UNWIND_MAX_FUNCTIONS 4096u
#define PM_UNWIND_MAX_SLOTS 64u
#define PM_UNWIND_MAX_EPILOG_BYTES 160u

typedef struct pm_x64_context {
    uint64_t gpr[16]; /* PE register numbering: RAX=0, RBX=3, RSP=4, R12=12. */
    uint64_t rip;
} pm_x64_context;

typedef struct pm_runtime_function {
    uint32_t begin_rva, end_rva, unwind_rva; /* End is exclusive. */
} pm_runtime_function;

typedef struct pm_unwind_image {
    /* A flat, entirely readable, immutable RVA projection, NOT a pointer to a
     * sparse executable mapping with unreadable gaps. No logical address is
     * ever dereferenced. Host provides correctly sized readable C buffers. */
    const uint8_t *bytes;
    size_t size;
    uint64_t address;
    const pm_runtime_function *functions;
    size_t function_count;
    int catalog_complete; /* Must be exactly 1; host attests complete catalogue. */
    int allow_leaf;       /* Default 0: absence of an entry FAILS. Explicit 1
                          * only for host-known ABI-conformant leaf code. */
} pm_unwind_image;

typedef struct pm_unwind_stack {
    const uint8_t *bytes; /* Immutable, bounded snapshot, not a live stack walker. */
    size_t size;
    uint64_t address;
} pm_unwind_stack;

typedef enum pm_unwind_phase {
    PM_UNWIND_LEAF = 1,
    PM_UNWIND_PROLOG = 2,
    PM_UNWIND_BODY = 3,
    PM_UNWIND_EPILOG = 4
} pm_unwind_phase;

typedef struct pm_unwind_result {
    pm_unwind_phase phase;
    uint32_t restored_nonvolatile_mask;
    uint32_t operations_applied;
    uint32_t stack_words_read;
    uint64_t stack_advance;
} pm_unwind_result;

/* HOST ABI only; not RtlVirtualUnwind, SEH, an exception dispatcher or Windows
 * CONTEXT. Computes ONE caller frame in a local copy. input/output may be the
 * same context. output and result remain byte-for-byte unchanged on ANY failure;
 * error may change. Outputs/error must not overlap each other, source views or
 * input context, except for the explicitly permitted output==input case.
 * Volatile GPR values are carried through, NOT reconstructed; SIMD/RFLAGS/TEB,
 * handlers, chain/frame-register info, dynamic tables and continuation absent.
 * The resulting RIP is copied from the stack; it is never invoked or certified
 * executable. No heap allocation, recursion, process, signal or GPU activity.
 *
 * The host must establish ABI-conformant code and an instruction-boundary RIP;
 * this module is not a general x86 disassembler or metadata/code verifier.
 * Complete table declaration and explicit leaf permission are enforced, but
 * neither is inferred/proven from the absence of a .pdata entry. All catalogue
 * entries and their metadata are validated, including entries outside the PC.
 * Version 1 / flags 0 / frame byte 0 and only PUSH_NONVOL, ALLOC_SMALL, and both
 * ALLOC_LARGE forms are accepted using the shortest allocation encoding.
 * PUSH codes must be last in the unwind array. Slots/stack movement are bounded.
 * Partial prolog (offset < SizeOfProlog): apply CodeOffset <= RIP-Begin.
 * At the completed-prolog boundary, inspect the instruction for an epilog first;
 * if none, classify PROLOG and reverse all operations. This preserves Microsoft's
 * <= prolog classification without letting unknown epilogs bypass rejection.
 * Body: reverse all operations. Leaf is never an error fallback.
 * Epilog: exact suffix of [ADD RSP,positive aligned imm8/imm32], nonvolatile POPs,
 * RET C3, matching a suffix of the unwind operations. No LEA/tail-JMP/RETimm or
 * unusual prefixes. Plausible but unsupported/truncated epilogs explicitly fail
 * rather than silently using body unwind. No frame-pointer or chained fallback.
 */
int pm_x64_unwind_one(const pm_unwind_image *image, const pm_unwind_stack *stack,
    const pm_x64_context *input, pm_x64_context *output, pm_unwind_result *result,
    char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
