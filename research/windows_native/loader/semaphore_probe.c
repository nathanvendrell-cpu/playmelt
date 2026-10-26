/* Only the embedded synthetic PE and controlled host pthread are executed. */
#include "winapi_combined.h"
#include "semaphore_fixture.h"
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>

static pthread_mutex_t gate=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_condition=PTHREAD_COND_INITIALIZER;
static int wait_entered,stop_worker;
static unsigned real_waits;
/* Test-only observer wraps, rather than replaces, the real Darwin wait. The
 * event mutex is still locked when notification is sent: the worker's ReleaseSemaphore
 * cannot acquire it until the actual cond-wait atomically releases it. */
static int observed_wait(pthread_cond_t *condition,pthread_mutex_t *mutex,const struct timespec *relative) {
    if (pthread_mutex_lock(&gate)!=0) return EINVAL;
    wait_entered=1;
    int error=pthread_cond_broadcast(&gate_condition);
    if (pthread_mutex_unlock(&gate)!=0 || error) return EINVAL;
    ++real_waits;
    return pthread_cond_timedwait_relative_np(condition,mutex,relative);
}
#define pthread_cond_timedwait_relative_np observed_wait
#include "winapi_events.c"
#undef pthread_cond_timedwait_relative_np

static pm_winapi_events *events;
static unsigned char *data;
static void *event_handle,*kernel_handle;
static pthread_t worker;
static int worker_created,worker_joined,worker_bound,worker_signaled,worker_unbound;
static unsigned checkpoints,failures;
static int addresses_verified,create_six_verified;
static uint64_t read_le(const void *pointer,size_t count) {
    const unsigned char *p=pointer; uint64_t value=0;
    for (size_t i=0;i<count;++i) value|=(uint64_t)p[i]<<(8*i);
    return value;
}
static void *notify_event(void *unused) {
    (void)unused;
    worker_bound=pm_winapi_events_bind(events);
    if (!worker_bound) return NULL;
    struct timespec deadline;
    int ready=clock_gettime(CLOCK_REALTIME,&deadline)==0;
    if (ready) deadline.tv_sec+=2;
    if (ready && pthread_mutex_lock(&gate)==0) {
        int error=0;
        while (!wait_entered && !stop_worker && !error)
            error=pthread_cond_timedwait(&gate_condition,&gate,&deadline);
        void *handle=event_handle;
        ready=!error && wait_entered && !stop_worker && handle;
        if (pthread_mutex_unlock(&gate)!=0) ready=0;
        if (ready) worker_signaled=pm_win_ReleaseSemaphore(handle,1,NULL);
    }
    worker_unbound=pm_winapi_events_unbind();
    return NULL;
}
static int join_worker(void) {
    if (!worker_created || worker_joined) return 1;
    if (pthread_join(worker,NULL)!=0) return 0;
    worker_joined=1; return 1;
}
static int32_t PM_WINAPI checkpoint(void) {
    unsigned phase=checkpoints++;
    int ok=phase<=2 && read_le(data+0x20,8)==(uintptr_t)&pm_win_ReleaseSemaphore &&
        read_le(data+0x28,8)==(uintptr_t)&pm_win_WaitForSingleObject &&
        read_le(data+0x30,8)==(uintptr_t)&pm_win_CloseHandle &&
        read_le(data+0x48,8)==(uintptr_t)kernel_handle && read_le(data+0x40,8)!=0;
    if (!ok) { ++failures; return 0; }
    if (phase==0) {
        ok=read_le(data+0x80,4)==0xacde3344;
        void *handle=(void *)(uintptr_t)read_le(data+0x40,8);
        /* Test-only internal observation of the actual created object. This is
         * not a public runtime/debug API. Flags/name/attributes were validated
         * by the real six-argument entry; verify count/max/access here too. */
        if (pthread_mutex_lock(&events->mutex)==0) {
            sync_handle *binding=find_handle(events,handle);
            event_slot *slot=binding?binding->object:NULL;
            if (!slot || !slot->semaphore || slot->count!=0 || slot->maximum!=2 ||
                binding->access!=(PM_EVENT_MODIFY_STATE|PM_EVENT_SYNCHRONIZE)) ok=0;
            if (pthread_mutex_unlock(&events->mutex)!=0) ok=0;
        } else ok=0;
        if (ok && pthread_mutex_lock(&gate)==0) {
            event_handle=handle;
            if (pthread_mutex_unlock(&gate)!=0) ok=0;
        } else ok=0;
        if (ok) { addresses_verified=1; create_six_verified=1; }
    } else if (phase==1) {
        ok=read_le(data+0x50,4)==PM_WAIT_OBJECT_0 && real_waits>=1 && join_worker() &&
            worker_bound && worker_signaled && worker_unbound;
    } else {
        ok=read_le(data+0x54,4)==1 && read_le(data+0x58,4)==PM_WAIT_OBJECT_0 &&
            read_le(data+0x5C,4)==PM_WAIT_OBJECT_0 && read_le(data+0x60,4)==PM_WAIT_TIMEOUT &&
            read_le(data+0x64,4)==0 && read_le(data+0x68,4)==298 &&
            read_le(data+0x6C,4)==PM_WAIT_TIMEOUT && read_le(data+0x70,4)==1 &&
            read_le(data+0x74,4)==PM_WAIT_FAILED && read_le(data+0x78,4)==PM_ERROR_INVALID_HANDLE &&
            read_le(data+0x7C,4)==0xacde3344;
    }
    if (!ok) ++failures;
    return ok;
}
static int imports(void *context,const char *dll,const char *name,uint16_t ordinal,int by_ordinal,uintptr_t *address) {
    (void)context; if (!address) return 0; *address=0;
    if (!by_ordinal && !ordinal && dll && name && !strcmp(dll,"playmelt_fixture.dll") && !strcmp(name,"SemaphoreCheckpoint")) {
        *address=(uintptr_t)&checkpoint; return 1;
    }
    return pm_winapi_combined_resolve(NULL,dll,name,ordinal,by_ordinal,address);
}
typedef uint32_t (PM_WINAPI *entry_function)(void);
/* Generated entry has no compiler type metadata; exemption is local only. */
__attribute__((no_sanitize("function")))
static uint32_t call_fixture(entry_function entry) { return entry(); }
int main(int argc,char **argv) {
    if (argc!=2 || strcmp(argv[1],"--synthetic-semaphore-test")) return 2;
    char error[256]={0}; pm_pe_image image={0}; pm_pe_modules registry; pm_winapi_modules *mods=NULL;
    int events_bound=0,modules_bound=0,passed=0,executed=0,iat=0,relocation=0;
    if (!pm_pe_modules_init(&registry,NULL,NULL)) goto cleanup;
    events=pm_winapi_events_create(); if (!events) goto cleanup;
    if (!pm_pe_load(semaphore_fixture,sizeof semaphore_fixture,imports,NULL,&image,error,sizeof error)) goto cleanup;
    mods=pm_winapi_modules_create(&registry,&image,"semaphore.exe",error,sizeof error); if (!mods) goto cleanup;
    const char *hosts[]={"kernel32.dll","kernelbase.dll","ntdll.dll"};
    for (unsigned i=0;i<3;++i) if (!pm_winapi_modules_add_host(mods,hosts[i],pm_winapi_combined_resolve,NULL)) goto cleanup;
    data=(unsigned char *)image.mapping+0xc000;
    const uintptr_t expected[]={(uintptr_t)&pm_win_CreateSemaphoreExA,(uintptr_t)&pm_win_GetModuleHandleA,
        (uintptr_t)&pm_win_GetProcAddress,(uintptr_t)&pm_win_SetLastError,(uintptr_t)&pm_win_GetLastError};
    iat=1;
    for (unsigned i=0;i<5;++i) if (read_le((unsigned char *)image.mapping+0x8180+8*i,8)!=expected[i]) iat=0;
    if (read_le((unsigned char *)image.mapping+0x81A8,8) ||
        read_le((unsigned char *)image.mapping+0x81C0,8)!=(uintptr_t)&checkpoint ||
        read_le((unsigned char *)image.mapping+0x81C8,8)) iat=0;
    relocation=read_le(data,8)==(uintptr_t)image.mapping+0xc008;
    if (!iat || !relocation) goto cleanup;
    modules_bound=pm_winapi_modules_bind(mods); if (!modules_bound) goto cleanup;
    events_bound=pm_winapi_events_bind(events); if (!events_bound) goto cleanup;
    kernel_handle=pm_win_GetModuleHandleA("kernel32.dll"); if (!kernel_handle) goto cleanup;
    if (pthread_create(&worker,NULL,notify_event,NULL)!=0) goto cleanup;
    worker_created=1;
    uint32_t result=call_fixture((entry_function)((unsigned char *)image.mapping+image.entrypoint_rva)); executed=1;
    passed=!result && checkpoints==3 && !failures && addresses_verified && worker_joined;
cleanup:;
    int stop_ok=pthread_mutex_lock(&gate)==0;
    if (stop_ok) {
        stop_worker=1; stop_ok=pthread_cond_broadcast(&gate_condition)==0;
        if (pthread_mutex_unlock(&gate)!=0) stop_ok=0;
    }
    int joined=join_worker();
    int event_unbound=!events_bound || pm_winapi_events_unbind();
    int mods_unbound=!modules_bound || pm_winapi_modules_unbind();
    int mods_destroyed=mods_unbound && pm_winapi_modules_destroy(&mods);
    int event_destroyed=joined && event_unbound && pm_winapi_events_destroy(&events);
    int unloaded=mods_destroyed && pm_pe_unload(&image);
    int gate_destroyed=joined && pthread_cond_destroy(&gate_condition)==0 && pthread_mutex_destroy(&gate)==0;
    int cleaned=stop_ok && joined && event_unbound && mods_unbound && mods_destroyed && event_destroyed && unloaded &&
        gate_destroyed && !events && !mods && !image.mapping;
    passed=passed && cleaned;
    int translated=-1; size_t length=sizeof translated;
    if (sysctlbyname("sysctl.proc_translated",&translated,&length,NULL,0)) translated=-1;
    if (!passed) fprintf(stderr,"Synthetic semaphore proof failed: %s\n",error);
    printf("{\"schemaVersion\":1,\"passed\":%s,\"syntheticPEExecuted\":%s,\"exactStaticIATVerified\":%s,"
        "\"relocationVerified\":%s,\"threeDynamicAddressesVerifiedBeforeCalls\":%s,\"fourSynchronizationAPIsCalledByPE\":%s,"
        "\"sixArgumentCreateVerified\":%s,\"realConditionWaits\":%u,\"hostThreadSignaled\":%s,\"hostThreadJoined\":%s,\"checkpoints\":%u,"
        "\"failures\":%u,\"cleanupVerified\":%s,\"rosettaTranslated\":%s,\"rosettaStateKnown\":%s,"
        "\"gameExecuted\":false,\"wineUsed\":false,\"gpuWorkSubmitted\":false,\"supportDetermined\":false}\n",
        passed?"true":"false",executed?"true":"false",iat?"true":"false",relocation?"true":"false",
        addresses_verified?"true":"false",passed?"true":"false",create_six_verified?"true":"false",real_waits,worker_signaled?"true":"false",
        worker_joined?"true":"false",checkpoints,failures,cleaned?"true":"false",
        translated==1?"true":"false",translated>=0?"true":"false");
    return passed?0:1;
}
