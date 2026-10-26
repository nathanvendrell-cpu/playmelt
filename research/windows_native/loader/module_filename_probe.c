/* Calls only compiled-in PE fixtures; logical path metadata does not name files
 * loaded by any filesystem operation. No arbitrary DLL/EXE path is accepted. */
#include "winapi_combined.h"
#include "module_filename_fixture.h"
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
static uint64_t read_le(const void *at,size_t bytes) {
    const unsigned char *p=at; uint64_t value=0;
    for (size_t i=0;i<bytes;++i) value|=(uint64_t)p[i]<<(i*8);
    return value;
}
static void write64(void *out,uint64_t value) { memcpy(out,&value,8); }
typedef uint32_t (PM_WINAPI *entry_function)(void);
/* Generated PE entry lacks Clang's function-type metadata. Exempt only this
 * trampoline call; ASan and remaining UBSan checks remain enabled throughout. */
__attribute__((no_sanitize("function")))
static uint32_t call_fixture(entry_function entry) { return entry(); }
int main(int argc,char **argv) {
    if (argc!=2 || strcmp(argv[1],"--synthetic-module-filename-test")) return 2;
    pm_pe_image module={0},client={0}; pm_pe_modules registry;
    pm_winapi_modules *mods=NULL; pm_winapi_memory *mem=NULL;
    int registered=0,mods_bound=0,mem_bound=0,passed=0,executed=0,iat=0,relocation=0,dynamic=0;
    char error[256]={0};
    const char main_path[]="C:\\Declared Only\\Path_Probe.EXE";
    const char dll_path[]="D:\\Declared Only\\Probe_Math.DLL";
    size_t main_length=strlen(main_path),dll_length=strlen(dll_path);
    if (!pm_pe_modules_init(&registry,NULL,NULL)) goto cleanup;
    if (!pm_pe_load(module_fixture,sizeof module_fixture,NULL,NULL,&module,error,sizeof error)) goto cleanup;
    if (!pm_pe_modules_add(&registry,"probe_math.dll",&module)) goto cleanup;
    registered=1;
    if (!pm_pe_load(module_filename_fixture,sizeof module_filename_fixture,pm_winapi_combined_resolve,NULL,
        &client,error,sizeof error)) goto cleanup;
    mods=pm_winapi_modules_create(&registry,&client,"path_probe.exe",error,sizeof error);
    if (!mods || !pm_winapi_modules_set_declared_path(mods,&client,main_path) ||
        !pm_winapi_modules_set_declared_path(mods,&module,dll_path) ||
        !pm_winapi_modules_add_host(mods,"kernel32.dll",pm_winapi_combined_resolve,NULL)) goto cleanup;
    mem=pm_winapi_memory_create(error,sizeof error); if (!mem) goto cleanup;
    void *allocation=NULL; size_t rounded=0,page=pm_winapi_memory_page_size(mem);
    if (!pm_winapi_memory_allocate(mem,page,&allocation,&rounded) || rounded!=page) goto cleanup;
    unsigned char *out=allocation; memset(out,0xa7,page);
    unsigned char *data=(unsigned char *)client.mapping+0xc000;
    write64(data+0x20,(uintptr_t)out+1); write64(data+0x28,(uintptr_t)out+257);
    write64(data+0x30,(uintptr_t)out+page-dll_length-1); write64(data+0x38,(uintptr_t)out+513);
    write64(data+0x48,(uintptr_t)&pm_win_GetModuleFileNameA);
    const uintptr_t addresses[]={(uintptr_t)&pm_win_GetModuleFileNameA,(uintptr_t)&pm_win_GetModuleHandleA,
        (uintptr_t)&pm_win_GetProcAddress,(uintptr_t)&pm_win_SetLastError,(uintptr_t)&pm_win_GetLastError};
    iat=1; for (size_t i=0;i<5;++i)
        if (read_le((unsigned char *)client.mapping+0x8180+8*i,8)!=addresses[i]) iat=0;
    if (read_le((unsigned char *)client.mapping+0x81a8,8)) iat=0;
    relocation=read_le(data,8)==(uintptr_t)client.mapping+0xc008;
    if (!iat || !relocation) goto cleanup;
    mods_bound=pm_winapi_modules_bind(mods); if (!mods_bound) goto cleanup;
    mem_bound=pm_winapi_memory_bind(mem); if (!mem_bound) goto cleanup;
    uint32_t status=call_fixture((entry_function)((unsigned char *)client.mapping+client.entrypoint_rva));
    executed=1;
    dynamic=read_le(data+0x50,8)==(uintptr_t)&pm_win_GetModuleFileNameA && read_le(data+0x68,4)==1;
    passed=status==0 && dynamic && read_le(data+0x60,8)==(uintptr_t)module.mapping &&
        read_le(data+0x70,4)==main_length && read_le(data+0x74,4)==0x2345 &&
        read_le(data+0x78,4)==4 && read_le(data+0x7c,4)==122 &&
        read_le(data+0x80,4)==dll_length && read_le(data+0x84,4)==0x3456 &&
        read_le(data+0x88,4)==0 && read_le(data+0x8c,4)==122 &&
        !memcmp(out+1,main_path,main_length+1) && !memcmp(out+257,dll_path,3) && out[260]==0 &&
        !memcmp(out+page-dll_length-1,dll_path,dll_length+1);
    for (size_t i=0;i<page;++i)
        if (!((i>=1 && i<main_length+2) || (i>=257 && i<261) || i>=page-dll_length-1) && out[i]!=0xa7) passed=0;
cleanup:;
    int mem_unbound=!mem_bound || pm_winapi_memory_unbind();
    int mods_unbound=!mods_bound || pm_winapi_modules_unbind();
    int mods_destroyed=mods_unbound && pm_winapi_modules_destroy(&mods);
    int mem_destroyed=mem_unbound && pm_winapi_memory_destroy(&mem);
    int client_unmapped=mods_destroyed && pm_pe_unload(&client);
    int removed=!registered || (client_unmapped && pm_pe_modules_remove(&registry,"probe_math.dll"));
    int module_unmapped=mods_destroyed && removed && pm_pe_unload(&module);
    int cleaned=mem_unbound && mods_unbound && mods_destroyed && mem_destroyed && client_unmapped &&
        removed && module_unmapped && !client.mapping && !module.mapping && !mem && !mods;
    passed=passed && cleaned;
    int translated=-1; size_t size=sizeof translated;
    if (sysctlbyname("sysctl.proc_translated",&translated,&size,NULL,0)) translated=-1;
    if (!passed) fprintf(stderr,"Module filename synthetic proof failed: %s\n",error);
    printf("{\"schemaVersion\":1,\"passed\":%s,\"syntheticPEExecuted\":%s,"
        "\"exactStaticIATVerified\":%s,\"relocationVerified\":%s,\"dynamicAddressVerifiedBeforeCall\":%s,"
        "\"getModuleFileNameGuestCalls\":%u,\"declaredPathOnly\":true,\"canariesVerified\":%s,"
        "\"cleanupVerified\":%s,\"rosettaTranslated\":%s,\"rosettaStateKnown\":%s,"
        "\"filesystemPathLoaded\":false,\"externalPEAccepted\":false,\"gameExecuted\":false,"
        "\"wineUsed\":false,\"gpuWorkSubmitted\":false,\"supportDetermined\":false}\n",
        passed?"true":"false",executed?"true":"false",iat?"true":"false",relocation?"true":"false",
        dynamic?"true":"false",passed?4:0,passed?"true":"false",cleaned?"true":"false",
        translated==1?"true":"false",translated>=0?"true":"false");
    return passed?0:1;
}
