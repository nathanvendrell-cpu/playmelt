/* Tiny owned allocations only; OS doubles retain real mappings and permissions. */
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
static unsigned allocations,map_count,map_calls,unmap_calls,protect_calls,wx;
static int fail_alloc,fail_map,fail_protect,fail_unmap,partial_unmap;
static void *last_unmapped; static size_t last_unmapped_bytes;
static struct { void *base; size_t bytes; } mappings[32];
#define CHECK(x) do { atomic_fetch_add(&checks,1); if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); abort(); } } while (0)
static void *controlled_calloc(size_t n,size_t bytes) {
    if (fail_alloc) return NULL;
    void *p=calloc(n,bytes); if (p) ++allocations; return p;
}
static void controlled_free(void *p) { if (p) { CHECK(allocations>0); --allocations; free(p); } }
static void *controlled_mmap(void *address,size_t bytes,int prot,int flags,int fd,off_t offset) {
    ++map_calls; if ((prot&PROT_WRITE)&&(prot&PROT_EXEC)) ++wx;
    if (fail_map) { errno=fail_map; return MAP_FAILED; }
    void *p=mmap(address,bytes,prot,flags,fd,offset);
    if (p!=MAP_FAILED) { CHECK(map_count<32); mappings[map_count].base=p; mappings[map_count++].bytes=bytes; }
    return p;
}
static int controlled_munmap(void *address,size_t bytes) {
    ++unmap_calls; last_unmapped=address; last_unmapped_bytes=bytes;
    unsigned found=map_count;
    for (unsigned i=0;i<map_count;++i) if (mappings[i].base==address) { found=i; break; }
    CHECK(found<map_count && mappings[found].bytes==bytes); /* never trim/free guest window only */
    if (partial_unmap) {
        CHECK(!munmap(address,(size_t)sysconf(_SC_PAGESIZE)));
        errno=EACCES; return -1;
    }
    if (fail_unmap) { errno=fail_unmap; return -1; }
    int result=munmap(address,bytes);
    if (!result) mappings[found]=mappings[--map_count];
    return result;
}
static int controlled_mprotect(void *address,size_t bytes,int prot) {
    ++protect_calls; if ((prot&PROT_WRITE)&&(prot&PROT_EXEC)) ++wx;
    if (fail_protect) {
        /* Deliberately change the first page before returning failure. */
        CHECK(!mprotect(address,(size_t)sysconf(_SC_PAGESIZE),PROT_READ|PROT_WRITE));
        errno=fail_protect; return -1;
    }
    return mprotect(address,bytes,prot);
}
#define calloc controlled_calloc
#define free controlled_free
#define mmap controlled_mmap
#define munmap controlled_munmap
#define mprotect controlled_mprotect
#include "winapi_memory.c"
#undef calloc
#undef free
#undef mmap
#undef munmap
#undef mprotect

static pm_winapi_memory *context(void) {
    char error[128]; pm_winapi_memory *ctx=pm_winapi_memory_create(error,sizeof error);
    CHECK(ctx && !error[0]); return ctx;
}
static int mach_permissions(void *pointer) {
    mach_vm_address_t at=(uintptr_t)pointer; mach_vm_size_t bytes=0;
    vm_region_basic_info_data_64_t info; mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t result=mach_vm_region(mach_task_self(),&at,&bytes,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
    if (object!=MACH_PORT_NULL) CHECK(mach_port_deallocate(mach_task_self(),object)==KERN_SUCCESS);
    return result==KERN_SUCCESS && at<=(uintptr_t)pointer && (uintptr_t)pointer-at<bytes?info.protection:-1;
}
static uint64_t read_le(const void *at,size_t count) {
    const unsigned char *p=at; uint64_t v=0; for (size_t i=0;i<count;++i) v|=(uint64_t)p[i]<<(8*i); return v;
}
static void alloc_rejected(void *at,size_t bytes,uint32_t type,uint32_t prot,uint32_t error) {
    unsigned before=map_calls;
    CHECK(!pm_win_VirtualAlloc(at,bytes,type,prot));
    CHECK(pm_win_GetLastError()==error && map_calls==before);
}
static void free_rejected(void *at,size_t bytes,uint32_t type,uint32_t error) {
    unsigned before=unmap_calls;
    CHECK(!pm_win_VirtualFree(at,bytes,type)); CHECK(pm_win_GetLastError()==error && unmap_calls==before);
}
static void test_forms_and_owned_windows(void) {
    alloc_rejected(NULL,1,0x3000,4,487); free_rejected((void *)1,0,0x8000,487);
    pm_winapi_memory *ctx=context(); size_t page=ctx->page_size,rounded;
    void *host=NULL; CHECK(pm_winapi_memory_allocate(ctx,page,&host,&rounded));
    CHECK(pm_winapi_memory_bind(ctx));
    const uint32_t types[]={0,0x1000,0x2000,0x4000,0x13000,0x20003000,UINT32_MAX};
    for (unsigned i=0;i<sizeof types/sizeof *types;++i) alloc_rejected(NULL,1,types[i],4,87);
    const uint32_t protections[]={0,1,2,0x10,0x20,0x40,0x104,UINT32_MAX};
    for (unsigned i=0;i<sizeof protections/sizeof *protections;++i) alloc_rejected(NULL,1,0x3000,protections[i],87);
    alloc_rejected((void *)65536,1,0x3000,4,87);
    alloc_rejected(NULL,0,0x3000,4,87); alloc_rejected(NULL,SIZE_MAX,0x3000,4,87);
    alloc_rejected(NULL,PM_MEMORY_MAX_REGION_BYTES+1,0x3000,4,87);
    pm_win_SetLastError(0xabc123);
    unsigned char *guest=pm_win_VirtualAlloc(NULL,page+13,0x3000,4);
    CHECK(guest && (uintptr_t)guest%65536==0 && pm_win_GetLastError()==0xabc123);
    memory_region *r=&ctx->regions[1];
    CHECK(r->guest && !r->quarantined && r->base==guest && r->bytes==2*page);
    CHECK(r->backing_bytes==2*page+65536-page && ctx->bytes==page+r->backing_bytes);
    CHECK((uintptr_t)guest>=(uintptr_t)r->backing && (uintptr_t)guest+2*page<=(uintptr_t)r->backing+r->backing_bytes);
    CHECK(mach_permissions(guest)==(VM_PROT_READ|VM_PROT_WRITE));
    int zero=1; for (size_t i=0;i<r->bytes;++i) if (guest[i]) zero=0; CHECK(zero);
    guest[0]=0x5a; guest[2*page-1]=0x79; CHECK(guest[0]==0x5a && guest[2*page-1]==0x79);
    memset(host,0xa7,page);
    if (guest!=(unsigned char *)r->backing) {
        CHECK(mach_permissions(r->backing)==VM_PROT_NONE);
        CHECK(pm_win_NtQueryVirtualMemory((void *)UINTPTR_MAX,r->backing,0,host,48,NULL)==PM_STATUS_INVALID_PARAMETER);
        CHECK(!pm_win_VirtualProtect(r->backing,1,4,host) && pm_win_GetLastError()==487);
    }
    unsigned char *tail=guest+r->bytes;
    if ((uintptr_t)tail<(uintptr_t)r->backing+r->backing_bytes) {
        CHECK(mach_permissions(tail)==VM_PROT_NONE);
        CHECK(pm_win_NtQueryVirtualMemory((void *)UINTPTR_MAX,tail,0,host,48,NULL)==PM_STATUS_INVALID_PARAMETER);
    }
    CHECK(pm_win_NtQueryVirtualMemory((void *)UINTPTR_MAX,guest+1,0,host,48,NULL)==PM_STATUS_SUCCESS);
    CHECK(read_le((unsigned char *)host+8,8)==(uintptr_t)guest && read_le((unsigned char *)host+24,8)==2*page && read_le((unsigned char *)host+36,4)==4);
    CHECK(pm_win_VirtualProtect(guest,1,PM_PAGE_READONLY,(unsigned char *)host+80));
    CHECK(mach_permissions(guest)==VM_PROT_READ);
    CHECK(pm_win_NtQueryVirtualMemory((void *)UINTPTR_MAX,guest,0,host,48,NULL)==PM_STATUS_SUCCESS);
    CHECK(read_le((unsigned char *)host+24,8)==page && read_le((unsigned char *)host+36,4)==PM_PAGE_READONLY);
    free_rejected(host,0,0x8000,487); free_rejected(guest+1,0,0x8000,487);
    free_rejected(guest,1,0x8000,87); free_rejected(guest,0,0x4000,87); free_rejected(NULL,0,0x8000,487);
    void *backing=r->backing; size_t backing_bytes=r->backing_bytes;
    pm_win_SetLastError(777); CHECK(pm_win_VirtualFree(guest,0,0x8000));
    CHECK(pm_win_GetLastError()==777 && last_unmapped==backing && last_unmapped_bytes==backing_bytes);
    CHECK(ctx->count==1 && ctx->bytes==page && map_count==1 && mach_permissions(guest)==-1);
    unsigned char before[48]; memcpy(before,host,48);
    CHECK(pm_win_NtQueryVirtualMemory((void *)UINTPTR_MAX,guest,0,host,48,NULL)==PM_STATUS_INVALID_PARAMETER);
    CHECK(!memcmp(before,host,48)); free_rejected(guest,0,0x8000,487);
    void *unused=NULL; CHECK(!pm_winapi_memory_allocate(ctx,1,&unused,&rounded));
    CHECK(!pm_winapi_memory_release(ctx,host) && !pm_winapi_memory_destroy(&ctx));
    CHECK(pm_winapi_memory_unbind()); CHECK(pm_winapi_memory_destroy(&ctx));
    CHECK(!map_count && !allocations && !wx);
}
static void test_failures_and_quarantine(void) {
    pm_winapi_memory *ctx=context(); CHECK(pm_winapi_memory_bind(ctx));
    fail_alloc=1; alloc_rejected(NULL,1,0x3000,4,8); fail_alloc=0;
    fail_map=ENOMEM; CHECK(!pm_win_VirtualAlloc(NULL,1,0x3000,4));
    CHECK(pm_win_GetLastError()==8 && !map_count && !ctx->count); fail_map=0;
    fail_protect=EACCES; CHECK(!pm_win_VirtualAlloc(NULL,1,0x3000,4));
    CHECK(pm_win_GetLastError()==5 && !map_count && !ctx->count && allocations==1);
    fail_unmap=EINVAL;
    for (unsigned i=0;i<PM_MEMORY_MAX_REGIONS;++i) {
        CHECK(!pm_win_VirtualAlloc(NULL,1,0x3000,4) && pm_win_GetLastError()==PM_ERROR_GEN_FAILURE);
        memory_region *r=&ctx->regions[i];
        CHECK(!r->base && !r->bytes && !r->pages && r->guest && r->quarantined && r->backing);
        CHECK(ctx->count==i+1 && ctx->bytes==(i+1)*65536 && allocations==1);
        free_rejected(r->backing,0,0x8000,487);
    }
    alloc_rejected(NULL,1,0x3000,4,8);
    fail_protect=0; CHECK(pm_winapi_memory_unbind());
    CHECK(!pm_winapi_memory_destroy(&ctx) && ctx && map_count==8);
    fail_unmap=0; CHECK(pm_winapi_memory_destroy(&ctx)); CHECK(!map_count && !allocations);
    ctx=context(); void *out=NULL; size_t rounded;
    CHECK(pm_winapi_memory_allocate(ctx,128,&out,&rounded)); CHECK(pm_winapi_memory_bind(ctx));
    void *guest=pm_win_VirtualAlloc(NULL,1,0x3000,4); CHECK(guest);
    size_t charged=ctx->bytes; partial_unmap=1;
    CHECK(!pm_win_VirtualFree(guest,0,0x8000) && pm_win_GetLastError()==5);
    CHECK(ctx->count==2 && ctx->bytes==charged && ctx->regions[1].quarantined);
    CHECK(pm_win_NtQueryVirtualMemory((void *)UINTPTR_MAX,guest,0,out,48,NULL)==PM_STATUS_INVALID_PARAMETER);
    CHECK(!pm_win_VirtualProtect(guest,1,4,out) && pm_win_GetLastError()==487);
    CHECK(!pm_win_VirtualProtect(out,1,2,guest) && pm_win_GetLastError()==998);
    partial_unmap=0; CHECK(pm_win_VirtualFree(guest,0,0x8000));
    CHECK(ctx->count==1 && ctx->bytes==rounded);
    CHECK(pm_winapi_memory_unbind()); CHECK(pm_winapi_memory_destroy(&ctx));
    CHECK(!map_count && !allocations && !wx);
}
static void test_padding_budget(void) {
    pm_winapi_memory *ctx=context(); CHECK(pm_winapi_memory_bind(ctx));
    size_t one=PM_MEMORY_MAX_REGION_BYTES+65536-ctx->page_size;
    unsigned expected=(unsigned)(PM_MEMORY_MAX_TOTAL_BYTES/one);
    for (unsigned i=0;i<expected;++i) CHECK(pm_win_VirtualAlloc(NULL,PM_MEMORY_MAX_REGION_BYTES,0x3000,4));
    CHECK(ctx->bytes==expected*one); alloc_rejected(NULL,PM_MEMORY_MAX_REGION_BYTES,0x3000,4,8);
    CHECK(pm_winapi_memory_unbind()); CHECK(pm_winapi_memory_destroy(&ctx));
    /* Failed unpublished allocations consume the same full backing quota. */
    ctx=context(); CHECK(pm_winapi_memory_bind(ctx)); fail_protect=EACCES; fail_unmap=EINVAL;
    for (unsigned i=0;i<expected;++i) CHECK(!pm_win_VirtualAlloc(NULL,PM_MEMORY_MAX_REGION_BYTES,0x3000,4));
    CHECK(ctx->bytes==expected*one && ctx->count==expected);
    alloc_rejected(NULL,PM_MEMORY_MAX_REGION_BYTES,0x3000,4,8);
    fail_protect=fail_unmap=0; CHECK(pm_winapi_memory_unbind()); CHECK(pm_winapi_memory_destroy(&ctx));
    CHECK(!map_count && !allocations);
}
static void test_host_release_quarantine(void) {
    pm_winapi_memory *ctx=context(); void *target=NULL,*out=NULL; size_t rounded;
    CHECK(pm_winapi_memory_allocate(ctx,1,&target,&rounded));
    CHECK(pm_winapi_memory_allocate(ctx,128,&out,&rounded));
    fail_unmap=EACCES;
    CHECK(!pm_winapi_memory_release(ctx,target) && ctx->regions[0].quarantined);
    CHECK(pm_winapi_memory_bind(ctx));
    CHECK(pm_win_NtQueryVirtualMemory((void *)UINTPTR_MAX,target,0,out,48,NULL)==PM_STATUS_INVALID_PARAMETER);
    CHECK(!pm_win_VirtualProtect(target,1,4,out) && pm_win_GetLastError()==487);
    CHECK(pm_winapi_memory_unbind()); fail_unmap=0;
    CHECK(pm_winapi_memory_release(ctx,target)); CHECK(pm_winapi_memory_destroy(&ctx));
    CHECK(!map_count && !allocations);
}
typedef struct thread_state { pm_winapi_memory *ctx; void *guest; int no_context,wrong_owner,bound; } thread_state;
static void *other_thread(void *opaque) {
    thread_state *state=opaque;
    state->no_context=!pm_win_VirtualAlloc(NULL,1,0x3000,4) && pm_win_GetLastError()==487;
    state->wrong_owner=!pm_win_VirtualFree(state->guest,0,0x8000) && pm_win_GetLastError()==487;
    state->bound=pm_winapi_memory_bind(state->ctx);
    return NULL;
}
static void *allocating_thread(void *opaque) {
    thread_state *state=opaque; state->bound=pm_winapi_memory_bind(state->ctx);
    if (state->bound) state->guest=pm_win_VirtualAlloc(NULL,1,0x3000,4);
    return NULL; /* destructor unbinds; memory remains for explicit owner cleanup */
}
static void test_thread_lifetime(void) {
    pm_winapi_memory *ctx=context(),*other=context(); CHECK(pm_winapi_memory_bind(ctx));
    void *guest=pm_win_VirtualAlloc(NULL,1,0x3000,4); CHECK(guest);
    thread_state state={.ctx=ctx,.guest=guest}; pthread_t thread;
    CHECK(!pthread_create(&thread,NULL,other_thread,&state)); CHECK(!pthread_join(thread,NULL));
    CHECK(state.no_context && state.wrong_owner && !state.bound);
    CHECK(pm_winapi_memory_unbind()); CHECK(pm_winapi_memory_bind(other));
    free_rejected(guest,0,0x8000,487); CHECK(pm_winapi_memory_unbind());
    CHECK(pm_winapi_memory_destroy(&other)); CHECK(pm_winapi_memory_destroy(&ctx));
    ctx=context(); state=(thread_state){.ctx=ctx};
    CHECK(!pthread_create(&thread,NULL,allocating_thread,&state)); CHECK(!pthread_join(thread,NULL));
    CHECK(state.bound && state.guest && ctx->count==1 && !ctx->bound);
    CHECK(pm_winapi_memory_destroy(&ctx)); CHECK(!map_count && !allocations && !wx);
}
int main(void) {
    test_forms_and_owned_windows(); test_failures_and_quarantine(); test_padding_budget(); test_host_release_quarantine(); test_thread_lifetime();
    printf("PASS: %u VirtualAlloc/Free checks; exact backings, zero fill, quotas, quarantine; liveMappings=%u liveAllocations=%u WX=%u\n",atomic_load(&checks),map_count,allocations,wx);
    return 0;
}
