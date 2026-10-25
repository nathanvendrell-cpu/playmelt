/* Small owned CPU allocations only. No unknown address is dereferenced. */
#include "winapi_memory.h"
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static unsigned checks, protect_calls;
static int fail_protection;
#define CHECK(x) do { ++checks; if (!(x)) { \
    fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#x); abort(); } } while (0)
static int controlled_mprotect(void *at,size_t bytes,int protection) {
    ++protect_calls;
    if (fail_protection) {
        CHECK(mprotect(at,bytes,PROT_NONE)==0);
        errno=EACCES; return -1;
    }
    return mprotect(at,bytes,protection);
}
#define mprotect controlled_mprotect
#include "winapi_memory.c"
#undef mprotect

static void *current_process(void) { return (void *)(uintptr_t)UINTPTR_MAX; }
static uint64_t read_le(const void *pointer,size_t count) {
    const unsigned char *p=pointer; uint64_t value=0;
    for (size_t i=0;i<count;++i) value|=(uint64_t)p[i]<<(8*i);
    return value;
}
static int permissions(void *pointer) {
    mach_vm_address_t at=(uintptr_t)pointer; mach_vm_size_t bytes=0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t status=mach_vm_region(mach_task_self(),&at,&bytes,
        VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
    if (object!=MACH_PORT_NULL) CHECK(mach_port_deallocate(mach_task_self(),object)==KERN_SUCCESS);
    CHECK(status==KERN_SUCCESS && at<=(uintptr_t)pointer && (uintptr_t)pointer-at<bytes);
    return info.protection;
}
static unsigned char *allocate(pm_winapi_memory *ctx,size_t bytes) {
    void *base=NULL; size_t rounded=0;
    CHECK(pm_winapi_memory_allocate(ctx,bytes,&base,&rounded));
    CHECK(base && rounded==bytes); return base;
}
static void success(void *address,unsigned char *out,size_t capacity,void *length,
    uintptr_t base,uintptr_t allocation,size_t size,uint32_t protection) {
    memset(out,0xa7,48); if (length) memset(length,0x79,8);
    pm_win_SetLastError(0x56781234);
    unsigned prior_calls=protect_calls;
    CHECK(pm_win_NtQueryVirtualMemory(current_process(),address,0,out,capacity,length)==PM_STATUS_SUCCESS);
    CHECK(pm_win_GetLastError()==0x56781234 && protect_calls==prior_calls);
    CHECK(read_le(out,8)==base && read_le(out+8,8)==allocation);
    CHECK(read_le(out+16,4)==PM_PAGE_READWRITE);
    CHECK(read_le(out+20,4)==0 && read_le(out+44,4)==0);
    CHECK(read_le(out+24,8)==size && read_le(out+32,4)==0x1000);
    CHECK(read_le(out+36,4)==protection && read_le(out+40,4)==0x20000);
    CHECK(!length || read_le(length,8)==48);
    int expected=protection==PM_PAGE_NOACCESS ? VM_PROT_NONE :
        protection==PM_PAGE_READONLY ? VM_PROT_READ :
        protection==PM_PAGE_READWRITE ? VM_PROT_READ|VM_PROT_WRITE : VM_PROT_READ|VM_PROT_EXECUTE;
    CHECK(permissions(address)==expected);
}
static void rejected(void *process,void *address,uint32_t kind,void *out,size_t bytes,
    void *length,int32_t status,unsigned char *watch,unsigned char *aux) {
    unsigned char before[256], other[64];
    memcpy(before,watch,sizeof before); memcpy(other,aux,sizeof other);
    pm_win_SetLastError(0x98761234); unsigned prior_calls=protect_calls;
    CHECK(pm_win_NtQueryVirtualMemory(process,address,kind,out,bytes,length)==status);
    CHECK(pm_win_GetLastError()==0x98761234 && protect_calls==prior_calls);
    CHECK(!memcmp(before,watch,sizeof before) && !memcmp(other,aux,sizeof other));
}
typedef struct thread_probe { void *target,*out,*length; int32_t status; uint32_t error; } thread_probe;
static void *other_thread(void *opaque) {
    thread_probe *probe=opaque;
    pm_win_SetLastError(0x78654321);
    probe->status=pm_win_NtQueryVirtualMemory(current_process(),probe->target,0,
        probe->out,48,probe->length);
    probe->error=pm_win_GetLastError(); return NULL;
}

int main(void) {
    char error[128]; pm_winapi_memory *ctx=pm_winapi_memory_create(error,sizeof error);
    CHECK(ctx && !error[0]); size_t page=pm_winapi_memory_page_size(ctx);
    unsigned char *target=allocate(ctx,5*page), *out=allocate(ctx,3*page);
    unsigned char *aux=allocate(ctx,page), *quarantine=allocate(ctx,page);
    memset(out,0xa7,3*page); memset(aux,0x79,page);
    CHECK(pm_winapi_memory_bind(ctx));
    CHECK(pm_win_VirtualProtect(target+page,2*page,PM_PAGE_READONLY,aux));
    /* RW/R/R/RW/RW: query never scans backward to the beginning of a run. */
    success(target+7,out+17,48,out+91,(uintptr_t)target,(uintptr_t)target,page,PM_PAGE_READWRITE);
    success(target+page+3,out+17,48,out+91,(uintptr_t)target+page,(uintptr_t)target,2*page,PM_PAGE_READONLY);
    success(target+2*page+page/2,out+17,48,out+91,(uintptr_t)target+2*page,(uintptr_t)target,page,PM_PAGE_READONLY);
    success(target+3*page+1,out+17,48,out+91,(uintptr_t)target+3*page,(uintptr_t)target,2*page,PM_PAGE_READWRITE);
    success(target+5*page-1,out+17,48,out+91,(uintptr_t)target+4*page,(uintptr_t)target,page,PM_PAGE_READWRITE);
    CHECK(out[16]==0xa7 && out[65]==0xa7 && out[90]==0xa7 && out[99]==0xa7);
    /* A large capacity touches only 48 bytes; NULL ReturnLength is valid. */
    success(target,out+3*page-48,SIZE_MAX,NULL,(uintptr_t)target,(uintptr_t)target,page,PM_PAGE_READWRITE);
    success(target,out+page-23,48,out+2*page-3,(uintptr_t)target,(uintptr_t)target,page,PM_PAGE_READWRITE);
    /* Query/output may share an allocation: metadata is read before copying. */
    success(target+3*page,target+3*page+1,48,target+3*page+57,
        (uintptr_t)target+3*page,(uintptr_t)target,2*page,PM_PAGE_READWRITE);
    CHECK(pm_win_VirtualProtect(target+4*page,page,PM_PAGE_NOACCESS,aux));
    success(target+4*page+8,out+17,48,aux+9,(uintptr_t)target+4*page,(uintptr_t)target,page,PM_PAGE_NOACCESS);
    CHECK(pm_win_VirtualProtect(target+4*page,page,PM_PAGE_EXECUTE_READ,aux));
    success(target+4*page+8,out+17,48,aux+9,(uintptr_t)target+4*page,(uintptr_t)target,page,PM_PAGE_EXECUTE_READ);
    CHECK(pm_win_VirtualProtect(target+4*page,page,PM_PAGE_READWRITE,aux));

#define REJECT(p,a,k,o,n,r,s) rejected(p,a,k,o,n,r,s,out,aux)
    REJECT(NULL,target,0,out+17,48,aux+9,PM_STATUS_INVALID_HANDLE);
    REJECT((void *)(uintptr_t)1,target,0,out+17,48,aux+9,PM_STATUS_INVALID_HANDLE);
    REJECT((void *)(uintptr_t)UINT32_MAX,target,0,out+17,48,aux+9,PM_STATUS_INVALID_HANDLE);
    REJECT(current_process(),target,1,out+17,48,aux+9,PM_STATUS_INVALID_INFO_CLASS);
    REJECT(current_process(),target,UINT32_MAX,out+17,48,aux+9,PM_STATUS_INVALID_INFO_CLASS);
    for (size_t length=0;length<48;++length)
        REJECT(current_process(),target,0,out+17,length,aux+9,PM_STATUS_INFO_LENGTH_MISMATCH);
    unsigned char stack[64]; memset(stack,0x31,sizeof stack);
    void *unknown[]={NULL,stack,(void *)(uintptr_t)1,(void *)(uintptr_t)UINTPTR_MAX};
    for (size_t i=0;i<sizeof unknown/sizeof *unknown;++i) {
        REJECT(current_process(),unknown[i],0,out+17,48,aux+9,PM_STATUS_INVALID_PARAMETER);
        REJECT(current_process(),target,0,unknown[i],48,aux+9,PM_STATUS_ACCESS_VIOLATION);
        if (unknown[i]) REJECT(current_process(),target,0,out+17,48,unknown[i],PM_STATUS_ACCESS_VIOLATION);
    }
    for (size_t i=0;i<sizeof stack;++i) CHECK(stack[i]==0x31);
    REJECT(current_process(),target,0,out+3*page-47,48,aux+9,PM_STATUS_ACCESS_VIOLATION);
    REJECT(current_process(),target,0,out+17,48,aux+page-7,PM_STATUS_ACCESS_VIOLATION);
    /* Both directions of partial overlap, containment and exact alias. */
    for (size_t offset=10;offset<65;++offset)
        REJECT(current_process(),target,0,out+17,48,out+offset,PM_STATUS_INVALID_PARAMETER);
    success(target,out+17,48,out+9,(uintptr_t)target,(uintptr_t)target,page,PM_PAGE_READWRITE);
    success(target,out+17,48,out+65,(uintptr_t)target,(uintptr_t)target,page,PM_PAGE_READWRITE);
    CHECK(pm_win_VirtualProtect(out+page,page,PM_PAGE_READONLY,aux));
    REJECT(current_process(),target,0,out+page-24,48,aux+9,PM_STATUS_ACCESS_VIOLATION);
    REJECT(current_process(),target,0,out+17,48,out+page-4,PM_STATUS_ACCESS_VIOLATION);
    CHECK(pm_win_VirtualProtect(out+page,page,PM_PAGE_NOACCESS,aux));
    REJECT(current_process(),target,0,out+page,48,aux+9,PM_STATUS_ACCESS_VIOLATION);
    REJECT(current_process(),target,0,out+17,48,out+page,PM_STATUS_ACCESS_VIOLATION);
    CHECK(pm_win_VirtualProtect(out+page,page,PM_PAGE_READWRITE,aux));
    /* Inject an OS failure AFTER changing permissions: the RW ledger is stale.
     * Quarantine cannot be queried or used for either output, without touching it. */
    fail_protection=1;
    CHECK(!pm_win_VirtualProtect(quarantine,page,PM_PAGE_READONLY,aux));
    fail_protection=0;
    REJECT(current_process(),quarantine,0,out+17,48,aux+9,PM_STATUS_INVALID_PARAMETER);
    REJECT(current_process(),target,0,quarantine,48,aux+9,PM_STATUS_ACCESS_VIOLATION);
    REJECT(current_process(),target,0,out+17,48,quarantine,PM_STATUS_ACCESS_VIOLATION);
    thread_probe probe={target,out+17,aux+9,0,0}; pthread_t thread;
    unsigned char before[48], before_length[8]; memcpy(before,out+17,48); memcpy(before_length,aux+9,8);
    CHECK(!pthread_create(&thread,NULL,other_thread,&probe)); CHECK(!pthread_join(thread,NULL));
    CHECK(probe.status==PM_STATUS_INVALID_PARAMETER && probe.error==0x78654321);
    CHECK(!memcmp(before,out+17,48) && !memcmp(before_length,aux+9,8));
    CHECK(pm_winapi_memory_unbind());
    REJECT(current_process(),target,0,out+17,48,aux+9,PM_STATUS_INVALID_PARAMETER);
    CHECK(pm_winapi_memory_release(ctx,target));
    CHECK(pm_winapi_memory_bind(ctx));
    REJECT(current_process(),target,0,out+17,48,aux+9,PM_STATUS_INVALID_PARAMETER);
    CHECK(pm_winapi_memory_unbind());
    CHECK(pm_winapi_memory_destroy(&ctx) && !ctx);

    uintptr_t address=0;
    CHECK(pm_winapi_memory_resolve(NULL,"ntdll.dll","NtQueryVirtualMemory",0,0,&address));
    CHECK(address==(uintptr_t)&pm_win_NtQueryVirtualMemory);
    CHECK(pm_winapi_memory_resolve(NULL,"NTDLL.DLL","NtQueryVirtualMemory",0,0,&address));
    const char *modules[]={"kernel32.dll","kernelbase.dll","ntdll","ntdll.dll.x","/ntdll.dll","x/ntdll.dll",NULL};
    for (size_t i=0;i<sizeof modules/sizeof *modules;++i) {
        address=123; CHECK(!pm_winapi_memory_resolve(NULL,modules[i],"NtQueryVirtualMemory",0,0,&address)); CHECK(!address);
    }
    const char *names[]={"ZwQueryVirtualMemory","ntQueryVirtualMemory","VirtualProtect","GetLastError",NULL};
    for (size_t i=0;i<sizeof names/sizeof *names;++i) {
        address=123; CHECK(!pm_winapi_memory_resolve(NULL,"ntdll.dll",names[i],0,0,&address)); CHECK(!address);
    }
    address=123; CHECK(!pm_winapi_memory_resolve(NULL,"ntdll.dll","NtQueryVirtualMemory",1,1,&address)); CHECK(!address);
    CHECK(!pm_winapi_memory_resolve(NULL,"ntdll.dll","NtQueryVirtualMemory",0,0,NULL));
    printf("PASS %u NtQueryVirtualMemory CPU checks; 48-byte layout, owned permissions, unchanged outputs, thread binding, resolver.\n",checks);
    return 0;
}
