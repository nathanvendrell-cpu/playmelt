#ifndef PLAYMELT_WINAPI_MODULES_H
#define PLAYMELT_WINAPI_MODULES_H

#include "pe_modules.h"
#include "winapi_subset.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pm_winapi_modules pm_winapi_modules;

/* Windows x64 ABI. FARPROC is an address because exports may also be data. */
void *PM_WINAPI pm_win_GetModuleHandleA(const char *module_name);
void *PM_WINAPI pm_win_GetModuleHandleW(const uint16_t *module_name);
uint32_t PM_WINAPI pm_win_GetModuleFileNameA(void *module, void *output, uint32_t capacity);
uintptr_t PM_WINAPI pm_win_GetProcAddress(void *module, const char *name_or_ordinal);

/* HOST ABI import resolver: adds the four module functions for kernel32.dll /
 * kernelbase.dll and delegates the original seven to pm_winapi_resolve. ctx is
 * unused; the Windows functions consult their explicitly bound thread context.
 * This opt-in resolver keeps the original seven-function library independent. */
int pm_winapi_modules_resolve(void *ctx, const char *dll, const char *name,
    uint16_t ordinal, int by_ordinal, uintptr_t *address);

/* HOST ABI. Copy the registry's explicit PE module registrations. Its fallback
 * is deliberately NOT inherited: host services must be explicitly added below.
 * main_image is required, main_basename is an ASCII stem.exe (<=127 bytes).
 * PE image objects, mappings, export catalogues and host callback contexts remain
 * BORROWED: keep them alive and unchanged until this context is destroyed, and
 * until all returned addresses/IAT users are done. Never unload concurrently.
 * Snapshot checks reject simple unload/reload, not freed C objects or ABA reuse.
 * No module is loaded, retained by an OS loader, initialized, or executed here.
 */
pm_winapi_modules *pm_winapi_modules_create(const pm_pe_modules *registry,
    const pm_pe_image *main_image, const char *main_basename,
    char *error, size_t error_capacity);

/* HOST ABI metadata declaration, exactly once per registered PE image, before
 * first bind. Copies a HOST-readable NUL-terminated string (<=511 bytes) into
 * this context; input must be readable through NUL or 512 bytes. Requires the
 * exact live image object, not a copy, and basename matching its registration
 * ignoring ASCII case. Strict subset: drive-letter colon backslash absolute
 * DOS path, printable ASCII, nonempty components, no dot/dotdot, trailing space
 * or dot, slash, additional colon, < > | ? * or quote. UNC/device prefixes are
 * refused; this is NOT a complete Windows filesystem-name validator.
 * Case is preserved. No path is inferred, normalized, searched, or claimed to
 * exist on disk. HOST service tables have no PE path. Repeated declarations and
 * all declarations after first successful bind (even after unbind) are refused
 * without changing metadata. Source mutation after success has no effect.
 * Preserves LastError. Serial ownership rules of other HOST calls apply. */
int pm_winapi_modules_set_declared_path(pm_winapi_modules *context,
    const pm_pe_image *image, const char *logical_path);

/* GetModuleFileNameA: NULL selects the main PE. Only a live registered PE with
 * an explicit path above is supported. Full output returns length excluding NUL
 * and preserves LastError. Capacity 1..length writes capacity-1 chars plus NUL,
 * returns capacity and sets ERROR_INSUFFICIENT_BUFFER (122). Capacity 0 returns
 * 0/122 without writing (explicit subset policy). Validate only actual bytes
 * written (<=512), not the entire advertised capacity. Output must be in ONE
 * owned RW nonquarantined region of the current memory binding, every crossed
 * page checked before any write. No stack/image/arbitrary-pointer output.
 * No module context or undeclared path =>126; unknown/stale/HOST-service handle
 * =>6; invalid output or absent memory binding =>998. Failures except successful
 * truncation leave output unchanged. These mappings are our subset policy.
 * No Windows codepage conversion, filesystem existence or loaded-path evidence.
 */

/* Register an explicit preloaded HOST service table (at most 8), not a PE DLL.
 * The HMODULE is an opaque token, never a synthetic claim of a mapped DLL.
 * Resolver uses HOST ABI, must return an actual nonzero address, and must not
 * reenter/mutate this context. Called only for this exact basename.dll, also
 * when a PE forwarder targets it. No fallback to undeclared modules.
 * Registration closes permanently at the first successful bind.
 */
int pm_winapi_modules_add_host(pm_winapi_modules *context, const char *basename,
    pm_import_resolver resolver, void *resolver_context);

/* One context per thread and at most one bound thread per context. Nested binds
 * fail, including binding the same context twice. Unbind is explicit; pthread
 * exit also releases the binding. Context storage is not silently freed at exit.
 * destroy refuses while bound and leaves *context intact; success clears it.
 * Owner-side create/add/bind/destroy calls must be serialized by the caller;
 * destroy may be attempted while another thread is bound (it returns 0 safely).
 * After joining that thread the owner can destroy. These host functions preserve
 * Win32 LastError. A destroyed pointer is invalid C input and must not be reused.
 */
int pm_winapi_modules_bind(pm_winapi_modules *context);
int pm_winapi_modules_unbind(void);
int pm_winapi_modules_destroy(pm_winapi_modules **context);

/* Win32 subset (entry points declared above):
 * GetModuleHandleA/W: NULL => main mapping; ASCII case-insensitive basename;
 * omitted extension appends .dll. W accepts ASCII encoded as UTF-16 only.
 * Paths, non-ASCII/codepage conversion, actual extensionless image names,
 * trailing-dot names and
 * side-by-side aliases are unsupported and return MOD_NOT_FOUND (126).
 * GetProcAddress: exact printable ASCII name <=255 bytes, or pointer value
 * 1..65535 as ordinal. Ordinal zero/holes fail. Handles must belong to the bound
 * context and retain their recorded image identity. Data exports are allowed;
 * forwarders use the closed registry's existing cycle/depth checks.
 * No context/missing module =>126; invalid/stale handle =>6; unavailable export
 * =>127. These are defined Win32 codes, but the exact failure mapping here is
 * this subset's policy, not a claim about undocumented Windows failure cases.
 * Success preserves LastError; failures update existing per-thread LastError.
 * Guest string pointers must be readable through their NUL or documented bound;
 * this is NOT a sandbox/SEH implementation for invalid pointers.
 * No LoadLibrary, FreeLibrary, DllMain, filesystem lookup, or guest execution.
 */

#ifdef __cplusplus
}
#endif
#endif
