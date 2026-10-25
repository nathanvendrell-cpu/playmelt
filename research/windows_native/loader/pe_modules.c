#include "pe_modules.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* PE forwarders name a target module and a named/ordinal export:
 * https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#export-address-table
 * This bounded registry implements only the explicit subset documented in .h;
 * it is not Windows dependency discovery or an operating-system module loader.
 */

static int fail(pm_pe_modules *registry, const char *format, ...) {
    if (registry) {
        va_list args;
        va_start(args, format);
        vsnprintf(registry->error, sizeof registry->error, format, args);
        va_end(args);
    }
    return 0;
}

static int usable(pm_pe_modules *registry) {
    if (!registry) return 0;
    registry->error[0] = '\0';
    return registry->count <= PM_PE_MODULES_CAPACITY ||
           fail(registry, "invalid-registry: count exceeds fixed capacity");
}

static unsigned char ascii_lower(unsigned char c) {
    return c >= 'A' && c <= 'Z' ? (unsigned char)(c + ('a' - 'A')) : c;
}

static int bounded_length(const char *value, size_t capacity, size_t *length) {
    if (!value) return 0;
    for (size_t i = 0; i < capacity; ++i) {
        if (!value[i]) { *length = i; return 1; }
    }
    return 0;
}

static int dll_suffix(const char *value) {
    return value[0] == '.' && ascii_lower((unsigned char)value[1]) == 'd' &&
           ascii_lower((unsigned char)value[2]) == 'l' &&
           ascii_lower((unsigned char)value[3]) == 'l';
}

static int normalize_module(const char *dll, char *normalized) {
    size_t size;
    if (!bounded_length(dll, PM_PE_MODULE_NAME_CAP, &size) || size < 5 ||
        !dll_suffix(dll + size - 4)) return 0;
    for (size_t i = 0; i < size - 4; ++i) {
        const unsigned char c = ascii_lower((unsigned char)dll[i]);
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'))
            return 0;
        normalized[i] = (char)c;
    }
    memcpy(normalized + size - 4, ".dll", 5);
    return 1;
}

static int valid_symbol(const char *name) {
    size_t size;
    if (!bounded_length(name, PM_PE_MODULE_SYMBOL_CAP, &size) || !size) return 0;
    for (size_t i = 0; i < size; ++i) {
        unsigned char c = (unsigned char)name[i];
        if (c < 0x21 || c > 0x7e) return 0;
    }
    return 1;
}

static pm_pe_module_slot *find_module(pm_pe_modules *registry, const char *name) {
    for (size_t i = 0; i < registry->count; ++i)
        if (!strcmp(registry->slots[i].name, name)) return &registry->slots[i];
    return NULL;
}

int pm_pe_modules_init(pm_pe_modules *registry, pm_import_resolver fallback,
                       void *fallback_context) {
    if (!registry) return 0;
    memset(registry, 0, sizeof *registry);
    if (fallback == pm_pe_modules_resolve)
        return fail(registry, "invalid-fallback: registry chaining is not supported");
    registry->fallback = fallback;
    registry->fallback_context = fallback_context;
    return 1;
}

int pm_pe_modules_add(pm_pe_modules *registry, const char *dll,
                      const pm_pe_image *image) {
    if (!usable(registry)) return 0;
    char normalized[PM_PE_MODULE_NAME_CAP];
    if (!normalize_module(dll, normalized))
        return fail(registry, "invalid-module-name: explicit ASCII basename.dll required");
    if (!image || !image->mapping || !image->mapping_size)
        return fail(registry, "invalid-image: a live successfully loaded image is required");
    if (find_module(registry, normalized))
        return fail(registry, "duplicate-module: %s", normalized);
    if (registry->count == PM_PE_MODULES_CAPACITY)
        return fail(registry, "registry-full: maximum %d modules", PM_PE_MODULES_CAPACITY);
    pm_pe_module_slot *slot = &registry->slots[registry->count++];
    memcpy(slot->name, normalized, strlen(normalized) + 1);
    slot->image = image;
    slot->mapping = image->mapping;
    slot->mapping_size = image->mapping_size;
    slot->exports = image->exports;
    return 1;
}

int pm_pe_modules_remove(pm_pe_modules *registry, const char *dll) {
    if (!usable(registry)) return 0;
    char normalized[PM_PE_MODULE_NAME_CAP];
    if (!normalize_module(dll, normalized))
        return fail(registry, "invalid-module-name: explicit ASCII basename.dll required");
    pm_pe_module_slot *slot = find_module(registry, normalized);
    if (!slot) return fail(registry, "module-not-registered: %s", normalized);
    const size_t index = (size_t)(slot - registry->slots);
    if (index + 1 < registry->count)
        memmove(slot, slot + 1, (registry->count - index - 1) * sizeof *slot);
    memset(&registry->slots[--registry->count], 0, sizeof *slot);
    return 1;
}

const char *pm_pe_modules_last_error(const pm_pe_modules *registry) {
    return registry ? registry->error : "invalid-registry: NULL";
}

static int parse_forwarder(pm_pe_modules *registry, const char *forwarder,
                            char *module, char *name, uint32_t *ordinal, int *by_ordinal) {
    size_t length;
    const size_t capacity = PM_PE_MODULE_NAME_CAP + PM_PE_MODULE_SYMBOL_CAP;
    if (!bounded_length(forwarder, capacity, &length) || !length)
        return fail(registry, "invalid-forwarder: absent or too long");
    if (strchr(forwarder, '/') || strchr(forwarder, '\\') || strchr(forwarder, ':'))
        return fail(registry, "invalid-forwarder: paths are not allowed");
    const char *dot = strchr(forwarder, '.');
    if (!dot || dot == forwarder)
        return fail(registry, "invalid-forwarder: module and symbol are required");
    const size_t stem_length = (size_t)(dot - forwarder);
    if (stem_length + 5 > PM_PE_MODULE_NAME_CAP)
        return fail(registry, "invalid-forwarder: module name is too long");
    char explicit_dll[PM_PE_MODULE_NAME_CAP];
    memcpy(explicit_dll, forwarder, stem_length);
    memcpy(explicit_dll + stem_length, ".dll", 5);
    if (!normalize_module(explicit_dll, module))
        return fail(registry, "invalid-forwarder: module is not an ASCII basename");
    const char *symbol = dot + 1;
    const size_t tail_length = length - stem_length - 1;
    if (tail_length >= 3 && ascii_lower((unsigned char)symbol[0]) == 'd' &&
        ascii_lower((unsigned char)symbol[1]) == 'l' &&
        ascii_lower((unsigned char)symbol[2]) == 'l') {
        if (tail_length == 3)
            return fail(registry, "invalid-forwarder: bare module.dll is ambiguous");
        if (symbol[3] == '.') symbol += 4;
    }
    if (!valid_symbol(symbol) || strchr(symbol, '.'))
        return fail(registry, "invalid-forwarder: missing, dotted, or invalid symbol");
    *ordinal = 0;
    *by_ordinal = 0;
    if (symbol[0] == '#') {
        if (!symbol[1]) return fail(registry, "invalid-forwarder: empty ordinal");
        uint32_t value = 0;
        for (const char *digit = symbol + 1; *digit; ++digit) {
            if (*digit < '0' || *digit > '9')
                return fail(registry, "invalid-forwarder: ordinal must be unsigned decimal");
            const uint32_t number = (uint32_t)(*digit - '0');
            if (value > (UINT32_MAX - number) / 10)
                return fail(registry, "invalid-forwarder: ordinal exceeds uint32");
            value = value * 10 + number;
        }
        *ordinal = value;
        *by_ordinal = 1;
        name[0] = '\0';
    } else {
        memcpy(name, symbol, strlen(symbol) + 1);
    }
    return 1;
}

int pm_pe_modules_lookup(pm_pe_modules *registry, const char *dll,
                         const char *name, uint32_t ordinal, int by_ordinal,
                         pm_pe_module_result *result) {
    if (result) memset(result, 0, sizeof *result);
    if (!usable(registry)) return 0;
    if (!result) return fail(registry, "invalid-output: result is NULL");
    char module[PM_PE_MODULE_NAME_CAP];
    char symbol[PM_PE_MODULE_SYMBOL_CAP] = {0};
    if (!normalize_module(dll, module))
        return fail(registry, "invalid-module-name: explicit ASCII basename.dll required");
    if ((by_ordinal != 0 && by_ordinal != 1) ||
        (by_ordinal && name) || (!by_ordinal && (ordinal || !valid_symbol(name))))
        return fail(registry, "invalid-symbol-query: choose exact name or uint32 ordinal");
    if (!by_ordinal) memcpy(symbol, name, strlen(name) + 1);
    struct visited_export { const pm_pe_image *image; uint32_t ordinal; };
    struct visited_export visited[PM_PE_MODULE_LOOKUP_LIMIT];
    unsigned visited_count = 0;
    for (unsigned lookup = 0; lookup < PM_PE_MODULE_LOOKUP_LIMIT; ++lookup) {
        pm_pe_module_slot *slot = find_module(registry, module);
        if (!slot) {
            if (!registry->fallback)
                return fail(registry, "module-not-registered: %s", module);
            if (by_ordinal && ordinal > UINT16_MAX)
                return fail(registry, "fallback-ordinal-overflow: uint16 resolver cannot represent ordinal");
            uintptr_t address = 0;
            int resolved = registry->fallback(registry->fallback_context, module,
                by_ordinal ? NULL : symbol, (uint16_t)ordinal, by_ordinal, &address);
            if (resolved != 1 || !address)
                return fail(registry, "fallback-refused: %s", module);
            result->address = address;
            result->ordinal = ordinal;
            result->from_fallback = 1;
            result->forwarder_hops = lookup;
            return 1;
        }
        if (slot->image->mapping != slot->mapping ||
            slot->image->mapping_size != slot->mapping_size ||
            slot->image->exports != slot->exports)
            return fail(registry, "stale-module: unregister before unload/reload of %s", module);
        pm_pe_export exported = {0};
        char error[PM_PE_MODULE_ERROR_CAP] = {0};
        if (pm_pe_find_export(slot->image, by_ordinal ? NULL : symbol, ordinal,
                              by_ordinal, &exported, error, sizeof error) != 1)
            return fail(registry, "export-unavailable: %.127s: %.96s", module, error);
        for (unsigned i = 0; i < visited_count; ++i)
            if (visited[i].image == slot->image && visited[i].ordinal == exported.ordinal)
                return fail(registry, "forwarder-cycle: %s ordinal %u", module, exported.ordinal);
        visited[visited_count++] = (struct visited_export){slot->image, exported.ordinal};
        if (exported.kind == PM_PE_EXPORT_DIRECT) {
            const uintptr_t base = (uintptr_t)slot->mapping;
            if (!exported.address || exported.forwarder || exported.rva >= slot->mapping_size ||
                base > UINTPTR_MAX - exported.rva ||
                (uintptr_t)exported.address != base + exported.rva ||
                (exported.executable != 0 && exported.executable != 1) ||
                (exported.writable != 0 && exported.writable != 1) ||
                (exported.executable && exported.writable))
                return fail(registry, "invalid-direct-export: inconsistent address or permissions");
            result->address = (uintptr_t)exported.address;
            result->image = slot->image;
            result->ordinal = exported.ordinal;
            result->rva = exported.rva;
            result->permissions_known = 1;
            result->executable = exported.executable;
            result->writable = exported.writable;
            result->forwarder_hops = lookup;
            return 1;
        }
        if (exported.kind != PM_PE_EXPORT_FORWARDER || exported.address ||
            exported.executable || exported.writable || exported.rva >= slot->mapping_size)
            return fail(registry, "invalid-export-kind: inconsistent forwarder metadata");
        if (!parse_forwarder(registry, exported.forwarder, module, symbol, &ordinal, &by_ordinal))
            return 0;
    }
    return fail(registry, "forwarder-depth: maximum %d module lookups", PM_PE_MODULE_LOOKUP_LIMIT);
}

int pm_pe_modules_resolve(void *context, const char *dll, const char *name,
                          uint16_t ordinal, int by_ordinal, uintptr_t *address) {
    pm_pe_modules *registry = context;
    if (address) *address = 0;
    if (!address) {
        if (usable(registry)) fail(registry, "invalid-output: address is NULL");
        return 0;
    }
    pm_pe_module_result result;
    if (!pm_pe_modules_lookup(registry, dll, name, ordinal, by_ordinal, &result)) return 0;
    *address = result.address;
    return 1;
}
