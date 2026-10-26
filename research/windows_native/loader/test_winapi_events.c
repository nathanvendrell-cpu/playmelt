/* CPU only. OS doubles wrap real condition variables, never a Windows process. */
#include "winapi_events.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static _Atomic unsigned checks;
#define CHECK(x) do { atomic_fetch_add(&checks,1); if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); abort(); } } while (0)
static int fail_init,fail_destroy,fail_broadcast,fail_wait,fail_clock,fail_setspec,fail_mutex_init;
static int fake_time,spurious;
static uint64_t fake_now;
static unsigned live_conditions,wait_calls;
static pthread_mutex_t gate=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_condition=PTHREAD_COND_INITIALIZER;
static unsigned entered,parked;
static _Thread_local int observed_entered,observed_parked;
static int hold_after;
static int wrapped_init(pthread_cond_t *condition,const pthread_condattr_t *attr) {
    if (fail_init) { --fail_init; return ENOMEM; }
    int result=pthread_cond_init(condition,attr); if (!result) ++live_conditions; return result;
}
static int wrapped_destroy(pthread_cond_t *condition) {
    if (fail_destroy) { --fail_destroy; return EBUSY; }
    int result=pthread_cond_destroy(condition); if (!result) --live_conditions; return result;
}
static int wrapped_broadcast(pthread_cond_t *condition) {
    if (fail_broadcast) { --fail_broadcast; CHECK(pthread_cond_broadcast(condition)==0); return EINVAL; }
    return pthread_cond_broadcast(condition);
}
static int wrapped_mutex_init(pthread_mutex_t *mutex,const pthread_mutexattr_t *attr) {
    if (fail_mutex_init) { --fail_mutex_init; return ENOMEM; }
    return pthread_mutex_init(mutex,attr);
}
static int wrapped_setspec(pthread_key_t key,const void *pointer) {
    if (fail_setspec) { --fail_setspec; return ENOMEM; }
    return pthread_setspecific(key,pointer);
}
static int wrapped_clock(clockid_t id,struct timespec *out) {
    if (fail_clock) { --fail_clock; return -1; }
    if (fake_time) { fake_now+=UINT64_C(11000000); out->tv_sec=(time_t)(fake_now/1000000000); out->tv_nsec=(long)(fake_now%1000000000); return 0; }
    return clock_gettime(id,out);
}
static int wrapped_wait(pthread_cond_t *condition,pthread_mutex_t *mutex,const struct timespec *timeout) {
    ++wait_calls;
    if (fail_wait) { --fail_wait; return EINVAL; }
    if (spurious) return 0;
    CHECK(pthread_mutex_lock(&gate)==0);
    if (!observed_entered) { ++entered; observed_entered=1; }
    CHECK(pthread_cond_broadcast(&gate_condition)==0); CHECK(pthread_mutex_unlock(&gate)==0);
    int result=pthread_cond_timedwait_relative_np(condition,mutex,timeout);
    CHECK(pthread_mutex_lock(&gate)==0);
    if (hold_after) {
        /* Deterministic test-only scheduling: temporarily release the event
         * mutex after the REAL wait returns, so Set+Reset can finish before
         * this waiter observes its predicate. Return still holds that mutex. */
        CHECK(pthread_mutex_unlock(mutex)==0);
        if (!observed_parked) { ++parked; observed_parked=1; }
        CHECK(pthread_cond_broadcast(&gate_condition)==0);
        while (hold_after) CHECK(pthread_cond_wait(&gate_condition,&gate)==0);
        CHECK(pthread_mutex_unlock(&gate)==0); CHECK(pthread_mutex_lock(mutex)==0);
    } else CHECK(pthread_mutex_unlock(&gate)==0);
    return result;
}
#define pthread_cond_init wrapped_init
#define pthread_cond_destroy wrapped_destroy
#define pthread_cond_broadcast wrapped_broadcast
#define pthread_cond_timedwait_relative_np wrapped_wait
#define pthread_mutex_init wrapped_mutex_init
#define pthread_setspecific wrapped_setspec
#define clock_gettime wrapped_clock
#include "winapi_events.c"
#undef pthread_cond_init
#undef pthread_cond_destroy
#undef pthread_cond_broadcast
#undef pthread_cond_timedwait_relative_np
#undef pthread_mutex_init
#undef pthread_setspecific
#undef clock_gettime
#define RIGHTS (PM_EVENT_MODIFY_STATE|PM_EVENT_SYNCHRONIZE)
static void *event(uint32_t flags,uint32_t rights) { void *h=pm_win_CreateEventExA(NULL,NULL,flags,rights); CHECK(h); return h; }
static void begin_gate(int hold) {
    CHECK(pthread_mutex_lock(&gate)==0); entered=parked=0; hold_after=hold; CHECK(pthread_mutex_unlock(&gate)==0);
}
static void await_count(unsigned *field,unsigned count) {
    struct timespec limit; CHECK(clock_gettime(CLOCK_REALTIME,&limit)==0); limit.tv_sec+=2;
    CHECK(pthread_mutex_lock(&gate)==0);
    while (*field<count) CHECK(pthread_cond_timedwait(&gate_condition,&gate,&limit)==0);
    CHECK(pthread_mutex_unlock(&gate)==0);
}
static void release_gate(void) {
    CHECK(pthread_mutex_lock(&gate)==0); hold_after=0;
    CHECK(pthread_cond_broadcast(&gate_condition)==0); CHECK(pthread_mutex_unlock(&gate)==0);
}
typedef struct waiter_args { pm_winapi_events *context; void *handle; uint32_t result,last; int cancel_test; } waiter_args;
static void *waiter(void *pointer) {
    waiter_args *arg=pointer; CHECK(pm_winapi_events_bind(arg->context));
    pm_win_SetLastError(456); arg->result=pm_win_WaitForSingleObject(arg->handle,100); arg->last=pm_win_GetLastError();
    if (arg->cancel_test) pthread_testcancel();
    CHECK(pm_winapi_events_unbind()); return NULL;
}
static void test_multi(pm_winapi_events *context,int manual,int second_set) {
    void *handle=event(manual?1:0,RIGHTS); begin_gate(1);
    waiter_args args[2]={{context,handle,999,0,0},{context,handle,999,0,0}}; pthread_t threads[2];
    for (unsigned i=0;i<2;++i) CHECK(pthread_create(&threads[i],NULL,waiter,&args[i])==0);
    await_count(&entered,2);
    CHECK(!pm_win_CloseHandle(handle) && pm_win_GetLastError()==170);
    CHECK(!pm_winapi_events_destroy(&context));
    CHECK(pm_win_SetEvent(handle)); await_count(&parked,2);
    CHECK(pm_win_ResetEvent(handle)); CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT);
    if (second_set) {
        CHECK(pm_win_SetEvent(handle)); CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT);
        CHECK(pm_win_SetEvent(handle)); /* No ungranted waiter remains: persistent signal. */
        CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_OBJECT_0);
        CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT);
    }
    release_gate();
    for (unsigned i=0;i<2;++i) { CHECK(pthread_join(threads[i],NULL)==0); CHECK(args[i].last==456); }
    unsigned successes=(args[0].result==0)+(args[1].result==0);
    CHECK(successes==(unsigned)((manual||second_set)?2:1));
    CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT); CHECK(pm_win_CloseHandle(handle));
}
static void test_basics(pm_winapi_events *context) {
    pm_win_SetLastError(123); void *auto_event=event(2,RIGHTS);
    CHECK(pm_win_GetLastError()==123); CHECK(pm_win_WaitForSingleObject(auto_event,0)==0);
    CHECK(pm_win_GetLastError()==123); CHECK(pm_win_WaitForSingleObject(auto_event,0)==PM_WAIT_TIMEOUT);
    CHECK(pm_win_SetEvent(auto_event)); CHECK(pm_win_SetEvent(auto_event));
    CHECK(pm_win_WaitForSingleObject(auto_event,0)==0); CHECK(pm_win_WaitForSingleObject(auto_event,0)==PM_WAIT_TIMEOUT);
    CHECK(pm_win_CloseHandle(auto_event)); CHECK(!pm_win_CloseHandle(auto_event) && pm_win_GetLastError()==6);
    void *fresh=event(3,RIGHTS); CHECK(fresh!=auto_event); CHECK(!pm_win_SetEvent(auto_event));
    CHECK(pm_win_WaitForSingleObject(fresh,0)==0); CHECK(pm_win_WaitForSingleObject(fresh,0)==0);
    CHECK(pm_win_ResetEvent(fresh)); CHECK(pm_win_WaitForSingleObject(fresh,0)==PM_WAIT_TIMEOUT);
    CHECK(!pm_win_CreateEventExA((void *)1,NULL,0,RIGHTS)); CHECK(!pm_win_CreateEventExA(NULL,(const char *)1,0,RIGHTS));
    uint32_t bad_flags[]={4,UINT32_MAX},bad_rights[]={0,1,0x1f0003,0x80000000};
    for (size_t i=0;i<2;++i) CHECK(!pm_win_CreateEventExA(NULL,NULL,bad_flags[i],RIGHTS) && pm_win_GetLastError()==87);
    for (size_t i=0;i<4;++i) CHECK(!pm_win_CreateEventExA(NULL,NULL,0,bad_rights[i]) && pm_win_GetLastError()==87);
    CHECK(pm_win_WaitForSingleObject(fresh,101)==PM_WAIT_FAILED && pm_win_GetLastError()==87);
    CHECK(pm_win_WaitForSingleObject(fresh,UINT32_MAX)==PM_WAIT_FAILED && pm_win_GetLastError()==87);
    CHECK(!pm_win_SetEvent(NULL)); CHECK(!pm_win_ResetEvent((void *)UINTPTR_MAX));
    CHECK(pm_win_WaitForSingleObject((void *)7,0)==PM_WAIT_FAILED && pm_win_GetLastError()==6);
    void *modify=event(0,PM_EVENT_MODIFY_STATE),*sync=event(2,PM_EVENT_SYNCHRONIZE);
    CHECK(pm_win_WaitForSingleObject(modify,0)==PM_WAIT_FAILED && pm_win_GetLastError()==5);
    CHECK(!pm_win_SetEvent(sync) && pm_win_GetLastError()==5); CHECK(!pm_win_ResetEvent(sync) && pm_win_GetLastError()==5);
    CHECK(pm_win_WaitForSingleObject(sync,0)==0); CHECK(pm_win_CloseHandle(sync)); CHECK(pm_win_CloseHandle(modify));
    CHECK(!pm_winapi_events_bind(context));
    fail_setspec=1; CHECK(!pm_winapi_events_unbind()); CHECK(context->bindings==1);
    CHECK(pm_win_CloseHandle(fresh));
    void *handles[PM_EVENTS_MAX_EVENTS];
    for (unsigned i=0;i<PM_EVENTS_MAX_EVENTS;++i) handles[i]=event(0,RIGHTS);
    CHECK(!pm_win_CreateEventExA(NULL,NULL,0,RIGHTS) && pm_win_GetLastError()==8);
    for (unsigned i=0;i<PM_EVENTS_MAX_EVENTS;++i) CHECK(pm_win_CloseHandle(handles[i]));
}
static void test_failures(pm_winapi_events *context) {
    fail_init=1; CHECK(!pm_win_CreateEventExA(NULL,NULL,0,RIGHTS) && pm_win_GetLastError()==31);
    void *handle=event(0,RIGHTS); fail_clock=1;
    CHECK(pm_win_WaitForSingleObject(handle,10)==PM_WAIT_FAILED && pm_win_GetLastError()==31);
    fail_wait=1; CHECK(pm_win_WaitForSingleObject(handle,10)==PM_WAIT_FAILED && pm_win_GetLastError()==31);
    CHECK(find_event(context,handle)->waiters==0);
    fake_time=spurious=1; fake_now=0; unsigned before=wait_calls; pm_win_SetLastError(789);
    CHECK(pm_win_WaitForSingleObject(handle,100)==PM_WAIT_TIMEOUT); CHECK(pm_win_GetLastError()==789);
    CHECK(wait_calls-before==9); fake_time=spurious=0;
    fail_destroy=1; CHECK(!pm_win_CloseHandle(handle) && pm_win_GetLastError()==31);
    CHECK(pm_win_SetEvent(handle)); CHECK(pm_win_WaitForSingleObject(handle,0)==0); CHECK(pm_win_CloseHandle(handle));
    /* Failed broadcast publishes no grant or persistent state. */
    handle=event(0,RIGHTS); begin_gate(1); waiter_args arg={context,handle,999,0,0}; pthread_t thread;
    CHECK(pthread_create(&thread,NULL,waiter,&arg)==0); await_count(&entered,1);
    fail_broadcast=1; CHECK(!pm_win_SetEvent(handle) && pm_win_GetLastError()==31);
    await_count(&parked,1);
    CHECK(pthread_mutex_lock(&context->mutex)==0);
    event_slot *slot=find_event(context,handle); CHECK(slot && !slot->signaled && slot->waiters==1);
    for (unsigned i=0;i<PM_EVENTS_MAX_BINDINGS;++i) CHECK(!slot->waiting[i].granted);
    CHECK(pthread_mutex_unlock(&context->mutex)==0);
    CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT);
    CHECK(pm_win_SetEvent(handle)); release_gate(); CHECK(pthread_join(thread,NULL)==0); CHECK(arg.result==0); CHECK(pm_win_CloseHandle(handle));
}
static void *bind_and_exit(void *pointer) { CHECK(pm_winapi_events_bind(pointer)); return NULL; }
static void *wrong_destroy(void *pointer) { pm_winapi_events *c=pointer; CHECK(!pm_winapi_events_destroy(&c) && c==pointer); return NULL; }
static void test_lifecycle(pm_winapi_events *context) {
    void *handle=event(0,RIGHTS); CHECK(pm_winapi_events_unbind());
    CHECK(!pm_win_SetEvent(handle) && pm_win_GetLastError()==6);
    CHECK(!pm_win_CreateEventExA(NULL,NULL,0,RIGHTS));
    pm_winapi_events *other=pm_winapi_events_create(); CHECK(other); CHECK(pm_winapi_events_bind(other));
    CHECK(!pm_win_CloseHandle(handle) && pm_win_GetLastError()==6); CHECK(pm_winapi_events_unbind());
    CHECK(pm_winapi_events_destroy(&other)); CHECK(pm_winapi_events_bind(context));
    pthread_t thread; CHECK(pthread_create(&thread,NULL,bind_and_exit,context)==0); CHECK(pthread_join(thread,NULL)==0);
    CHECK(context->bindings==1); CHECK(pthread_create(&thread,NULL,wrong_destroy,context)==0); CHECK(pthread_join(thread,NULL)==0);
    begin_gate(0); waiter_args arg={context,handle,999,0,1}; CHECK(pthread_create(&thread,NULL,waiter,&arg)==0);
    await_count(&entered,1); CHECK(pthread_cancel(thread)==0); CHECK(pm_win_SetEvent(handle));
    void *result=NULL; CHECK(pthread_join(thread,&result)==0 && result==PTHREAD_CANCELED);
    CHECK(context->bindings==1 && find_event(context,handle)->waiters==0); CHECK(pm_win_CloseHandle(handle));
    CHECK(pm_winapi_events_unbind()); fail_setspec=1; CHECK(!pm_winapi_events_bind(context) && context->bindings==0);
    CHECK(pm_winapi_events_bind(context));
}
static void *binding_hold(void *pointer) {
    CHECK(pm_winapi_events_bind(pointer)); CHECK(pthread_mutex_lock(&gate)==0); ++entered;
    CHECK(pthread_cond_broadcast(&gate_condition)==0);
    struct timespec limit; CHECK(clock_gettime(CLOCK_REALTIME,&limit)==0); limit.tv_sec+=2;
    while (hold_after) CHECK(pthread_cond_timedwait(&gate_condition,&gate,&limit)==0);
    CHECK(pthread_mutex_unlock(&gate)==0); return NULL; /* TLS destructor unbinds. */
}
static void *binding_rejected(void *pointer) { CHECK(!pm_winapi_events_bind(pointer)); return NULL; }
static void test_binding_capacity(pm_winapi_events *context) {
    begin_gate(1); pthread_t threads[PM_EVENTS_MAX_BINDINGS-1],extra;
    for (unsigned i=0;i<PM_EVENTS_MAX_BINDINGS-1;++i) CHECK(pthread_create(&threads[i],NULL,binding_hold,context)==0);
    await_count(&entered,PM_EVENTS_MAX_BINDINGS-1);
    CHECK(pthread_create(&extra,NULL,binding_rejected,context)==0); CHECK(pthread_join(extra,NULL)==0);
    CHECK(!pm_winapi_events_destroy(&context)); release_gate();
    for (unsigned i=0;i<PM_EVENTS_MAX_BINDINGS-1;++i) CHECK(pthread_join(threads[i],NULL)==0);
    CHECK(context->bindings==1);
}
static void test_resolver(void) {
    struct { const char *name; uintptr_t address; } services[]={
#define S(n) {#n,(uintptr_t)&pm_win_##n}
        S(CreateEventExA),S(SetEvent),S(ResetEvent),S(WaitForSingleObject),S(CloseHandle)
#undef S
    };
    for (size_t i=0;i<5;++i) {
        uintptr_t address=99; CHECK(pm_winapi_events_resolve(NULL,"KeRnElBaSe.DLL",services[i].name,0,0,&address) && address==services[i].address);
        CHECK(!pm_winapi_events_resolve(NULL,"ntdll.dll",services[i].name,0,0,&address) && !address);
        CHECK(!pm_winapi_events_resolve(NULL,"kernel32.dll",services[i].name,1,0,&address) && !address);
        CHECK(!pm_winapi_events_resolve(NULL,"kernel32.dll",services[i].name,0,1,&address) && !address);
    }
    uintptr_t address=99; CHECK(!pm_winapi_events_resolve(NULL,"kernel32.dll","CreateEventExW",0,0,&address) && !address);
    CHECK(!pm_winapi_events_resolve(NULL,"kernel32.dll","setEvent",0,0,&address) && !address);
    CHECK(pm_winapi_events_resolve(NULL,"kernel32.dll","GetLastError",0,0,&address) && address==(uintptr_t)&pm_win_GetLastError);
}
int main(void) {
    test_resolver(); fail_mutex_init=1; CHECK(!pm_winapi_events_create());
    pm_winapi_events *context=pm_winapi_events_create(); CHECK(context && pm_winapi_events_bind(context));
    test_basics(context); test_failures(context); test_binding_capacity(context); test_multi(context,0,0); test_multi(context,0,1); test_multi(context,1,0); test_lifecycle(context);
    void *remaining=event(0,RIGHTS); (void)remaining; CHECK(pm_winapi_events_unbind());
    fail_destroy=1; CHECK(!pm_winapi_events_destroy(&context) && context && context->closing);
    CHECK(!pm_winapi_events_bind(context)); CHECK(pm_winapi_events_destroy(&context) && !context);
    CHECK(!pm_winapi_events_destroy(NULL)); CHECK(pm_winapi_events_destroy(&context));
    context=pm_winapi_events_create(); CHECK(context && pm_winapi_events_bind(context));
    atomic_store(&next_token,UINTPTR_MAX); CHECK(!pm_win_CreateEventExA(NULL,NULL,0,RIGHTS) && pm_win_GetLastError()==8);
    CHECK(pm_winapi_events_unbind()); CHECK(pm_winapi_events_destroy(&context)); CHECK(!live_conditions);
    CHECK(pthread_cond_destroy(&gate_condition)==0); CHECK(pthread_mutex_destroy(&gate)==0);
    printf("PASS: %u event checks; real condvars, grants, finite waits, cancellation, fault cleanup; liveConditions=0\n",atomic_load(&checks));
    return 0;
}
