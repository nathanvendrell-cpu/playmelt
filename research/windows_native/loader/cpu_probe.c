/* Executes ONLY the embedded, source-generated test PE. No file-loading CLI. */
#include "pe_loader.h"
#include "winapi_subset.h"
#include "probe_fixture.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#if !defined(__x86_64__)
#error "This probe must exercise the actual Microsoft x64 calling convention."
#endif

static uint64_t read64(const void *p) { uint64_t v; memcpy(&v, p, sizeof v); return v; }
static uint32_t read32(const void *p) { uint32_t v; memcpy(&v, p, sizeof v); return v; }
static uint64_t utc_filetime(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_REALTIME, &t)) return 0;
    return ((uint64_t)t.tv_sec + UINT64_C(11644473600)) * UINT64_C(10000000) + (uint64_t)t.tv_nsec / 100;
}

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--synthetic-cpu-self-test")) {
        fputs("Only --synthetic-cpu-self-test is accepted; no external executable can be supplied.\n", stderr);
        return 2;
    }
    pm_pe_image image = {0};
    char error[256] = {0};
    if (!pm_pe_load(probe_fixture, sizeof probe_fixture, pm_winapi_resolve, NULL, &image, error, sizeof error)) {
        fprintf(stderr, "Synthetic PE rejected: %s\n", error);
        if (!pm_pe_unload(&image)) fputs("Synthetic image cleanup failed; the test process will exit.\n", stderr);
        return 1;
    }
    typedef uint32_t (__attribute__((ms_abi)) *entry_function)(void);
    entry_function entry = (entry_function)((uint8_t *)image.mapping + image.entrypoint_rva);
    uint64_t before = utc_filetime();
    uint32_t status = entry();
    uint64_t after = utc_filetime();
    const uint8_t *results = (const uint8_t *)image.mapping + 0xC000;
    uint64_t qpf = read64(results + 0x28), qpc0 = read64(results + 0x30), qpc1 = read64(results + 0x38);
    uint64_t ticks = read64(results + 0x40), filetime = read64(results + 0x50);
    uint64_t qpc2 = read64(results + 0x58);
    int relocated = (uintptr_t)image.mapping != UINT64_C(0x140000000) && read64(results) == (uintptr_t)(results + 8);
    int passed = relocated && status == 0 && read32(results + 0x20) == (uint32_t)getpid() &&
        read32(results + 0x48) == 0xBEEF && qpf == UINT64_C(1000000000) && qpc1 >= qpc0 &&
        qpc2 >= qpc1 && ticks >= qpc1 / UINT64_C(1000000) && ticks <= qpc2 / UINT64_C(1000000) &&
        before && after >= before && filetime >= before && filetime <= after;
    int translated = -1; size_t n = sizeof translated;
    if (sysctlbyname("sysctl.proc_translated", &translated, &n, NULL, 0)) translated = -1;
    int unmapped = pm_pe_unload(&image);
    passed = passed && unmapped;
    printf("{\"schemaVersion\":1,\"syntheticPEExecuted\":true,\"passed\":%s,"
           "\"architecture\":\"x86_64\",\"rosettaTranslated\":%s,\"rosettaStateKnown\":%s,"
           "\"windowsABIImportsChecked\":7,\"gameExecuted\":false,\"wineUsed\":false,"
           "\"relocatedFromPreferredBase\":%s,"
           "\"gpuWorkSubmitted\":false,\"fullWindowsCompatibility\":false,\"imageUnmapped\":%s}\n",
           passed ? "true" : "false", translated == 1 ? "true" : "false", translated >= 0 ? "true" : "false",
           relocated ? "true" : "false",
           unmapped && image.mapping == NULL ? "true" : "false");
    return passed ? 0 : 1;
}
