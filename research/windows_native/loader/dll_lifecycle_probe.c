/* Calls ONLY the source-generated, embedded DLL fixtures, never a file path. */
#include "pe_loader.h"
#include "dll_lifecycle_fixture.h"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>

#if !defined(__x86_64__)
#error "This explicit synthetic DllMain probe requires Microsoft x64 ABI."
#endif

static pm_pe_image *active_image;
static unsigned callbacks, callback_failures;
static uint64_t read64(const void *p) { uint64_t v; memcpy(&v, p, sizeof v); return v; }
static uint32_t read32(const void *p) { uint32_t v; memcpy(&v, p, sizeof v); return v; }

static int32_t __attribute__((ms_abi)) checkpoint(void *base, uint32_t reason, void *reserved) {
    ++callbacks;
    if (!active_image) { ++callback_failures; return 0; }
    const uint8_t *data = (const uint8_t *)active_image->mapping + 0xC000;
    pm_pe_dll_state phase = pm_pe_synthetic_dll_state(active_image);
    if (base != active_image->mapping || reserved != NULL ||
        read64(data + 0x20) != (uintptr_t)base || read32(data + 0x28) != reason ||
        read64(data + 0x30) != 0 ||
        (reason == 1 ? phase != PM_PE_DLL_ATTACHING : (reason != 0 || phase != PM_PE_DLL_DETACHING)))
        ++callback_failures;
    char error[192];
    if (pm_pe_synthetic_dll_attach(active_image, error, sizeof error) ||
        pm_pe_synthetic_dll_detach(active_image, error, sizeof error) || pm_pe_unload(active_image))
        ++callback_failures;
    return 1;
}

static int resolve(void *context, const char *dll, const char *name,
                    uint16_t ordinal, int by_ordinal, uintptr_t *address) {
    (void)context;
    if (!address) return 0;
    *address = 0;
    if (by_ordinal || ordinal || !dll || !name || strcmp(dll, "playmelt_fixture.dll") ||
        strcmp(name, "ProbeLifecycleCheckpoint")) return 0;
    *address = (uintptr_t)&checkpoint;
    return 1;
}

typedef struct { pm_pe_image *image; int refused; } foreign_attempt;
static void *wrong_thread(void *raw) {
    foreign_attempt *attempt = raw;
    char error[192];
    attempt->refused = pm_pe_synthetic_dll_state(attempt->image) == PM_PE_DLL_UNAVAILABLE &&
        !pm_pe_synthetic_dll_attach(attempt->image, error, sizeof error) &&
        !pm_pe_synthetic_dll_detach(attempt->image, error, sizeof error) &&
        !pm_pe_unload(attempt->image);
    return NULL;
}

static int exercise(const uint8_t *bytes, size_t size, int attach_succeeds) {
    pm_pe_image image = {0}; char error[192] = {0};
    int passed = 0;
    unsigned initial_callbacks = callbacks, initial_failures = callback_failures;
    if (pm_pe_load(bytes, size, resolve, NULL, &image, error, sizeof error) || image.mapping ||
        !strstr(error, "unsupported-dll")) goto cleanup;
    if (!pm_pe_load_synthetic_dll(bytes, size, resolve, NULL, &image, error, sizeof error)) goto cleanup;
    if (pm_pe_synthetic_dll_state(&image) != PM_PE_DLL_READY || callbacks != initial_callbacks) goto cleanup;
    const uint8_t *data = (const uint8_t *)image.mapping + 0xC000;
    if ((uintptr_t)image.mapping == UINT64_C(0x140000000) ||
        read64(data) != (uintptr_t)(data + 8) || read32(data + 0x38) != 0 ||
        read64((const uint8_t *)image.mapping + 0x8180) != (uintptr_t)&checkpoint) goto cleanup;
    pm_pe_image copy = image;
    if (pm_pe_synthetic_dll_attach(&copy, error, sizeof error) || pm_pe_unload(&copy) ||
        pm_pe_synthetic_dll_detach(&image, error, sizeof error)) goto cleanup;
    active_image = &image;
    int attached = pm_pe_synthetic_dll_attach(&image, error, sizeof error);
    if (attached != attach_succeeds) goto cleanup;
    if (attach_succeeds) {
        if (pm_pe_synthetic_dll_state(&image) != PM_PE_DLL_ATTACHED ||
            read32(data + 0x38) != 1 || pm_pe_unload(&image) ||
            pm_pe_synthetic_dll_attach(&image, error, sizeof error)) goto cleanup;
        foreign_attempt attempt = {&image, 0}; pthread_t thread;
        if (pthread_create(&thread, NULL, wrong_thread, &attempt) != 0) goto cleanup;
        if (pthread_join(thread, NULL) != 0 || !attempt.refused) goto cleanup;
        if (!pm_pe_synthetic_dll_detach(&image, error, sizeof error) ||
            pm_pe_synthetic_dll_state(&image) != PM_PE_DLL_DETACHED) goto cleanup;
    } else if (pm_pe_synthetic_dll_state(&image) != PM_PE_DLL_FAILED ||
               !strstr(error, "PROCESS_DETACH cleanup completed")) goto cleanup;
    if (read32(data + 0x38) != 2 || read32(data + 0x40) != 1 || read32(data + 0x44) != 0 ||
        pm_pe_synthetic_dll_detach(&image, error, sizeof error) ||
        pm_pe_synthetic_dll_attach(&image, error, sizeof error) ||
        read32(data + 0x38) != 2 || callbacks != initial_callbacks + 2 || callback_failures != initial_failures)
        goto cleanup;
    passed = 1;
cleanup:
    if (pm_pe_synthetic_dll_state(&image) == PM_PE_DLL_ATTACHED)
        (void)pm_pe_synthetic_dll_detach(&image, error, sizeof error);
    int unmapped = pm_pe_unload(&image);
    active_image = NULL;
    if (!passed || !unmapped || image.mapping || image.synthetic_dll) {
        fprintf(stderr, "Synthetic DLL lifecycle failed (expected attach %d): %s\n", attach_succeeds, error);
        return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--synthetic-dll-lifecycle-self-test")) {
        fputs("Only the embedded synthetic DLL lifecycle self-test is accepted.\n", stderr);
        return 2;
    }
    int passed = exercise(dll_success_fixture, sizeof dll_success_fixture, 1) &&
        exercise(dll_failure_fixture, sizeof dll_failure_fixture, 0);
    int translated = -1; size_t count = sizeof translated;
    if (sysctlbyname("sysctl.proc_translated", &translated, &count, NULL, 0)) translated = -1;
    printf("{\"schemaVersion\":1,\"passed\":%s,\"syntheticDllNotifications\":%u,"
           "\"callbackFailures\":%u,\"strictLoaderStillRefusesInitialization\":%s,"
           "\"attachFalseCleanupVerified\":%s,\"reentranceAndUnloadRefused\":%s,"
           "\"wrongThreadRefused\":%s,\"allImagesUnmapped\":%s,"
           "\"architecture\":\"x86_64\",\"rosettaTranslated\":%s,\"rosettaStateKnown\":%s,"
           "\"gameExecuted\":false,\"wineUsed\":false,\"gpuWorkSubmitted\":false,"
           "\"windowsExceptionsImplemented\":false,\"fullWindowsCompatibility\":false}\n",
           passed ? "true" : "false", callbacks, callback_failures,
           passed ? "true" : "false", passed ? "true" : "false", passed ? "true" : "false",
           passed ? "true" : "false", passed ? "true" : "false",
           translated == 1 ? "true" : "false", translated >= 0 ? "true" : "false");
    return passed ? 0 : 1;
}
