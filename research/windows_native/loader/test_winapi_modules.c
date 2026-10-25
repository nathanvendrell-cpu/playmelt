#include "winapi_modules.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static atomic_uint checks;
#define CHECK(x) do { atomic_fetch_add(&checks, 1); if (!(x)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); abort(); \
} } while (0)

static unsigned char main_bytes[4096], dll_bytes[4096], second_bytes[4096];
static pm_pe_image main_image = {.mapping=main_bytes, .mapping_size=sizeof main_bytes};
static pm_pe_image dll_image = {.mapping=dll_bytes, .mapping_size=sizeof dll_bytes};
static pm_pe_image second_image = {.mapping=second_bytes, .mapping_size=sizeof second_bytes};
static atomic_uint fallback_calls;
static int corrupt_export;

/* Mock only export lookup; real closed-registry forwarding and Windows ABI
 * wrappers are linked. These bytes are data, never mapped executable/called. */
int pm_pe_find_export(const pm_pe_image *image, const char *name, uint32_t ordinal,
    int by_ordinal, pm_pe_export *out, char *error, size_t cap) {
    memset(out, 0, sizeof *out);
    if (error && cap) error[0] = 0;
    uint32_t id = ordinal;
    if (!by_ordinal) {
        if (!strcmp(name, "Answer")) id=17;
        else if (!strcmp(name, "Data")) id=18;
        else if (!strcmp(name, "Forward")) id=19;
        else if (!strcmp(name, "OrdinalForward")) id=20;
        else if (!strcmp(name, "Host")) id=21;
        else if (!strcmp(name, "Cycle")) id=22;
        else if (!strcmp(name, "UnknownHost")) id=23;
        else if (!strcmp(name, "HugeOrdinal")) id=24;
        else if (!strcmp(name, "EmptyForward")) id=25;
        else return 0;
    }
    out->ordinal=id;
    out->rva=64;
    if (id == 17 || id == 18) {
        out->kind=PM_PE_EXPORT_DIRECT;
        out->address=(const unsigned char *)image->mapping + (id == 17 ? 64 : 128);
        out->rva=id == 17 ? 64 : 128;
        out->executable=id == 17;
        out->writable=id == 18;
        if (corrupt_export) out->writable=out->executable=1;
        return 1;
    }
    out->kind=PM_PE_EXPORT_FORWARDER;
    switch (id) {
        case 19: out->forwarder="second.dll.Answer"; break;
        case 20: out->forwarder="second.#18"; break;
        case 21: out->forwarder="kernel32.GetCurrentProcessId"; break;
        case 22: out->forwarder="probe.Cycle"; break;
        case 23: out->forwarder="unregistered.Function"; break;
        case 24: out->forwarder="kernel32.#4294967296"; break;
        case 25: out->forwarder="second."; break;
        default: return 0;
    }
    return 1;
}

static int forbidden_fallback(void *ctx, const char *dll, const char *name,
    uint16_t ordinal, int by_ordinal, uintptr_t *address) {
    (void)ctx; (void)dll; (void)name; (void)ordinal; (void)by_ordinal;
    atomic_fetch_add(&fallback_calls, 1);
    *address=42; return 1;
}

static int host_resolve(void *ctx, const char *dll, const char *name,
    uint16_t ordinal, int by_ordinal, uintptr_t *address) {
    CHECK(ctx == &fallback_calls);
    pm_win_SetLastError(999);
    return pm_winapi_modules_resolve(NULL, dll, name, ordinal, by_ordinal, address);
}

static pm_winapi_modules *make_context(void) {
    pm_pe_modules registry;
    CHECK(pm_pe_modules_init(&registry, forbidden_fallback, NULL));
    CHECK(pm_pe_modules_add(&registry, "probe.dll", &dll_image));
    CHECK(pm_pe_modules_add(&registry, "second.dll", &second_image));
    char error[128];
    pm_winapi_modules *ctx=pm_winapi_modules_create(&registry, &main_image,
                                                   "fixture.exe", error, sizeof error);
    CHECK(ctx && !error[0]);
    /* Context is independent of later source-registry bookkeeping. */
    CHECK(pm_pe_modules_remove(&registry, "probe.dll"));
    CHECK(pm_winapi_modules_add_host(ctx, "KERNEL32.dll", host_resolve, &fallback_calls));
    CHECK(pm_winapi_modules_add_host(ctx, "kernelbase.dll", pm_winapi_modules_resolve, NULL));
    return ctx;
}

static void expect_error(uint32_t expected) { CHECK(pm_win_GetLastError() == expected); }

static void test_contract(void) {
    CHECK(!pm_win_GetModuleHandleA(NULL)); expect_error(PM_ERROR_MOD_NOT_FOUND);
    CHECK(!pm_win_GetProcAddress((void *)(uintptr_t)1, "Answer")); expect_error(PM_ERROR_MOD_NOT_FOUND);
    CHECK(!pm_winapi_modules_unbind());
    CHECK(!pm_winapi_modules_bind(NULL));
    CHECK(!pm_winapi_modules_destroy(NULL));
    pm_winapi_modules *empty=NULL;
    CHECK(pm_winapi_modules_destroy(&empty));
    pm_winapi_modules *ctx=make_context();
    CHECK(!pm_winapi_modules_add_host(ctx, "probe.dll", pm_winapi_modules_resolve, NULL));
    CHECK(!pm_winapi_modules_add_host(ctx, "kernel32.dll", pm_winapi_modules_resolve, NULL));
    CHECK(!pm_winapi_modules_add_host(ctx, "invalid", pm_winapi_modules_resolve, NULL));
    CHECK(!pm_winapi_modules_add_host(ctx, "unused.dll", pm_pe_modules_resolve, NULL));
    CHECK(!pm_winapi_modules_add_host(ctx, "unused.dll", NULL, NULL));
    CHECK(pm_winapi_modules_bind(ctx));
    CHECK(!pm_winapi_modules_bind(ctx));
    CHECK(!pm_winapi_modules_destroy(&ctx) && ctx);
    CHECK(!pm_winapi_modules_add_host(ctx, "unused.dll", pm_winapi_modules_resolve, NULL));
    pm_win_SetLastError(456);
    CHECK(pm_win_GetModuleHandleA(NULL)==main_bytes); expect_error(456);
    CHECK(pm_win_GetModuleHandleW(NULL)==main_bytes); expect_error(456);
    CHECK(pm_win_GetModuleHandleA("FiXtUrE.ExE")==main_bytes); expect_error(456);
    CHECK(pm_win_GetModuleHandleA("PROBE.DLL")==dll_bytes); expect_error(456);
    CHECK(pm_win_GetModuleHandleA("probe")==dll_bytes); expect_error(456);
    const uint16_t wide[]={'P','r','O','b','E',0};
    CHECK(pm_win_GetModuleHandleW(wide)==dll_bytes); expect_error(456);
    const char *absent[]={"", "probe.", ".dll", "fixture", "probe.exe", "absent.dll",
        "C:\\probe.dll", "./probe.dll", "dir/probe.dll", "a.b.dll", "pro be.dll", "pröbe.dll"};
    for (size_t i=0; i<sizeof absent/sizeof *absent; ++i) {
        CHECK(!pm_win_GetModuleHandleA(absent[i])); expect_error(PM_ERROR_MOD_NOT_FOUND);
    }
    char long_name[PM_PE_MODULE_NAME_CAP]; memset(long_name,'a',sizeof long_name);
    CHECK(!pm_win_GetModuleHandleA(long_name)); expect_error(PM_ERROR_MOD_NOT_FOUND);
    uint16_t wide_long[PM_PE_MODULE_NAME_CAP];
    for (size_t i=0;i<PM_PE_MODULE_NAME_CAP;++i) wide_long[i]='a';
    CHECK(!pm_win_GetModuleHandleW(wide_long)); expect_error(PM_ERROR_MOD_NOT_FOUND);
    const uint16_t unicode[]={0xd800,0};
    CHECK(!pm_win_GetModuleHandleW(unicode)); expect_error(PM_ERROR_MOD_NOT_FOUND);
    void *host=pm_win_GetModuleHandleA("KERNEL32");
    CHECK(host && host!=main_bytes && host!=dll_bytes);
    CHECK(pm_win_GetModuleHandleA("kernel32.dll")==host);
    pm_win_SetLastError(789);
    CHECK(pm_win_GetProcAddress(dll_bytes,"Answer")== (uintptr_t)dll_bytes+64); expect_error(789);
    CHECK(pm_win_GetProcAddress(dll_bytes,(const char *)(uintptr_t)17)==(uintptr_t)dll_bytes+64);
    CHECK(pm_win_GetProcAddress(dll_bytes,"Data")== (uintptr_t)dll_bytes+128);
    CHECK(pm_win_GetProcAddress(dll_bytes,"Forward")== (uintptr_t)second_bytes+64);
    CHECK(pm_win_GetProcAddress(dll_bytes,"OrdinalForward")== (uintptr_t)second_bytes+128);
    CHECK(pm_win_GetProcAddress(host,"GetCurrentProcessId")== (uintptr_t)&pm_win_GetCurrentProcessId); expect_error(789);
    CHECK(pm_win_GetProcAddress(dll_bytes,"Host")== (uintptr_t)&pm_win_GetCurrentProcessId); expect_error(789);
    CHECK(pm_win_GetProcAddress(main_bytes,"Answer")== (uintptr_t)main_bytes+64);
    CHECK(pm_win_GetProcAddress(main_bytes,"Data")== (uintptr_t)main_bytes+128);
    CHECK(pm_win_GetProcAddress(main_bytes,"Forward")== (uintptr_t)second_bytes+64);
    CHECK(pm_win_GetProcAddress(main_bytes,"OrdinalForward")== (uintptr_t)second_bytes+128);
    CHECK(pm_win_GetProcAddress(main_bytes,"Host")== (uintptr_t)&pm_win_GetCurrentProcessId); expect_error(789);
    const char *bad_procs[]={"answer", "", "not present", "UnknownHost", "Cycle", "HugeOrdinal", "EmptyForward"};
    for (size_t i=0;i<sizeof bad_procs/sizeof *bad_procs;++i) {
        CHECK(!pm_win_GetProcAddress(dll_bytes,bad_procs[i])); expect_error(PM_ERROR_PROC_NOT_FOUND);
        CHECK(!pm_win_GetProcAddress(main_bytes,bad_procs[i])); expect_error(PM_ERROR_PROC_NOT_FOUND);
    }
    const uintptr_t bad_ordinals[]={0,1,16,26,65535};
    for (size_t i=0;i<sizeof bad_ordinals/sizeof *bad_ordinals;++i) {
        CHECK(!pm_win_GetProcAddress(dll_bytes,(const char *)bad_ordinals[i])); expect_error(PM_ERROR_PROC_NOT_FOUND);
    }
    CHECK(!pm_win_GetProcAddress(host,(const char *)(uintptr_t)17)); expect_error(PM_ERROR_PROC_NOT_FOUND);
    CHECK(!pm_win_GetProcAddress(host,"LoadLibraryA")); expect_error(PM_ERROR_PROC_NOT_FOUND);
    CHECK(!pm_win_GetProcAddress(host,"getcurrentprocessid")); expect_error(PM_ERROR_PROC_NOT_FOUND);
    char long_symbol[PM_PE_MODULE_SYMBOL_CAP]; memset(long_symbol,'x',sizeof long_symbol);
    CHECK(!pm_win_GetProcAddress(dll_bytes,long_symbol)); expect_error(PM_ERROR_PROC_NOT_FOUND);
    const uintptr_t invalid_handles[]={0,1,UINTPTR_MAX,(uintptr_t)dll_bytes+1};
    for (size_t i=0;i<sizeof invalid_handles/sizeof *invalid_handles;++i) {
        CHECK(!pm_win_GetProcAddress((void *)invalid_handles[i],(const char *)(uintptr_t)0x10000));
        expect_error(PM_ERROR_INVALID_HANDLE); /* No dereference of bad name. */
    }
    corrupt_export=1;
    CHECK(!pm_win_GetProcAddress(main_bytes,"Answer")); expect_error(PM_ERROR_PROC_NOT_FOUND);
    CHECK(!pm_win_GetProcAddress(dll_bytes,"Answer")); expect_error(PM_ERROR_PROC_NOT_FOUND);
    corrupt_export=0;
    dll_image.mapping=NULL;
    CHECK(!pm_win_GetModuleHandleA("probe")); expect_error(PM_ERROR_MOD_NOT_FOUND);
    CHECK(!pm_win_GetProcAddress(dll_bytes,"Answer")); expect_error(PM_ERROR_INVALID_HANDLE);
    dll_image.mapping=dll_bytes;
    main_image.mapping_size--;
    CHECK(!pm_win_GetModuleHandleA(NULL)); expect_error(PM_ERROR_MOD_NOT_FOUND);
    CHECK(!pm_win_GetProcAddress(main_bytes,"Answer")); expect_error(PM_ERROR_INVALID_HANDLE);
    main_image.mapping_size++;
    second_image.exports=(struct pm_pe_export_catalog *)(uintptr_t)1;
    CHECK(!pm_win_GetProcAddress(dll_bytes,"Forward")); expect_error(PM_ERROR_PROC_NOT_FOUND);
    second_image.exports=NULL;
    CHECK(atomic_load(&fallback_calls)==0);
    CHECK(pm_winapi_modules_unbind());
    CHECK(!pm_winapi_modules_unbind());
    CHECK(!pm_winapi_modules_add_host(ctx,"unused.dll",pm_winapi_modules_resolve,NULL));
    CHECK(pm_winapi_modules_bind(ctx));
    CHECK(pm_winapi_modules_unbind());
    CHECK(pm_winapi_modules_destroy(&ctx) && !ctx);
    CHECK(!pm_win_GetModuleHandleA("kernel32")); expect_error(PM_ERROR_MOD_NOT_FOUND);
}

static void test_invalid_create(void) {
    pm_pe_modules registry;
    CHECK(pm_pe_modules_init(&registry,NULL,NULL));
    char error[128];
    CHECK(!pm_winapi_modules_create(NULL,&main_image,"fixture.exe",error,sizeof error) && error[0]);
    CHECK(!pm_winapi_modules_create(&registry,NULL,"fixture.exe",NULL,0));
    const char *names[]={NULL,"fixture","fixture.dll","../fixture.exe","fi.xture.exe",""};
    for (size_t i=0;i<sizeof names/sizeof *names;++i)
        CHECK(!pm_winapi_modules_create(&registry,&main_image,names[i],error,sizeof error));
    CHECK(pm_pe_modules_add(&registry,"main.dll",&main_image));
    CHECK(!pm_winapi_modules_create(&registry,&main_image,"fixture.exe",error,sizeof error));
    CHECK(pm_pe_modules_remove(&registry,"main.dll"));
    CHECK(pm_pe_modules_add(&registry,"a.dll",&dll_image));
    CHECK(pm_pe_modules_add(&registry,"b.dll",&dll_image));
    CHECK(!pm_winapi_modules_create(&registry,&main_image,"fixture.exe",error,sizeof error));
    CHECK(pm_pe_modules_remove(&registry,"b.dll"));
    dll_image.mapping_size--;
    CHECK(!pm_winapi_modules_create(&registry,&main_image,"fixture.exe",error,sizeof error));
    dll_image.mapping_size++;
    registry.count=PM_PE_MODULES_CAPACITY+1;
    CHECK(!pm_winapi_modules_create(&registry,&main_image,"fixture.exe",error,sizeof error));
    pm_winapi_modules *ctx=make_context();
    char name[32];
    for (unsigned i=0;i<6;++i) {
        snprintf(name,sizeof name,"host%u.dll",i);
        CHECK(pm_winapi_modules_add_host(ctx,name,pm_winapi_modules_resolve,NULL));
    }
    CHECK(!pm_winapi_modules_add_host(ctx,"extra.dll",pm_winapi_modules_resolve,NULL));
    dll_image.mapping_size--;
    CHECK(!pm_winapi_modules_bind(ctx));
    dll_image.mapping_size++;
    CHECK(pm_winapi_modules_destroy(&ctx));
}

typedef struct worker_args { pm_winapi_modules *ctx; int expect_bind; } worker_args;
static void *worker(void *opaque) {
    worker_args *args=opaque;
    CHECK(pm_win_GetLastError()==0);
    CHECK(!pm_win_GetModuleHandleA(NULL)); expect_error(PM_ERROR_MOD_NOT_FOUND);
    CHECK(pm_winapi_modules_bind(args->ctx)==args->expect_bind);
    if (args->expect_bind) {
        CHECK(pm_win_GetModuleHandleA(NULL)==main_bytes);
        CHECK(pm_win_GetProcAddress(dll_bytes,"Answer")== (uintptr_t)dll_bytes+64);
        CHECK(!pm_winapi_modules_destroy(&args->ctx));
    }
    pm_win_SetLastError(1234);
    return NULL; /* TLS destructor must release the binding without a manual unbind. */
}

static void test_threads(void) {
    pm_winapi_modules *ctx=make_context();
    pm_win_SetLastError(5432);
    CHECK(pm_winapi_modules_bind(ctx));
    worker_args args={ctx,0};
    pthread_t thread;
    CHECK(pthread_create(&thread,NULL,worker,&args)==0);
    CHECK(pthread_join(thread,NULL)==0);
    expect_error(5432);
    CHECK(pm_winapi_modules_unbind());
    args.expect_bind=1;
    CHECK(pthread_create(&thread,NULL,worker,&args)==0);
    CHECK(pthread_join(thread,NULL)==0);
    expect_error(5432);
    CHECK(pm_winapi_modules_bind(ctx)); /* Exiting worker released its binding. */
    CHECK(pm_winapi_modules_unbind());
    CHECK(pm_winapi_modules_destroy(&ctx));
}

static void test_import_resolver(void) {
    uintptr_t address=99;
    struct entry { const char *name; uintptr_t address; } entries[]={
        {"GetModuleHandleA",(uintptr_t)&pm_win_GetModuleHandleA},
        {"GetModuleHandleW",(uintptr_t)&pm_win_GetModuleHandleW},
        {"GetProcAddress",(uintptr_t)&pm_win_GetProcAddress}
    };
    for (size_t i=0;i<sizeof entries/sizeof *entries;++i) {
        CHECK(pm_winapi_modules_resolve(NULL,"KERNEL32.DLL",entries[i].name,0,0,&address));
        CHECK(address==entries[i].address);
        CHECK(pm_winapi_modules_resolve(NULL,"kernelbase.dll",entries[i].name,0,0,&address));
        CHECK(address==entries[i].address);
        CHECK(!pm_winapi_modules_resolve(NULL,"ntdll.dll",entries[i].name,0,0,&address) && !address);
    }
    CHECK(!pm_winapi_modules_resolve(NULL,"kernel32.dll","GetProcAddress",1,1,&address) && !address);
    const char *unsupported[]={"LoadLibraryA","LoadLibraryW","FreeLibrary","DllMain","getprocaddress"};
    for (size_t i=0;i<sizeof unsupported/sizeof *unsupported;++i)
        CHECK(!pm_winapi_modules_resolve(NULL,"kernel32.dll",unsupported[i],0,0,&address) && !address);
}

int main(void) {
    test_contract(); test_invalid_create(); test_threads(); test_import_resolver();
    printf("PASS: %u WinAPI module checks; mock PE exports, real ABI wrappers/registry; no PE entry executed\n",
           atomic_load(&checks));
    return 0;
}
