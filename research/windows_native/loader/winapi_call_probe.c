/* Only our compiled-in generated PE bytes. No path/argument loader exists. */
#include "winapi_modules.h"
#include "winapi_call_fixture.h"
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static uint32_t read32(const void *at) { uint32_t n; memcpy(&n,at,sizeof n); return n; }
static uint64_t read64(const void *at) { uint64_t n; memcpy(&n,at,sizeof n); return n; }

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1],"--synthetic-module-api-test")) return 2;
    pm_pe_image module={0}, client={0};
    pm_pe_modules registry;
    pm_winapi_modules *ctx=NULL;
    pm_pe_modules_init(&registry,NULL,NULL);
    char error[256]={0};
    int ok=0, executed=0, registered=0, bound=0;
    if (!pm_pe_load(module_fixture,sizeof module_fixture,NULL,NULL,
                     &module,error,sizeof error) || module.entrypoint_rva) goto cleanup;
    if (!pm_pe_modules_add(&registry,"probe_math.dll",&module)) goto cleanup;
    registered=1;
    if (!pm_pe_load(winapi_call_fixture,sizeof winapi_call_fixture,
                     pm_winapi_modules_resolve,NULL,&client,error,sizeof error)) goto cleanup;
    ctx=pm_winapi_modules_create(&registry,&client,"module_api.exe",error,sizeof error);
    if (!ctx || !pm_winapi_modules_add_host(ctx,"kernel32.dll",pm_winapi_modules_resolve,NULL) ||
        !pm_winapi_modules_bind(ctx)) goto cleanup;
    bound=1;
    typedef uint32_t (PM_WINAPI *entry_function)(void);
    entry_function entry=(entry_function)((unsigned char *)client.mapping+client.entrypoint_rva);
    uint32_t status=entry();
    executed=1;
    const unsigned char *data=(const unsigned char *)client.mapping+0xC000;
    ok=status==0 && read64(data+0x20)==(uintptr_t)client.mapping &&
        read64(data+0x28)==(uintptr_t)module.mapping && read64(data+0x30)==(uintptr_t)module.mapping &&
        read32(data+0x38)==42 && read32(data+0x3C)==42 && read32(data+0x40)==(uint32_t)getpid() &&
        read64(data+0x48)==UINT64_C(0x1122334455667788) && read32(data+0x58)==0xBEEF &&
        read32(data+0x50)==PM_ERROR_PROC_NOT_FOUND && read32(data+0x54)==PM_ERROR_INVALID_HANDLE &&
        read64(data+0x60)==(uintptr_t)client.mapping && !read64(data+0x68) && !read64(data+0x70);
cleanup:;
    int unbound=!bound || pm_winapi_modules_unbind();
    int destroyed=pm_winapi_modules_destroy(&ctx);
    /* Never invalidate borrowed images if a context could not be released.
     * Report cleanup failure instead of manufacturing an all-unmapped result. */
    int client_unmapped=destroyed && pm_pe_unload(&client);
    int removed=!registered || (client_unmapped && pm_pe_modules_remove(&registry,"probe_math.dll"));
    int module_unmapped=destroyed && removed && pm_pe_unload(&module);
    int cleaned=unbound && destroyed && removed && client_unmapped && module_unmapped &&
        !client.mapping && !module.mapping;
    ok=ok && cleaned;
    int translated=-1; size_t length=sizeof translated;
    if (sysctlbyname("sysctl.proc_translated",&translated,&length,NULL,0)) translated=-1;
    if (!ok) fprintf(stderr,"Synthetic module API failure: %s\n",error);
    printf("{\"schemaVersion\":1,\"passed\":%s,\"syntheticPEExecuted\":%s,"
        "\"getModuleHandleAAndW\":%s,\"getProcAddressNamedOrdinalDataForwarder\":%s,"
        "\"win32ErrorsVerified\":%s,\"cleanupVerified\":%s,\"rosettaTranslated\":%s,"
        "\"rosettaStateKnown\":%s,\"gameExecuted\":false,\"wineUsed\":false,"
        "\"gpuWorkSubmitted\":false,\"dllEntryPointExecuted\":false,\"supportDetermined\":false}\n",
        ok?"true":"false",executed?"true":"false",ok?"true":"false",ok?"true":"false",
        ok?"true":"false",cleaned?"true":"false",translated==1?"true":"false",translated>=0?"true":"false");
    return ok?0:1;
}
