#ifndef PM_GS_PE_PROBE_H
#define PM_GS_PE_PROBE_H
#include "gs_probe.h"
#define GS_PE_ENTRY_RESULT 400
#define GS_PE_ENTRY_CALLS 408
#ifndef __ASSEMBLER__
typedef struct pm_gs_pe_context {
    pm_gs_context gs;
    uint64_t entry_result, entry_calls;
} pm_gs_pe_context;
_Static_assert(offsetof(pm_gs_pe_context,entry_result)==GS_PE_ENTRY_RESULT,"entry result offset");
_Static_assert(offsetof(pm_gs_pe_context,entry_calls)==GS_PE_ENTRY_CALLS,"entry calls offset");
/* Disposable child only, not public guest dispatch. entry is the verified RX
 * entry in our freshly loaded embedded fixture. No arbitrary PE/path accepted.
 * The fixture checks gs.failure immediately after every IAT call, before any
 * further GS access (the gateway can fail back into Darwin GS). */
uint64_t pm_gs_invoke_pe(pm_gs_pe_context *context,uintptr_t entry);
#endif
#endif
