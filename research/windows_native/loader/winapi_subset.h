#ifndef PLAYMELT_WINAPI_SUBSET_H
#define PLAYMELT_WINAPI_SUBSET_H

#include <stdint.h>

/* A host Mach-O x86_64 library with Microsoft x64 entry points. Never silently
 * substitute the ARM64 or System V ABI for a Windows x64 imported function. */
#if !defined(__APPLE__) || !defined(__x86_64__)
#error "Playmelt WinAPI subset requires a macOS x86_64 host target"
#endif
#if defined(__clang__)
#if !__has_attribute(ms_abi)
#error "Compiler does not support the Microsoft x64 ABI"
#endif
#elif !defined(__GNUC__)
#error "Compiler does not support the Microsoft x64 ABI"
#endif
#define PM_WINAPI __attribute__((ms_abi))

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pm_filetime {
    uint32_t dwLowDateTime;
    uint32_t dwHighDateTime;
} pm_filetime;

enum {
    PM_ERROR_INVALID_HANDLE = 6,
    PM_ERROR_GEN_FAILURE = 31,
    PM_ERROR_INVALID_PARAMETER = 87,
    PM_ERROR_MOD_NOT_FOUND = 126,
    PM_ERROR_PROC_NOT_FOUND = 127,
    PM_ERROR_ARITHMETIC_OVERFLOW = 534
};

/* These seven functions use the Windows x64 calling convention; the resolver
 * below uses the ordinary HOST C ABI and matches pm_import_resolver directly.
 * LastError lives in host thread-local storage, initially zero in this subset.
 * This is not a Windows TEB/TLS loader, handle table, or exception implementation.
 * Success preserves LastError. Nonnull output pointers must be writable; there
 * is no Windows access-violation/SEH emulation for invalid guest pointers.
 * NULL outputs are rejected safely with INVALID_PARAMETER (a subset extension).
 */
uint32_t PM_WINAPI pm_win_GetLastError(void);
void PM_WINAPI pm_win_SetLastError(uint32_t error);
uint32_t PM_WINAPI pm_win_GetCurrentProcessId(void);
int32_t PM_WINAPI pm_win_QueryPerformanceCounter(int64_t *counter);
int32_t PM_WINAPI pm_win_QueryPerformanceFrequency(int64_t *frequency);
uint64_t PM_WINAPI pm_win_GetTickCount64(void);
void PM_WINAPI pm_win_GetSystemTimeAsFileTime(pm_filetime *filetime);

/* Strict named imports from kernel32.dll/kernelbase.dll only (DLL ASCII case
 * insensitive, symbol names case sensitive). No paths, ordinals, API-set aliases,
 * dynamic loading, or fallback stubs. ctx is unused. Returns 1 iff resolved and
 * *address != 0. Rejection returns 0 and clears *address when address != NULL.
 * Inputs are trusted host NUL-terminated strings already validated by the loader.
 */
int pm_winapi_resolve(void *ctx, const char *dll, const char *name,
                      uint16_t ordinal, int by_ordinal, uintptr_t *address);

/* Deterministic HOST-ABI arithmetic helpers, not Windows imports. Both return
 * 1 on success, 0 on bad input/overflow, leave output unchanged on failure, and
 * never change LastError. Exposed for CPU tests of non-unit timebases/boundaries.
 */
int pm_winapi_ticks_to_nanoseconds(uint64_t ticks, uint32_t numer,
                                  uint32_t denom, uint64_t *nanoseconds);
int pm_winapi_unix_to_filetime(int64_t seconds, int32_t nanoseconds,
                              uint64_t *filetime);

#ifdef __cplusplus
}
#endif
#endif
