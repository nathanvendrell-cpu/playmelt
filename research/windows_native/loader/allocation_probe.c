/* Embedded data-only allocation lifecycle, never execute guest-allocated pages. */
#include "winapi_combined.h"
#include "allocation_fixture.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>

static unsigned char *data,*output;
static size_t page,zero_bytes;
static unsigned checkpoints,failures,mach_checks;
static int aligned,free_address_verified,writes_verified,absence_verified;
static void *kernel_handle;
static uint64_t read_le(const void *pointer,size_t count) {
    const unsigned char *p=pointer; uint64_t value=0;
    for (size_t i=0;i<count;++i) value|=(uint64_t)p[i]<<(8*i);
    return value;
}
static void write64(void *pointer,uint64_t value) { memcpy(pointer,&value,8); }
static int permissions_or_absent(void *pointer) {
    mach_vm_address_t at=(uintptr_t)pointer; mach_vm_size_t bytes=0;
    vm_region_basic_info_data_64_t info; mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t status=mach_vm_region(mach_task_self(),&at,&bytes,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
    if (object!=MACH_PORT_NULL && mach_port_deallocate(mach_task_self(),object)!=KERN_SUCCESS) return -2;
    ++mach_checks;
    if (status==KERN_INVALID_ADDRESS || (status==KERN_SUCCESS && at>(uintptr_t)pointer)) return -1;
    return status==KERN_SUCCESS && at<=(uintptr_t)pointer && (uintptr_t)pointer-at<bytes?info.protection:-2;
}
static int32_t PM_WINAPI checkpoint(void) {
    unsigned phase=checkpoints++;
    if (phase>2) { ++failures; return 0; }
    uintptr_t raw=read_le(data+0x38,8);
    int ok=raw && raw%65536==0 && read_le(data+0x40,8)==(uintptr_t)&pm_win_VirtualFree &&
        read_le(data+0x48,8)==(uintptr_t)kernel_handle;
    if (!ok) { ++failures; return 0; }
    /* Access only while our known allocation is still live; after Free this
     * numerical address is used only for an immediate Mach coverage check. */
    unsigned char *guest=(unsigned char *)raw;
    int actual=permissions_or_absent(guest);
    if (phase==0) {
        aligned=1; free_address_verified=1;
        if (actual!=(VM_PROT_READ|VM_PROT_WRITE) || read_le(data+0x50,4)!=0xacde3344) ok=0;
        if (ok) {
            for (size_t i=0;i<page;++i) if (guest[i]) ok=0;
            if (ok) zero_bytes=page;
        }
    } else {
        const unsigned char *record=output+39;
        if (read_le(data+0x58,4)!=0x13579bdf || read_le(data+0x5C,4)!=1 ||
            read_le(data+0x60,4)!=PM_STATUS_SUCCESS || read_le(data+0x6C,4)!=0xacde3344 ||
            read_le(output+9,4)!=PM_PAGE_READWRITE || read_le(record,8)!=raw ||
            read_le(record+8,8)!=raw || read_le(record+16,4)!=PM_PAGE_READWRITE ||
            read_le(record+20,4)!=0 || read_le(record+24,8)!=page || read_le(record+32,4)!=0x1000 ||
            read_le(record+36,4)!=PM_PAGE_READONLY || read_le(record+40,4)!=0x20000 ||
            read_le(record+44,4)!=0 || read_le(output+113,8)!=48) ok=0;
        if (phase==1) {
            if (actual!=VM_PROT_READ) ok=0;
            if (ok && (read_le(guest,4)!=0x13579bdf || guest[36]!=0x7b)) ok=0;
            if (ok) writes_verified=1;
        } else {
            if (actual!=-1 || read_le(data+0x64,4)!=1 || read_le(data+0x68,4)!=(uint32_t)PM_STATUS_INVALID_PARAMETER) ok=0;
            if (ok) absence_verified=1;
        }
    }
    for (size_t i=0;i<128;++i)
        if ((!phase || !((i>=9 && i<13) || (i>=39 && i<87) || (i>=113 && i<121))) && output[i]!=0xa7) ok=0;
    if (!ok) ++failures;
    return ok;
}
static int imports(void *context,const char *dll,const char *name,uint16_t ordinal,int by_ordinal,uintptr_t *address) {
    (void)context; if (!address) return 0; *address=0;
    if (!by_ordinal && !ordinal && dll && name && !strcmp(dll,"playmelt_fixture.dll") && !strcmp(name,"AllocationCheckpoint")) {
        *address=(uintptr_t)&checkpoint; return 1;
    }
    return pm_winapi_combined_resolve(NULL,dll,name,ordinal,by_ordinal,address);
}
typedef uint32_t (PM_WINAPI *entry_function)(void);
/* Only generated-PE call lacks Clang type metadata; other instrumentation stays. */
__attribute__((no_sanitize("function")))
static uint32_t call_fixture(entry_function entry) { return entry(); }

int main(int argc,char **argv) {
    if (argc!=2 || strcmp(argv[1],"--synthetic-allocation-test")) return 2;
    char error[256]={0}; pm_pe_image image={0}; pm_pe_modules registry;
    pm_winapi_modules *mods=NULL; pm_winapi_memory *mem=NULL;
    int memory_bound=0,modules_bound=0,passed=0,executed=0,iat=0,relocation=0;
    if (!pm_pe_modules_init(&registry,NULL,NULL)) goto cleanup;
    mem=pm_winapi_memory_create(error,sizeof error); if (!mem) goto cleanup;
    page=pm_winapi_memory_page_size(mem); void *allocation=NULL; size_t rounded;
    if (!pm_winapi_memory_allocate(mem,page,&allocation,&rounded) || rounded!=page) goto cleanup;
    output=allocation; memset(output,0xa7,page);
    if (!pm_pe_load(allocation_fixture,sizeof allocation_fixture,imports,NULL,&image,error,sizeof error)) goto cleanup;
    mods=pm_winapi_modules_create(&registry,&image,"allocation.exe",error,sizeof error); if (!mods) goto cleanup;
    const char *hosts[]={"kernel32.dll","kernelbase.dll","ntdll.dll"};
    for (unsigned i=0;i<3;++i) if (!pm_winapi_modules_add_host(mods,hosts[i],pm_winapi_combined_resolve,NULL)) goto cleanup;
    data=(unsigned char *)image.mapping+0xc000;
    write64(data+0x20,(uintptr_t)output+9); write64(data+0x28,(uintptr_t)output+39); write64(data+0x30,(uintptr_t)output+113);
    const uintptr_t expected[]={(uintptr_t)&pm_win_VirtualAlloc,(uintptr_t)&pm_win_VirtualProtect,
        (uintptr_t)&pm_win_GetModuleHandleA,(uintptr_t)&pm_win_GetProcAddress,
        (uintptr_t)&pm_win_SetLastError,(uintptr_t)&pm_win_GetLastError};
    iat=1;
    for (unsigned i=0;i<6;++i) if (read_le((unsigned char *)image.mapping+0x8180+8*i,8)!=expected[i]) iat=0;
    if (read_le((unsigned char *)image.mapping+0x81B0,8) ||
        read_le((unsigned char *)image.mapping+0x81C0,8)!=(uintptr_t)&pm_win_NtQueryVirtualMemory ||
        read_le((unsigned char *)image.mapping+0x81C8,8) ||
        read_le((unsigned char *)image.mapping+0x81E0,8)!=(uintptr_t)&checkpoint ||
        read_le((unsigned char *)image.mapping+0x81E8,8)) iat=0;
    relocation=read_le(data,8)==(uintptr_t)image.mapping+0xc008;
    if (!iat || !relocation) goto cleanup;
    modules_bound=pm_winapi_modules_bind(mods); if (!modules_bound) goto cleanup;
    memory_bound=pm_winapi_memory_bind(mem); if (!memory_bound) goto cleanup;
    kernel_handle=pm_win_GetModuleHandleA("kernel32.dll"); if (!kernel_handle) goto cleanup;
    uint32_t result=call_fixture((entry_function)((unsigned char *)image.mapping+image.entrypoint_rva)); executed=1;
    passed=!result && checkpoints==3 && !failures && aligned && free_address_verified && writes_verified &&
        absence_verified && zero_bytes==page && mach_checks==3;
cleanup:;
    int mem_unbound=!memory_bound || pm_winapi_memory_unbind();
    int mods_unbound=!modules_bound || pm_winapi_modules_unbind();
    int mods_destroyed=mods_unbound && pm_winapi_modules_destroy(&mods);
    int mem_destroyed=mem_unbound && pm_winapi_memory_destroy(&mem);
    int unloaded=mods_destroyed && pm_pe_unload(&image);
    int cleaned=mem_unbound && mods_unbound && mods_destroyed && mem_destroyed && unloaded && !mem && !mods && !image.mapping;
    passed=passed && cleaned;
    int translated=-1; size_t length=sizeof translated;
    if (sysctlbyname("sysctl.proc_translated",&translated,&length,NULL,0)) translated=-1;
    if (!passed) fprintf(stderr,"Synthetic allocation proof failed: %s\n",error);
    printf("{\"schemaVersion\":1,\"passed\":%s,\"syntheticPEExecuted\":%s,\"exactStaticIATVerified\":%s,"
        "\"relocationVerified\":%s,\"dynamicFreeAddressVerifiedBeforeCall\":%s,\"baseAligned64KiB\":%s,"
        "\"zeroFillBytesChecked\":%zu,\"guestWriteReadVerified\":%s,\"checkpoints\":%u,\"failures\":%u,"
        "\"actualMachChecks\":%u,\"releasedAddressNoLongerCovered\":%s,\"cleanupVerified\":%s,"
        "\"rosettaTranslated\":%s,\"rosettaStateKnown\":%s,\"allocatedPagesExecuted\":false,"
        "\"gameExecuted\":false,\"wineUsed\":false,\"gpuWorkSubmitted\":false,\"supportDetermined\":false}\n",
        passed?"true":"false",executed?"true":"false",iat?"true":"false",relocation?"true":"false",
        free_address_verified?"true":"false",aligned?"true":"false",zero_bytes,writes_verified?"true":"false",
        checkpoints,failures,mach_checks,absence_verified?"true":"false",cleaned?"true":"false",
        translated==1?"true":"false",translated>=0?"true":"false");
    return passed?0:1;
}
