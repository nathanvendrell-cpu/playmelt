#include "winapi_combined.h"
#include <string.h>

/* Existing narrower API contracts are unchanged. Primary composition usage:
 * https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getprocaddress
 * https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualprotect
 * https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntqueryvirtualmemory
 */
static int module_is(const char *input, const char *expected) {
    if (!input) return 0;
    for (size_t i=0;;++i) {
        unsigned char a=(unsigned char)input[i], b=(unsigned char)expected[i];
        if (a>='A' && a<='Z') a=(unsigned char)(a+('a'-'A'));
        if (a!=b) return 0;
        if (!b) return 1;
    }
}

int pm_winapi_combined_resolve(void *context, const char *dll, const char *name,
    uint16_t ordinal, int by_ordinal, uintptr_t *address) {
    (void)context;
    if (!address) return 0;
    *address=0;
    if (by_ordinal!=0 || ordinal!=0 || !name ||
        (!module_is(dll,"kernel32.dll") && !module_is(dll,"kernelbase.dll") &&
         !module_is(dll,"ntdll.dll"))) return 0;
    size_t length=0;
    for (;length<256 && name[length];++length)
        if ((unsigned char)name[length]<33 || (unsigned char)name[length]>126) return 0;
    if (!length || length==256) return 0;
    const char *symbols[]={"GetLastError","SetLastError","GetCurrentProcessId",
        "QueryPerformanceCounter","QueryPerformanceFrequency","GetTickCount64",
        "GetSystemTimeAsFileTime","GetModuleHandleA","GetModuleHandleW",
        "GetProcAddress","VirtualProtect","VirtualAlloc","VirtualFree","NtQueryVirtualMemory",
        "CreateEventExA","SetEvent","ResetEvent","WaitForSingleObject","CloseHandle"};
    int allowed=0;
    for (size_t i=0;i<sizeof symbols/sizeof *symbols;++i)
        if (!strcmp(name,symbols[i])) { allowed=1; break; }
    if (!allowed) return 0;
    /* Explicit ownership prevents a future provider from accidentally exporting
     * a kernel symbol from ntdll (or NtQuery from kernel32). */
    if (module_is(dll,"ntdll.dll") != !strcmp(name,"NtQueryVirtualMemory")) return 0;
    const pm_import_resolver providers[]={pm_winapi_resolve,
        pm_winapi_modules_resolve,pm_winapi_memory_resolve,pm_winapi_events_resolve};
    uintptr_t selected=0;
    for (size_t i=0;i<sizeof providers/sizeof *providers;++i) {
        uintptr_t candidate=0;
        int ok=providers[i](NULL,dll,name,0,0,&candidate);
        if ((ok!=0 && ok!=1) || (ok==0 && candidate!=0) || (ok==1 && candidate==0)) return 0;
        if (ok) {
            if (selected && selected!=candidate) return 0;
            selected=candidate;
        }
    }
    *address=selected;
    return selected!=0;
}
