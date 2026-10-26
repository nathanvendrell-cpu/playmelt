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
    PM_MEM_COMMIT = 0x1000,
    PM_MEM_RESERVE = 0x2000,
    PM_MEM_RELEASE = 0x8000,
    PM_MEMORY_ERROR_ACCESS_DENIED = 5,
    PM_MEMORY_ERROR_NOT_ENOUGH_MEMORY = 8,
    PM_MEMORY_ERROR_INVALID_ADDRESS = 487,
    PM_MEMORY_ERROR_NOACCESS = 998
};
#define PM_MEMORY_MAX_REGIONS 8u
#define PM_MEMORY_MAX_REGION_BYTES (1024u * 1024u)
#define PM_MEMORY_MAX_TOTAL_BYTES (4u * 1024u * 1024u)
#define PM_MEMORY_ALLOCATION_GRANULARITY 65536u
#define PM_MEMORY_BASIC_INFORMATION64_BYTES 48u
#define PM_STATUS_SUCCESS ((int32_t)0)
#define PM_STATUS_INVALID_INFO_CLASS ((int32_t)UINT32_C(0xc0000003))
#define PM_STATUS_INFO_LENGTH_MISMATCH ((int32_t)UINT32_C(0xc0000004))
#define PM_STATUS_ACCESS_VIOLATION ((int32_t)UINT32_C(0xc0000005))
#define PM_STATUS_INVALID_HANDLE ((int32_t)UINT32_C(0xc0000008))
#define PM_STATUS_INVALID_PARAMETER ((int32_t)UINT32_C(0xc000000d))

/* HOST ABI, not VirtualAlloc/VirtualFree. Own small anonymous allocations; no
 * imported/borrowed memory registration exists. Allocation rounds up to host
 * pages and starts RW; returned rounded size is the entire owned reservation.
 * Sizes and region count are bounded above. The total budget includes the full
 * backing of guest allocations, including alignment padding and retained failed
 * cleanup slots. No files, GPU or MAP_JIT are used.
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
 * Failed host release/destroy also quarantines each failed region: no later
 * query/protection/output use is accepted, but release/destroy can be retried.
 * All host functions preserve LastError. Destroy(NULL pointer-to-context)=0;
 * destroy(&null_context)=1. Bind/unbind are explicit, not automatically nested.
 */
int pm_winapi_memory_bind(pm_winapi_memory *context);
int pm_winapi_memory_unbind(void);
int pm_winapi_memory_destroy(pm_winapi_memory **context);

/* Windows x64 ABI, strictly limited guest allocation on the CURRENT bound memory
 * context. VirtualAlloc accepts ONLY (NULL,1..1MiB,MEM_RESERVE|MEM_COMMIT,RW).
 * Exposed size rounds to HOST pages (not emulated Windows 4KiB pages). Base is
 * aligned to this AMD64 prototype's fixed 64KiB allocation granularity. Real
 * anonymous zero-filled memory: reserve a PROT_NONE backing, expose its aligned
 * RW window, keep padding PROT_NONE. Keep/release the WHOLE backing, never trim.
 * Padding is not guest memory and cannot be queried/protected. No allocation at
 * a specified address, reserve-only, commit-only, decommit, reset, huge pages,
 * executable allocation, VRAM or promise about physical resident memory.
 *
 * VirtualFree accepts ONLY (exact published GUEST base,0,MEM_RELEASE) in that
 * same bound context. It never releases HOST allocations or another context's
 * memory. Interior/unknown/double-free addresses fail. Success removes the ledger
 * entry ONLY after munmap of the full backing succeeds. Raw pointers then expire;
 * address reuse can occur, so this is not an ABA defence against a stale caller.
 * Success preserves LastError. Invalid form =>87; absent context/unknown address
 * =>487; exhausted budget/calloc =>8; OS errors use the existing errno mapping.
 *
 * A protection setup failure triggers backing cleanup. If cleanup also fails,
 * return NULL + GEN_FAILURE(31), retain a counted unpublished quarantined slot
 * (no guest base) for owner destroy after unbind. Original mprotect error is used
 * if cleanup succeeds. Failed VirtualFree keeps its slot/budget and quarantines
 * it: queries/protection/output use fail until a successful retry Free or owner
 * destroy. Do not assume OS failures roll back or continue using that pointer.
 * Host allocate/release/destroy remain forbidden while bound; only these guest
 * calls may add/remove their own guest regions from the uniquely bound context.
 * Thread exit unbinds but does not silently free allocations; owner must destroy.
 */
void *PM_WINAPI pm_win_VirtualAlloc(void *address, size_t bytes,
    uint32_t allocation_type, uint32_t protection);
int32_t PM_WINAPI pm_win_VirtualFree(void *address, size_t bytes, uint32_t free_type);

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

/* Windows x64 ABI, six arguments. Restricted NtQueryVirtualMemory:
 * - only the current-process pseudo-handle (all pointer bits 1) and information
 *   class 0 (MemoryBasicInformation); no real handles or other process access;
 * - target must belong to one nonquarantined owned reservation. Query starts at
 *   its enclosing HOST page and scans FORWARD through identical page protection,
 *   stopping at an attribute change or that reservation's end. It never reads
 *   target bytes, so a known NOACCESS page can be queried;
 * - writes exactly 48 little-endian bytes of AMD64 MEMORY_BASIC_INFORMATION:
 *   BaseAddress 0, AllocationBase 8, AllocationProtect 16, PartitionId 20 (zero),
 *   padding 22 (zero), RegionSize 24, State 32, Protect 36, Type 40, padding 44
 *   (zero). Owned allocations are MEM_COMMIT/MEM_PRIVATE; original protection RW;
 * - information_length >=48; larger capacity does not cause additional writes
 *   or require extra bytes to be mapped. Optional ReturnLength receives uint64 48;
 * - both actual output ranges (48 / 8 bytes) must be nonquarantined owned RW
 *   pages. Unaligned outputs and disjoint outputs in one allocation are accepted.
 *   Output ranges overlapping each other are refused, including partial overlap;
 * - validate everything before writing either output. Both outputs and LastError
 *   remain unchanged on ALL errors; success also preserves LastError.
 * Error precedence/policy: bad process => INVALID_HANDLE; class =>
 * INVALID_INFO_CLASS; short length => INFO_LENGTH_MISMATCH; no binding, unknown
 * or quarantined target, overlapping outputs => INVALID_PARAMETER; invalid
 * output => ACCESS_VIOLATION. This is our restricted policy, not a promise of
 * Windows error precedence or ReturnLength behavior on failures.
 * No free-region discovery, PE/image/mapped-file/stack query, kernel access,
 * Windows 4KiB granularity emulation, memory allocation or exception handling.
 */
int32_t PM_WINAPI pm_win_NtQueryVirtualMemory(void *process, void *address,
    uint32_t information_class, void *information, size_t information_length,
    void *return_length);

/* Narrow HOST ABI bridge, NOT a Windows export or arbitrary-pointer writer.
 * Validate/write exactly 8 bytes in ONE nonquarantined owned RW region of the
 * current, exclusively thread-bound memory context. Every crossed host page is
 * checked; padding, image/stack/unowned pointers are refused. Unaligned output
 * is copied as bytes. Failure leaves output and LastError unchanged; success
 * also preserves LastError. No memory operations/reentrant signal handlers may
 * mutate this context between can_write and write; write independently rechecks.
 * Host raw memory access must be serialized, as for the existing memory APIs.
 * This is validation-before-copy, not an atomic 8-byte publication guarantee.
 */
int pm_winapi_memory_can_write_handle(void *output);
int pm_winapi_memory_write_handle(void *output,uintptr_t handle);

/* Narrow HOST ABI trusted-source copy, NOT a Windows export. bytes must be
 * 1..512; source must be HOST-readable for that many bytes. Source/destination overlap
 * is supported via memmove. No source-pointer validation is claimed. Destination must be
 * entirely in ONE nonquarantined owned RW region of the bound memory context;
 * all crossed pages are checked BEFORE any write. No partial copy on refusal.
 * Preserves LastError. The same exclusive-context/no-external-mutation contract
 * as write_handle applies. A large guest capacity must not be passed here:
 * callers provide only the actual bounded output length. */
int pm_winapi_memory_copy_bytes_owned(void *output, const void *source, size_t bytes);

/* HOST ABI opt-in import resolver. Strict named NtQueryVirtualMemory only on
 * ntdll.dll; VirtualAlloc/VirtualFree/VirtualProtect on kernel32.dll/kernelbase.dll, then delegate
 * the original seven-function base resolver. DLL case is ignored, symbols exact.
 * No dependency on module handles; no fallback stubs or other allocation forms. */
int pm_winapi_memory_resolve(void *context, const char *dll, const char *name,
    uint16_t ordinal, int by_ordinal, uintptr_t *address);

#ifdef __cplusplus
}
#endif
#endif
