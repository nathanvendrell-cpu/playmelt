/* CPU-only registry tests. Link with pe_modules.c, NOT pe_loader.c.
 * A fake export catalogue below isolates registry policy from PE parsing.
 * No executable memory, real PE, imported function, filesystem or GPU is used.
 */
#include "pe_modules.h"

#include <stdio.h>
#include <string.h>

static unsigned checks, failures, catalogue_queries;
#define CHECK(condition) do { ++checks; if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); ++failures; \
} } while (0)

typedef struct fake_export { const char *name; pm_pe_export value; } fake_export;
struct pm_pe_export_catalog { fake_export entries[8]; size_t count; };
typedef struct fake_image {
    unsigned char bytes[128];
    struct pm_pe_export_catalog catalogue;
    pm_pe_image image;
} fake_image;

static void make_image(fake_image *fake) {
    memset(fake, 0, sizeof *fake);
    fake->image.mapping = fake->bytes;
    fake->image.mapping_size = sizeof fake->bytes;
    fake->image.exports = &fake->catalogue;
}

static void direct(fake_image *fake, const char *name, uint32_t ordinal,
                    uint32_t rva, int executable, int writable) {
    fake_export *entry = &fake->catalogue.entries[fake->catalogue.count++];
    entry->name = name;
    entry->value = (pm_pe_export){ .kind = PM_PE_EXPORT_DIRECT, .ordinal = ordinal,
        .rva = rva, .address = fake->bytes + rva,
        .executable = executable, .writable = writable };
}

static void forward(fake_image *fake, const char *name, uint32_t ordinal,
                     const char *target) {
    fake_export *entry = &fake->catalogue.entries[fake->catalogue.count++];
    entry->name = name;
    entry->value = (pm_pe_export){ .kind = PM_PE_EXPORT_FORWARDER,
        .ordinal = ordinal, .rva = 64, .forwarder = target };
}

int pm_pe_find_export(const pm_pe_image *image, const char *name, uint32_t ordinal,
                      int by_ordinal, pm_pe_export *result, char *error, size_t cap) {
    ++catalogue_queries;
    memset(result, 0, sizeof *result);
    if (image->exports) {
        const struct pm_pe_export_catalog *catalogue = image->exports;
        for (size_t i = 0; i < catalogue->count; ++i) {
            const fake_export *entry = &catalogue->entries[i];
            if ((by_ordinal && entry->value.ordinal == ordinal) ||
                (!by_ordinal && entry->name && !strcmp(entry->name, name))) {
                *result = entry->value;
                return 1;
            }
        }
    }
    if (error && cap) snprintf(error, cap, "mock export not found");
    return 0;
}

struct fallback_state {
    unsigned calls;
    int mode;
    char module[PM_PE_MODULE_NAME_CAP];
    char name[PM_PE_MODULE_SYMBOL_CAP];
    uint16_t ordinal;
    int by_ordinal;
};
static uint32_t host_data = 123;
static int fallback(void *context, const char *dll, const char *name,
                     uint16_t ordinal, int by_ordinal, uintptr_t *address) {
    struct fallback_state *state = context;
    ++state->calls;
    snprintf(state->module, sizeof state->module, "%s", dll);
    snprintf(state->name, sizeof state->name, "%s", name ? name : "");
    state->ordinal = ordinal;
    state->by_ordinal = by_ordinal;
    *address = state->mode == 1 ? 0 : (uintptr_t)&host_data;
    return state->mode == 0 ? 0 : state->mode == 2 ? 2 : 1;
}

static void expect_failure(pm_pe_modules *registry, const char *dll, const char *name,
                            uint32_t ordinal, int by_ordinal, const char *error) {
    pm_pe_module_result result;
    memset(&result, 0xa5, sizeof result);
    CHECK(!pm_pe_modules_lookup(registry, dll, name, ordinal, by_ordinal, &result));
    pm_pe_module_result zero;
    memset(&zero, 0, sizeof zero);
    CHECK(!memcmp(&result, &zero, sizeof result));
    CHECK(strstr(pm_pe_modules_last_error(registry), error) != NULL);
}

static void test_registration_and_direct(void) {
    pm_pe_modules registry;
    fake_image a, b;
    make_image(&a); make_image(&b);
    direct(&a, "Add", 17, 8, 1, 0);
    direct(&a, NULL, 18, 16, 1, 0);
    direct(&a, "MagicData", 19, 24, 0, 1);
    direct(&a, "ReadOnly", UINT32_MAX, 32, 0, 0);
    direct(&a, "Name.With.Dot", 20, 40, 1, 0);
    CHECK(pm_pe_modules_init(&registry, NULL, NULL));
    CHECK(pm_pe_modules_add(&registry, "Probe_Math.DLL", &a.image));
    CHECK(!pm_pe_modules_add(&registry, "probe_math.dll", &b.image));
    CHECK(registry.count == 1);
    pm_pe_module_result result;
    CHECK(pm_pe_modules_lookup(&registry, "PROBE_MATH.dll", "Add", 0, 0, &result));
    CHECK(result.address == (uintptr_t)(a.bytes + 8));
    CHECK(result.image == &a.image && result.ordinal == 17 && result.rva == 8);
    CHECK(result.permissions_known && result.executable && !result.writable && !result.from_fallback);
    CHECK(result.forwarder_hops == 0);
    CHECK(pm_pe_modules_lookup(&registry, "probe_math.dll", NULL, 18, 1, &result));
    CHECK(result.address == (uintptr_t)(a.bytes + 16) && result.ordinal == 18);
    CHECK(pm_pe_modules_lookup(&registry, "probe_math.dll", "MagicData", 0, 0, &result));
    CHECK(result.permissions_known && !result.executable && result.writable);
    uintptr_t imported = 0;
    pm_import_resolver callback = pm_pe_modules_resolve; /* Type compatibility. */
    CHECK(callback(&registry, "probe_math.dll", "MagicData", 0, 0, &imported));
    CHECK(imported == (uintptr_t)(a.bytes + 24)); /* DATA imports are accepted. */
    CHECK(callback(&registry, "probe_math.dll", NULL, 18, 1, &imported));
    CHECK(imported == (uintptr_t)(a.bytes + 16));
    CHECK(pm_pe_modules_lookup(&registry, "probe_math.dll", NULL, UINT32_MAX, 1, &result));
    CHECK(result.ordinal == UINT32_MAX && !result.executable && !result.writable);
    CHECK(pm_pe_modules_lookup(&registry, "probe_math.dll", "Name.With.Dot", 0, 0, &result));
    expect_failure(&registry, "probe_math.dll", "add", 0, 0, "export-unavailable");
    expect_failure(&registry, "probe_math.dll", NULL, 16, 1, "export-unavailable");
    CHECK(pm_pe_modules_add(&registry, "second.dll", &b.image));
    CHECK(pm_pe_modules_remove(&registry, "PROBE_MATH.DLL"));
    CHECK(registry.count == 1 && !strcmp(registry.slots[0].name, "second.dll"));
    CHECK(a.image.mapping == a.bytes); /* remove never unloads borrowed memory. */
    CHECK(!pm_pe_modules_remove(&registry, "probe_math.dll"));
    CHECK(pm_pe_modules_remove(&registry, "second.dll") && registry.count == 0);
    expect_failure(&registry, "missing.dll", "Add", 0, 0, "module-not-registered");
}

static void test_invalid_queries_and_names(void) {
    pm_pe_modules registry;
    fake_image image; make_image(&image);
    CHECK(pm_pe_modules_init(&registry, NULL, NULL));
    const char *invalid[] = {NULL, "", ".dll", "plain", "a.exe", "a.dll.dll",
        "a.b.dll", "../a.dll", "C:\\a.dll", "/a.dll", "a/d.dll", "a.dll ",
        " a.dll", "a:d.dll", "a\n.dll", "\xc3\xa9.dll"};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; ++i) {
        CHECK(!pm_pe_modules_add(&registry, invalid[i], &image.image));
        CHECK(!pm_pe_modules_remove(&registry, invalid[i]));
        expect_failure(&registry, invalid[i], "X", 0, 0, "invalid-module-name");
    }
    char maximum[PM_PE_MODULE_NAME_CAP];
    memset(maximum, 'a', sizeof maximum);
    memcpy(maximum + sizeof maximum - 5, ".dll", 5);
    CHECK(pm_pe_modules_add(&registry, maximum, &image.image));
    CHECK(pm_pe_modules_remove(&registry, maximum));
    char overlong[PM_PE_MODULE_NAME_CAP + 1];
    memset(overlong, 'a', sizeof overlong);
    memcpy(overlong + sizeof overlong - 5, ".dll", 5);
    CHECK(!pm_pe_modules_add(&registry, overlong, &image.image));
    char symbol[PM_PE_MODULE_SYMBOL_CAP + 1]; memset(symbol, 'x', sizeof symbol);
    symbol[sizeof symbol - 1] = 0;
    expect_failure(&registry, "a.dll", symbol, 0, 0, "invalid-symbol-query");
    expect_failure(&registry, "a.dll", NULL, 0, 0, "invalid-symbol-query");
    expect_failure(&registry, "a.dll", "", 0, 0, "invalid-symbol-query");
    expect_failure(&registry, "a.dll", "with space", 0, 0, "invalid-symbol-query");
    expect_failure(&registry, "a.dll", "X", 1, 0, "invalid-symbol-query");
    expect_failure(&registry, "a.dll", "X", 1, 1, "invalid-symbol-query");
    expect_failure(&registry, "a.dll", NULL, 1, 2, "invalid-symbol-query");
    expect_failure(&registry, "a.dll", NULL, 1, -1, "invalid-symbol-query");
    CHECK(!pm_pe_modules_add(&registry, "a.dll", NULL));
    const pm_pe_image empty = {0};
    CHECK(!pm_pe_modules_add(&registry, "a.dll", &empty));
    CHECK(!pm_pe_modules_lookup(&registry, "a.dll", "X", 0, 0, NULL));
    CHECK(!pm_pe_modules_resolve(&registry, "a.dll", "X", 0, 0, NULL));
    uintptr_t address = 99;
    CHECK(!pm_pe_modules_resolve(NULL, "a.dll", "X", 0, 0, &address) && !address);
    CHECK(!pm_pe_modules_init(NULL, NULL, NULL));
    CHECK(!pm_pe_modules_init(&registry, pm_pe_modules_resolve, NULL));
    CHECK(strstr(pm_pe_modules_last_error(&registry), "invalid-fallback") != NULL);
}

static void test_fallback_and_stale_images(void) {
    pm_pe_modules registry;
    fake_image image; make_image(&image);
    direct(&image, "Value", 1, 8, 0, 1);
    struct fallback_state state = {.mode = 3};
    CHECK(pm_pe_modules_init(&registry, fallback, &state));
    pm_pe_module_result result;
    CHECK(pm_pe_modules_lookup(&registry, "KERNEL32.DLL", "GetCurrentProcessId", 0, 0, &result));
    CHECK(state.calls == 1 && !strcmp(state.module, "kernel32.dll"));
    CHECK(result.from_fallback && !result.permissions_known && !result.executable &&
          !result.writable && !result.image && result.address == (uintptr_t)&host_data);
    CHECK(pm_pe_modules_add(&registry, "kernel32.dll", &image.image));
    expect_failure(&registry, "kernel32.dll", "GetCurrentProcessId", 0, 0, "export-unavailable");
    CHECK(state.calls == 1); /* Present module never escapes to fallback. */
    CHECK(pm_pe_modules_lookup(&registry, "kernel32.dll", "Value", 0, 0, &result));
    CHECK(state.calls == 1 && !result.from_fallback);
    const unsigned queried = catalogue_queries;
    image.image.mapping = NULL;
    expect_failure(&registry, "kernel32.dll", "Value", 0, 0, "stale-module");
    CHECK(catalogue_queries == queried && state.calls == 1);
    image.image.mapping = image.bytes + 1;
    expect_failure(&registry, "kernel32.dll", "Value", 0, 0, "stale-module");
    image.image.mapping = image.bytes;
    --image.image.mapping_size;
    expect_failure(&registry, "kernel32.dll", "Value", 0, 0, "stale-module");
    image.image.mapping_size = sizeof image.bytes;
    image.image.exports = NULL;
    expect_failure(&registry, "kernel32.dll", "Value", 0, 0, "stale-module");
    image.image.exports = &image.catalogue;
    CHECK(pm_pe_modules_remove(&registry, "kernel32.dll"));
    CHECK(pm_pe_modules_lookup(&registry, "kernel32.dll", NULL, UINT16_MAX, 1, &result));
    CHECK(state.calls == 2 && state.by_ordinal == 1 && state.ordinal == UINT16_MAX && !state.name[0]);
    expect_failure(&registry, "kernel32.dll", NULL, (uint32_t)UINT16_MAX + 1, 1, "fallback-ordinal-overflow");
    CHECK(state.calls == 2);
    for (int mode = 0; mode <= 2; ++mode) {
        state.mode = mode;
        expect_failure(&registry, "kernel32.dll", "Value", 0, 0, "fallback-refused");
    }
}

static void test_forwarders(void) {
    pm_pe_modules registry;
    fake_image a, b; make_image(&a); make_image(&b);
    forward(&a, "ByName", 1, "tArGeT.Real");
    forward(&a, "ByOrdinal", 2, "TARGET.DlL.#18");
    forward(&a, "Host", 3, "KERNEL32.GetCurrentProcessId");
    forward(&a, "Again", 4, "source.ByOrdinal");
    forward(&a, "Missing", 5, "target.NoSuchExport");
    forward(&a, "BigOrdinal", 6, "target.#4294967295");
    direct(&b, "Real", 17, 8, 1, 0);
    direct(&b, "Data", 18, 16, 0, 1);
    direct(&b, "Last", UINT32_MAX, 24, 0, 0);
    struct fallback_state state = {.mode = 3};
    CHECK(pm_pe_modules_init(&registry, fallback, &state));
    CHECK(pm_pe_modules_add(&registry, "source.dll", &a.image));
    CHECK(pm_pe_modules_add(&registry, "target.dll", &b.image));
    pm_pe_module_result result;
    CHECK(pm_pe_modules_lookup(&registry, "source.dll", "ByName", 0, 0, &result));
    CHECK(result.image == &b.image && result.ordinal == 17 && result.forwarder_hops == 1 && result.executable);
    CHECK(pm_pe_modules_lookup(&registry, "source.dll", "ByOrdinal", 0, 0, &result));
    CHECK(result.ordinal == 18 && result.permissions_known && !result.executable && result.writable);
    CHECK(pm_pe_modules_lookup(&registry, "source.dll", "Again", 0, 0, &result));
    CHECK(result.ordinal == 18 && result.forwarder_hops == 2 && result.image == &b.image);
    CHECK(pm_pe_modules_lookup(&registry, "source.dll", "BigOrdinal", 0, 0, &result));
    CHECK(result.ordinal == UINT32_MAX);
    expect_failure(&registry, "source.dll", "Missing", 0, 0, "export-unavailable");
    CHECK(state.calls == 0);
    CHECK(pm_pe_modules_lookup(&registry, "source.dll", "Host", 0, 0, &result));
    CHECK(state.calls == 1 && !strcmp(state.name, "GetCurrentProcessId"));
    CHECK(result.forwarder_hops == 1 && result.from_fallback && !result.permissions_known);
    CHECK(pm_pe_modules_remove(&registry, "target.dll"));
    CHECK(pm_pe_modules_remove(&registry, "source.dll"));
}

static void test_bad_forwarders_and_cycles(void) {
    pm_pe_modules registry;
    fake_image image; make_image(&image);
    forward(&image, "Start", 10, "unused.X");
    struct fallback_state state = {.mode = 3};
    CHECK(pm_pe_modules_init(&registry, fallback, &state));
    CHECK(pm_pe_modules_add(&registry, "source.dll", &image.image));
    const char *invalid[] = {NULL, "", "target", ".Name", "target.", "target.dll",
        "target.dll.", "target.exe.Name", "target.Name.More", "target.dll.Name.More",
        "../target.Name", "C:\\target.Name", "target/x.Name", "target.#", "target.#-1",
        "target.#+1", "target.#1x", "target.#4294967296", "target.#99999999999999999999999",
        "target.Bad Name", "target.\xc3\xa9", "target./Name", "target.\\Name", "target.C:Name"};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; ++i) {
        image.catalogue.entries[0].value.forwarder = invalid[i];
        expect_failure(&registry, "source.dll", "Start", 0, 0, "invalid-forwarder");
    }
    CHECK(state.calls == 0);
    image.catalogue.entries[0].value.forwarder = "missing.#65536";
    expect_failure(&registry, "source.dll", "Start", 0, 0, "fallback-ordinal-overflow");
    CHECK(state.calls == 0);
    image.catalogue.entries[0].value.forwarder = "source.Start";
    expect_failure(&registry, "source.dll", "Start", 0, 0, "forwarder-cycle");
    /* Same image under an explicit alias: cycle identity is not module spelling. */
    CHECK(pm_pe_modules_add(&registry, "alias.dll", &image.image));
    image.catalogue.entries[0].value.forwarder = "alias.Start";
    expect_failure(&registry, "source.dll", "Start", 0, 0, "forwarder-cycle");
    CHECK(state.calls == 0);
    CHECK(pm_pe_modules_remove(&registry, "alias.dll"));
    CHECK(pm_pe_modules_remove(&registry, "source.dll"));
}

static void test_depth_and_capacity(void) {
    pm_pe_modules registry;
    fake_image images[PM_PE_MODULE_LOOKUP_LIMIT + 1];
    char dlls[PM_PE_MODULES_CAPACITY + 1][24];
    char targets[PM_PE_MODULE_LOOKUP_LIMIT][32];
    CHECK(pm_pe_modules_init(&registry, NULL, NULL));
    for (unsigned i = 0; i <= PM_PE_MODULE_LOOKUP_LIMIT; ++i) {
        make_image(&images[i]);
        snprintf(dlls[i], sizeof dlls[i], "m%u.dll", i);
        if (i < PM_PE_MODULE_LOOKUP_LIMIT) {
            snprintf(targets[i], sizeof targets[i], "m%u.Hop", i + 1);
            forward(&images[i], "Hop", 1, targets[i]);
        } else direct(&images[i], "Hop", 1, 8, 1, 0);
        CHECK(pm_pe_modules_add(&registry, dlls[i], &images[i].image));
    }
    pm_pe_module_result result;
    CHECK(pm_pe_modules_lookup(&registry, "m1.dll", "Hop", 0, 0, &result));
    CHECK(result.forwarder_hops == PM_PE_MODULE_LOOKUP_LIMIT - 1);
    CHECK(result.image == &images[PM_PE_MODULE_LOOKUP_LIMIT].image);
    expect_failure(&registry, "m0.dll", "Hop", 0, 0, "forwarder-depth");
    for (unsigned i = 0; i <= PM_PE_MODULE_LOOKUP_LIMIT; ++i)
        CHECK(pm_pe_modules_remove(&registry, dlls[i]));
    for (unsigned i = 0; i <= PM_PE_MODULES_CAPACITY; ++i) {
        snprintf(dlls[i], sizeof dlls[i], "m%u.dll", i);
        const int added = pm_pe_modules_add(&registry, dlls[i], &images[0].image);
        CHECK(added == (i < PM_PE_MODULES_CAPACITY));
    }
    CHECK(registry.count == PM_PE_MODULES_CAPACITY);
    CHECK(strstr(pm_pe_modules_last_error(&registry), "registry-full") != NULL);
    for (unsigned i = 0; i < PM_PE_MODULES_CAPACITY; ++i)
        CHECK(pm_pe_modules_remove(&registry, dlls[i]));
    CHECK(registry.count == 0);
}

static void test_inconsistent_catalogue(void) {
    pm_pe_modules registry;
    fake_image image; make_image(&image);
    direct(&image, "Value", 1, 8, 0, 1);
    CHECK(pm_pe_modules_init(&registry, NULL, NULL));
    CHECK(pm_pe_modules_add(&registry, "source.dll", &image.image));
    pm_pe_export *value = &image.catalogue.entries[0].value;
    const pm_pe_export original = *value;
    value->address = NULL;
    expect_failure(&registry, "source.dll", "Value", 0, 0, "invalid-direct-export");
    *value = original; value->address = image.bytes + 9;
    expect_failure(&registry, "source.dll", "Value", 0, 0, "invalid-direct-export");
    *value = original; value->rva = sizeof image.bytes;
    expect_failure(&registry, "source.dll", "Value", 0, 0, "invalid-direct-export");
    *value = original; value->executable = 1;
    expect_failure(&registry, "source.dll", "Value", 0, 0, "invalid-direct-export");
    *value = original; value->executable = 2;
    expect_failure(&registry, "source.dll", "Value", 0, 0, "invalid-direct-export");
    *value = original; value->kind = (pm_pe_export_kind)99;
    expect_failure(&registry, "source.dll", "Value", 0, 0, "invalid-export-kind");
    CHECK(pm_pe_modules_remove(&registry, "source.dll"));
}

int main(void) {
    test_registration_and_direct();
    test_invalid_queries_and_names();
    test_fallback_and_stale_images();
    test_forwarders();
    test_bad_forwarders_and_cycles();
    test_depth_and_capacity();
    test_inconsistent_catalogue();
    printf("PE module registry CPU mock tests: %u checks, %u failures; no PE/guest code/GPU executed\n",
           checks, failures);
    return failures ? 1 : 0;
}
