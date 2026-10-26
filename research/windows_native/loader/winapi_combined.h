#ifndef PLAYMELT_WINAPI_COMBINED_H
#define PLAYMELT_WINAPI_COMBINED_H

#include "winapi_modules.h"
#include "winapi_memory.h"
#include "winapi_events.h"

#ifdef __cplusplus
extern "C" {
#endif

/* HOST ABI composition of the existing 7 base + 3 module + 4 memory + 7 synchronization entry
 * points; no new Windows API, binding, module load, or memory registration.
 * Only canonical named requests (ordinal==0, by_ordinal==0), exact symbols,
 * and ASCII case-insensitive kernel32.dll/kernelbase.dll/ntdll.dll basenames.
 * Strings are trusted host-readable NUL-terminated inputs, bounded to 255 bytes
 * for symbols. NtQueryVirtualMemory belongs only to ntdll.dll; the other 20
 * belong only to kernel32.dll/kernelbase.dll. No API-set/path/ordinal fallback.
 * All four fixed providers are consulted. Duplicate successes MUST have the
 * same nonzero address; divergence or an inconsistent provider response fails.
 * Rejection clears *address. Context is unused. LastError remains unchanged.
 *
 * Dynamic lookup requires callers to explicitly add these three host tables
 * with pm_winapi_modules_add_host(...,pm_winapi_combined_resolve,NULL), before
 * binding. Existing PE registrations take precedence: add_host refuses name
 * collisions, never substitutes this service for an already registered PE DLL.
 * With an import-side PE registry, use this only as its explicit host fallback
 * behind pm_pe_modules_resolve. Do NOT retry it directly after an unresolved
 * export from a registered PE: that would bypass the registry's authority.
 * Module, memory and event TLS contexts remain independent. Track each successful bind
 * separately; on failure unbind ONLY contexts acquired by that caller. A module
 * context's first successful bind permanently seals registrations, even if it
 * is subsequently unbound. No transactional rollback is claimed.
 * Keep host tokens, memory and borrowed PE objects alive until ALL guest/IAT/
 * dynamic-address calls finish. Then unbind, destroy contexts, and unload images.
 * Resolution alone does not prove the necessary memory/event context is bound.
 */
int pm_winapi_combined_resolve(void *context, const char *dll, const char *name,
    uint16_t ordinal, int by_ordinal, uintptr_t *address);

#ifdef __cplusplus
}
#endif
#endif
