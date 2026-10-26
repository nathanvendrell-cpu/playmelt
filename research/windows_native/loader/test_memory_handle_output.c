/* Existing private OS doubles, separate executable from its regression suite. */
#define main memory_regression_not_invoked
#include "test_winapi_memory.c"
#undef main
static void *foreign_write(void *pointer) {
    pm_win_SetLastError(456); CHECK(!pm_winapi_memory_can_write_handle(pointer));
    CHECK(!pm_winapi_memory_write_handle(pointer,123)); CHECK(pm_win_GetLastError()==456); return NULL;
}
int main(void) {
    pm_winapi_memory *ctx=context(); size_t page=ctx->page_size;
    unsigned char *out=allocate(ctx,2*page),*aux=allocate(ctx,page),*fault=allocate(ctx,page);
    memset(out,0xa7,2*page); CHECK(!pm_winapi_memory_can_write_handle(out)); CHECK(pm_winapi_memory_bind(ctx));
    pm_win_SetLastError(1234);
    CHECK(pm_winapi_memory_can_write_handle(out+3)); CHECK(pm_winapi_memory_write_handle(out+3,UINT64_C(0x8877665544332211)));
    const unsigned char expected[]={0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88};
    CHECK(!memcmp(out+3,expected,8) && out[2]==0xa7 && out[11]==0xa7 && pm_win_GetLastError()==1234);
    CHECK(pm_winapi_memory_can_write_handle(out+page-3)); CHECK(pm_winapi_memory_write_handle(out+page-3,UINT64_C(0x8877665544332211)));
    CHECK(!memcmp(out+page-3,expected,8));
    CHECK(pm_win_VirtualProtect(out+page,1,PM_PAGE_READONLY,aux));
    CHECK(!pm_winapi_memory_can_write_handle(out+page-3)); CHECK(!pm_winapi_memory_write_handle(out+page-3,0));
    CHECK(!memcmp(out+page-3,expected,8)); CHECK(pm_win_GetLastError()==1234);
    CHECK(pm_win_VirtualProtect(out+page,1,PM_PAGE_READWRITE,aux));
    uint64_t unowned=UINT64_C(0x8877665544332211);
    void *bad[]={NULL,(void *)1,(void *)(UINTPTR_MAX-3),out+2*page-7,&unowned};
    for (unsigned i=0;i<sizeof bad/sizeof *bad;++i) {
        CHECK(!pm_winapi_memory_can_write_handle(bad[i])); CHECK(!pm_winapi_memory_write_handle(bad[i],0));
        CHECK(pm_win_GetLastError()==1234);
    }
    CHECK(unowned==UINT64_C(0x8877665544332211));
    pthread_t thread; CHECK(pthread_create(&thread,NULL,foreign_write,out)==0); CHECK(pthread_join(thread,NULL)==0);
    CHECK(!memcmp(out+3,expected,8));
    unsigned char *guest=pm_win_VirtualAlloc(NULL,37,PM_MEM_RESERVE|PM_MEM_COMMIT,PM_PAGE_READWRITE); CHECK(guest);
    CHECK(pm_winapi_memory_write_handle(guest+1,55));
    CHECK(!pm_winapi_memory_write_handle(guest+page-7,55)); CHECK(pm_win_VirtualFree(guest,0,PM_MEM_RELEASE));
    CHECK(!pm_winapi_memory_can_write_handle(guest)); /* numerical stale pointer, never dereferenced */
    partial_protection_failure=1; CHECK(!pm_win_VirtualProtect(fault,1,PM_PAGE_READONLY,aux)); partial_protection_failure=0;
    CHECK(actual_permissions(fault)==VM_PROT_NONE);
    pm_win_SetLastError(987); CHECK(!pm_winapi_memory_can_write_handle(fault));
    CHECK(!pm_winapi_memory_write_handle(fault,1) && pm_win_GetLastError()==987);
    CHECK(pm_winapi_memory_unbind()); CHECK(!pm_winapi_memory_write_handle(out,1));
    pm_winapi_memory *other=context(); CHECK(pm_winapi_memory_bind(other)); CHECK(!pm_winapi_memory_write_handle(out,1));
    CHECK(pm_winapi_memory_unbind()); CHECK(pm_winapi_memory_destroy(&other));
    CHECK(pm_winapi_memory_destroy(&ctx)); CHECK(!mappings && !allocations && !wx_requests);
    printf("PASS: %u owned handle-output checks; 8-byte bounds, pages, quarantine, foreign binding and real cleanup\n",atomic_load(&checks));
    return 0;
}
