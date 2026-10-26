/* Two embedded EXEs retain our actual synthetic DLL through their real IAT use.
 * No external PE path, no dynamic loading API and no Windows reference claims. */
#include "pe_loader.h"
#include "pe_modules.h"
#include "winapi_subset.h"
#include "hold_fixture.h"
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>
static uint64_t r64(const void *p) { uint64_t n; memcpy(&n,p,8); return n; }
static uint32_t r32(const void *p) { uint32_t n; memcpy(&n,p,4); return n; }
typedef uint32_t (PM_WINAPI *entry_function)(void);
__attribute__((no_sanitize("function")))
static uint32_t call_fixture(entry_function entry) { return entry(); }
static int verify_client(pm_pe_image *client,pm_pe_image *dll,int *iat,int *executed) {
    unsigned char *table=(unsigned char *)client->mapping+0x8180;
    const uintptr_t expected[]={(uintptr_t)dll->mapping+0x4000,(uintptr_t)dll->mapping+0x4010,
        (uintptr_t)&pm_win_GetCurrentProcessId,(uintptr_t)dll->mapping+0x4010,(uintptr_t)dll->mapping+0xc008};
    for (size_t i=0;i<5;++i) if (r64(table+8*i)!=expected[i]) return 0;
    if (r64(table+40)) return 0;
    ++*iat;
    unsigned char *data=(unsigned char *)client->mapping+0xc000;
    if (r64(data)!=(uintptr_t)data+8) return 0;
    uint32_t status=call_fixture((entry_function)((unsigned char *)client->mapping+client->entrypoint_rva));
    ++*executed;
    return !status && r32(data+0x20)==42 && r32(data+0x24)==42 && r32(data+0x28)==(uint32_t)getpid() &&
        r32(data+0x2c)==72 && r64(data+0x30)==UINT64_C(0x1122334455667788);
}
int main(int argc,char **argv) {
    if (argc!=2 || strcmp(argv[1],"--synthetic-hold-test")) return 2;
    pm_pe_image dll={0},clients[2]={0}; pm_pe_modules registry;
    char error[256]={0}; int registered=0,passed=0,executed=0,iat=0,blocks=0,notifications=0;
    if (!pm_pe_modules_init(&registry,pm_winapi_resolve,NULL)) goto cleanup;
    /* Existing strict route still refuses a DLL initialization entry. */
    if (pm_pe_load(hold_dll_fixture,sizeof hold_dll_fixture,NULL,NULL,&dll,error,sizeof error) || dll.mapping ||
        !strstr(error,"unsupported-dll")) goto cleanup;
    if (!pm_pe_load_synthetic_dll(hold_dll_fixture,sizeof hold_dll_fixture,NULL,NULL,&dll,error,sizeof error)) goto cleanup;
    if (!pm_pe_synthetic_dll_attach(&dll,error,sizeof error)) goto cleanup;
    unsigned char *data=(unsigned char *)dll.mapping+0xc000;
    if (r64(data+0x20)!=(uintptr_t)dll.mapping || r32(data+0x28)!=1 || r64(data+0x30) || r32(data+0x38)!=1) goto cleanup;
    notifications=1;
    if (!pm_pe_modules_add(&registry,"probe_math.dll",&dll)) goto cleanup;
    registered=1; const pm_pe_image *deps[]={&dll};
    for (size_t i=0;i<2;++i) {
        if (!pm_pe_load(hold_client_fixture,sizeof hold_client_fixture,pm_pe_modules_resolve,&registry,
            &clients[i],error,sizeof error) || !pm_pe_hold_dependencies(&clients[i],deps,1,error,sizeof error)) goto cleanup;
    }
    /* No OS unmap or DllMain call is allowed while either EXE holds the DLL. */
    if (pm_pe_unload(&dll) || pm_pe_synthetic_dll_detach(&dll,error,sizeof error) || r32(data+0x38)!=1 ||
        pm_pe_synthetic_dll_state(&dll)!=PM_PE_DLL_ATTACHED) goto cleanup;
    blocks+=2;
    if (!verify_client(&clients[0],&dll,&iat,&executed) || !pm_pe_unload(&clients[0])) goto cleanup;
    if (pm_pe_unload(&dll) || pm_pe_synthetic_dll_detach(&dll,error,sizeof error) || r32(data+0x38)!=1) goto cleanup;
    blocks+=2;
    if (!verify_client(&clients[1],&dll,&iat,&executed) || !pm_pe_unload(&clients[1])) goto cleanup;
    if (!pm_pe_synthetic_dll_detach(&dll,error,sizeof error) || r32(data+0x38)!=2 || r32(data+0x28)!=0 ||
        r64(data+0x20)!=(uintptr_t)dll.mapping || r64(data+0x30)) goto cleanup;
    notifications=2; passed=1;
cleanup:;
    int client0=pm_pe_unload(&clients[0]),client1=pm_pe_unload(&clients[1]);
    int detached=1;
    if (pm_pe_synthetic_dll_state(&dll)==PM_PE_DLL_ATTACHED)
        detached=pm_pe_synthetic_dll_detach(&dll,error,sizeof error);
    int removed=!registered || (client0 && client1 && detached && pm_pe_modules_remove(&registry,"probe_math.dll"));
    int unloaded=removed && pm_pe_unload(&dll);
    int cleaned=client0 && client1 && detached && removed && unloaded && !dll.mapping && !clients[0].mapping && !clients[1].mapping;
    passed=passed && cleaned;
    int translated=-1; size_t size=sizeof translated;
    if (sysctlbyname("sysctl.proc_translated",&translated,&size,NULL,0)) translated=-1;
    if (!passed) fprintf(stderr,"Synthetic dependency proof failed: %s\n",error);
    printf("{\"schemaVersion\":1,\"passed\":%s,\"clientExecutions\":%d,\"exactIATsVerified\":%d,"
        "\"heldUnloadAndDetachRefusals\":%d,\"actualDllNotifications\":%d,\"cleanupVerified\":%s,"
        "\"rosettaTranslated\":%s,\"rosettaStateKnown\":%s,\"externalPEAccepted\":false,"
        "\"windowsLoadLibraryImplemented\":false,\"gameExecuted\":false,\"wineUsed\":false,"
        "\"gpuWorkSubmitted\":false,\"supportDetermined\":false}\n",
        passed?"true":"false",executed,iat,blocks,notifications,cleaned?"true":"false",
        translated==1?"true":"false",translated>=0?"true":"false");
    return passed?0:1;
}
