/* Our own PE and owned output region only. No external binary or game input. */
#include "winapi_combined.h"
#include "duplicate_fixture.h"
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
/* Internal object/right observations are test-only, no public debug API. */
#include "winapi_events.c"
static pm_winapi_events *events;
static unsigned char *data,*output;
static size_t page;
static void *kernel_handle;
static unsigned checkpoints,failures;
static int dynamic_verified,seven_verified,shared_verified,closed_verified;
static uint64_t read_le(const void *pointer,size_t count) {
    const unsigned char *p=pointer; uint64_t value=0;
    for (size_t i=0;i<count;++i) value|=(uint64_t)p[i]<<(8*i);
    return value;
}
static void write64(void *pointer,uint64_t value) { memcpy(pointer,&value,8); }
static int32_t PM_WINAPI checkpoint(void) {
    unsigned phase=checkpoints++;
    int ok=phase<=2 && read_le(data+0x20,8)==(uintptr_t)&pm_win_DuplicateHandle &&
        read_le(data+0x28,8)==(uintptr_t)(output+5) && read_le(data+0x30,8)==(uintptr_t)kernel_handle;
    if (!ok) { ++failures; return 0; }
    void *source=(void *)(uintptr_t)read_le(data+0x40,8),*alias=(void *)(uintptr_t)read_le(data+0x48,8);
    if (phase==0) dynamic_verified=1;
    else if (phase==1) {
        ok=read_le(data+0x50,4)==1 && alias && alias!=source && read_le(output+5,8)==(uintptr_t)alias;
        if (pthread_mutex_lock(&events->mutex)==0) {
            sync_handle *a=find_handle(events,source),*b=find_handle(events,alias);
            if (!a || !b || a->object!=b->object || a->object->references!=2 ||
                a->access!=(PM_EVENT_MODIFY_STATE|PM_EVENT_SYNCHRONIZE) || b->access!=PM_EVENT_SYNCHRONIZE ||
                a->object->signaled || a->object->semaphore) ok=0;
            if (pthread_mutex_unlock(&events->mutex)!=0) ok=0;
        } else ok=0;
        if (ok) seven_verified=shared_verified=1;
    } else {
        ok=read_le(data+0x54,4)==0 && read_le(data+0x58,4)==5 && read_le(data+0x5C,4)==1 &&
            read_le(data+0x60,4)==PM_WAIT_OBJECT_0 && read_le(data+0x64,4)==PM_WAIT_TIMEOUT &&
            read_le(data+0x68,4)==1 && read_le(data+0x6C,4)==PM_WAIT_TIMEOUT &&
            read_le(data+0x70,4)==1 && read_le(data+0x74,4)==0 && read_le(data+0x78,4)==6;
        if (pthread_mutex_lock(&events->mutex)==0) {
            if (find_handle(events,source) || find_handle(events,alias)) ok=0;
            if (pthread_mutex_unlock(&events->mutex)!=0) ok=0;
        } else ok=0;
        if (ok) closed_verified=1;
    }
    for (size_t i=0;i<page;++i) if ((phase==0 || i<5 || i>=13) && output[i]!=0xa7) ok=0;
    if (!ok) ++failures;
    return ok;
}
static int imports(void *context,const char *dll,const char *name,uint16_t ordinal,int by_ordinal,uintptr_t *address) {
    (void)context; if (!address) return 0; *address=0;
    if (!by_ordinal && !ordinal && dll && name && !strcmp(dll,"playmelt_fixture.dll") && !strcmp(name,"DuplicateCheckpoint")) {
        *address=(uintptr_t)&checkpoint; return 1;
    }
    return pm_winapi_combined_resolve(NULL,dll,name,ordinal,by_ordinal,address);
}
typedef uint32_t (PM_WINAPI *entry_function)(void);
__attribute__((no_sanitize("function")))
static uint32_t call_fixture(entry_function entry) { return entry(); }
int main(int argc,char **argv) {
    if (argc!=2 || strcmp(argv[1],"--synthetic-duplicate-test")) return 2;
    char error[256]={0}; pm_pe_image image={0}; pm_pe_modules registry;
    pm_winapi_modules *mods=NULL; pm_winapi_memory *memory=NULL;
    int events_bound=0,modules_bound=0,memory_bound=0,passed=0,executed=0,iat=0,relocation=0;
    if (!pm_pe_modules_init(&registry,NULL,NULL)) goto cleanup;
    events=pm_winapi_events_create(); if (!events) goto cleanup;
    memory=pm_winapi_memory_create(error,sizeof error); if (!memory) goto cleanup;
    page=pm_winapi_memory_page_size(memory); size_t rounded; void *region=NULL;
    if (!pm_winapi_memory_allocate(memory,page,&region,&rounded) || rounded!=page) goto cleanup;
    output=region; memset(output,0xa7,page);
    if (!pm_pe_load(duplicate_fixture,sizeof duplicate_fixture,imports,NULL,&image,error,sizeof error)) goto cleanup;
    mods=pm_winapi_modules_create(&registry,&image,"duplicate.exe",error,sizeof error); if (!mods) goto cleanup;
    const char *hosts[]={"kernel32.dll","kernelbase.dll","ntdll.dll"};
    for (unsigned i=0;i<3;++i) if (!pm_winapi_modules_add_host(mods,hosts[i],pm_winapi_combined_resolve,NULL)) goto cleanup;
    data=(unsigned char *)image.mapping+0xc000; write64(data+0x28,(uintptr_t)(output+5));
    const uintptr_t expected[]={(uintptr_t)&pm_win_CreateEventExA,(uintptr_t)&pm_win_GetModuleHandleA,
        (uintptr_t)&pm_win_GetProcAddress,(uintptr_t)&pm_win_SetEvent,(uintptr_t)&pm_win_WaitForSingleObject,
        (uintptr_t)&pm_win_CloseHandle,(uintptr_t)&pm_win_GetLastError};
    iat=1;
    for (unsigned i=0;i<7;++i) if (read_le((unsigned char *)image.mapping+0x8180+8*i,8)!=expected[i]) iat=0;
    if (read_le((unsigned char *)image.mapping+0x81B8,8) ||
        read_le((unsigned char *)image.mapping+0x81E0,8)!=(uintptr_t)&checkpoint ||
        read_le((unsigned char *)image.mapping+0x81E8,8)) iat=0;
    relocation=read_le(data,8)==(uintptr_t)image.mapping+0xc008;
    if (!iat || !relocation) goto cleanup;
    modules_bound=pm_winapi_modules_bind(mods); if (!modules_bound) goto cleanup;
    memory_bound=pm_winapi_memory_bind(memory); if (!memory_bound) goto cleanup;
    events_bound=pm_winapi_events_bind(events); if (!events_bound) goto cleanup;
    kernel_handle=pm_win_GetModuleHandleA("kernel32.dll"); if (!kernel_handle) goto cleanup;
    uint32_t result=call_fixture((entry_function)((unsigned char *)image.mapping+image.entrypoint_rva)); executed=1;
    passed=!result && checkpoints==3 && !failures && dynamic_verified && seven_verified && shared_verified && closed_verified;
cleanup:;
    int event_unbound=!events_bound || pm_winapi_events_unbind();
    int memory_unbound=!memory_bound || pm_winapi_memory_unbind();
    int mods_unbound=!modules_bound || pm_winapi_modules_unbind();
    int mods_destroyed=mods_unbound && pm_winapi_modules_destroy(&mods);
    int event_destroyed=event_unbound && pm_winapi_events_destroy(&events);
    int memory_destroyed=memory_unbound && pm_winapi_memory_destroy(&memory);
    int unloaded=mods_destroyed && pm_pe_unload(&image);
    int cleaned=event_unbound && memory_unbound && mods_unbound && mods_destroyed && event_destroyed && memory_destroyed &&
        unloaded && !events && !memory && !mods && !image.mapping;
    passed=passed && cleaned;
    int translated=-1; size_t length=sizeof translated;
    if (sysctlbyname("sysctl.proc_translated",&translated,&length,NULL,0)) translated=-1;
    if (!passed) fprintf(stderr,"Synthetic duplicate proof failed: %s\n",error);
    printf("{\"schemaVersion\":1,\"passed\":%s,\"syntheticPEExecuted\":%s,\"exactStaticIATVerified\":%s,"
        "\"relocationVerified\":%s,\"dynamicAddressVerifiedBeforeCall\":%s,\"sevenArgumentDuplicateVerified\":%s,"
        "\"sharedObjectAndReducedRightsVerified\":%s,\"aliasSurvivedSourceClose\":%s,\"checkpoints\":%u,"
        "\"failures\":%u,\"cleanupVerified\":%s,\"rosettaTranslated\":%s,\"rosettaStateKnown\":%s,"
        "\"gameExecuted\":false,\"wineUsed\":false,\"gpuWorkSubmitted\":false,\"supportDetermined\":false}\n",
        passed?"true":"false",executed?"true":"false",iat?"true":"false",relocation?"true":"false",
        dynamic_verified?"true":"false",seven_verified?"true":"false",shared_verified?"true":"false",
        closed_verified?"true":"false",checkpoints,failures,cleaned?"true":"false",
        translated==1?"true":"false",translated>=0?"true":"false");
    return passed?0:1;
}
