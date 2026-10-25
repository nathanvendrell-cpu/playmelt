#include "winapi_memory.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* Primary Microsoft contracts consulted 2026-10-25:
 * https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualprotect
 * https://learn.microsoft.com/en-us/windows/win32/memory/memory-protection-constants
 * https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--0-499-
 * https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--500-999-
 * https://pubs.opengroup.org/onlinepubs/7908799/xsh/mprotect.html
 * https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/mprotect.2.html
 * POSIX permits partial protection changes on some failures: quarantine them.
 * The narrower ownership/output/W^X policy is explicit in winapi_memory.h.
 */

typedef struct memory_region {
    void *base;
    size_t bytes;
    uint32_t *pages;
    int quarantined;
} memory_region;

struct pm_winapi_memory {
    memory_region regions[PM_MEMORY_MAX_REGIONS];
    size_t count, bytes, page_size;
    pthread_mutex_t mutex;
    int bound;
};

static pthread_key_t memory_key;
static pthread_once_t memory_once = PTHREAD_ONCE_INIT;
static int memory_key_ready;

static void release_binding(void *value) {
    pm_winapi_memory *ctx = value;
    if (!ctx) return;
    pthread_mutex_lock(&ctx->mutex);
    ctx->bound = 0;
    pthread_mutex_unlock(&ctx->mutex);
}

static void create_memory_key(void) {
    memory_key_ready = pthread_key_create(&memory_key, release_binding) == 0;
}

static int tls_ready(void) {
    return pthread_once(&memory_once, create_memory_key) == 0 && memory_key_ready;
}

pm_winapi_memory *pm_winapi_memory_create(char *error, size_t error_capacity) {
    if (error && error_capacity) error[0] = 0;
    const char *reason = "allocation failed";
    long page = sysconf(_SC_PAGESIZE);
    if (page < 4096 || page > 65536 || (page & (page - 1))) {
        reason = "unsupported host page size";
        goto fail;
    }
    pm_winapi_memory *ctx = calloc(1, sizeof *ctx);
    if (!ctx) goto fail;
    ctx->page_size = (size_t)page;
    if (pthread_mutex_init(&ctx->mutex, NULL)) {
        free(ctx); reason = "mutex initialization failed"; goto fail;
    }
    return ctx;
fail:
    if (error && error_capacity) snprintf(error, error_capacity, "%s", reason);
    return NULL;
}

size_t pm_winapi_memory_page_size(const pm_winapi_memory *ctx) {
    return ctx ? ctx->page_size : 0;
}

int pm_winapi_memory_allocate(pm_winapi_memory *ctx, size_t bytes,
    void **base, size_t *rounded_bytes) {
    if (base) *base = NULL;
    if (rounded_bytes) *rounded_bytes = 0;
    if (!ctx || !base || !rounded_bytes || !bytes || bytes > PM_MEMORY_MAX_REGION_BYTES) return 0;
    pthread_mutex_lock(&ctx->mutex);
    int ok = 0;
    size_t rounded = (bytes + ctx->page_size - 1) & ~(ctx->page_size - 1);
    if (ctx->bound || ctx->count == PM_MEMORY_MAX_REGIONS ||
        rounded > PM_MEMORY_MAX_TOTAL_BYTES - ctx->bytes) goto done;
    size_t count = rounded / ctx->page_size;
    uint32_t *pages = calloc(count, sizeof *pages);
    if (!pages) goto done;
    void *mapping = mmap(NULL, rounded, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mapping == MAP_FAILED) { free(pages); goto done; }
    for (size_t i = 0; i < count; ++i) pages[i] = PM_PAGE_READWRITE;
    ctx->regions[ctx->count++] = (memory_region){mapping, rounded, pages, 0};
    ctx->bytes += rounded;
    *base = mapping;
    *rounded_bytes = rounded;
    ok = 1;
done:
    pthread_mutex_unlock(&ctx->mutex);
    return ok;
}

static int release_region(pm_winapi_memory *ctx, size_t index) {
    memory_region *region = &ctx->regions[index];
    if (munmap(region->base, region->bytes)) return 0;
    ctx->bytes -= region->bytes;
    free(region->pages);
    if (index + 1 < ctx->count)
        memmove(region, region + 1, (ctx->count - index - 1) * sizeof *region);
    memset(&ctx->regions[--ctx->count], 0, sizeof *region);
    return 1;
}

int pm_winapi_memory_release(pm_winapi_memory *ctx, void *exact_base) {
    if (!ctx || !exact_base) return 0;
    pthread_mutex_lock(&ctx->mutex);
    int ok = 0;
    if (!ctx->bound) {
        for (size_t i = 0; i < ctx->count; ++i) {
            if (ctx->regions[i].base == exact_base) { ok = release_region(ctx, i); break; }
        }
    }
    pthread_mutex_unlock(&ctx->mutex);
    return ok;
}

int pm_winapi_memory_bind(pm_winapi_memory *ctx) {
    if (!ctx || !tls_ready() || pthread_getspecific(memory_key)) return 0;
    pthread_mutex_lock(&ctx->mutex);
    int ok = !ctx->bound && pthread_setspecific(memory_key, ctx) == 0;
    if (ok) ctx->bound = 1;
    pthread_mutex_unlock(&ctx->mutex);
    return ok;
}

int pm_winapi_memory_unbind(void) {
    if (!tls_ready()) return 0;
    pm_winapi_memory *ctx = pthread_getspecific(memory_key);
    if (!ctx || pthread_setspecific(memory_key, NULL)) return 0;
    release_binding(ctx);
    return 1;
}

int pm_winapi_memory_destroy(pm_winapi_memory **context) {
    if (!context) return 0;
    pm_winapi_memory *ctx = *context;
    if (!ctx) return 1;
    pthread_mutex_lock(&ctx->mutex);
    int ok = !ctx->bound;
    if (ok) {
        for (size_t i = ctx->count; i > 0; --i)
            if (!release_region(ctx, i - 1)) ok = 0;
    }
    pthread_mutex_unlock(&ctx->mutex);
    if (!ok || pthread_mutex_destroy(&ctx->mutex)) return 0;
    free(ctx);
    *context = NULL;
    return 1;
}

static memory_region *find_range(pm_winapi_memory *ctx, uintptr_t start, size_t bytes) {
    if (!bytes || start > UINTPTR_MAX - bytes) return NULL;
    for (size_t i = 0; i < ctx->count; ++i) {
        memory_region *r = &ctx->regions[i];
        uintptr_t base = (uintptr_t)r->base;
        if (start >= base && bytes <= r->bytes && start - base <= r->bytes - bytes) return r;
    }
    return NULL;
}

static uint32_t host_error(int error) {
    switch (error) {
        case EACCES: case EPERM: return PM_MEMORY_ERROR_ACCESS_DENIED;
        case ENOMEM: return PM_MEMORY_ERROR_NOT_ENOUGH_MEMORY;
        case EINVAL: return PM_ERROR_INVALID_PARAMETER;
        default: return PM_ERROR_GEN_FAILURE;
    }
}

int32_t PM_WINAPI pm_win_VirtualProtect(void *address, size_t bytes,
    uint32_t new_protection, void *old_protection) {
    uint32_t failure = PM_ERROR_INVALID_PARAMETER;
    int protection;
    switch (new_protection) {
        case PM_PAGE_NOACCESS: protection = PROT_NONE; break;
        case PM_PAGE_READONLY: protection = PROT_READ; break;
        case PM_PAGE_READWRITE: protection = PROT_READ | PROT_WRITE; break;
        case PM_PAGE_EXECUTE_READ: protection = PROT_READ | PROT_EXEC; break;
        default: goto fail;
    }
    if (!bytes) goto fail;
    failure = PM_MEMORY_ERROR_INVALID_ADDRESS;
    pm_winapi_memory *ctx = tls_ready() ? pthread_getspecific(memory_key) : NULL;
    if (!ctx) goto fail;
    memory_region *target = find_range(ctx, (uintptr_t)address, bytes);
    if (!target || target->quarantined) goto fail;
    failure = PM_MEMORY_ERROR_NOACCESS;
    memory_region *output = find_range(ctx, (uintptr_t)old_protection, sizeof(uint32_t));
    if (!output || output->quarantined || output == target) goto fail;
    size_t output_first = ((uintptr_t)old_protection - (uintptr_t)output->base) / ctx->page_size;
    size_t output_last = ((uintptr_t)old_protection - (uintptr_t)output->base + sizeof(uint32_t) - 1) / ctx->page_size;
    for (size_t i = output_first; i <= output_last; ++i)
        if (output->pages[i] != PM_PAGE_READWRITE) goto fail;
    size_t first = ((uintptr_t)address - (uintptr_t)target->base) / ctx->page_size;
    size_t last = ((uintptr_t)address - (uintptr_t)target->base + bytes - 1) / ctx->page_size;
    uint32_t old = target->pages[first];
    void *aligned = (unsigned char *)target->base + first * ctx->page_size;
    size_t length = (last - first + 1) * ctx->page_size;
    if (mprotect(aligned, length, protection)) {
        failure = host_error(errno);
        target->quarantined = 1;
        goto fail;
    }
    for (size_t i = first; i <= last; ++i) target->pages[i] = new_protection;
    /* The void* output deliberately carries no uint32_t alignment promise. */
    memcpy(old_protection, &old, sizeof old);
    return 1;
fail:
    pm_win_SetLastError(failure);
    return 0;
}

static int kernel_module(const char *dll) {
    if (!dll) return 0;
    char lower[15];
    size_t i;
    for (i = 0; i < sizeof lower; ++i) {
        unsigned char c = (unsigned char)dll[i];
        lower[i] = (char)(c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c);
        if (!c) break;
    }
    return i < sizeof lower && (!strcmp(lower, "kernel32.dll") || !strcmp(lower, "kernelbase.dll"));
}

int pm_winapi_memory_resolve(void *context, const char *dll, const char *name,
    uint16_t ordinal, int by_ordinal, uintptr_t *address) {
    (void)context;
    if (!address) return 0;
    *address = 0;
    if (by_ordinal || !name || !kernel_module(dll)) return 0;
    if (!strcmp(name, "VirtualProtect")) { *address = (uintptr_t)&pm_win_VirtualProtect; return 1; }
    return pm_winapi_resolve(NULL, dll, name, ordinal, by_ordinal, address);
}
