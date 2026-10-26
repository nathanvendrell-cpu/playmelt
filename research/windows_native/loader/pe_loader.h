#ifndef PLAYMELT_PE_LOADER_H
#define PLAYMELT_PE_LOADER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Experimental mapping APIs never call an entry point, TLS, Wine or GPU.
 * Only the separate explicit synthetic lifecycle API below invokes DllMain.
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
struct pm_pe_synthetic_dll_control;
struct pm_pe_unwind_control;
struct pm_pe_lifetime;
struct pm_unwind_image;
typedef struct pm_pe_image {
    void *mapping;
    size_t mapping_size;
    uint32_t entrypoint_rva;
    struct pm_pe_export_catalog *exports; /* Owned; never copy image ownership. */
    struct pm_pe_synthetic_dll_control *synthetic_dll; /* Explicit fixture-only opt-in. */
    struct pm_pe_unwind_control *synthetic_unwind; /* Owned research EXE metadata. */
    struct pm_pe_lifetime *lifetime; /* Private provenance/explicit HOST dependencies. */
} pm_pe_image;

typedef enum pm_pe_dll_state {
    PM_PE_DLL_UNAVAILABLE = 0,
    PM_PE_DLL_READY,
    PM_PE_DLL_ATTACHING,
    PM_PE_DLL_ATTACHED,
    PM_PE_DLL_DETACHING,
    PM_PE_DLL_DETACHED,
    PM_PE_DLL_FAILED
} pm_pe_dll_state;

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

/* Separate research opt-in; ONLY source-generated embedded DLL fixtures owned by
 * this project. No external file path is accepted. This is not a sandbox against
 * a malicious native caller. Requires a DLL with a nonzero file-backed RX entry.
 * All ordinary loader limits and unsupported-directory refusals still apply.
 * Loading only maps/binds/protects; it never invokes the entry point.
 */
int pm_pe_load_synthetic_dll(const uint8_t *bytes, size_t size, pm_import_resolver resolver,
                            void *context, pm_pe_image *image, char *error, size_t error_cap);

/* Separate research opt-in for OUR embedded AMD64 EXE fixtures only. Requires
 * complete_catalogue_attested==1 AND nonempty exception directory 3. This explicit
 * host attestation is not inferred/proved from .pdata. Default pm_pe_load and
 * synthetic_dll still reject directory 3. No handler, SEH, TLS, DLL, continuation,
 * OS function-table registration or execution occurs while loading.
 * Image <=1 MiB, <=4096 sorted/nonoverlapping RUNTIME_FUNCTION records. The SAME
 * private V1/flags0/three-opcode validator as x64_unwind validates the catalogue.
 * Code is file-backed RX; metadata is file-backed R, never W/X, including final
 * HOST page protections. Relocations and IAT writes (including zero terminators)
 * may not overlap any recorded code or metadata byte. Source stays unchanged.
 * Projection is copied from the loaded mapping AFTER permitted fixups and then
 * revalidated. Only recorded code/.pdata/.xdata ranges are populated; other RVAs
 * are zero, not a representation of arbitrary memory or permission to read it.
 */
int pm_pe_load_synthetic_unwind_exe(const uint8_t *bytes, size_t size,
    pm_import_resolver resolver, void *context, int complete_catalogue_attested,
    pm_pe_image *image, char *error, size_t error_cap);

/* Borrowed projection+catalogue, valid only until successful unload. Leaf remains
 * disabled. output unchanged on refusal. Keep the ORIGINAL image object alive,
 * unmodified at its original address, and use/unload it only on its loading thread.
 * Copies/stale fields/wrong thread are refused ONLY while the original owner
 * and its control storage remain alive. Never inspect a copied handle after
 * owner unload. This is not a C memory-safety boundary or ABA/concurrent-unload
 * defence. output/error must not overlap each other, image, or owned storage.
 * Never mutate mapping protections,
 * code/metadata or borrowed projection. No snapshot is refreshed from guest code.
 * Caller must not retain/access any borrowed view after unload. */
int pm_pe_unwind_view(const pm_pe_image *image, struct pm_unwind_image *output,
    char *error, size_t error_cap);

/* One-shot explicit Microsoft x64 ABI process notifications, on the loading
 * thread only. Attach calls entry(base,1,NULL); FALSE calls entry(base,0,NULL)
 * for cleanup and returns failure in FAILED state. Explicit detach calls
 * entry(base,0,NULL), ignores its BOOL return, and enters DETACHED. Caller then
 * unloads. READY/FAILED/DETACHED may unload; ATTACHING/ATTACHED/DETACHING may not.
 * No thread notifications, CRT, TLS, loader lock, exception handling/unwind or
 * arbitrary DLL compatibility is implemented. A fault/exception is not caught.
 *
 * Keep this handle alive at its original address; never copy/mutate its fields.
 * All operations and imported callbacks are confined to the loading thread.
 * Another thread must not race handle destruction or inspect mapping contents.
 * Calls from another thread are refused while the original handle is live;
 * this does not make raw C handle access thread-safe. Nested lifecycle operations
 * on the same image are refused. Detach does not wait for arbitrary guest work.
 */
int pm_pe_synthetic_dll_attach(pm_pe_image *image, char *error, size_t error_cap);
int pm_pe_synthetic_dll_detach(pm_pe_image *image, char *error, size_t error_cap);
pm_pe_dll_state pm_pe_synthetic_dll_state(const pm_pe_image *image);

#define PM_PE_DEPENDENCY_LIMIT 32u
#define PM_PE_CLIENT_HOLD_LIMIT 1024u

/* HOST ownership only, NOT LoadLibrary/FreeLibrary/GetModuleHandleEx or a
 * Windows reference count. Declare 1..32 explicit DLL dependencies once for a
 * successfully loaded EXE. The entire list is validated before any retention;
 * failure leaves all counts/client state unchanged, including one-shot state.
 * All images must be original live objects on their loading thread. No copies,
 * mock snapshots, cleanup-only images, duplicates, self, or EXE targets. A DLL
 * with an initialization entry must be synthetic and ATTACHED; strict entry0
 * DLLs need no notification. At most 1024 client holds per DLL. EXE->DLL only:
 * no cycles, transitive dependency discovery or graph traversal is claimed.
 *
 * A held DLL cannot detach or unload. Successful unmap of the client releases
 * exactly its declared holds; failure retains them for retry. There is no early
 * release API. Existing registries/contexts remain BORROWED: only listed edges
 * are protected, not an inferred complete set of IAT/dynamic pointers. Call this
 * before any client EXE invocation (HOST precondition, not automatically
 * detected); a required synthetic DLL attach necessarily precedes acquisition.
 * No fallback-address lifetime is retained, and no DllMain is called here.
 * Keep original C image objects alive/unmodified; no external unmap/protection
 * changes. All ownership mutations/guest calls are serialized by the HOST.
 * Copy checks are valid only while the original owner/control is alive; no ABA
 * protection, arbitrary-pointer validation or concurrent C handle safety.
 * Output error must not alias images, list, mapping, or private control storage.
 */
int pm_pe_hold_dependencies(pm_pe_image *client,
    const pm_pe_image *const *dependencies, size_t count, char *error, size_t error_cap);

/* Success=1, including an empty/NULL image. Failure=0 preserves the handle so the
 * caller can retry; never claim imageUnmapped when this function returns 0.
 * Every real loaded image enforces original-owner/loading-thread provenance.
 * Incoming dependency holds refuse unload before any OS call. A failed munmap
 * conserves mapping, controls and outgoing holds, but marks the image cleanup-
 * only: no new holds, export/view use or lifecycle calls, only retry unload.
 * Previously returned raw addresses must NOT be used after successful unload
 * or a failed OS unmap attempt. A pre-OS hold/lifecycle refusal leaves readiness
 * unchanged, so the owner may continue permitted client calls.
 * This does not promise atomic OS rollback. An opted-in DLL also enforces its
 * lifecycle state; live ATTACHED/busy DLLs must first detach without holds. */
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
