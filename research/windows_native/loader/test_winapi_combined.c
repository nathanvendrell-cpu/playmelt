#include "winapi_combined.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); abort(); } } while (0)
static unsigned char main_bytes[4096], dll_bytes[4096];
static pm_pe_image main_image={.mapping=main_bytes,.mapping_size=sizeof main_bytes};
static pm_pe_image collision_image={.mapping=dll_bytes,.mapping_size=sizeof dll_bytes};
typedef struct service { const char *name; uintptr_t address; } service;
static const service services[]={
#define SERVICE(n) {#n,(uintptr_t)&pm_win_##n}
    SERVICE(GetLastError),SERVICE(SetLastError),SERVICE(GetCurrentProcessId),
    SERVICE(QueryPerformanceCounter),SERVICE(QueryPerformanceFrequency),
    SERVICE(GetTickCount64),SERVICE(GetSystemTimeAsFileTime),
    SERVICE(GetModuleHandleA),SERVICE(GetModuleHandleW),SERVICE(GetProcAddress),
    SERVICE(VirtualProtect),SERVICE(VirtualAlloc),SERVICE(VirtualFree),SERVICE(NtQueryVirtualMemory),SERVICE(CreateEventExA),SERVICE(SetEvent),
    SERVICE(ResetEvent),SERVICE(WaitForSingleObject),SERVICE(CloseHandle),
    SERVICE(CreateSemaphoreExA),SERVICE(ReleaseSemaphore)
#undef SERVICE
};
static pm_winapi_modules *modules(void) {
    pm_pe_modules registry; CHECK(pm_pe_modules_init(&registry,NULL,NULL));
    char error[128];
    pm_winapi_modules *context=pm_winapi_modules_create(&registry,&main_image,"combined.exe",error,sizeof error);
    CHECK(context && !error[0]);
    const char *hosts[]={"kernel32.dll","kernelbase.dll","ntdll.dll"};
    for (unsigned i=0;i<3;++i) CHECK(pm_winapi_modules_add_host(context,hosts[i],pm_winapi_combined_resolve,NULL));
    CHECK(!pm_winapi_modules_add_host(context,"KERNEL32.DLL",pm_winapi_combined_resolve,NULL));
    return context;
}
static void rejected(const char *dll,const char *symbol,uint16_t ordinal,int by_ordinal) {
    uintptr_t address=123; pm_win_SetLastError(0xabc123);
    CHECK(!pm_winapi_combined_resolve(NULL,dll,symbol,ordinal,by_ordinal,&address));
    CHECK(!address && pm_win_GetLastError()==0xabc123);
}
static void test_resolution(void) {
    const char *hosts[]={"kernel32.dll","KernelBase.DLL","NTDLL.dll"};
    for (unsigned h=0;h<3;++h) for (unsigned i=0;i<sizeof services/sizeof *services;++i) {
        uintptr_t address=123; pm_win_SetLastError(765);
        int expected=(h==2)==!strcmp(services[i].name,"NtQueryVirtualMemory");
        CHECK(pm_winapi_combined_resolve(NULL,hosts[h],services[i].name,0,0,&address)==expected);
        CHECK(address==(expected?services[i].address:0) && pm_win_GetLastError()==765);
    }
    const char *bad_dlls[]={NULL,"","kernel32","kernel32.dll/","/kernel32.dll","other.dll", "api-ms-win-core-memory-l1-1-0.dll"};
    for (unsigned i=0;i<sizeof bad_dlls/sizeof *bad_dlls;++i) rejected(bad_dlls[i],"GetLastError",0,0);
    const char *bad_names[]={NULL,"","getLastError","GetLastError ","GetLastErrorX","VirtualAllocEx","FreeLibrary","LoadLibraryA","VirtualProtectEx","\xff"};
    for (unsigned i=0;i<sizeof bad_names/sizeof *bad_names;++i) rejected("kernel32.dll",bad_names[i],0,0);
    char long_name[257]; memset(long_name,'A',sizeof long_name); long_name[256]=0;
    rejected("kernel32.dll",long_name,0,0);
    rejected("kernel32.dll","GetLastError",1,0);
    rejected("kernel32.dll","GetLastError",0,1);
    rejected("kernel32.dll","GetLastError",0,-1);
    CHECK(!pm_winapi_combined_resolve(NULL,"kernel32.dll","GetLastError",0,0,NULL));
    /* Missing export from an explicitly registered PE must NOT fall through to
     * an identically named host service (no automatic DLL replacement). */
    pm_pe_modules registry; CHECK(pm_pe_modules_init(&registry,pm_winapi_combined_resolve,NULL));
    CHECK(pm_pe_modules_add(&registry,"kernel32.dll",&collision_image));
    uintptr_t address=123;
    CHECK(!pm_pe_modules_resolve(&registry,"kernel32.dll","GetLastError",0,0,&address) && !address);
    char error[128];
    pm_winapi_modules *context=pm_winapi_modules_create(&registry,&main_image,"combined.exe",error,sizeof error);
    CHECK(context);
    CHECK(!pm_winapi_modules_add_host(context,"kernel32.dll",pm_winapi_combined_resolve,NULL));
    CHECK(pm_winapi_modules_destroy(&context) && !context);
}
static void test_dynamic_and_bindings(void) {
    CHECK(!pm_win_GetModuleHandleA("kernel32.dll"));
    CHECK(pm_win_GetLastError()==PM_ERROR_MOD_NOT_FOUND);
    char error[128];
    pm_winapi_modules *mods=modules();
    pm_winapi_memory *mem=pm_winapi_memory_create(error,sizeof error);
    CHECK(mem);
    size_t page=pm_winapi_memory_page_size(mem),rounded; void *target=NULL,*output=NULL;
    CHECK(pm_winapi_memory_allocate(mem,page,&target,&rounded) && rounded==page);
    CHECK(pm_winapi_memory_allocate(mem,page,&output,&rounded) && rounded==page);
    memset(output,0xa7,page);
    CHECK(pm_winapi_modules_bind(mods));
    void *k32=pm_win_GetModuleHandleA("KERNEL32"),*kbase=pm_win_GetModuleHandleA("kernelbase.dll");
    const uint16_t wide[]={'n','t','d','l','l',0};
    void *ntdll=pm_win_GetModuleHandleW(wide);
    CHECK(k32 && kbase && ntdll && k32!=kbase && k32!=ntdll && kbase!=ntdll);
    CHECK(pm_win_GetModuleHandleA(NULL)==main_bytes);
    for (unsigned i=0;i<sizeof services/sizeof *services;++i) {
        pm_win_SetLastError(123);
        int isnt=!strcmp(services[i].name,"NtQueryVirtualMemory");
        CHECK(pm_win_GetProcAddress(isnt?ntdll:k32,services[i].name)==services[i].address);
        CHECK(pm_win_GetLastError()==123);
        if (!isnt) CHECK(pm_win_GetProcAddress(kbase,services[i].name)==services[i].address);
    }
    CHECK(!pm_win_GetProcAddress(k32,"NtQueryVirtualMemory") && pm_win_GetLastError()==PM_ERROR_PROC_NOT_FOUND);
    CHECK(!pm_win_GetProcAddress(ntdll,"VirtualProtect") && pm_win_GetLastError()==PM_ERROR_PROC_NOT_FOUND);
    CHECK(!pm_win_GetProcAddress(k32,"VirtualAllocEx") && pm_win_GetLastError()==PM_ERROR_PROC_NOT_FOUND);
    CHECK(!pm_win_GetProcAddress(k32,(const char *)(uintptr_t)1) && pm_win_GetLastError()==PM_ERROR_PROC_NOT_FOUND);
    CHECK(!pm_win_GetModuleHandleA("missing") && pm_win_GetLastError()==PM_ERROR_MOD_NOT_FOUND);
    typedef int32_t (PM_WINAPI *protect_function)(void *,size_t,uint32_t,void *);
    typedef int32_t (PM_WINAPI *query_function)(void *,void *,uint32_t,void *,size_t,void *);
    protect_function protect=(protect_function)pm_win_GetProcAddress(k32,"VirtualProtect");
    query_function query=(query_function)pm_win_GetProcAddress(ntdll,"NtQueryVirtualMemory");
    CHECK(protect && query);
    /* Resolution is possible without a bound memory context, but calls MUST
     * fail truthfully and preserve output; no fake operational success. */
    CHECK(!protect(target,1,PM_PAGE_READONLY,output));
    CHECK(pm_win_GetLastError()==PM_MEMORY_ERROR_INVALID_ADDRESS && *(unsigned char *)output==0xa7);
    CHECK(query((void *)UINTPTR_MAX,target,0,output,48,NULL)==PM_STATUS_INVALID_PARAMETER);
    CHECK(pm_winapi_memory_bind(mem));
    CHECK(!pm_winapi_memory_bind(mem) && !pm_winapi_modules_bind(mods));
    CHECK(!pm_winapi_memory_destroy(&mem) && mem);
    CHECK(!pm_winapi_modules_destroy(&mods) && mods);
    pm_win_SetLastError(456);
    CHECK(protect(target,1,PM_PAGE_READONLY,output) && pm_win_GetLastError()==456);
    uint32_t old; memcpy(&old,output,4); CHECK(old==PM_PAGE_READWRITE);
    CHECK(query((void *)UINTPTR_MAX,target,0,(unsigned char *)output+16,48,(unsigned char *)output+80)==PM_STATUS_SUCCESS);
    memcpy(&old,(unsigned char *)output+16+36,4); CHECK(old==PM_PAGE_READONLY);
    CHECK(!protect(target,1,0x40,output) && pm_win_GetLastError()==PM_ERROR_INVALID_PARAMETER);
    CHECK(protect(target,1,PM_PAGE_READWRITE,output));
    CHECK(pm_winapi_memory_unbind()); CHECK(pm_winapi_modules_unbind());
    CHECK(!pm_win_GetModuleHandleA("kernel32") && pm_win_GetLastError()==PM_ERROR_MOD_NOT_FOUND);
    CHECK(pm_winapi_modules_destroy(&mods) && !mods);
    CHECK(pm_winapi_memory_destroy(&mem) && !mem);
}
static void test_partial_binding(void) {
    char error[128]; pm_winapi_modules *mods=modules();
    pm_winapi_memory *prior=pm_winapi_memory_create(error,sizeof error);
    pm_winapi_memory *candidate=pm_winapi_memory_create(error,sizeof error);
    CHECK(prior && candidate);
    void *target=NULL,*output=NULL; size_t size;
    CHECK(pm_winapi_memory_allocate(prior,1,&target,&size));
    CHECK(pm_winapi_memory_allocate(prior,1,&output,&size));
    CHECK(pm_winapi_memory_bind(prior));
    int acquired_modules=pm_winapi_modules_bind(mods);
    CHECK(acquired_modules);
    int acquired_memory=pm_winapi_memory_bind(candidate);
    CHECK(!acquired_memory);
    /* Exact rollback of this attempted attachment, preserving caller's prior
     * binding. Host registrations stay sealed: this is NOT a transaction. */
    CHECK(!acquired_memory && acquired_modules && pm_winapi_modules_unbind());
    CHECK(!pm_winapi_modules_add_host(mods,"extra.dll",pm_winapi_combined_resolve,NULL));
    CHECK(pm_win_VirtualProtect(target,1,PM_PAGE_READONLY,output));
    CHECK(!pm_winapi_memory_destroy(&prior) && prior);
    CHECK(pm_winapi_memory_destroy(&candidate) && !candidate);
    CHECK(pm_winapi_modules_destroy(&mods) && !mods);
    CHECK(pm_winapi_memory_unbind());
    CHECK(pm_winapi_memory_destroy(&prior) && !prior);
}
int main(void) {
    test_resolution(); test_dynamic_and_bindings(); test_partial_binding();
    printf("PASS: %u combined WinAPI checks; no PE executed\n",checks);
    return 0;
}
