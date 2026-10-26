#include "winapi_events.h"
#include "winapi_memory.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Primary contracts consulted 2026-10-26:
 * https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createeventexa
 * https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setevent
 * https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-resetevent
 * https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject
 * https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-closehandle
 * https://learn.microsoft.com/en-us/windows/win32/sync/synchronization-object-security-and-access-rights
 * https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createsemaphoreexa
 * https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-releasesemaphore
 * Darwin relative cond-wait avoids realtime clock jumps; each retry derives its
 * interval from the SAME monotone deadline, never from the original duration.
 */
typedef struct event_slot {
    pthread_cond_t condition;
    unsigned references,waiters;
    struct { int active,granted; } waiting[PM_EVENTS_MAX_BINDINGS];
    int manual,signaled,semaphore;
    int32_t count,maximum;
} event_slot;
typedef struct sync_handle {
    uintptr_t token;
    event_slot *object;
    uint32_t access;
    unsigned waiters;
} sync_handle;
struct pm_winapi_events {
    pthread_mutex_t mutex;
    pthread_t owner;
    unsigned bindings;
    int closing;
    event_slot slots[PM_EVENTS_MAX_EVENTS];
    sync_handle handles[PM_EVENTS_MAX_HANDLES];
};
static pthread_key_t events_key;
static pthread_once_t events_once=PTHREAD_ONCE_INIT;
static int events_key_error;
static _Atomic(uintptr_t) next_token=UINT64_C(0x504d450000000001);

static int disable_cancel(int *previous) {
    return pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,previous)==0;
}
static void restore_cancel(int previous) { (void)pthread_setcancelstate(previous,NULL); }
static void release_binding(void *pointer) {
    pm_winapi_events *context=pointer;
    if (!context) return;
    if (pthread_mutex_lock(&context->mutex)!=0) return;
    if (context->bindings) --context->bindings;
    (void)pthread_mutex_unlock(&context->mutex);
}
static void initialize_key(void) { events_key_error=pthread_key_create(&events_key,release_binding); }
static int key_ready(void) { return pthread_once(&events_once,initialize_key)==0 && !events_key_error; }
static pm_winapi_events *current(void) { return key_ready()?pthread_getspecific(events_key):NULL; }

pm_winapi_events *pm_winapi_events_create(void) {
    if (!key_ready()) return NULL;
    pm_winapi_events *context=calloc(1,sizeof *context);
    if (!context) return NULL;
    if (pthread_mutex_init(&context->mutex,NULL)!=0) { free(context); return NULL; }
    context->owner=pthread_self();
    return context;
}
int pm_winapi_events_bind(pm_winapi_events *context) {
    int previous;
    if (!context || !key_ready() || pthread_getspecific(events_key) || !disable_cancel(&previous)) return 0;
    int ok=0;
    if (pthread_mutex_lock(&context->mutex)==0) {
        if (!context->closing && context->bindings<PM_EVENTS_MAX_BINDINGS && pthread_setspecific(events_key,context)==0) {
            ++context->bindings; ok=1;
        }
        (void)pthread_mutex_unlock(&context->mutex);
    }
    restore_cancel(previous); return ok;
}
int pm_winapi_events_unbind(void) {
    int previous; pm_winapi_events *context=current();
    if (!context || !disable_cancel(&previous)) return 0;
    int ok=0;
    if (pthread_mutex_lock(&context->mutex)==0) {
        if (pthread_setspecific(events_key,NULL)==0) { --context->bindings; ok=1; }
        (void)pthread_mutex_unlock(&context->mutex);
    }
    restore_cancel(previous); return ok;
}
int pm_winapi_events_destroy(pm_winapi_events **pointer) {
    if (!pointer) return 0;
    pm_winapi_events *context=*pointer;
    if (!context) return 1;
    int previous;
    if (!pthread_equal(context->owner,pthread_self()) || !disable_cancel(&previous)) return 0;
    int ok=1;
    if (pthread_mutex_lock(&context->mutex)!=0) { restore_cancel(previous); return 0; }
    if (context->bindings) ok=0;
    else context->closing=1;
    for (size_t i=0;ok && i<PM_EVENTS_MAX_EVENTS;++i) {
        event_slot *slot=&context->slots[i];
        if (!slot->references) continue;
        if (slot->waiters || pthread_cond_destroy(&slot->condition)!=0) { ok=0; break; }
        for (size_t h=0;h<PM_EVENTS_MAX_HANDLES;++h)
            if (context->handles[h].object==slot) memset(&context->handles[h],0,sizeof context->handles[h]);
        memset(slot,0,sizeof *slot);
    }
    (void)pthread_mutex_unlock(&context->mutex);
    if (ok && pthread_mutex_destroy(&context->mutex)!=0) ok=0;
    if (ok) { free(context); *pointer=NULL; }
    restore_cancel(previous); return ok;
}
static uintptr_t issue_token(void) {
    uintptr_t value=atomic_load_explicit(&next_token,memory_order_relaxed);
    while (value<UINTPTR_MAX) {
        if (atomic_compare_exchange_weak_explicit(&next_token,&value,value+1,
            memory_order_relaxed,memory_order_relaxed)) return value;
    }
    return 0;
}
static sync_handle *find_handle(pm_winapi_events *context,void *handle) {
    uintptr_t token=(uintptr_t)handle;
    if (!token) return NULL;
    for (size_t i=0;i<PM_EVENTS_MAX_HANDLES;++i)
        if (context->handles[i].token==token) return &context->handles[i];
    return NULL;
}
static sync_handle *free_handle(pm_winapi_events *context) {
    for (size_t i=0;i<PM_EVENTS_MAX_HANDLES;++i)
        if (!context->handles[i].token) return &context->handles[i];
    return NULL;
}
static pm_winapi_events *enter(int *previous) {
    pm_winapi_events *context=current();
    if (!context) { pm_win_SetLastError(PM_ERROR_INVALID_HANDLE); return NULL; }
    if (!disable_cancel(previous)) { pm_win_SetLastError(PM_ERROR_GEN_FAILURE); return NULL; }
    if (pthread_mutex_lock(&context->mutex)!=0) {
        restore_cancel(*previous); pm_win_SetLastError(PM_ERROR_GEN_FAILURE); return NULL;
    }
    return context;
}
static void leave(pm_winapi_events *context,int previous) {
    (void)pthread_mutex_unlock(&context->mutex); restore_cancel(previous);
}
void *PM_WINAPI pm_win_CreateEventExA(void *attributes,const char *name,uint32_t flags,uint32_t access) {
    if (attributes || name || (flags&~3u) || !access || (access&~(PM_EVENT_MODIFY_STATE|PM_EVENT_SYNCHRONIZE))) {
        pm_win_SetLastError(PM_ERROR_INVALID_PARAMETER); return NULL;
    }
    int previous; pm_winapi_events *context=enter(&previous);
    if (!context) return NULL;
    event_slot *slot=NULL;
    for (size_t i=0;i<PM_EVENTS_MAX_EVENTS;++i) if (!context->slots[i].references) { slot=&context->slots[i]; break; }
    sync_handle *entry=free_handle(context);
    uintptr_t token=slot && entry?issue_token():0;
    if (!token) pm_win_SetLastError(8);
    else if (pthread_cond_init(&slot->condition,NULL)!=0) { pm_win_SetLastError(PM_ERROR_GEN_FAILURE); token=0; }
    else {
        slot->references=1; *entry=(sync_handle){.token=token,.object=slot,.access=access}; slot->manual=(flags&1)!=0;
        slot->signaled=(flags&2)!=0; slot->waiters=0; slot->semaphore=0;
    }
    leave(context,previous); return (void *)token;
}
void *PM_WINAPI pm_win_CreateSemaphoreExA(void *attributes,int32_t initial_count,int32_t maximum_count,
    const char *name,uint32_t flags,uint32_t access) {
    if (attributes || name || flags || initial_count<0 || maximum_count<=0 || initial_count>maximum_count ||
        !access || (access&~(PM_EVENT_MODIFY_STATE|PM_EVENT_SYNCHRONIZE))) {
        pm_win_SetLastError(PM_ERROR_INVALID_PARAMETER); return NULL;
    }
    int previous; pm_winapi_events *context=enter(&previous);
    if (!context) return NULL;
    event_slot *slot=NULL;
    for (size_t i=0;i<PM_EVENTS_MAX_EVENTS;++i) if (!context->slots[i].references) { slot=&context->slots[i]; break; }
    sync_handle *entry=free_handle(context);
    uintptr_t token=slot && entry?issue_token():0;
    if (!token) pm_win_SetLastError(8);
    else if (pthread_cond_init(&slot->condition,NULL)!=0) { pm_win_SetLastError(PM_ERROR_GEN_FAILURE); token=0; }
    else {
        slot->references=1; *entry=(sync_handle){.token=token,.object=slot,.access=access}; slot->semaphore=1;
        slot->count=initial_count; slot->maximum=maximum_count; slot->waiters=0;
    }
    leave(context,previous); return (void *)token;
}
int32_t PM_WINAPI pm_win_ReleaseSemaphore(void *handle,int32_t release_count,void *previous_count) {
    /* Do not touch a caller-provided pointer: this subset accepts NULL only. */
    if (previous_count || release_count<=0) { pm_win_SetLastError(PM_ERROR_INVALID_PARAMETER); return 0; }
    int previous; pm_winapi_events *context=enter(&previous);
    if (!context) return 0;
    int32_t ok=0; sync_handle *entry=find_handle(context,handle);
    event_slot *slot=entry?entry->object:NULL;
    if (!slot || !slot->semaphore) pm_win_SetLastError(PM_ERROR_INVALID_HANDLE);
    else if (!(entry->access&PM_EVENT_MODIFY_STATE)) pm_win_SetLastError(5);
    /* This check precedes grant distribution: pending waits cannot legitimize
     * an increment that would exceed the semaphore's current maximum. */
    else if (release_count>slot->maximum-slot->count) pm_win_SetLastError(298);
    else {
        int eligible=0;
        for (size_t i=0;i<PM_EVENTS_MAX_BINDINGS;++i)
            if (slot->waiting[i].active && !slot->waiting[i].granted) { eligible=1; break; }
        if (eligible && pthread_cond_broadcast(&slot->condition)!=0) pm_win_SetLastError(PM_ERROR_GEN_FAILURE);
        else {
            int32_t available=slot->count+release_count; /* proven <= maximum <= INT32_MAX */
            for (size_t i=0;available>0 && i<PM_EVENTS_MAX_BINDINGS;++i)
                if (slot->waiting[i].active && !slot->waiting[i].granted) {
                    slot->waiting[i].granted=1; --available;
                }
            slot->count=available; ok=1;
        }
    }
    leave(context,previous); return ok;
}
static int32_t change_event(void *handle,int set) {
    int previous; pm_winapi_events *context=enter(&previous);
    if (!context) return 0;
    int32_t ok=0; sync_handle *entry=find_handle(context,handle);
    event_slot *slot=entry?entry->object:NULL;
    if (!slot || slot->semaphore) pm_win_SetLastError(PM_ERROR_INVALID_HANDLE);
    else if (!(entry->access&PM_EVENT_MODIFY_STATE)) pm_win_SetLastError(5);
    else if (!set) { slot->signaled=0; ok=1; }
    else if (slot->signaled) ok=1;
    else {
        size_t eligible=PM_EVENTS_MAX_BINDINGS;
        for (size_t i=0;i<PM_EVENTS_MAX_BINDINGS;++i)
            if (slot->waiting[i].active && !slot->waiting[i].granted) { eligible=i; break; }
        /* Broadcast, not signal: a shared condvar could otherwise wake a waiter
         * already granted rather than the newly selected consumer. Wake first
         * under the mutex; publish grants only after the OS reports success. */
        if (eligible!=PM_EVENTS_MAX_BINDINGS && pthread_cond_broadcast(&slot->condition)!=0)
            pm_win_SetLastError(PM_ERROR_GEN_FAILURE);
        else {
            if (slot->manual) {
                for (size_t i=0;i<PM_EVENTS_MAX_BINDINGS;++i)
                    if (slot->waiting[i].active) slot->waiting[i].granted=1;
                slot->signaled=1;
            } else if (eligible!=PM_EVENTS_MAX_BINDINGS) slot->waiting[eligible].granted=1;
            else slot->signaled=1;
            ok=1;
        }
    }
    leave(context,previous); return ok;
}
int32_t PM_WINAPI pm_win_SetEvent(void *handle) { return change_event(handle,1); }
int32_t PM_WINAPI pm_win_ResetEvent(void *handle) { return change_event(handle,0); }
static int monotone_ns(uint64_t *value) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC,&now)!=0 || now.tv_sec<0 || now.tv_nsec<0 || now.tv_nsec>=1000000000 ||
        (uint64_t)now.tv_sec>(UINT64_MAX-(uint64_t)now.tv_nsec)/UINT64_C(1000000000)) return 0;
    *value=(uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec; return 1;
}
uint32_t PM_WINAPI pm_win_WaitForSingleObject(void *handle,uint32_t milliseconds) {
    if (milliseconds>PM_EVENTS_MAX_WAIT_MS) { pm_win_SetLastError(PM_ERROR_INVALID_PARAMETER); return PM_WAIT_FAILED; }
    int previous; pm_winapi_events *context=enter(&previous);
    if (!context) return PM_WAIT_FAILED;
    uint32_t result=PM_WAIT_FAILED; sync_handle *entry=find_handle(context,handle);
    event_slot *slot=entry?entry->object:NULL;
    if (!slot) pm_win_SetLastError(PM_ERROR_INVALID_HANDLE);
    else if (!(entry->access&PM_EVENT_SYNCHRONIZE)) pm_win_SetLastError(5);
    else if (slot->semaphore?slot->count>0:slot->signaled) {
        if (slot->semaphore) --slot->count; else if (!slot->manual) slot->signaled=0;
        result=PM_WAIT_OBJECT_0;
    }
    else if (!milliseconds) result=PM_WAIT_TIMEOUT;
    else {
        uint64_t now,deadline,interval=(uint64_t)milliseconds*UINT64_C(1000000);
        if (!monotone_ns(&now) || now>UINT64_MAX-interval) pm_win_SetLastError(PM_ERROR_GEN_FAILURE);
        else {
            size_t waiter=0;
            while (waiter<PM_EVENTS_MAX_BINDINGS && slot->waiting[waiter].active) ++waiter;
            /* One synchronous call per bound thread makes this bound sufficient.
             * Fail explicitly even if a host violation somehow exhausts it. */
            if (waiter==PM_EVENTS_MAX_BINDINGS) {
                pm_win_SetLastError(8); leave(context,previous); return PM_WAIT_FAILED;
            }
            deadline=now+interval; ++slot->waiters; ++entry->waiters;
            slot->waiting[waiter].active=1; slot->waiting[waiter].granted=0;
            for (;;) {
                if (slot->waiting[waiter].granted) { result=PM_WAIT_OBJECT_0; break; }
                if (!monotone_ns(&now)) { pm_win_SetLastError(PM_ERROR_GEN_FAILURE); break; }
                if (now>=deadline) { result=PM_WAIT_TIMEOUT; break; }
                uint64_t remaining=deadline-now;
                struct timespec relative={(time_t)(remaining/UINT64_C(1000000000)),(long)(remaining%UINT64_C(1000000000))};
                int error=pthread_cond_timedwait_relative_np(&slot->condition,&context->mutex,&relative);
                if (error!=0 && error!=ETIMEDOUT) { pm_win_SetLastError(PM_ERROR_GEN_FAILURE); break; }
                /* ETIMEDOUT still rechecks the predicate under the reacquired
                 * mutex: a concurrent Set can have won the deadline race. */
            }
            memset(&slot->waiting[waiter],0,sizeof slot->waiting[waiter]);
            --slot->waiters; --entry->waiters;
        }
    }
    leave(context,previous); return result;
}
int32_t PM_WINAPI pm_win_CloseHandle(void *handle) {
    int previous; pm_winapi_events *context=enter(&previous);
    if (!context) return 0;
    int32_t ok=0; sync_handle *entry=find_handle(context,handle);
    event_slot *slot=entry?entry->object:NULL;
    if (!slot) pm_win_SetLastError(PM_ERROR_INVALID_HANDLE);
    else if (entry->waiters) pm_win_SetLastError(170);
    else if (slot->references>1) {
        --slot->references; memset(entry,0,sizeof *entry); ok=1;
    } else if (slot->waiters) pm_win_SetLastError(170);
    else if (pthread_cond_destroy(&slot->condition)!=0) pm_win_SetLastError(PM_ERROR_GEN_FAILURE);
    else { memset(slot,0,sizeof *slot); memset(entry,0,sizeof *entry); ok=1; }
    leave(context,previous); return ok;
}
int32_t PM_WINAPI pm_win_DuplicateHandle(void *source_process,void *source_handle,
    void *target_process,void *target_handle,uint32_t desired_access,int32_t inherit,uint32_t options) {
    if ((uintptr_t)source_process!=UINTPTR_MAX || (uintptr_t)target_process!=UINTPTR_MAX) {
        pm_win_SetLastError(PM_ERROR_INVALID_HANDLE); return 0;
    }
    /* CLOSE_SOURCE is deliberately unsupported: never close on any error. */
    if (inherit || (options!=0 && options!=PM_DUPLICATE_SAME_ACCESS)) {
        pm_win_SetLastError(PM_ERROR_INVALID_PARAMETER); return 0;
    }
    int previous; pm_winapi_events *context=enter(&previous);
    if (!context) return 0;
    int32_t ok=0; sync_handle *source=find_handle(context,source_handle);
    sync_handle *target=free_handle(context);
    uint32_t access=options==PM_DUPLICATE_SAME_ACCESS && source?source->access:desired_access;
    if (!source) pm_win_SetLastError(PM_ERROR_INVALID_HANDLE);
    else if (access&~(PM_EVENT_MODIFY_STATE|PM_EVENT_SYNCHRONIZE)) pm_win_SetLastError(PM_ERROR_INVALID_PARAMETER);
    else if (access&~source->access) pm_win_SetLastError(5);
    else if (!pm_winapi_memory_can_write_handle(target_handle)) pm_win_SetLastError(998);
    else if (!target) pm_win_SetLastError(8);
    else {
        uintptr_t token=issue_token();
        if (!token) pm_win_SetLastError(8);
        else if (!pm_winapi_memory_write_handle(target_handle,token)) pm_win_SetLastError(998);
        else {
            /* Output is validated/written while the sync mutex is held. The
             * bound memory context is exclusive to this thread; no callback or
             * cancellation point can mutate it here. No fallible operation
             * remains between publication of output and this handle entry. */
            *target=(sync_handle){.token=token,.object=source->object,.access=access};
            ++source->object->references; ok=1;
        }
    }
    leave(context,previous); return ok;
}
static int module_is(const char *input,const char *expected) {
    if (!input) return 0;
    for (size_t i=0;;++i) {
        unsigned char a=(unsigned char)input[i],b=(unsigned char)expected[i];
        if (a>='A' && a<='Z') a=(unsigned char)(a+'a'-'A');
        if (a!=b) return 0;
        if (!b) return 1;
    }
}
int pm_winapi_events_resolve(void *context,const char *dll,const char *name,uint16_t ordinal,int by_ordinal,uintptr_t *address) {
    if (!address) return 0;
    *address=0;
    if (ordinal || by_ordinal || !name || (!module_is(dll,"kernel32.dll") && !module_is(dll,"kernelbase.dll"))) return 0;
#define RESOLVE(symbol) if (!strcmp(name,#symbol)) { *address=(uintptr_t)&pm_win_##symbol; return 1; }
    RESOLVE(DuplicateHandle) RESOLVE(CreateSemaphoreExA) RESOLVE(ReleaseSemaphore)
    RESOLVE(CreateEventExA) RESOLVE(SetEvent) RESOLVE(ResetEvent) RESOLVE(WaitForSingleObject) RESOLVE(CloseHandle)
#undef RESOLVE
    return pm_winapi_resolve(context,dll,name,ordinal,by_ordinal,address);
}
