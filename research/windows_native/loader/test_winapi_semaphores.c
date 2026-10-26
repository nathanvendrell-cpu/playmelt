/* Reuse the existing test-only OS wrappers/gates. Its renamed main is NOT run
 * here; the runner executes the events regression as a separate executable. */
#define main event_regression_not_invoked
#include "test_winapi_events.c"
#undef main
#include <limits.h>

static void *semaphore(int32_t initial,int32_t maximum,uint32_t access) {
    void *handle=pm_win_CreateSemaphoreExA(NULL,initial,maximum,NULL,0,access); CHECK(handle); return handle;
}
static void no_grants(pm_winapi_events *context,void *handle,unsigned waiters) {
    CHECK(pthread_mutex_lock(&context->mutex)==0);
    event_slot *slot=find_event(context,handle); CHECK(slot && slot->semaphore && slot->count==0 && slot->waiters==waiters);
    for (unsigned i=0;i<PM_EVENTS_MAX_BINDINGS;++i) CHECK(!slot->waiting[i].granted);
    CHECK(pthread_mutex_unlock(&context->mutex)==0);
}
static void semaphore_basics(pm_winapi_events *context) {
    pm_win_SetLastError(1234); void *handle=semaphore(2,3,RIGHTS);
    CHECK(pm_win_GetLastError()==1234); CHECK(pm_win_WaitForSingleObject(handle,0)==0);
    CHECK(pm_win_WaitForSingleObject(handle,0)==0); CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT);
    CHECK(pm_win_ReleaseSemaphore(handle,3,NULL)); CHECK(pm_win_GetLastError()==1234);
    CHECK(pm_win_WaitForSingleObject(handle,0)==0); CHECK(find_event(context,handle)->count==2);
    CHECK(!pm_win_ReleaseSemaphore(handle,2,NULL) && pm_win_GetLastError()==298); CHECK(find_event(context,handle)->count==2);
    CHECK(pm_win_ReleaseSemaphore(handle,1,NULL)); CHECK(find_event(context,handle)->count==3);
    CHECK(!pm_win_SetEvent(handle) && pm_win_GetLastError()==6); CHECK(!pm_win_ResetEvent(handle) && pm_win_GetLastError()==6);
    CHECK(find_event(context,handle)->count==3); CHECK(pm_win_CloseHandle(handle));
    CHECK(!pm_win_ReleaseSemaphore(handle,1,NULL) && pm_win_GetLastError()==6);
    void *fresh=semaphore(0,2,RIGHTS); CHECK(fresh!=handle); CHECK(!pm_win_ReleaseSemaphore(handle,1,NULL));
    uint32_t canary=0xfacecafe;
    CHECK(!pm_win_ReleaseSemaphore(fresh,1,&canary) && pm_win_GetLastError()==87);
    CHECK(canary==0xfacecafe && find_event(context,fresh)->count==0);
    CHECK(!pm_win_ReleaseSemaphore(fresh,1,(void *)1) && pm_win_GetLastError()==87);
    CHECK(pm_win_WaitForSingleObject(fresh,0)==PM_WAIT_TIMEOUT);
    const int32_t invalid_counts[]={0,-1,INT32_MIN};
    for (unsigned i=0;i<3;++i) CHECK(!pm_win_ReleaseSemaphore(fresh,invalid_counts[i],NULL) && pm_win_GetLastError()==87);
    CHECK(pm_win_WaitForSingleObject(fresh,101)==PM_WAIT_FAILED && pm_win_GetLastError()==87);
    CHECK(pm_win_WaitForSingleObject(fresh,UINT32_MAX)==PM_WAIT_FAILED && pm_win_GetLastError()==87);
    CHECK(pm_win_CloseHandle(fresh));
    void *event_handle=event(0,RIGHTS); CHECK(!pm_win_ReleaseSemaphore(event_handle,1,NULL) && pm_win_GetLastError()==6);
    CHECK(pm_win_WaitForSingleObject(event_handle,0)==PM_WAIT_TIMEOUT); CHECK(pm_win_CloseHandle(event_handle));
    void *modify=semaphore(0,1,PM_EVENT_MODIFY_STATE),*sync=semaphore(1,1,PM_EVENT_SYNCHRONIZE);
    CHECK(pm_win_WaitForSingleObject(modify,0)==PM_WAIT_FAILED && pm_win_GetLastError()==5);
    CHECK(pm_win_ReleaseSemaphore(modify,1,NULL)); CHECK(!pm_win_ReleaseSemaphore(sync,1,NULL) && pm_win_GetLastError()==5);
    CHECK(pm_win_WaitForSingleObject(sync,0)==0); CHECK(pm_win_CloseHandle(sync)); CHECK(pm_win_CloseHandle(modify));
}
static void semaphore_forms_and_bounds(pm_winapi_events *context) {
    const int32_t initial[]={-1,INT32_MIN,1,2},maximum[]={1,1,0,1};
    for (unsigned i=0;i<4;++i) CHECK(!pm_win_CreateSemaphoreExA(NULL,initial[i],maximum[i],NULL,0,RIGHTS) && pm_win_GetLastError()==87);
    CHECK(!pm_win_CreateSemaphoreExA(NULL,0,-1,NULL,0,RIGHTS));
    CHECK(!pm_win_CreateSemaphoreExA((void *)1,0,1,NULL,0,RIGHTS));
    CHECK(!pm_win_CreateSemaphoreExA(NULL,0,1,(const char *)1,0,RIGHTS));
    CHECK(!pm_win_CreateSemaphoreExA(NULL,0,1,NULL,1,RIGHTS));
    CHECK(!pm_win_CreateSemaphoreExA(NULL,0,1,NULL,0,0));
    CHECK(!pm_win_CreateSemaphoreExA(NULL,0,1,NULL,0,0x1f0003));
    CHECK(!pm_win_CreateSemaphoreExA(NULL,0,1,NULL,0,0x80000000));
    void *large=semaphore(INT32_MAX,INT32_MAX,RIGHTS);
    CHECK(!pm_win_ReleaseSemaphore(large,1,NULL) && pm_win_GetLastError()==298);
    CHECK(pm_win_WaitForSingleObject(large,0)==0); CHECK(find_event(context,large)->count==INT32_MAX-1);
    CHECK(pm_win_ReleaseSemaphore(large,1,NULL)); CHECK(find_event(context,large)->count==INT32_MAX); CHECK(pm_win_CloseHandle(large));
    large=semaphore(0,INT32_MAX,RIGHTS); CHECK(pm_win_ReleaseSemaphore(large,INT32_MAX,NULL));
    CHECK(find_event(context,large)->count==INT32_MAX); CHECK(pm_win_CloseHandle(large));
    void *handles[PM_EVENTS_MAX_EVENTS];
    for (unsigned i=0;i<PM_EVENTS_MAX_EVENTS;++i) handles[i]=(i%2)?semaphore(0,1,RIGHTS):event(0,RIGHTS);
    CHECK(!pm_win_CreateSemaphoreExA(NULL,0,1,NULL,0,RIGHTS) && pm_win_GetLastError()==8);
    CHECK(!pm_win_CreateEventExA(NULL,NULL,0,RIGHTS) && pm_win_GetLastError()==8);
    for (unsigned i=0;i<PM_EVENTS_MAX_EVENTS;++i) CHECK(pm_win_CloseHandle(handles[i]));
}
static void semaphore_grants(pm_winapi_events *context,int release_both) {
    void *handle=semaphore(0,1,RIGHTS); begin_gate(1);
    waiter_args args[2]={{context,handle,999,0,0},{context,handle,999,0,0}}; pthread_t threads[2];
    for (unsigned i=0;i<2;++i) CHECK(pthread_create(&threads[i],NULL,waiter,&args[i])==0);
    await_count(&entered,2); CHECK(!pm_win_CloseHandle(handle) && pm_win_GetLastError()==170);
    CHECK(!pm_win_ReleaseSemaphore(handle,2,NULL) && pm_win_GetLastError()==298); no_grants(context,handle,2);
    fail_broadcast=1; CHECK(!pm_win_ReleaseSemaphore(handle,1,NULL) && pm_win_GetLastError()==31);
    await_count(&parked,2); no_grants(context,handle,2);
    CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT);
    CHECK(pm_win_ReleaseSemaphore(handle,1,NULL)); CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT);
    if (release_both) {
        CHECK(pm_win_ReleaseSemaphore(handle,1,NULL)); CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT);
        CHECK(pm_win_ReleaseSemaphore(handle,1,NULL)); CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_OBJECT_0);
        CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT);
    }
    release_gate();
    for (unsigned i=0;i<2;++i) { CHECK(pthread_join(threads[i],NULL)==0); CHECK(args[i].last==456); }
    unsigned successes=(args[0].result==0)+(args[1].result==0);
    CHECK(successes==(release_both?2u:1u)); CHECK(find_event(context,handle)->count==0);
    CHECK(pm_win_CloseHandle(handle));
}
static void semaphore_batch_grant(pm_winapi_events *context) {
    void *handle=semaphore(0,3,RIGHTS); begin_gate(1);
    waiter_args args[2]={{context,handle,999,0,0},{context,handle,999,0,0}}; pthread_t threads[2];
    for (unsigned i=0;i<2;++i) CHECK(pthread_create(&threads[i],NULL,waiter,&args[i])==0);
    await_count(&entered,2); CHECK(pm_win_ReleaseSemaphore(handle,3,NULL)); await_count(&parked,2);
    CHECK(pthread_mutex_lock(&context->mutex)==0);
    event_slot *slot=find_event(context,handle); unsigned grants=0;
    CHECK(slot && slot->count==1);
    for (unsigned i=0;i<PM_EVENTS_MAX_BINDINGS;++i) grants+=(unsigned)slot->waiting[i].granted;
    CHECK(grants==2); CHECK(pthread_mutex_unlock(&context->mutex)==0);
    CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_OBJECT_0);
    CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT);
    release_gate();
    for (unsigned i=0;i<2;++i) { CHECK(pthread_join(threads[i],NULL)==0); CHECK(args[i].result==0 && args[i].last==456); }
    CHECK(find_event(context,handle)->count==0); CHECK(pm_win_CloseHandle(handle));
}
static void semaphore_lifecycle(pm_winapi_events *context) {
    fail_init=1; CHECK(!pm_win_CreateSemaphoreExA(NULL,0,1,NULL,0,RIGHTS) && pm_win_GetLastError()==31);
    void *handle=semaphore(0,1,RIGHTS); fail_wait=1;
    CHECK(pm_win_WaitForSingleObject(handle,10)==PM_WAIT_FAILED && pm_win_GetLastError()==31); no_grants(context,handle,0);
    fail_destroy=1; CHECK(!pm_win_CloseHandle(handle) && pm_win_GetLastError()==31);
    CHECK(pm_win_ReleaseSemaphore(handle,1,NULL)); CHECK(pm_win_WaitForSingleObject(handle,0)==0);
    CHECK(pm_winapi_events_unbind()); CHECK(!pm_win_ReleaseSemaphore(handle,1,NULL) && pm_win_GetLastError()==6);
    CHECK(!pm_win_CreateSemaphoreExA(NULL,0,1,NULL,0,RIGHTS));
    pm_winapi_events *other=pm_winapi_events_create(); CHECK(other && pm_winapi_events_bind(other));
    CHECK(!pm_win_ReleaseSemaphore(handle,1,NULL) && pm_win_GetLastError()==6); CHECK(pm_winapi_events_unbind());
    CHECK(pm_winapi_events_destroy(&other)); CHECK(pm_winapi_events_bind(context));
    begin_gate(0); waiter_args arg={context,handle,999,0,1}; pthread_t thread;
    CHECK(pthread_create(&thread,NULL,waiter,&arg)==0); await_count(&entered,1);
    CHECK(pthread_cancel(thread)==0); CHECK(pm_win_ReleaseSemaphore(handle,1,NULL));
    void *result=NULL; CHECK(pthread_join(thread,&result)==0 && result==PTHREAD_CANCELED);
    CHECK(context->bindings==1); no_grants(context,handle,0);
    CHECK(pm_win_WaitForSingleObject(handle,0)==PM_WAIT_TIMEOUT);
    CHECK(pm_win_ReleaseSemaphore(handle,1,NULL)); CHECK(pm_win_WaitForSingleObject(handle,0)==0); CHECK(pm_win_CloseHandle(handle));
}
static void semaphore_resolver(void) {
    const char *names[]={"CreateSemaphoreExA","ReleaseSemaphore"};
    const uintptr_t expected[]={(uintptr_t)&pm_win_CreateSemaphoreExA,(uintptr_t)&pm_win_ReleaseSemaphore};
    for (unsigned i=0;i<2;++i) {
        uintptr_t address=1; CHECK(pm_winapi_events_resolve(NULL,"kernel32.dll",names[i],0,0,&address) && address==expected[i]);
        CHECK(!pm_winapi_events_resolve(NULL,"ntdll.dll",names[i],0,0,&address) && !address);
        CHECK(!pm_winapi_events_resolve(NULL,"kernel32.dll",names[i],1,0,&address) && !address);
        CHECK(!pm_winapi_events_resolve(NULL,"kernel32.dll",names[i],0,1,&address) && !address);
    }
}
int main(void) {
    semaphore_resolver(); pm_winapi_events *context=pm_winapi_events_create(); CHECK(context && pm_winapi_events_bind(context));
    semaphore_basics(context); semaphore_forms_and_bounds(context); semaphore_grants(context,0); semaphore_grants(context,1); semaphore_batch_grant(context); semaphore_lifecycle(context);
    (void)semaphore(1,1,RIGHTS); CHECK(pm_winapi_events_unbind());
    fail_destroy=1; CHECK(!pm_winapi_events_destroy(&context) && context && context->closing);
    CHECK(!pm_winapi_events_bind(context)); CHECK(pm_winapi_events_destroy(&context) && !context);
    context=pm_winapi_events_create(); CHECK(context && pm_winapi_events_bind(context));
    atomic_store(&next_token,UINTPTR_MAX); CHECK(!pm_win_CreateSemaphoreExA(NULL,0,1,NULL,0,RIGHTS) && pm_win_GetLastError()==8);
    CHECK(pm_winapi_events_unbind()); CHECK(pm_winapi_events_destroy(&context)); CHECK(!live_conditions);
    CHECK(pthread_cond_destroy(&gate_condition)==0); CHECK(pthread_mutex_destroy(&gate)==0);
    printf("PASS: %u semaphore checks; signed bounds, mixed quota, grants, finite waits, failure atomicity, cancellation; liveConditions=0\n",atomic_load(&checks));
    return 0;
}
