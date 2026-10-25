/* Executes our embedded fixture only. Owned target pages contain no code. */
#include "pe_loader.h"
#include "winapi_memory.h"
#include "memory_fixture.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>

static void *target;
static uint32_t *old_protection;
static size_t page;
static unsigned checkpoints, checkpoint_failures;
static int permissions(void *pointer) {
    mach_vm_address_t at=(uintptr_t)pointer; mach_vm_size_t length=0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t status=mach_vm_region(mach_task_self(),&at,&length,VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info,&count,&object);
    if (object!=MACH_PORT_NULL) mach_port_deallocate(mach_task_self(),object);
    return status==KERN_SUCCESS && at<=(uintptr_t)pointer && (uintptr_t)pointer-at<length ? info.protection : -1;
}
static int32_t PM_WINAPI checkpoint(void) {
    unsigned phase=checkpoints++;
    int expected=phase==0 ? VM_PROT_READ|VM_PROT_EXECUTE : VM_PROT_READ|VM_PROT_WRITE;
    uint32_t old=phase==0 ? PM_PAGE_READWRITE : PM_PAGE_EXECUTE_READ;
    if (phase>=3 || permissions(target)!=expected ||
        permissions((unsigned char *)target+page)!=expected || *old_protection!=old) {
        ++checkpoint_failures; return 0;
    }
    return 1;
}
static int resolver(void *context,const char *dll,const char *name,
    uint16_t ordinal,int by_ordinal,uintptr_t *address) {
    (void)context;
    if (!address) return 0;
    *address=0;
    if (!by_ordinal && !ordinal && dll && name && !strcmp(dll,"playmelt_fixture.dll") &&
        !strcmp(name,"MemoryCheckpoint")) { *address=(uintptr_t)&checkpoint; return 1; }
    return pm_winapi_memory_resolve(NULL,dll,name,ordinal,by_ordinal,address);
}
static uint32_t read32(const void *p) { uint32_t n; memcpy(&n,p,sizeof n); return n; }
static uint64_t read64(const void *p) { uint64_t n; memcpy(&n,p,sizeof n); return n; }
static void write64(void *p,uint64_t value) { memcpy(p,&value,sizeof value); }

int main(int argc,char **argv) {
    if (argc!=2 || strcmp(argv[1],"--synthetic-virtualprotect-test")) return 2;
    char error[256]={0}; pm_pe_image image={0};
    pm_winapi_memory *ctx=pm_winapi_memory_create(error,sizeof error);
    int passed=0, bound=0, executed=0, iat_verified=0;
    if (!ctx) goto cleanup;
    page=pm_winapi_memory_page_size(ctx);
    size_t rounded; void *output=NULL;
    if (!pm_winapi_memory_allocate(ctx,2*page,&target,&rounded) || rounded!=2*page ||
        !pm_winapi_memory_allocate(ctx,4,&output,&rounded)) goto cleanup;
    old_protection=output;
    if (!pm_pe_load(memory_fixture,sizeof memory_fixture,resolver,NULL,&image,error,sizeof error)) goto cleanup;
    unsigned char *data=(unsigned char *)image.mapping+0xC000;
    write64(data+0x20,(uintptr_t)target); write64(data+0x28,page); write64(data+0x30,(uintptr_t)output);
    iat_verified=read64((unsigned char *)image.mapping+0x8180)==(uintptr_t)&pm_win_VirtualProtect;
    if (!iat_verified || !pm_winapi_memory_bind(ctx)) goto cleanup;
    bound=1;
    typedef uint32_t (PM_WINAPI *entry_function)(void);
    entry_function entry=(entry_function)((unsigned char *)image.mapping+image.entrypoint_rva);
    uint32_t status=entry(); executed=1;
    passed=!status && checkpoints==3 && !checkpoint_failures && read32(data+0x48)==0xCAFE &&
        read32(data+0x50)==PM_ERROR_INVALID_PARAMETER && *old_protection==PM_PAGE_EXECUTE_READ;
cleanup:;
    int unbound=!bound || pm_winapi_memory_unbind();
    int destroyed=unbound && pm_winapi_memory_destroy(&ctx);
    int unloaded=pm_pe_unload(&image);
    int cleaned=unbound && destroyed && unloaded && !ctx && !image.mapping;
    passed=passed && cleaned;
    int translated=-1; size_t length=sizeof translated;
    if (sysctlbyname("sysctl.proc_translated",&translated,&length,NULL,0)) translated=-1;
    if (!passed) fprintf(stderr,"VirtualProtect synthetic probe failed: %s\n",error);
    printf("{\"schemaVersion\":1,\"passed\":%s,\"syntheticPEExecuted\":%s,"
        "\"directVirtualProtectIATVerified\":%s,\"osProtectionCheckpoints\":%u,"
        "\"checkpointFailures\":%u,\"cleanupVerified\":%s,\"rosettaTranslated\":%s,"
        "\"rosettaStateKnown\":%s,\"ownedRegionCodeExecuted\":false,\"gameExecuted\":false,"
        "\"wineUsed\":false,\"gpuWorkSubmitted\":false,\"supportDetermined\":false}\n",
        passed?"true":"false",executed?"true":"false",iat_verified?"true":"false",checkpoints,
        checkpoint_failures,cleaned?"true":"false",translated==1?"true":"false",translated>=0?"true":"false");
    return passed?0:1;
}
