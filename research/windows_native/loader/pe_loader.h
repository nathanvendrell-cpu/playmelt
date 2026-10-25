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
 * Return 1 only for an explicitly implemented named import and nonzero address.
 * Ordinal fields reserve the API contract; this prototype rejects ordinals.
 */
typedef int (*pm_import_resolver)(void *context, const char *dll, const char *name,
                                 uint16_t ordinal, int by_ordinal,
                                 uintptr_t *address);

typedef struct pm_pe_image {
    void *mapping;
    size_t mapping_size;
    uint32_t entrypoint_rva;
} pm_pe_image;

/* Initialize *image to {0}. Success=1, failure=0 and bounded error text.
 * New mappings are released and *image stays zero on ordinary failure. If the OS
 * refuses cleanup, failure text starts with cleanup-failed and mapping+size are
 * retained solely for retrying unload, with entrypoint_rva=0 (never ready).
 * An already-loaded output is rejected without destroying it. Unload before reuse.
 * File <=16 MiB; image <=64 MiB; <=32 sections/1024 symbols/4096 reloc entries.
 * Supported: ordinary named imports and DIR64/ABSOLUTE base relocations.
 * Unsupported directories (TLS, exception/unwind, CLR, delay-import, load-config,
 * bound imports, exports/resources/etc.) are rejected rather than ignored.
 * Only import, base-relocation and IAT directories are accepted by this subset.
 * Final permissions are per-host-page W^X; incompatible page sharing fails.
 * The mapping is NOT a Windows process or a certificate of executable support.
 */
int pm_pe_load(const uint8_t *bytes, size_t size, pm_import_resolver resolver,
               void *context, pm_pe_image *image, char *error, size_t error_cap);
/* Success=1, including an empty/NULL image. Failure=0 preserves the handle so the
 * caller can retry; never claim imageUnmapped when this function returns 0. */
int pm_pe_unload(pm_pe_image *image);

#ifdef __cplusplus
}
#endif
#endif
