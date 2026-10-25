#include "winapi_modules.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Primary contracts, consulted 2026-10-25:
 * https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulehandlea
 * https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulehandlew
 * https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getprocaddress
 * https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--0-499-
 * Deliberately narrower naming/lifetime rules are documented in the header.
 */

#define HOST_CAPACITY 8
typedef struct host_module {
    char name[PM_PE_MODULE_NAME_CAP];
    pm_import_resolver resolver;
    void *context;
} host_module;

struct pm_winapi_modules {
    pm_pe_modules registry;
    pm_pe_module_slot main;
    host_module hosts[HOST_CAPACITY];
    size_t host_count;
    pthread_mutex_t mutex;
    int bound;
    int sealed;
};

static pthread_key_t context_key;
static pthread_once_t context_key_once = PTHREAD_ONCE_INIT;
static int context_key_ready;

static void release_binding(void *value) {
    pm_winapi_modules *ctx = value;
    if (!ctx) return;
    pthread_mutex_lock(&ctx->mutex);
    ctx->bound = 0;
    pthread_mutex_unlock(&ctx->mutex);
}

static void create_key(void) {
    context_key_ready = pthread_key_create(&context_key, release_binding) == 0;
}

static int tls_ready(void) {
    return pthread_once(&context_key_once, create_key) == 0 && context_key_ready;
}

static pm_winapi_modules *current_context(void) {
    return tls_ready() ? pthread_getspecific(context_key) : NULL;
}

static unsigned char lower_ascii(unsigned char c) {
    return c >= 'A' && c <= 'Z' ? (unsigned char)(c + ('a' - 'A')) : c;
}

static int normalize(const char *input, char *out, int main_name, int implicit) {
    if (!input) return 0;
    size_t n = 0;
    for (; n < PM_PE_MODULE_NAME_CAP; ++n) {
        unsigned char c = (unsigned char)input[n];
        if (!c) break;
        out[n] = (char)lower_ascii(c);
    }
    if (!n || n == PM_PE_MODULE_NAME_CAP) return 0;
    out[n] = 0;
    if (implicit && !strchr(out, '.')) {
        if (n + 4 >= PM_PE_MODULE_NAME_CAP) return 0;
        memcpy(out + n, ".dll", 5);
        n += 4;
    }
    if (n < 5 || strcmp(out + n - 4, main_name ? ".exe" : ".dll")) return 0;
    for (size_t i = 0; i < n - 4; ++i) {
        unsigned char c = (unsigned char)out[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
              c == '_' || c == '-')) return 0;
    }
    return 1;
}

int pm_winapi_modules_resolve(void *ctx, const char *dll, const char *name,
    uint16_t ordinal, int by_ordinal, uintptr_t *address) {
    (void)ctx;
    if (!address) return 0;
    *address = 0;
    char normalized[PM_PE_MODULE_NAME_CAP];
    if (by_ordinal || !name || !normalize(dll, normalized, 0, 0) ||
        (strcmp(normalized, "kernel32.dll") && strcmp(normalized, "kernelbase.dll"))) return 0;
#define RESOLVE(symbol) if (!strcmp(name, #symbol)) { \
    *address = (uintptr_t)&pm_win_##symbol; return 1; }
    RESOLVE(GetModuleHandleA)
    RESOLVE(GetModuleHandleW)
    RESOLVE(GetProcAddress)
#undef RESOLVE
    return pm_winapi_resolve(NULL, dll, name, ordinal, by_ordinal, address);
}

static int live(const pm_pe_module_slot *slot) {
    return slot->image && slot->mapping && slot->mapping_size &&
        slot->image->mapping == slot->mapping &&
        slot->image->mapping_size == slot->mapping_size &&
        slot->image->exports == slot->exports;
}

static int host_fallback(void *opaque, const char *dll, const char *name,
    uint16_t ordinal, int by_ordinal, uintptr_t *address) {
    pm_winapi_modules *ctx = opaque;
    if (!address) return 0;
    *address = 0;
    for (size_t i = 0; i < ctx->host_count; ++i) {
        host_module *host = &ctx->hosts[i];
        if (!strcmp(host->name, dll)) {
            int ok = host->resolver(host->context, dll, name, ordinal, by_ordinal, address);
            if (ok == 1 && *address) return 1;
            *address = 0;
            return 0;
        }
    }
    return 0;
}

pm_winapi_modules *pm_winapi_modules_create(const pm_pe_modules *registry,
    const pm_pe_image *main_image, const char *main_basename,
    char *error, size_t error_capacity) {
    if (error && error_capacity) error[0] = 0;
    const char *reason = "invalid module context input";
    char main_name[PM_PE_MODULE_NAME_CAP];
    if (!registry || registry->count > PM_PE_MODULES_CAPACITY || !main_image ||
        !main_image->mapping || !main_image->mapping_size ||
        !normalize(main_basename, main_name, 1, 0)) goto failed;
    pm_winapi_modules *ctx = calloc(1, sizeof *ctx);
    if (!ctx) { reason = "module context allocation failed"; goto failed; }
    if (pthread_mutex_init(&ctx->mutex, NULL) != 0) {
        free(ctx); reason = "module context mutex initialization failed"; goto failed;
    }
    pm_pe_modules_init(&ctx->registry, host_fallback, ctx);
    for (size_t i = 0; i < registry->count; ++i) {
        const pm_pe_module_slot *source = &registry->slots[i];
        if (!live(source) || source->mapping == main_image->mapping ||
            !pm_pe_modules_add(&ctx->registry, source->name, source->image)) {
            reason = "invalid, stale or duplicate module registration";
            goto failed_context;
        }
        for (size_t j = 0; j < i; ++j) {
            if (source->mapping == registry->slots[j].mapping) {
                reason = "ambiguous module handle: duplicate mapping";
                goto failed_context;
            }
        }
    }
    memcpy(ctx->main.name, main_name, strlen(main_name) + 1);
    ctx->main.image = main_image;
    ctx->main.mapping = main_image->mapping;
    ctx->main.mapping_size = main_image->mapping_size;
    ctx->main.exports = main_image->exports;
    return ctx;
failed_context:
    pthread_mutex_destroy(&ctx->mutex);
    free(ctx);
failed:
    if (error && error_capacity) snprintf(error, error_capacity, "%s", reason);
    return NULL;
}

int pm_winapi_modules_add_host(pm_winapi_modules *ctx, const char *basename,
    pm_import_resolver resolver, void *resolver_context) {
    char name[PM_PE_MODULE_NAME_CAP];
    if (!ctx || !resolver || resolver == pm_pe_modules_resolve ||
        !normalize(basename, name, 0, 0)) return 0;
    pthread_mutex_lock(&ctx->mutex);
    int ok = 0;
    if (ctx->sealed || ctx->host_count == HOST_CAPACITY) goto done;
    for (size_t i = 0; i < ctx->registry.count; ++i)
        if (!strcmp(ctx->registry.slots[i].name, name)) goto done;
    for (size_t i = 0; i < ctx->host_count; ++i)
        if (!strcmp(ctx->hosts[i].name, name)) goto done;
    host_module *host = &ctx->hosts[ctx->host_count++];
    memcpy(host->name, name, strlen(name) + 1);
    host->resolver = resolver;
    host->context = resolver_context;
    ok = 1;
done:
    pthread_mutex_unlock(&ctx->mutex);
    return ok;
}

int pm_winapi_modules_bind(pm_winapi_modules *ctx) {
    if (!ctx || !tls_ready() || pthread_getspecific(context_key)) return 0;
    pthread_mutex_lock(&ctx->mutex);
    int ok = !ctx->bound && live(&ctx->main);
    for (size_t i = 0; ok && i < ctx->registry.count; ++i)
        ok = live(&ctx->registry.slots[i]);
    if (ok) ok = pthread_setspecific(context_key, ctx) == 0;
    if (ok) ctx->bound = ctx->sealed = 1;
    pthread_mutex_unlock(&ctx->mutex);
    return ok;
}

int pm_winapi_modules_unbind(void) {
    pm_winapi_modules *ctx = current_context();
    if (!ctx || pthread_setspecific(context_key, NULL) != 0) return 0;
    release_binding(ctx);
    return 1;
}

int pm_winapi_modules_destroy(pm_winapi_modules **context) {
    if (!context) return 0;
    pm_winapi_modules *ctx = *context;
    if (!ctx) return 1;
    pthread_mutex_lock(&ctx->mutex);
    int bound = ctx->bound;
    pthread_mutex_unlock(&ctx->mutex);
    if (bound || pthread_mutex_destroy(&ctx->mutex) != 0) return 0;
    free(ctx);
    *context = NULL;
    return 1;
}

static void *get_module(const char *name) {
    pm_winapi_modules *ctx = current_context();
    if (!ctx) goto missing;
    if (!name) {
        if (live(&ctx->main)) return (void *)ctx->main.mapping;
        goto missing;
    }
    char normalized[PM_PE_MODULE_NAME_CAP];
    if (normalize(name, normalized, 1, 0)) {
        if (!strcmp(normalized, ctx->main.name) && live(&ctx->main))
            return (void *)ctx->main.mapping;
        goto missing;
    }
    if (!normalize(name, normalized, 0, 1)) goto missing;
    for (size_t i = 0; i < ctx->registry.count; ++i) {
        pm_pe_module_slot *slot = &ctx->registry.slots[i];
        if (!strcmp(slot->name, normalized)) {
            if (live(slot)) return (void *)slot->mapping;
            goto missing;
        }
    }
    for (size_t i = 0; i < ctx->host_count; ++i)
        if (!strcmp(ctx->hosts[i].name, normalized)) return &ctx->hosts[i];
missing:
    pm_win_SetLastError(PM_ERROR_MOD_NOT_FOUND);
    return NULL;
}

void *PM_WINAPI pm_win_GetModuleHandleA(const char *module_name) {
    return get_module(module_name);
}

void *PM_WINAPI pm_win_GetModuleHandleW(const uint16_t *module_name) {
    if (!module_name) return get_module(NULL);
    char ascii[PM_PE_MODULE_NAME_CAP];
    for (size_t i = 0; i < sizeof ascii; ++i) {
        uint16_t c;
        memcpy(&c, (const unsigned char *)module_name + i * sizeof c, sizeof c);
        if (c > 127) break;
        ascii[i] = (char)c;
        if (!c) return get_module(ascii);
    }
    pm_win_SetLastError(PM_ERROR_MOD_NOT_FOUND);
    return NULL;
}

/* Main executable exports use their actual .exe identity, not a private alias
 * injected into the public DLL registry. Its forwarders enter the same closed
 * DLL registry. Forwarding back to an .exe is outside the registry's subset. */
static int main_export(pm_winapi_modules *ctx, const char *name, uint32_t ordinal,
    int by_ordinal, uintptr_t *address) {
    pm_pe_export value = {0};
    char error[PM_PE_MODULE_ERROR_CAP];
    if (pm_pe_find_export(ctx->main.image, name, ordinal, by_ordinal,
                          &value, error, sizeof error) != 1) return 0;
    if (value.kind == PM_PE_EXPORT_DIRECT) {
        uintptr_t base = (uintptr_t)ctx->main.mapping;
        if (!value.address || value.forwarder || value.rva >= ctx->main.mapping_size ||
            base > UINTPTR_MAX - value.rva || (uintptr_t)value.address != base + value.rva ||
            (value.executable != 0 && value.executable != 1) ||
            (value.writable != 0 && value.writable != 1) ||
            (value.executable && value.writable)) return 0;
        *address = (uintptr_t)value.address;
        return 1;
    }
    if (value.kind != PM_PE_EXPORT_FORWARDER || !value.forwarder || value.address ||
        value.executable || value.writable || value.rva >= ctx->main.mapping_size) return 0;
    const size_t cap = PM_PE_MODULE_NAME_CAP + PM_PE_MODULE_SYMBOL_CAP;
    size_t length = strnlen(value.forwarder, cap);
    if (length == cap) return 0;
    const char *dot = strchr(value.forwarder, '.');
    if (!dot || dot == value.forwarder) return 0;
    size_t stem = (size_t)(dot - value.forwarder);
    if (stem + 5 > PM_PE_MODULE_NAME_CAP) return 0;
    char dll[PM_PE_MODULE_NAME_CAP];
    memcpy(dll, value.forwarder, stem);
    memcpy(dll + stem, ".dll", 5);
    const char *symbol = dot + 1;
    size_t tail = length - stem - 1;
    if (tail >= 3 && lower_ascii((unsigned char)symbol[0]) == 'd' &&
        lower_ascii((unsigned char)symbol[1]) == 'l' &&
        lower_ascii((unsigned char)symbol[2]) == 'l') {
        if (tail == 3) return 0;
        if (symbol[3] == '.') symbol += 4;
    }
    if (!*symbol || strchr(symbol, '.')) return 0;
    uint32_t target_ordinal = 0;
    int ordinal_query = symbol[0] == '#';
    if (ordinal_query) {
        if (!symbol[1]) return 0;
        for (const char *p = symbol + 1; *p; ++p) {
            if (*p < '0' || *p > '9' || target_ordinal > (UINT32_MAX - (*p - '0')) / 10)
                return 0;
            target_ordinal = target_ordinal * 10 + (uint32_t)(*p - '0');
        }
    }
    pm_pe_module_result result;
    if (!pm_pe_modules_lookup(&ctx->registry, dll, ordinal_query ? NULL : symbol,
                              target_ordinal, ordinal_query, &result)) return 0;
    *address = result.address;
    return 1;
}

uintptr_t PM_WINAPI pm_win_GetProcAddress(void *module, const char *name_or_ordinal) {
    pm_winapi_modules *ctx = current_context();
    if (!ctx) {
        pm_win_SetLastError(PM_ERROR_MOD_NOT_FOUND);
        return 0;
    }
    /* Match opaque handles before reading the name: never dereference hModule. */
    pm_pe_module_slot *slot = NULL;
    host_module *host = NULL;
    if (module == ctx->main.mapping) slot = &ctx->main;
    for (size_t i = 0; !slot && i < ctx->registry.count; ++i)
        if (module == ctx->registry.slots[i].mapping) slot = &ctx->registry.slots[i];
    for (size_t i = 0; !slot && i < ctx->host_count; ++i)
        if (module == &ctx->hosts[i]) host = &ctx->hosts[i];
    if ((!slot && !host) || (slot && !live(slot))) {
        pm_win_SetLastError(PM_ERROR_INVALID_HANDLE);
        return 0;
    }
    uintptr_t raw = (uintptr_t)name_or_ordinal;
    int by_ordinal = raw <= UINT16_MAX;
    uint16_t ordinal = by_ordinal ? (uint16_t)raw : 0;
    const char *name = by_ordinal ? NULL : name_or_ordinal;
    if (by_ordinal && !ordinal) goto missing;
    if (!by_ordinal) {
        size_t n = strnlen(name, PM_PE_MODULE_SYMBOL_CAP);
        if (!n || n == PM_PE_MODULE_SYMBOL_CAP) goto missing;
        for (size_t i = 0; i < n; ++i)
            if ((unsigned char)name[i] < 0x21 || (unsigned char)name[i] > 0x7e) goto missing;
    }
    uintptr_t address = 0;
    int ok;
    /* A host callback may modify LastError; successful API calls preserve the
     * incoming value regardless of callback internals. */
    uint32_t previous_error = pm_win_GetLastError();
    if (host) {
        ok = host_fallback(ctx, host->name, name, ordinal, by_ordinal, &address);
    } else if (slot == &ctx->main) {
        ok = main_export(ctx, name, ordinal, by_ordinal, &address);
    } else {
        pm_pe_module_result result;
        ok = pm_pe_modules_lookup(&ctx->registry, slot->name, name, ordinal, by_ordinal, &result);
        address = ok ? result.address : 0;
    }
    if (ok && address) {
        pm_win_SetLastError(previous_error);
        return address;
    }
missing:
    pm_win_SetLastError(PM_ERROR_PROC_NOT_FOUND);
    return 0;
}
