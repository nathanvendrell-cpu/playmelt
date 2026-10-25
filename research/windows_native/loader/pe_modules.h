#ifndef PLAYMELT_PE_MODULES_H
#define PLAYMELT_PE_MODULES_H

#include "pe_loader.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PM_PE_MODULES_CAPACITY 32
#define PM_PE_MODULE_NAME_CAP 128
#define PM_PE_MODULE_SYMBOL_CAP 256
#define PM_PE_MODULE_LOOKUP_LIMIT 16
#define PM_PE_MODULE_ERROR_CAP 256

/* Fixed storage; use the functions below, never mutate these fields directly. */
typedef struct pm_pe_module_slot {
    char name[PM_PE_MODULE_NAME_CAP];
    const pm_pe_image *image;
    const void *mapping;
    size_t mapping_size;
    const struct pm_pe_export_catalog *exports;
} pm_pe_module_slot;

typedef struct pm_pe_modules {
    pm_pe_module_slot slots[PM_PE_MODULES_CAPACITY];
    size_t count;
    pm_import_resolver fallback;
    void *fallback_context;
    char error[PM_PE_MODULE_ERROR_CAP];
} pm_pe_modules;

typedef struct pm_pe_module_result {
    uintptr_t address;
    const pm_pe_image *image; /* Final owner; NULL for an external fallback. */
    uint32_t ordinal;         /* Final export ordinal; requested ordinal for fallback. */
    uint32_t rva;             /* Final RVA; zero/unknown for fallback. */
    int permissions_known;   /* False for fallback: zero flags do NOT mean read-only. */
    int executable;
    int writable;
    int from_fallback;
    unsigned forwarder_hops;
} pm_pe_module_result;

/* Registry only: no filesystem, dlopen, autoload, DllMain, mapping, or execution.
 * Caller confines this registry and its borrowed pm_pe_image objects to one
 * thread, with no executing guest or concurrent mutation during add/remove or
 * unload. Add only images from a successful pm_pe_load. Unregister BEFORE unload;
 * also unload all importing clients before removing an imported module. Returned
 * addresses and installed IAT entries cannot be revoked or repaired by remove.
 * Image objects must remain alive at stable addresses. Snapshot checks detect
 * simple unload/reload, not a freed handle, an ABA reuse, or arbitrary mutation.
 * No ownership of images or fallback context is transferred.
 *
 * init initializes caller-owned storage; no allocation or destructor is needed.
 * Reinitializing an active registry would discard bookkeeping; remove first.
 * Fallback is optional, invoked ONLY if the requested normalized module is absent.
 * It must be synchronous and must not re-enter or mutate this registry. Directly
 * supplying pm_pe_modules_resolve as fallback is rejected (no registry chaining).
 */
int pm_pe_modules_init(pm_pe_modules *registry, pm_import_resolver fallback,
                       void *fallback_context);
int pm_pe_modules_add(pm_pe_modules *registry, const char *dll,
                      const pm_pe_image *image);
int pm_pe_modules_remove(pm_pe_modules *registry, const char *dll);
const char *pm_pe_modules_last_error(const pm_pe_modules *registry);

/* Basenames are ASCII [A-Za-z0-9_-]+.dll, case insensitive, <=127 bytes including
 * extension. No paths, alternate extensions, dots in the stem, whitespace, or
 * implicit extension on add/remove/public lookup. Named exports are exact,
 * case-sensitive printable ASCII (no spaces), <=255 bytes; ordinal queries use
 * name=NULL and by_ordinal=1. Named queries use ordinal=0 and by_ordinal=0.
 *
 * Forwarders accept MODULE.NAME, MODULE.dll.NAME (extension case insensitive),
 * or either form with #decimalOrdinal in place of NAME. Dotted symbols and bare
 * MODULE.dll are refused as ambiguous in this bounded subset. Forwarder ordinals
 * span uint32; external fallback accepts only uint16 because pm_import_resolver
 * has that ABI. Nothing is truncated. At most 16 module lookups per request.
 * Cycles are rejected using the actual image plus resolved export ordinal.
 * A registered module whose export fails never falls back to a host substitute.
 *
 * Success returns a borrowed address, including DATA exports. permissions_known
 * and executable describe the final export; lookup is NOT permission to execute
 * arbitrary code and does not prove Windows compatibility. No function is called.
 * Failure returns 0, zeroes result/address, and records a bounded error string.
 */
int pm_pe_modules_lookup(pm_pe_modules *registry, const char *dll,
                         const char *name, uint32_t ordinal, int by_ordinal,
                         pm_pe_module_result *result);
int pm_pe_modules_resolve(void *context, const char *dll, const char *name,
                          uint16_t ordinal, int by_ordinal, uintptr_t *address);

#ifdef __cplusplus
}
#endif
#endif
