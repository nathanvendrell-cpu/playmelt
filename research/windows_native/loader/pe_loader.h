#ifndef PLAYMELT_PE_LOADER_H
#define PLAYMELT_PE_LOADER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Experimental mapping only: no entry, TLS callback, DllMain, Wine or GPU call.
 * The caller supplies immutable bytes of its OWN synthetic PE64 AMD64 fixture.
 * No filesystem access, dependency discovery, dlopen or external CLI is provided.
 * Resolver uses the host C ABI; addresses it returns may use a different ABI.
 * Return 1 only for an explicitly implemented import and nonzero address.
 * Ordinal imports use name=NULL, by_ordinal=1, ordinal=the validated 16-bit value.
 * Named imports use by_ordinal=0, ordinal=0. Unknown dependencies remain refusals.
 */
typedef int (*pm_import_resolver)(void *context, const char *dll, const char *name,
                                 uint16_t ordinal, int by_ordinal,
                                 uintptr_t *address);

struct pm_pe_export_catalog;
typedef struct pm_pe_image {
    void *mapping;
    size_t mapping_size;
    uint32_t entrypoint_rva;
    struct pm_pe_export_catalog *exports; /* Owned; never copy image ownership. */
} pm_pe_image;

typedef enum pm_pe_export_kind {
    PM_PE_EXPORT_DIRECT = 1,
    PM_PE_EXPORT_FORWARDER = 2
} pm_pe_export_kind;

typedef struct pm_pe_export {
    pm_pe_export_kind kind;
    uint32_t ordinal;
    uint32_t rva;
    const void *address;     /* DIRECT only; a readable address, not necessarily code. */
    const char *forwarder;   /* FORWARDER only; borrowed until successful unload. */
    int executable;
    int writable;
} pm_pe_export;

/* Initialize *image to {0}. Success=1, failure=0 and bounded error text.
 * New mappings are released and *image stays zero on ordinary failure. If the OS
 * refuses cleanup, failure text starts with cleanup-failed and mapping+size are
 * retained solely for retrying unload, with entrypoint_rva=0 (never ready).
 * An already-loaded output is rejected without destroying it. Unload before reuse.
 * File <=16 MiB; image <=64 MiB; <=32 sections/1024 symbols/4096 reloc entries.
 * Supported: ordinary named/ordinal imports, bounded exports and DIR64/ABSOLUTE
 * base relocations. A DLL MUST have entrypoint_rva=0; no DllMain is invoked.
 * Unsupported directories (TLS, exception/unwind, CLR, delay-import, load-config,
 * bound imports, resources/etc.) are rejected rather than ignored.
 * Only export, import, base-relocation and IAT directories are accepted.
 * Final permissions are per-host-page W^X; incompatible page sharing fails.
 * The mapping is NOT a Windows process or a certificate of executable support.
 */
int pm_pe_load(const uint8_t *bytes, size_t size, pm_import_resolver resolver,
               void *context, pm_pe_image *image, char *error, size_t error_cap);
/* Success=1, including an empty/NULL image. Failure=0 preserves the handle so the
 * caller can retry; never claim imageUnmapped when this function returns 0. */
int pm_pe_unload(pm_pe_image *image);

/* Exact case-sensitive name, or public (biased) uint32 ordinal. 1=found,
 * 0=refused/not found with output zeroed. Forwarders are descriptions only;
 * no module lookup, filesystem operation or recursive resolution takes place.
 * Holes are not exports. Results/addresses are borrowed from a live loaded image.
 * Export tables are copied from immutable source bytes before fixups, capped at
 * 1024 addresses, 1024 names and 128 KiB total strings. Do not use stale images.
 */
int pm_pe_find_export(const pm_pe_image *image, const char *name, uint32_t ordinal,
                      int by_ordinal, pm_pe_export *result, char *error, size_t error_cap);

#ifdef __cplusplus
}
#endif
#endif
