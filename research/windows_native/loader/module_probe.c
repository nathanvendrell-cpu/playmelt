/* Executes only our embedded synthetic PE client and zero-entrypoint DLL. */
#include "pe_loader.h"
#include "pe_modules.h"
#include "winapi_subset.h"
#include "module_fixture.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

#if !defined(__x86_64__)
#error "The synthetic module probe requires the real Microsoft x64 ABI."
#endif

static uint64_t read64(const void *p) { uint64_t v; memcpy(&v, p, sizeof v); return v; }
static uint32_t read32(const void *p) { uint32_t v; memcpy(&v, p, sizeof v); return v; }

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--synthetic-module-self-test")) {
        fputs("Only the embedded synthetic module self-test is accepted.\n", stderr);
        return 2;
    }
    pm_pe_image module = {0}, client = {0};
    pm_pe_modules registry;
    pm_pe_modules_init(&registry, pm_winapi_resolve, NULL);
    char error[256] = {0};
    int passed = 0, executed = 0, registered = 0, missing_rejected = 0;
    int exports_checked = 0, iat_checked = 0, relocated = 0, removed = 1;
    // A missing dependency must fail closed, before any PE instruction runs.
    int premature = pm_pe_load(client_fixture, sizeof client_fixture,
        pm_pe_modules_resolve, &registry, &client, error, sizeof error);
    missing_rejected = !premature && !client.mapping;
    if (!missing_rejected) goto cleanup;
    if (!pm_pe_load(module_fixture, sizeof module_fixture, NULL, NULL,
                    &module, error, sizeof error)) goto cleanup;
    if (module.entrypoint_rva != 0) goto cleanup;
    if (!pm_pe_modules_add(&registry, "probe_math.dll", &module)) goto cleanup;
    registered = 1;
    pm_pe_export named = {0}, ordinal = {0}, data = {0}, hole = {0};
    if (!pm_pe_find_export(&module, "Add", 0, 0, &named, error, sizeof error) ||
        !pm_pe_find_export(&module, NULL, 18, 1, &ordinal, error, sizeof error) ||
        !pm_pe_find_export(&module, "MagicData", 0, 0, &data, error, sizeof error) ||
        pm_pe_find_export(&module, NULL, 22, 1, &hole, error, sizeof error)) goto cleanup;
    if (!named.executable || named.writable || !ordinal.executable || ordinal.writable ||
        data.executable || !data.writable ||
        named.address != (uint8_t *)module.mapping + 0x4000 ||
        ordinal.address != (uint8_t *)module.mapping + 0x4010 ||
        data.address != (uint8_t *)module.mapping + 0xC008) goto cleanup;
    uintptr_t forwarded = 0, host_pid = 0, product = 0;
    if (!pm_pe_modules_resolve(&registry, "PROBE_MATH.DLL", "GetHostPID", 0, 0, &forwarded) ||
        !pm_winapi_resolve(NULL, "kernel32.dll", "GetCurrentProcessId", 0, 0, &host_pid) ||
        forwarded != host_pid ||
        !pm_pe_modules_resolve(&registry, "probe_math.dll", "ProductAgain", 0, 0, &product) ||
        product != (uintptr_t)ordinal.address) goto cleanup;
    exports_checked = 1;
    if (!pm_pe_load(client_fixture, sizeof client_fixture,
                    pm_pe_modules_resolve, &registry, &client, error, sizeof error)) goto cleanup;
    const uint8_t *iat = (const uint8_t *)client.mapping + 0x8180;
    iat_checked = read64(iat) == (uintptr_t)named.address &&
        read64(iat + 8) == (uintptr_t)ordinal.address && read64(iat + 16) == host_pid &&
        read64(iat + 24) == (uintptr_t)ordinal.address && read64(iat + 32) == (uintptr_t)data.address &&
        read64(iat + 40) == 0;
    if (!iat_checked) goto cleanup;
    const uint8_t *dll_data = (const uint8_t *)module.mapping + 0xC000;
    const uint8_t *results = (const uint8_t *)client.mapping + 0xC000;
    relocated = (uintptr_t)module.mapping != UINT64_C(0x140000000) &&
        (uintptr_t)client.mapping != UINT64_C(0x140000000) &&
        read64(dll_data) == (uintptr_t)(dll_data + 8) &&
        read64(results) == (uintptr_t)(results + 8);
    if (!relocated) goto cleanup;
    typedef uint32_t (__attribute__((ms_abi)) *entry_function)(void);
    entry_function entry = (entry_function)((uint8_t *)client.mapping + client.entrypoint_rva);
    uint32_t status = entry();
    executed = 1;
    passed = status == 0 && read32(results + 0x20) == 42 &&
        read32(results + 0x24) == 42 && read32(results + 0x28) == (uint32_t)getpid() &&
        read32(results + 0x2C) == 72 && read64(results + 0x30) == UINT64_C(0x1122334455667788);

cleanup:;
    // Dependents release their IAT pointers before the borrowed module is removed.
    int client_unmapped = pm_pe_unload(&client);
    if (registered) removed = pm_pe_modules_remove(&registry, "probe_math.dll");
    int module_unmapped = pm_pe_unload(&module);
    int all_unmapped = client_unmapped && module_unmapped && !client.mapping && !module.mapping;
    passed = passed && all_unmapped && removed && missing_rejected && exports_checked && iat_checked && relocated;
    int translated = -1; size_t n = sizeof translated;
    if (sysctlbyname("sysctl.proc_translated", &translated, &n, NULL, 0)) translated = -1;
    if (!passed) fprintf(stderr, "Synthetic module probe failed: loader=%s registry=%s\n",
                        error, pm_pe_modules_last_error(&registry));
    printf("{\"schemaVersion\":1,\"passed\":%s,\"syntheticPEExecuted\":%s,"
           "\"crossPECallsVerified\":%s,\"namedExportVerified\":%s,\"ordinalExportVerified\":%s,"
           "\"namedForwarderVerified\":%s,\"ordinalForwarderVerified\":%s,\"dataExportVerified\":%s,"
           "\"missingModuleRejected\":%s,\"bothImagesRelocated\":%s,\"allImagesUnmapped\":%s,"
           "\"exactIATPointersVerified\":%s,"
           "\"architecture\":\"x86_64\",\"rosettaTranslated\":%s,\"rosettaStateKnown\":%s,"
           "\"dllEntryPointExecuted\":false,\"gameExecuted\":false,\"wineUsed\":false,"
           "\"gpuWorkSubmitted\":false,\"fullWindowsCompatibility\":false}\n",
           passed ? "true" : "false", executed ? "true" : "false", passed ? "true" : "false",
           passed ? "true" : "false", passed ? "true" : "false", passed ? "true" : "false",
           passed ? "true" : "false", passed ? "true" : "false", missing_rejected ? "true" : "false",
           relocated ? "true" : "false", all_unmapped ? "true" : "false",
           iat_checked ? "true" : "false",
           translated == 1 ? "true" : "false", translated >= 0 ? "true" : "false");
    return passed ? 0 : 1;
}
