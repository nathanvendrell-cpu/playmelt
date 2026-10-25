#include "winapi_subset.h"

#include <limits.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Contract references (reviewed 2026-10-25):
 * https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention
 * https://learn.microsoft.com/en-us/windows/win32/api/errhandlingapi/nf-errhandlingapi-getlasterror
 * https://learn.microsoft.com/en-us/windows/win32/api/errhandlingapi/nf-errhandlingapi-setlasterror
 * https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getcurrentprocessid
 * https://learn.microsoft.com/en-us/windows/win32/api/profileapi/nf-profileapi-queryperformancecounter
 * https://learn.microsoft.com/en-us/windows/win32/api/profileapi/nf-profileapi-queryperformancefrequency
 * https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps
 * https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-gettickcount64
 * https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getsystemtimeasfiletime
 * https://learn.microsoft.com/en-us/windows/win32/api/minwinbase/ns-minwinbase-filetime
 * Apple SDK mach/mach_time.h: mach_continuous_time advances during sleep.
 * No Windows implementation code or external runtime is incorporated here.
 */

_Static_assert(sizeof(uintptr_t) == 8, "Windows x64 needs 64-bit addresses");
_Static_assert(sizeof(pm_filetime) == 8, "FILETIME must occupy eight bytes");
_Static_assert(offsetof(pm_filetime, dwHighDateTime) == 4, "FILETIME layout");

static _Thread_local uint32_t pm_last_error;
static pthread_once_t pm_clock_once = PTHREAD_ONCE_INIT;
static mach_timebase_info_data_t pm_timebase;
static int pm_clock_available;

uint32_t PM_WINAPI pm_win_GetLastError(void) { return pm_last_error; }
void PM_WINAPI pm_win_SetLastError(uint32_t error) { pm_last_error = error; }

uint32_t PM_WINAPI pm_win_GetCurrentProcessId(void) {
    /* Actual host PID; there is no virtual Windows process namespace. */
    return (uint32_t)getpid();
}

int pm_winapi_ticks_to_nanoseconds(uint64_t ticks, uint32_t numer,
                                  uint32_t denom, uint64_t *nanoseconds) {
    if (!nanoseconds || !numer || !denom) return 0;
    const __uint128_t scaled = (__uint128_t)ticks * numer / denom;
    if (scaled > UINT64_MAX) return 0;
    *nanoseconds = (uint64_t)scaled;
    return 1;
}

static void pm_initialize_clock(void) {
    pm_clock_available = mach_timebase_info(&pm_timebase) == KERN_SUCCESS &&
                         pm_timebase.numer != 0 && pm_timebase.denom != 0;
}

static int pm_clock_ready(void) {
    if (pthread_once(&pm_clock_once, pm_initialize_clock) != 0 ||
        !pm_clock_available) {
        pm_last_error = PM_ERROR_GEN_FAILURE;
        return 0;
    }
    return 1;
}

static int pm_continuous_nanoseconds(uint64_t *nanoseconds) {
    if (!pm_clock_ready()) return 0;
    if (!pm_winapi_ticks_to_nanoseconds(mach_continuous_time(), pm_timebase.numer,
                                       pm_timebase.denom, nanoseconds)) {
        pm_last_error = PM_ERROR_ARITHMETIC_OVERFLOW;
        return 0;
    }
    return 1;
}

int32_t PM_WINAPI pm_win_QueryPerformanceCounter(int64_t *counter) {
    if (!counter) { pm_last_error = PM_ERROR_INVALID_PARAMETER; return 0; }
    uint64_t ns;
    if (!pm_continuous_nanoseconds(&ns)) return 0;
    if (ns > INT64_MAX) {
        pm_last_error = PM_ERROR_ARITHMETIC_OVERFLOW;
        return 0;
    }
    *counter = (int64_t)ns;
    return 1;
}

int32_t PM_WINAPI pm_win_QueryPerformanceFrequency(int64_t *frequency) {
    if (!frequency) { pm_last_error = PM_ERROR_INVALID_PARAMETER; return 0; }
    if (!pm_clock_ready()) return 0;
    /* The published counter unit is ns, independent of hardware tick frequency.
     * This does NOT claim nanosecond resolution or Windows hardware parity. */
    *frequency = INT64_C(1000000000);
    return 1;
}

uint64_t PM_WINAPI pm_win_GetTickCount64(void) {
    uint64_t ns;
    /* Monotonic host boot clock including sleep, not wall-clock time. Resolution
     * follows macOS, not the typical Windows 10-16 ms timer granularity. Host
     * failure returns 0 and sets LastError (explicit extension: no Win32 error
     * return is defined for this API). */
    if (!pm_continuous_nanoseconds(&ns)) return 0;
    return ns / UINT64_C(1000000);
}

int pm_winapi_unix_to_filetime(int64_t seconds, int32_t nanoseconds,
                              uint64_t *filetime) {
    if (!filetime || nanoseconds < 0 || nanoseconds >= 1000000000) return 0;
    /* Signed wide arithmetic handles dates before 1970 and rejects dates before
     * 1601 or outside FILETIME. Truncate the fractional part to 100 ns units. */
    const __int128 ticks = ((__int128)seconds + INT64_C(11644473600)) *
                          INT64_C(10000000) + nanoseconds / 100;
    if (ticks < 0 || (__uint128_t)ticks > UINT64_MAX) return 0;
    *filetime = (uint64_t)ticks;
    return 1;
}

void PM_WINAPI pm_win_GetSystemTimeAsFileTime(pm_filetime *filetime) {
    if (!filetime) { pm_last_error = PM_ERROR_INVALID_PARAMETER; return; }
    struct timespec utc;
    if (clock_gettime(CLOCK_REALTIME, &utc) != 0) {
        pm_last_error = PM_ERROR_GEN_FAILURE;
        return;
    }
    uint64_t ticks;
    if (!pm_winapi_unix_to_filetime((int64_t)utc.tv_sec, (int32_t)utc.tv_nsec,
                                   &ticks)) {
        pm_last_error = PM_ERROR_ARITHMETIC_OVERFLOW;
        return;
    }
    /* Write DWORDs separately: FILETIME need not have uint64_t alignment.
     * Failures above leave the output unchanged and set LastError. This failure
     * extension does not emulate Windows faults for arbitrary invalid pointers. */
    filetime->dwLowDateTime = (uint32_t)ticks;
    filetime->dwHighDateTime = (uint32_t)(ticks >> 32);
}

static unsigned char pm_ascii_lower(unsigned char c) {
    return c >= 'A' && c <= 'Z' ? (unsigned char)(c + ('a' - 'A')) : c;
}

static int pm_dll_equals(const char *actual, const char *expected) {
    if (!actual) return 0;
    while (*actual && *expected) {
        if (pm_ascii_lower((unsigned char)*actual) != (unsigned char)*expected)
            return 0;
        ++actual; ++expected;
    }
    return *actual == '\0' && *expected == '\0';
}

int pm_winapi_resolve(void *ctx, const char *dll, const char *name,
                      uint16_t ordinal, int by_ordinal, uintptr_t *address) {
    (void)ctx;
    (void)ordinal;
    if (!address) return 0;
    *address = 0;
    if (by_ordinal || !name ||
        !(pm_dll_equals(dll, "kernel32.dll") || pm_dll_equals(dll, "kernelbase.dll")))
        return 0;
#define PM_RESOLVE(symbol) \
    if (strcmp(name, #symbol) == 0) { \
        *address = (uintptr_t)&pm_win_##symbol; return 1; \
    }
    PM_RESOLVE(GetLastError)
    PM_RESOLVE(SetLastError)
    PM_RESOLVE(GetCurrentProcessId)
    PM_RESOLVE(QueryPerformanceCounter)
    PM_RESOLVE(QueryPerformanceFrequency)
    PM_RESOLVE(GetTickCount64)
    PM_RESOLVE(GetSystemTimeAsFileTime)
#undef PM_RESOLVE
    return 0;
}
