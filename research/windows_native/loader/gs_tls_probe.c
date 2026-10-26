/* Reuse the reviewed PE/GS host and assembly; change only the load mode and
 * install its owned, actually initialized TLS vector instead of a stack slab. */
#define PM_GS_TLS_PROBE 1
#include "gs_pe_probe.c"
