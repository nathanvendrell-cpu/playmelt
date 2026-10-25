#ifndef PLAYMELT_WINAPI_MEMORY_H
#define PLAYMELT_WINAPI_MEMORY_H

#include "winapi_subset.h"
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pm_winapi_memory pm_winapi_memory;

enum {
    PM_PAGE_NOACCESS = 0x01,
    PM_PAGE_READONLY = 0x02,
    PM_PAGE_READWRITE = 0x04,
    PM_PAGE_EXECUTE_READ = 0x20,
    PM_MEMORY_ERROR_ACCESS_DENIED = 5,
    PM_MEMORY_ERROR_NOT_ENOUGH_MEMORY = 8,
    PM_MEMORY_ERROR_INVALID_ADDRESS = 487,
    PM_MEMORY_ERROR_NOACCESS = 998
};
#define PM_MEMORY_MAX_REGIONS 8u
#define PM_MEMORY_MAX_REGION_BYTES (1024u * 1024u)
#define PM_MEMORY_MAX_TOTAL_BYTES (4u * 1024u * 1024u)

/* HOST ABI, not VirtualAlloc/VirtualFree. Own small anonymous allocations; no
 * imported/borrowed memory registration exists. Allocation rounds up to host
 * pages and starts RW; returned rounded size is the entire owned reservation.
 * Sizes and region count are bounded above. No files, GPU or MAP_JIT are used.
 * Caller must never externally mprotect/munmap these mappings or race access.
 * Raw addresses expire at release/destroy; this is not an untrusted-code sandbox.
 * create/add/release/destroy must be owner-serialized. Host output pointers are
 * trusted C output arguments; they are not exposed as Windows imports.
 */
pm_winapi_memory *pm_winapi_memory_create(char *error, size_t error_capacity);
size_t pm_winapi_memory_page_size(const pm_winapi_memory *context);
int pm_winapi_memory_allocate(pm_winapi_memory *context, size_t bytes,
    void **base, size_t *rounded_bytes);
int pm_winapi_memory_release(pm_winapi_memory *context, void *exact_base);

/* One bound context per thread, one thread per context. Allocations, releases
 * and destroy are refused while bound. Thread exit releases the binding, not
 * the allocations; owner joins then explicitly destroys. No internal thread.
 * Destroy reports munmap failures and retains context + failed mappings for a
 * retry; successfully unmapped regions are removed. It never loses a live handle.
 * All host functions preserve LastError. Destroy(NULL pointer-to-context)=0;
 * destroy(&null_context)=1. Bind/unbind are explicit, not automatically nested.
 */
int pm_winapi_memory_bind(pm_winapi_memory *context);
int pm_winapi_memory_unbind(void);
int pm_winapi_memory_destroy(pm_winapi_memory **context);

/* Windows x64 ABI, deliberately restricted VirtualProtect. The PDWORD output is
 * represented as void* in C to permit byte-safe unaligned outputs without making
 * a false uint32_t alignment promise; the machine calling convention is identical.
 * - target bytes must belong to ONE owned allocation; enclosing host pages are
 *   changed by real mprotect, never by metadata-only success;
 * - old_protection must point to 4 writable bytes in a DIFFERENT owned allocation.
 *   Unowned pointers (including ordinary host/guest stacks), readonly outputs,
 *   NULL, and same-allocation outputs are refused before reading/writing them;
 * - only NOACCESS/R/RW/RX are representable. Execute-only, RWX, COW, GUARD,
 *   NOCACHE/WRITECOMBINE/CFG flags are refused, never silently weakened;
 * - old_protection receives the previous flag of the FIRST affected page;
 * - success preserves LastError; failure leaves old_protection unchanged.
 * An OS mprotect failure can leave partially changed permissions: the entire
 * target allocation is then quarantined, never reused as target OR output.
 * Its last ledger is not authoritative. Unbind and release/destroy it; no
 * implicit rollback, retry/recovery or unknown-protection success is fabricated.
 * No context/unknown, quarantined or overflowing target => INVALID_ADDRESS(487); size zero or
 * unsupported flags => INVALID_PARAMETER(87); invalid output => NOACCESS(998).
 * Host mprotect errors map to ACCESS_DENIED(5), NOT_ENOUGH_MEMORY(8),
 * INVALID_PARAMETER(87), otherwise GEN_FAILURE(31). These are real Win32 error
 * codes; exact failure mapping is this documented subset's policy.
 * No instruction-cache flushing or guest code execution is performed. Windows
 * callers are responsible for cache coherency before executing rewritten code;
 * FlushInstructionCache, exception handling and full Windows VM remain absent.
 */
int32_t PM_WINAPI pm_win_VirtualProtect(void *address, size_t bytes,
    uint32_t new_protection, void *old_protection);

/* HOST ABI opt-in import resolver. Strict named VirtualProtect on kernel32.dll
 * and kernelbase.dll, then delegate the original seven-function base resolver.
 * No dependency on module handles; no VirtualAlloc/Free or fallback stubs. */
int pm_winapi_memory_resolve(void *context, const char *dll, const char *name,
    uint16_t ordinal, int by_ordinal, uintptr_t *address);

#ifdef __cplusplus
}
#endif
#endif
