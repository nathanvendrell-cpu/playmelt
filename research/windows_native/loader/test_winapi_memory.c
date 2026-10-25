#include "winapi_memory.h"
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static atomic_uint checks;
#define CHECK(x) do { atomic_fetch_add(&checks,1); if (!(x)) { \
    fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#x); abort(); } } while (0)

static unsigned mappings, allocations, map_calls, protect_calls, wx_requests;
static int mapping_failure, allocation_failure, protect_error, unmap_failure;
static int partial_protection_failure;
static void *unmap_failure_address;
static long page_override;
static void *last_protected;
static size_t last_length;
static void *tracked_calloc(size_t n,size_t size) {
    if (allocation_failure) return NULL;
    void *p=calloc(n,size); if (p) ++allocations; return p;
}
static void tracked_free(void *p) { if (p) { CHECK(allocations>0); --allocations; free(p); } }
static void *tracked_mmap(void *at,size_t bytes,int protection,int flags,int fd,off_t offset) {
    ++map_calls;
    if ((protection&PROT_WRITE)&&(protection&PROT_EXEC)) ++wx_requests;
    if (mapping_failure) { errno=ENOMEM; return MAP_FAILED; }
    void *p=mmap(at,bytes,protection,flags,fd,offset);
    if (p!=MAP_FAILED) ++mappings;
    return p;
}
static int tracked_munmap(void *at,size_t bytes) {
    if (unmap_failure || at==unmap_failure_address) { errno=EINVAL; return -1; }
    int result=munmap(at,bytes);
    if (!result) { CHECK(mappings>0); --mappings; }
    return result;
}
static int tracked_mprotect(void *at,size_t bytes,int protection) {
    ++protect_calls; last_protected=at; last_length=bytes;
    if ((protection&PROT_WRITE)&&(protection&PROT_EXEC)) ++wx_requests;
    if (partial_protection_failure) {
        CHECK(mprotect(at,(size_t)sysconf(_SC_PAGESIZE),PROT_NONE)==0);
        errno=EACCES; return -1;
    }
    if (protect_error) { errno=protect_error; return -1; }
    return mprotect(at,bytes,protection);
}
static long tracked_sysconf(int name) { return page_override ? page_override : sysconf(name); }
#define calloc tracked_calloc
#define free tracked_free
#define mmap tracked_mmap
#define munmap tracked_munmap
#define mprotect tracked_mprotect
#define sysconf tracked_sysconf
#include "winapi_memory.c"
#undef calloc
#undef free
#undef mmap
#undef munmap
#undef mprotect
#undef sysconf

static int actual_permissions(void *p) {
    mach_vm_address_t at=(uintptr_t)p; mach_vm_size_t bytes=0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t result=mach_vm_region(mach_task_self(),&at,&bytes,VM_REGION_BASIC_INFO_64,
                                       (vm_region_info_t)&info,&count,&object);
    if (object!=MACH_PORT_NULL) CHECK(mach_port_deallocate(mach_task_self(),object)==KERN_SUCCESS);
    CHECK(result==KERN_SUCCESS && at<=(uintptr_t)p && (uintptr_t)p-at<bytes);
    return info.protection;
}

static pm_winapi_memory *context(void) {
    char error[128];
    pm_winapi_memory *ctx=pm_winapi_memory_create(error,sizeof error);
    CHECK(ctx && !error[0]); return ctx;
}
static void *allocate(pm_winapi_memory *ctx,size_t bytes) {
    void *base=NULL; size_t rounded=0;
    CHECK(pm_winapi_memory_allocate(ctx,bytes,&base,&rounded));
    CHECK(base && rounded>=bytes && rounded%ctx->page_size==0);
    CHECK(actual_permissions(base)==(VM_PROT_READ|VM_PROT_WRITE));
    return base;
}
static uint32_t read32(const void *p) { uint32_t value; memcpy(&value,p,sizeof value); return value; }
static void sentinel(void *p) { const uint32_t value=0xdeadbeef; memcpy(p,&value,sizeof value); }
static void failed(void *at,size_t bytes,uint32_t protection,void *out,uint32_t error) {
    unsigned calls=protect_calls;
    CHECK(!pm_win_VirtualProtect(at,bytes,protection,out));
    if (pm_win_GetLastError()!=error)
        fprintf(stderr,"Error mismatch actual=%u expected=%u size=%zu protection=%u\n",
                pm_win_GetLastError(),error,bytes,protection);
    CHECK(pm_win_GetLastError()==error);
    CHECK(protect_calls==calls);
}

static void test_protections(void) {
    pm_winapi_memory *ctx=context(); size_t page=ctx->page_size;
    unsigned char *target=allocate(ctx,3*page), *output=allocate(ctx,2*page), *aux=allocate(ctx,page);
    void *fault_targets[5];
    for (size_t i=0;i<5;++i) fault_targets[i]=allocate(ctx,page);
    CHECK(pm_winapi_memory_bind(ctx));
    CHECK(!pm_winapi_memory_bind(ctx));
    CHECK(!pm_winapi_memory_release(ctx,target));
    void *forbidden; size_t rounded;
    CHECK(!pm_winapi_memory_allocate(ctx,page,&forbidden,&rounded));
    CHECK(!pm_winapi_memory_destroy(&ctx) && ctx);
    pm_win_SetLastError(777);
    CHECK(pm_win_VirtualProtect(target+page+3,1,PM_PAGE_READONLY,(uint32_t *)output));
    CHECK(read32(output)==PM_PAGE_READWRITE && pm_win_GetLastError()==777);
    CHECK(last_protected==target+page && last_length==page);
    CHECK(actual_permissions(target)==(VM_PROT_READ|VM_PROT_WRITE));
    CHECK(actual_permissions(target+page)==VM_PROT_READ);
    CHECK(actual_permissions(target+2*page)==(VM_PROT_READ|VM_PROT_WRITE));
    /* Two bytes cover two differently protected pages; old = first page only. */
    CHECK(pm_win_VirtualProtect(target+page-1,2,PM_PAGE_EXECUTE_READ,(uint32_t *)output));
    CHECK(read32(output)==PM_PAGE_READWRITE);
    CHECK(last_protected==target && last_length==2*page);
    CHECK(actual_permissions(target)==(VM_PROT_READ|VM_PROT_EXECUTE));
    CHECK(actual_permissions(target+page)==(VM_PROT_READ|VM_PROT_EXECUTE));
    CHECK(pm_win_VirtualProtect(target+1,page,PM_PAGE_READWRITE,(uint32_t *)output));
    CHECK(read32(output)==PM_PAGE_EXECUTE_READ);
    CHECK(actual_permissions(target)==(VM_PROT_READ|VM_PROT_WRITE));
    CHECK(actual_permissions(target+page)==(VM_PROT_READ|VM_PROT_WRITE));
    CHECK(pm_win_VirtualProtect(target+page,1,PM_PAGE_NOACCESS,(uint32_t *)output));
    CHECK(read32(output)==PM_PAGE_READWRITE && actual_permissions(target+page)==VM_PROT_NONE);
    CHECK(pm_win_VirtualProtect(target+page,1,PM_PAGE_READWRITE,(uint32_t *)output));
    CHECK(read32(output)==PM_PAGE_NOACCESS);
    /* Output may be unaligned and straddle two owned RW pages. */
    void *straddled=output+page-2;
    CHECK(pm_win_VirtualProtect(target,1,PM_PAGE_READONLY,straddled));
    CHECK(read32(straddled)==PM_PAGE_READWRITE);
    CHECK(pm_win_VirtualProtect(target,1,PM_PAGE_READWRITE,straddled));
    CHECK(pm_win_VirtualProtect(output+page,1,PM_PAGE_READONLY,(uint32_t *)aux));
    failed(target,1,PM_PAGE_READONLY,straddled,PM_MEMORY_ERROR_NOACCESS);
    CHECK(actual_permissions(target)==(VM_PROT_READ|VM_PROT_WRITE));
    CHECK(pm_win_VirtualProtect(output+page,1,PM_PAGE_READWRITE,(uint32_t *)aux));
    /* Unknown, same-allocation, overflow, one-past and cross-reservation ranges. */
    uint32_t stack_output=0xdeadbeef;
    failed(target,1,PM_PAGE_READONLY,&stack_output,PM_MEMORY_ERROR_NOACCESS);
    CHECK(stack_output==0xdeadbeef);
    failed(target,1,PM_PAGE_READONLY,(uint32_t *)target,PM_MEMORY_ERROR_NOACCESS);
    failed(target,1,PM_PAGE_READONLY,NULL,PM_MEMORY_ERROR_NOACCESS);
    failed(target,1,PM_PAGE_READONLY,(uint32_t *)(uintptr_t)UINTPTR_MAX,PM_MEMORY_ERROR_NOACCESS);
    failed(target,1,PM_PAGE_READONLY,(uint32_t *)(output+2*page-2),PM_MEMORY_ERROR_NOACCESS);
    sentinel(output);
    failed(NULL,1,PM_PAGE_READONLY,(uint32_t *)output,PM_MEMORY_ERROR_INVALID_ADDRESS);
    failed((void *)(uintptr_t)UINTPTR_MAX,2,PM_PAGE_READONLY,(uint32_t *)output,PM_MEMORY_ERROR_INVALID_ADDRESS);
    failed(target,SIZE_MAX,PM_PAGE_READONLY,(uint32_t *)output,PM_MEMORY_ERROR_INVALID_ADDRESS);
    failed(&stack_output,1,PM_PAGE_READONLY,(uint32_t *)output,PM_MEMORY_ERROR_INVALID_ADDRESS);
    failed(target+3*page-1,2,PM_PAGE_READONLY,(uint32_t *)output,PM_MEMORY_ERROR_INVALID_ADDRESS);
    failed(target,0,PM_PAGE_READONLY,(uint32_t *)output,PM_ERROR_INVALID_PARAMETER);
    uintptr_t low=(uintptr_t)target<(uintptr_t)output?(uintptr_t)target:(uintptr_t)output;
    uintptr_t high=(uintptr_t)target>(uintptr_t)output?(uintptr_t)target:(uintptr_t)output;
    failed((void *)low,(size_t)(high-low+1),PM_PAGE_READONLY,(uint32_t *)aux,PM_MEMORY_ERROR_INVALID_ADDRESS);
    const uint32_t rejected[]={0,3,8,0x10,0x40,0x80,0x100,0x104,0x204,0x404,0x40000020,UINT32_MAX};
    for (size_t i=0;i<sizeof rejected/sizeof *rejected;++i)
        failed(target,1,rejected[i],(uint32_t *)output,PM_ERROR_INVALID_PARAMETER);
    CHECK(read32(output)==0xdeadbeef && wx_requests==0);
    /* Failed targets become quarantined even when this stub changed no pages. */
    const int errors[]={EACCES,EPERM,ENOMEM,EINVAL,EIO};
    const uint32_t codes[]={5,5,8,87,31};
    for (size_t i=0;i<sizeof errors/sizeof *errors;++i) {
        protect_error=errors[i]; unsigned before=protect_calls;
        CHECK(!pm_win_VirtualProtect(fault_targets[i],1,PM_PAGE_READONLY,(uint32_t *)output));
        CHECK(pm_win_GetLastError()==codes[i] && protect_calls==before+1);
        CHECK(read32(output)==0xdeadbeef && ctx->regions[3+i].quarantined);
        CHECK(actual_permissions(fault_targets[i])==(VM_PROT_READ|VM_PROT_WRITE));
        failed(fault_targets[i],1,PM_PAGE_READWRITE,(uint32_t *)output,PM_MEMORY_ERROR_INVALID_ADDRESS);
    }
    protect_error=0;
    CHECK(pm_winapi_memory_unbind());
    failed(target,1,PM_PAGE_READONLY,(uint32_t *)output,PM_MEMORY_ERROR_INVALID_ADDRESS);
    CHECK(!pm_winapi_memory_unbind());
    CHECK(pm_winapi_memory_destroy(&ctx) && !ctx);
    CHECK(!mappings && !allocations);
}

static void test_partial_failure_quarantine(void) {
    pm_winapi_memory *ctx=context(); size_t page=ctx->page_size;
    unsigned char *victim=allocate(ctx,2*page);
    uint32_t *output=allocate(ctx,page);
    void *safe=allocate(ctx,page);
    sentinel(output);
    CHECK(pm_winapi_memory_bind(ctx));
    partial_protection_failure=1;
    CHECK(!pm_win_VirtualProtect(victim,2*page,PM_PAGE_READONLY,output));
    partial_protection_failure=0;
    CHECK(pm_win_GetLastError()==PM_MEMORY_ERROR_ACCESS_DENIED);
    CHECK(actual_permissions(victim)==VM_PROT_NONE);
    CHECK(actual_permissions(victim+page)==(VM_PROT_READ|VM_PROT_WRITE));
    CHECK(read32(output)==0xdeadbeef && ctx->regions[0].quarantined);
    failed(victim,1,PM_PAGE_READWRITE,output,PM_MEMORY_ERROR_INVALID_ADDRESS);
    failed(victim+page,1,PM_PAGE_READWRITE,output,PM_MEMORY_ERROR_INVALID_ADDRESS);
    /* In particular never write the old protection into the now-NONE page. */
    failed(safe,1,PM_PAGE_READONLY,(uint32_t *)victim,PM_MEMORY_ERROR_NOACCESS);
    failed(safe,1,PM_PAGE_READONLY,(uint32_t *)(victim+page),PM_MEMORY_ERROR_NOACCESS);
    CHECK(actual_permissions(safe)==(VM_PROT_READ|VM_PROT_WRITE));
    CHECK(pm_winapi_memory_unbind());
    CHECK(pm_winapi_memory_release(ctx,victim));
    CHECK(pm_winapi_memory_destroy(&ctx));
    CHECK(!mappings && !allocations && !wx_requests);
}

static void test_limits_and_cleanup(void) {
    char error[32]; page_override=123;
    CHECK(!pm_winapi_memory_create(error,sizeof error) && error[0]); page_override=0;
    allocation_failure=1;
    CHECK(!pm_winapi_memory_create(error,sizeof error)); allocation_failure=0;
    pm_winapi_memory *ctx=context(); size_t page=ctx->page_size;
    pm_win_SetLastError(999);
    void *base; size_t bytes;
    CHECK(!pm_winapi_memory_allocate(ctx,0,&base,&bytes) && !base && !bytes);
    CHECK(!pm_winapi_memory_allocate(ctx,SIZE_MAX,&base,&bytes));
    CHECK(!pm_winapi_memory_allocate(ctx,PM_MEMORY_MAX_REGION_BYTES+1,&base,&bytes));
    CHECK(!pm_winapi_memory_allocate(ctx,page,NULL,&bytes));
    CHECK(!pm_winapi_memory_allocate(ctx,page,&base,NULL));
    allocation_failure=1;
    CHECK(!pm_winapi_memory_allocate(ctx,page,&base,&bytes)); allocation_failure=0;
    mapping_failure=1;
    CHECK(!pm_winapi_memory_allocate(ctx,page,&base,&bytes)); mapping_failure=0;
    CHECK(!mappings && allocations==1);
    for (unsigned i=0;i<PM_MEMORY_MAX_REGIONS;++i) (void)allocate(ctx,1);
    CHECK(ctx->count==PM_MEMORY_MAX_REGIONS);
    CHECK(!pm_winapi_memory_allocate(ctx,1,&base,&bytes));
    CHECK(!pm_winapi_memory_release(ctx,(void *)(uintptr_t)1));
    base=ctx->regions[0].base;
    CHECK(!pm_winapi_memory_release(ctx,(unsigned char *)base+1));
    unmap_failure=1;
    CHECK(!pm_winapi_memory_release(ctx,base));
    CHECK(!pm_winapi_memory_destroy(&ctx) && ctx && mappings==PM_MEMORY_MAX_REGIONS);
    unmap_failure=0;
    CHECK(pm_winapi_memory_release(ctx,base));
    CHECK(!pm_winapi_memory_release(ctx,base));
    unmap_failure_address=ctx->regions[2].base;
    CHECK(!pm_winapi_memory_destroy(&ctx) && ctx);
    CHECK(mappings==1 && ctx->count==1 && ctx->regions[0].base==unmap_failure_address);
    unmap_failure_address=NULL;
    CHECK(pm_winapi_memory_destroy(&ctx) && !ctx);
    CHECK(pm_win_GetLastError()==999 && !mappings && !allocations);
    CHECK(pm_winapi_memory_destroy(&ctx)); CHECK(!pm_winapi_memory_destroy(NULL));
    ctx=context();
    for (unsigned i=0;i<4;++i) (void)allocate(ctx,PM_MEMORY_MAX_REGION_BYTES);
    CHECK(ctx->bytes==PM_MEMORY_MAX_TOTAL_BYTES);
    CHECK(!pm_winapi_memory_allocate(ctx,1,&base,&bytes));
    CHECK(pm_winapi_memory_destroy(&ctx));
    CHECK(!mappings && !allocations && !wx_requests);
}

typedef struct worker_input { pm_winapi_memory *ctx; void *target; uint32_t *output; int binds; } worker_input;
static void *worker(void *opaque) {
    worker_input *arg=opaque;
    CHECK(pm_win_GetLastError()==0);
    failed(arg->target,1,PM_PAGE_READONLY,arg->output,PM_MEMORY_ERROR_INVALID_ADDRESS);
    CHECK(pm_winapi_memory_bind(arg->ctx)==arg->binds);
    if (arg->binds) {
        CHECK(pm_win_VirtualProtect(arg->target,1,PM_PAGE_READONLY,arg->output));
        CHECK(!pm_winapi_memory_destroy(&arg->ctx));
    }
    return NULL; /* Explicit pthread TLS destructor releases binding. */
}
static void test_threads_and_imports(void) {
    pm_winapi_memory *ctx=context();
    worker_input arg={ctx,allocate(ctx,1),allocate(ctx,4),0};
    pthread_t thread;
    CHECK(pm_winapi_memory_bind(ctx)); pm_win_SetLastError(1234);
    CHECK(pthread_create(&thread,NULL,worker,&arg)==0);
    CHECK(pthread_join(thread,NULL)==0 && pm_win_GetLastError()==1234);
    CHECK(pm_winapi_memory_unbind()); arg.binds=1;
    CHECK(pthread_create(&thread,NULL,worker,&arg)==0);
    CHECK(pthread_join(thread,NULL)==0 && pm_win_GetLastError()==1234);
    CHECK(pm_winapi_memory_bind(ctx));
    CHECK(pm_win_VirtualProtect(arg.target,1,PM_PAGE_READWRITE,arg.output));
    CHECK(*arg.output==PM_PAGE_READONLY);
    CHECK(pm_winapi_memory_unbind());
    CHECK(pm_winapi_memory_destroy(&ctx));
    uintptr_t address=1;
    CHECK(pm_winapi_memory_resolve(NULL,"KERNEL32.DLL","VirtualProtect",0,0,&address));
    CHECK(address==(uintptr_t)&pm_win_VirtualProtect);
    CHECK(pm_winapi_memory_resolve(NULL,"kernelbase.dll","VirtualProtect",0,0,&address));
    CHECK(pm_winapi_memory_resolve(NULL,"kernel32.dll","GetLastError",0,0,&address));
    CHECK(address==(uintptr_t)&pm_win_GetLastError);
    CHECK(!pm_winapi_memory_resolve(NULL,"ntdll.dll","VirtualProtect",0,0,&address) && !address);
    CHECK(!pm_winapi_memory_resolve(NULL,"kernel32.dll",NULL,5,1,&address) && !address);
    const char *refused[]={"VirtualAlloc","VirtualFree","VirtualProtectEx","virtualprotect","FlushInstructionCache"};
    for (size_t i=0;i<sizeof refused/sizeof *refused;++i)
        CHECK(!pm_winapi_memory_resolve(NULL,"kernel32.dll",refused[i],0,0,&address) && !address);
    CHECK(!mappings && !allocations && !wx_requests);
}

int main(void) {
    test_protections(); test_partial_failure_quarantine(); test_limits_and_cleanup(); test_threads_and_imports();
    printf("PASS: %u VirtualProtect checks; real OS protections, no PE execution; liveMappings=%u liveAllocations=%u WX=%u\n",
        atomic_load(&checks),mappings,allocations,wx_requests);
    return 0;
}
