/* CPU-only mapping tests: compile this translation unit ALONE. It includes the
 * production implementation with OS-call wrappers to verify cleanup/fault paths.
 * No PE entry point, imported function or other machine code is called.
 * Example (after a compilation slot is authorized):
 * clang -std=c11 -Wall -Wextra -Werror test_pe_loader.c -o <temporary-output>
 */
#include "pe_loader.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_vm.h>
#endif

static unsigned map_calls, unmap_calls, protect_calls, live_mappings, wx_requests;
static int fail_mapping, fail_allocation, fail_protection_at, fail_unmapping;
static long page_override;
static void *last_mapping;

static void *tracked_mmap(void *address, size_t size, int prot, int flags, int fd, off_t offset) {
    ++map_calls;
    if ((prot & PROT_WRITE) && (prot & PROT_EXEC)) ++wx_requests;
    if (fail_mapping) { errno = ENOMEM; return MAP_FAILED; }
    void *result = mmap(address, size, prot, flags, fd, offset);
    if (result != MAP_FAILED) { ++live_mappings; last_mapping = result; }
    return result;
}
static int tracked_munmap(void *address, size_t size) {
    ++unmap_calls;
    if (fail_unmapping) { errno = EINVAL; return -1; }
    int result = munmap(address, size);
    if (result == 0) --live_mappings;
    return result;
}
static int tracked_mprotect(void *address, size_t size, int prot) {
    ++protect_calls;
    if ((prot & PROT_WRITE) && (prot & PROT_EXEC)) ++wx_requests;
    if (fail_protection_at && protect_calls >= (unsigned)fail_protection_at) { errno = EPERM; return -1; }
    return mprotect(address, size, prot);
}
static void *tracked_calloc(size_t count, size_t size) {
    return fail_allocation ? NULL : calloc(count, size);
}
static long tracked_sysconf(int name) {
    return name == _SC_PAGESIZE && page_override ? page_override : sysconf(name);
}

#define mmap tracked_mmap
#define munmap tracked_munmap
#define mprotect tracked_mprotect
#define calloc tracked_calloc
#define sysconf tracked_sysconf
#include "pe_loader.c"
#undef mmap
#undef munmap
#undef mprotect
#undef calloc
#undef sysconf

static unsigned checks;
#define CHECK(expression) do { ++checks; if (!(expression)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expression); exit(1); } } while (0)

#define FILE_SIZE 0x1000u
#define OPT 0x98u
#define DIR (OPT + 112u)
#define SECTIONS (OPT + 240u)
#define IMAGE_BASE UINT64_C(0x140000000)

typedef struct { uint8_t bytes[FILE_SIZE]; } fixture;
static void w16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void w32(uint8_t *p, uint32_t v) { for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(v >> (8 * i)); }
static void w64(uint8_t *p, uint64_t v) { for (unsigned i = 0; i < 8; ++i) p[i] = (uint8_t)(v >> (8 * i)); }
static void directory(fixture *f, unsigned index, uint32_t rva, uint32_t size) {
    w32(f->bytes + DIR + index * 8, rva); w32(f->bytes + DIR + index * 8 + 4, size);
}
static void section(fixture *f, unsigned index, const char *name, uint32_t rva,
                    uint32_t vsize, uint32_t raw, uint32_t rawsize, uint32_t flags) {
    uint8_t *p = f->bytes + SECTIONS + index * 40;
    memcpy(p, name, strlen(name));
    w32(p + 8, vsize); w32(p + 12, rva); w32(p + 16, rawsize); w32(p + 20, raw); w32(p + 36, flags);
}
static fixture make_fixture(void) {
    fixture f = {0};
    memcpy(f.bytes, "MZ", 2); w32(f.bytes + 0x3c, 0x80); memcpy(f.bytes + 0x80, "PE\0\0", 4);
    w16(f.bytes + 0x84, 0x8664); w16(f.bytes + 0x86, 4); w16(f.bytes + 0x94, 240); w16(f.bytes + 0x96, 0x22);
    w16(f.bytes + OPT, 0x20b); w32(f.bytes + OPT + 16, 0x4000); w64(f.bytes + OPT + 24, IMAGE_BASE);
    w32(f.bytes + OPT + 32, 0x4000); w32(f.bytes + OPT + 36, 0x200);
    w32(f.bytes + OPT + 56, 0x14000); w32(f.bytes + OPT + 60, 0x400);
    w16(f.bytes + OPT + 68, 3); w16(f.bytes + OPT + 70, 0x140); w32(f.bytes + OPT + 108, 16);
    section(&f, 0, ".text", 0x4000, 0x200, 0x400, 0x200, 0x60000020);
    section(&f, 1, ".rdata", 0x8000, 0x600, 0x600, 0x600, 0x40000040);
    section(&f, 2, ".data", 0xc000, 0x400, 0xc00, 0x200, 0xc0000040);
    section(&f, 3, ".reloc", 0x10000, 0x200, 0xe00, 0x200, 0x40000040);
    memcpy(f.bytes + 0x400, "INERT TEST BYTES; NEVER CALLED", 29);
    directory(&f, 1, 0x8000, 40); directory(&f, 5, 0x10000, 12); directory(&f, 12, 0x8300, 16);
    w32(f.bytes + 0x600, 0x8200); w32(f.bytes + 0x60c, 0x8100); w32(f.bytes + 0x610, 0x8300);
    memcpy(f.bytes + 0x700, "KERNEL32.dll", 13);
    w64(f.bytes + 0x800, 0x8500); w16(f.bytes + 0xb00, 0);
    memcpy(f.bytes + 0xb02, "FixtureFunction", 16);
    w64(f.bytes + 0xc00, IMAGE_BASE + 0x4020);
    w32(f.bytes + 0xe00, 0xc000); w32(f.bytes + 0xe04, 12); w16(f.bytes + 0xe08, 0xa000);
    return f;
}

typedef struct { unsigned calls; unsigned reject_at; int zero_address; } resolver_state;
static void fixture_target_never_called(void) { abort(); }
static int resolve(void *ctx, const char *dll, const char *name, uint16_t ordinal, int by_ordinal, uintptr_t *address) {
    resolver_state *state = ctx;
    ++state->calls;
    CHECK(!ordinal && !by_ordinal);
    *address = 0;
    if (state->reject_at && state->calls == state->reject_at) return 0;
    if (strcmp(dll, "KERNEL32.dll") || strcmp(name, "FixtureFunction")) return 0;
    if (!state->zero_address) *address = (uintptr_t)&fixture_target_never_called;
    return 1;
}
static void reset_tracking(void) {
    CHECK(live_mappings == 0);
    map_calls = unmap_calls = protect_calls = wx_requests = 0;
    fail_mapping = fail_allocation = fail_protection_at = fail_unmapping = 0;
    page_override = 0; last_mapping = NULL;
}
static void reject_fixture(fixture *f, const char *expected) {
    pm_pe_image image = {0}; char error[192]; resolver_state state = {0};
    reset_tracking();
    CHECK(!pm_pe_load(f->bytes, sizeof(f->bytes), resolve, &state, &image, error, sizeof(error)));
    CHECK(strstr(error, expected) != NULL);
    CHECK(image.mapping == NULL && image.mapping_size == 0 && image.entrypoint_rva == 0);
    CHECK(live_mappings == 0 && wx_requests == 0);
}
#ifdef __APPLE__
static int actual_permissions(void *pointer) {
    mach_vm_address_t address = (mach_vm_address_t)(uintptr_t)pointer;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = mach_vm_region(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
                                         (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) (void)mach_port_deallocate(mach_task_self(), object);
    CHECK(result == KERN_SUCCESS && address <= (uintptr_t)pointer && (uintptr_t)pointer - address < size);
    return info.protection;
}
#endif

static void test_success(void) {
    fixture f = make_fixture(), original = f;
    pm_pe_image image = {0}; char error[192]; resolver_state state = {0};
    reset_tracking();
    CHECK(pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error)));
    CHECK(error[0] == 0 && image.mapping != NULL && image.entrypoint_rva == 0x4000);
    CHECK(image.mapping_size >= 0x14000 && state.calls == 1);
    CHECK(map_calls == 1 && live_mappings == 1 && unmap_calls == 0 && wx_requests == 0);
    uint8_t *mapping = image.mapping;
    CHECK(memcmp(mapping, f.bytes, 0x400) == 0);
    CHECK(memcmp(mapping + 0x4000, f.bytes + 0x400, 0x200) == 0);
    CHECK(u64(mapping + 0xc000) == (uint64_t)(uintptr_t)mapping + 0x4020);
    CHECK(u64(mapping + 0x8300) == (uint64_t)(uintptr_t)&fixture_target_never_called);
    CHECK(u64(mapping + 0x8308) == 0);
    for (unsigned i = 0xc200; i < 0xc400; ++i) CHECK(mapping[i] == 0);
    CHECK(memcmp(&f, &original, sizeof(f)) == 0);
#ifdef __APPLE__
    CHECK(actual_permissions(mapping) == VM_PROT_READ);
    CHECK(actual_permissions(mapping + 0x4000) == (VM_PROT_READ | VM_PROT_EXECUTE));
    CHECK(actual_permissions(mapping + 0x8000) == VM_PROT_READ);
    CHECK(actual_permissions(mapping + 0xc000) == (VM_PROT_READ | VM_PROT_WRITE));
#endif
    void *kept = image.mapping;
    CHECK(!pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error)));
    CHECK(image.mapping == kept && live_mappings == 1);
    CHECK(pm_pe_unload(&image));
    CHECK(live_mappings == 0 && unmap_calls == 1);
    CHECK(image.mapping == NULL && image.mapping_size == 0 && image.entrypoint_rva == 0);
    CHECK(pm_pe_unload(&image)); CHECK(pm_pe_unload(NULL));
    CHECK(unmap_calls == 1);
}

static void test_rejections(void) {
    fixture f = make_fixture(); f.bytes[0] = 0; reject_fixture(&f, "MZ");
    f = make_fixture(); w32(f.bytes + 0x3c, 0xffffffff); reject_fixture(&f, "PE offset");
    f = make_fixture(); w16(f.bytes + 0x84, 0xaa64); reject_fixture(&f, "unsupported-machine");
    f = make_fixture(); w16(f.bytes + OPT, 0x10b); reject_fixture(&f, "PE32+");
    f = make_fixture(); w16(f.bytes + 0x86, 33); reject_fixture(&f, "section-limit");
    f = make_fixture(); w16(f.bytes + 0x96, 0x2022); reject_fixture(&f, "unsupported-dll");
    f = make_fixture(); w16(f.bytes + 0x96, 0x23); reject_fixture(&f, "relocation-stripped");
    f = make_fixture(); w32(f.bytes + OPT + 56, 0x80000000); reject_fixture(&f, "image/header");
    f = make_fixture(); w32(f.bytes + OPT + 60, 0x200); reject_fixture(&f, "section table");
    f = make_fixture(); w32(f.bytes + OPT + 32, 0x3000); reject_fixture(&f, "alignment");
    f = make_fixture(); w16(f.bytes + OPT + 68, 1); reject_fixture(&f, "unsupported-subsystem");
    f = make_fixture(); w16(f.bytes + OPT + 70, 0x4140); reject_fixture(&f, "unsupported-cfg");
    f = make_fixture(); w32(f.bytes + OPT + 108, 17); reject_fixture(&f, "data directories");
    f = make_fixture(); w32(f.bytes + SECTIONS + 36, 0xe0000020); reject_fixture(&f, "unsupported-wx");
    f = make_fixture(); w32(f.bytes + SECTIONS + 40 + 12, 0x4000); reject_fixture(&f, "overlapping virtual");
    f = make_fixture(); w32(f.bytes + SECTIONS + 40 + 20, 0x400); reject_fixture(&f, "overlapping file");
    f = make_fixture(); w32(f.bytes + SECTIONS + 20, 0xffffff00); reject_fixture(&f, "invalid-section");
    f = make_fixture(); w32(f.bytes + OPT + 16, 0x8000); reject_fixture(&f, "invalid-entry");
    f = make_fixture(); w32(f.bytes + OPT + 16, 0); reject_fixture(&f, "invalid-entry");
    const unsigned rejected[] = {0, 2, 3, 4, 6, 7, 8, 9, 10, 11, 13, 14, 15};
    for (unsigned i = 0; i < sizeof(rejected)/sizeof(rejected[0]); ++i) {
        f = make_fixture(); directory(&f, rejected[i], 0x8400, 16); reject_fixture(&f, "unsupported-directory");
        CHECK(map_calls == 0);
    }
    f = make_fixture(); directory(&f, 5, 0, 0); reject_fixture(&f, "missing-relocations");
    CHECK(map_calls == 1 && unmap_calls == 1);
    f = make_fixture(); directory(&f, 5, 0x10000, 0); reject_fixture(&f, "incomplete");
    f = make_fixture(); w32(f.bytes + 0xe04, 0); reject_fixture(&f, "block size");
    f = make_fixture(); w32(f.bytes + 0xe04, 0xfffffff0); reject_fixture(&f, "block size");
    f = make_fixture(); w32(f.bytes + 0xe04, 10); reject_fixture(&f, "block size");
    f = make_fixture(); w16(f.bytes + 0xe08, 0x3000); reject_fixture(&f, "unsupported-relocation");
    f = make_fixture(); w32(f.bytes + 0xe00, 0xfffff000); reject_fixture(&f, "DIR64 target");
    f = make_fixture(); w16(f.bytes + 0xe0a, 0xa004); reject_fixture(&f, "overlapping DIR64");
    f = make_fixture(); w64(f.bytes + OPT + 24, 0); w64(f.bytes + 0xc00, UINT64_MAX); reject_fixture(&f, "DIR64 overflow");
    f = make_fixture(); w64(f.bytes + OPT + 24, UINT64_C(0xffff000000000000)); w64(f.bytes + 0xc00, 0); reject_fixture(&f, "DIR64 underflow");
    f = make_fixture(); directory(&f, 1, 0x8000, 20); reject_fixture(&f, "descriptor terminator");
    f = make_fixture(); w32(f.bytes + 0x604, 1); reject_fixture(&f, "bound/forwarded");
    f = make_fixture(); w64(f.bytes + 0x800, (UINT64_C(1) << 63) | 7); reject_fixture(&f, "ordinal");
    f = make_fixture(); w64(f.bytes + 0x800, UINT64_C(0x100008500)); reject_fixture(&f, "hint/name");
    f = make_fixture(); w32(f.bytes + 0x60c, 0xc300); reject_fixture(&f, "DLL name");
    f = make_fixture(); w32(f.bytes + 0x610, 0x4000); reject_fixture(&f, "IAT is executable");
    f = make_fixture(); w32(f.bytes + SECTIONS + 40 + 36, 0x40); reject_fixture(&f, "unreadable");
    f = make_fixture(); f.bytes[0xb02] = 255; reject_fixture(&f, "symbol");
    f = make_fixture(); memset(f.bytes + 0x700, 'X', 129); reject_fixture(&f, "DLL name");
    f = make_fixture(); memcpy(f.bytes + 0x700, "UNKNOWN.dll", 12); reject_fixture(&f, "unresolved-import");
    CHECK(map_calls == 1 && unmap_calls == 1);
    f = make_fixture();
    directory(&f, 1, 0x8000, 60);
    w32(f.bytes + 0x614, 0x8280); w32(f.bytes + 0x620, 0x8100); w32(f.bytes + 0x624, 0x8300);
    reject_fixture(&f, "duplicate IAT");
}

static void test_failures_and_limits(void) {
    fixture f = make_fixture(); pm_pe_image image = {0}; char error[192]; resolver_state state = {0};
    reset_tracking(); fail_mapping = 1;
    CHECK(!pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error)));
    CHECK(strstr(error, "allocation-failed") && live_mappings == 0 && unmap_calls == 0);
    reset_tracking(); fail_allocation = 1;
    CHECK(!pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error)));
    CHECK(map_calls == 0 && live_mappings == 0);
    reset_tracking(); fail_protection_at = 2;
    CHECK(!pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error)));
    CHECK(strstr(error, "protection-failed") && map_calls == 1 && unmap_calls == 1 && live_mappings == 0 && wx_requests == 0);
    reset_tracking();
    w64(f.bytes + 0x808, 0x8500); directory(&f, 12, 0x8300, 24);
    state = (resolver_state){.reject_at = 2};
    CHECK(!pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error)));
    CHECK(state.calls == 2 && unmap_calls == 1 && live_mappings == 0);
    reset_tracking(); f = make_fixture(); state = (resolver_state){.zero_address = 1};
    CHECK(!pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error)));
    CHECK(strstr(error, "unresolved-import") && live_mappings == 0);
    reset_tracking();
    CHECK(!pm_pe_load(f.bytes, sizeof(f.bytes), NULL, NULL, &image, error, sizeof(error)));
    CHECK(live_mappings == 0);
    for (size_t size = 0; size < FILE_SIZE; size += 127) {
        CHECK(!pm_pe_load(f.bytes, size, resolve, &state, &image, error, sizeof(error)));
        CHECK(image.mapping == NULL && live_mappings == 0);
    }
    CHECK(!pm_pe_load(f.bytes, PM_MAX_FILE + 1u, resolve, &state, &image, error, sizeof(error)));
    CHECK(!pm_pe_load(NULL, FILE_SIZE, resolve, &state, &image, error, sizeof(error)));
    CHECK(!pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, NULL, error, sizeof(error)));
    char tiny[2] = {'X', 'Y'};
    CHECK(!pm_pe_load(NULL, 0, NULL, NULL, &image, tiny, 1));
    CHECK(tiny[0] == 0 && tiny[1] == 'Y');
    CHECK(!pm_pe_load(NULL, 0, NULL, NULL, &image, NULL, 0));
    reset_tracking(); page_override = 123;
    CHECK(!pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error)));
    CHECK(strstr(error, "host page size") && live_mappings == 0);
    reset_tracking(); page_override = 16384;
    f = make_fixture(); memset(f.bytes + DIR, 0, 128); w32(f.bytes + OPT + 32, 0x1000);
    w32(f.bytes + OPT + 56, 0x5000); w32(f.bytes + OPT + 16, 0x1000);
    for (unsigned i = 0; i < 4; ++i) w32(f.bytes + SECTIONS + i * 40 + 12, 0x1000 * (i + 1));
    CHECK(!pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error)));
    CHECK(strstr(error, "share a host page") && map_calls == 0 && live_mappings == 0);
    reset_tracking();
    f = make_fixture(); state = (resolver_state){0};
    CHECK(pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error)));
    void *retained = image.mapping;
    fail_unmapping = 1;
    CHECK(!pm_pe_unload(&image));
    CHECK(image.mapping == retained && image.entrypoint_rva == 0x4000 && live_mappings == 1);
    fail_unmapping = 0;
    CHECK(pm_pe_unload(&image));
    CHECK(image.mapping == NULL && live_mappings == 0);
    reset_tracking(); fail_unmapping = 1; state = (resolver_state){.reject_at = 1};
    CHECK(!pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error)));
    CHECK(strstr(error, "cleanup-failed") && image.mapping != NULL && image.mapping_size != 0);
    CHECK(image.entrypoint_rva == 0 && live_mappings == 1);
    fail_unmapping = 0;
    CHECK(pm_pe_unload(&image));
    CHECK(image.mapping == NULL && live_mappings == 0);
    reset_tracking();
}

static void test_seeded_mutations(void) {
    unsigned seed = 83129;
    for (unsigned iteration = 0; iteration < 128; ++iteration) {
        fixture f = make_fixture(); pm_pe_image image = {0}; char error[192]; resolver_state state = {0};
        for (unsigned i = 0; i < 3; ++i) {
            seed = seed * 1664525u + 1013904223u;
            size_t offset = seed % FILE_SIZE;
            seed = seed * 1664525u + 1013904223u;
            f.bytes[offset] = (uint8_t)(seed >> 24);
        }
        if (pm_pe_load(f.bytes, sizeof(f.bytes), resolve, &state, &image, error, sizeof(error))) CHECK(pm_pe_unload(&image));
        CHECK(image.mapping == NULL && live_mappings == 0 && wx_requests == 0);
    }
}

int main(void) {
    test_success(); test_rejections(); test_failures_and_limits(); test_seeded_mutations();
    CHECK(live_mappings == 0 && wx_requests == 0);
    printf("PE loader: %u checks PASS; 128 synthetic mutations; executionPerformed=false; wineUsed=false; liveMappings=0\n", checks);
    return 0;
}
