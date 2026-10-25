/* Only our embedded PE can execute. No pathname, DLL initialization or GPU. */
#include "pe_loader.h"
#include "winapi_memory.h"
#include "memory_query_fixture.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>

static unsigned char *target, *output, *data;
static size_t page;
static unsigned checkpoints, checkpoint_failures, mach_checks;
static uint64_t read_le(const void *at,size_t bytes) {
    const unsigned char *p=at; uint64_t value=0;
    for (size_t i=0;i<bytes;++i) value|=(uint64_t)p[i]<<(8*i);
    return value;
}
static void write64(void *p,uint64_t value) { memcpy(p,&value,sizeof value); }
static int permissions(void *pointer) {
    mach_vm_address_t at=(uintptr_t)pointer; mach_vm_size_t size=0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t status=mach_vm_region(mach_task_self(),&at,&size,VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info,&count,&object);
    if (object!=MACH_PORT_NULL && mach_port_deallocate(mach_task_self(),object)!=KERN_SUCCESS) return -1;
    ++mach_checks;
    return status==KERN_SUCCESS && at<=(uintptr_t)pointer && (uintptr_t)pointer-at<size ? info.protection : -1;
}
static int32_t PM_WINAPI checkpoint(void) {
    unsigned phase=checkpoints++;
    if (phase>=5) { ++checkpoint_failures; return 0; }
    unsigned char *record=output+17;
    size_t first=phase==0 ? 1 : phase==4 ? 0 : 2;
    size_t pages=phase==0 ? 2 : 1;
    uint32_t protection=phase==4 ? PM_PAGE_READWRITE : PM_PAGE_READONLY;
    int32_t expected_status=phase==2 ? PM_STATUS_INFO_LENGTH_MISMATCH :
        phase==3 ? PM_STATUS_ACCESS_VIOLATION : PM_STATUS_SUCCESS;
    int ok=read_le(data+0x50,4)==(uint32_t)expected_status &&
        read_le(data+0x54,4)==0xcafe1234 && read_le(record,8)==(uintptr_t)target+first*page &&
        read_le(record+8,8)==(uintptr_t)target && read_le(record+16,4)==PM_PAGE_READWRITE &&
        read_le(record+20,4)==0 && read_le(record+24,8)==pages*page &&
        read_le(record+32,4)==0x1000 && read_le(record+36,4)==protection &&
        read_le(record+40,4)==0x20000 && read_le(record+44,4)==0 &&
        read_le(output+97,8)==48;
    for (size_t i=0;i<128;++i)
        if (!(i>=17 && i<65) && !(i>=97 && i<105) && output[i]!=0xa7) ok=0;
    /* Compare all four known pages with their actual Mach protections. */
    for (size_t i=0;i<4;++i)
        if (permissions(target+i*page)!=(i==1 || i==2 ? VM_PROT_READ : VM_PROT_READ|VM_PROT_WRITE)) ok=0;
    if (!ok) ++checkpoint_failures;
    return ok;
}
static int resolver(void *context,const char *dll,const char *name,
    uint16_t ordinal,int by_ordinal,uintptr_t *address) {
    (void)context;
    if (!address) return 0;
    *address=0;
    if (!by_ordinal && !ordinal && dll && name && !strcmp(dll,"playmelt_fixture.dll") &&
        !strcmp(name,"QueryCheckpoint")) { *address=(uintptr_t)&checkpoint; return 1; }
    return pm_winapi_memory_resolve(NULL,dll,name,ordinal,by_ordinal,address);
}

int main(int argc,char **argv) {
    if (argc!=2 || strcmp(argv[1],"--synthetic-ntquery-test")) return 2;
    char error[256]={0}; pm_pe_image image={0};
    pm_winapi_memory *ctx=pm_winapi_memory_create(error,sizeof error);
    int passed=0, bound=0, executed=0, iat_verified=0, relocation_verified=0;
    if (!ctx) goto cleanup;
    page=pm_winapi_memory_page_size(ctx);
    size_t rounded; void *memory=NULL;
    if (!pm_winapi_memory_allocate(ctx,4*page,&memory,&rounded) || rounded!=4*page) goto cleanup;
    target=memory;
    if (!pm_winapi_memory_allocate(ctx,page,&memory,&rounded) || rounded!=page) goto cleanup;
    output=memory;
    if (!pm_pe_load(memory_query_fixture,sizeof memory_query_fixture,resolver,NULL,&image,error,sizeof error)) goto cleanup;
    data=(unsigned char *)image.mapping+0xc000;
    write64(data+0x20,(uintptr_t)target); write64(data+0x28,page);
    write64(data+0x30,(uintptr_t)output+17); write64(data+0x38,(uintptr_t)output+97);
    unsigned char *iat=(unsigned char *)image.mapping+0x8180;
    iat_verified=read_le(iat,8)==(uintptr_t)&pm_win_NtQueryVirtualMemory && !read_le(iat+8,8) &&
        read_le(iat+0x20,8)==(uintptr_t)&pm_win_GetLastError &&
        read_le(iat+0x28,8)==(uintptr_t)&pm_win_SetLastError && !read_le(iat+0x30,8) &&
        read_le(iat+0x40,8)==(uintptr_t)&checkpoint && !read_le(iat+0x48,8);
    relocation_verified=read_le(data,8)==(uintptr_t)image.mapping+0xc008;
    if (!iat_verified || !relocation_verified || !pm_winapi_memory_bind(ctx)) goto cleanup;
    bound=1;
    if (!pm_win_VirtualProtect(target+page,2*page,PM_PAGE_READONLY,output)) goto cleanup;
    memset(output,0xa7,page);
    typedef uint32_t (PM_WINAPI *entry_function)(void);
    entry_function entry=(entry_function)((unsigned char *)image.mapping+image.entrypoint_rva);
    uint32_t result=entry(); executed=1;
    passed=!result && checkpoints==5 && !checkpoint_failures && mach_checks==20 &&
        pm_win_GetLastError()==0xcafe1234;
cleanup:;
    int unbound=!bound || pm_winapi_memory_unbind();
    int destroyed=unbound && pm_winapi_memory_destroy(&ctx);
    int unloaded=pm_pe_unload(&image);
    int cleaned=unbound && destroyed && unloaded && !ctx && !image.mapping;
    passed=passed && cleaned;
    int translated=-1; size_t length=sizeof translated;
    if (sysctlbyname("sysctl.proc_translated",&translated,&length,NULL,0)) translated=-1;
    if (!passed) fprintf(stderr,"NtQueryVirtualMemory synthetic probe failed: %s\n",error);
    printf("{\"schemaVersion\":1,\"passed\":%s,\"syntheticPEExecuted\":%s,"
        "\"exactIATVerified\":%s,\"relocationVerified\":%s,\"sixArgumentCalls\":%u,"
        "\"checkpointFailures\":%u,\"actualMachPageChecks\":%u,\"cleanupVerified\":%s,"
        "\"rosettaTranslated\":%s,\"rosettaStateKnown\":%s,\"externalPEAccepted\":false,"
        "\"dllInitialization\":false,\"gameExecuted\":false,\"wineUsed\":false,"
        "\"gpuWorkSubmitted\":false,\"supportDetermined\":false}\n",
        passed?"true":"false",executed?"true":"false",iat_verified?"true":"false",
        relocation_verified?"true":"false",checkpoints,checkpoint_failures,mach_checks,
        cleaned?"true":"false",translated==1?"true":"false",translated>=0?"true":"false");
    return passed?0:1;
}
