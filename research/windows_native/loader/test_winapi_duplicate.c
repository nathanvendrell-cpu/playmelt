#include "winapi_memory.h"
static int fail_handle_write;
static int injected_handle_write(void *output,uintptr_t value) {
    if (fail_handle_write) { --fail_handle_write; return 0; }
    return pm_winapi_memory_write_handle(output,value);
}
#define pm_winapi_memory_write_handle injected_handle_write
#define main event_regression_not_invoked
#include "test_winapi_events.c"
#undef main
#undef pm_winapi_memory_write_handle
#define PROCESS ((void *)UINTPTR_MAX)
static unsigned char *out;
static void *read_output(void) { uintptr_t value=0; memcpy(&value,out,8); return (void *)value; }
static void *duplicate(void *source,uint32_t access,uint32_t options) {
    CHECK(pm_win_DuplicateHandle(PROCESS,source,PROCESS,out,access,0,options));
    void *handle=read_output(); CHECK(handle && handle!=source); return handle;
}
static unsigned handle_count(pm_winapi_events *context) {
    unsigned count=0; for (unsigned i=0;i<PM_EVENTS_MAX_HANDLES;++i) count+=context->handles[i].token!=0; return count;
}
static void failure_unchanged(pm_winapi_events *context,void *process,void *source,void *target,
    void *output,uint32_t access,int inherit,uint32_t options,uint32_t expected) {
    unsigned before=handle_count(context); event_slot *object=find_event(context,source);
    unsigned refs=object?object->references:0; unsigned char canary[8]; memcpy(canary,out,8);
    CHECK(!pm_win_DuplicateHandle(process,source,target,output,access,inherit,options)); CHECK(pm_win_GetLastError()==expected);
    CHECK(!memcmp(out,canary,8) && handle_count(context)==before);
    if (object) CHECK(object->references==refs);
}
static void duplicate_basics(pm_winapi_events *context) {
    void *source=event(0,RIGHTS); pm_win_SetLastError(1234);
    void *same=duplicate(source,UINT32_MAX,PM_DUPLICATE_SAME_ACCESS); CHECK(pm_win_GetLastError()==1234);
    CHECK(find_event(context,same)==find_event(context,source) && find_event(context,source)->references==2);
    CHECK(find_handle(context,same)->access==RIGHTS);
    void *sync=duplicate(source,PM_EVENT_SYNCHRONIZE,0),*modify=duplicate(source,PM_EVENT_MODIFY_STATE,0),*zero=duplicate(source,0,0);
    CHECK(!pm_win_SetEvent(sync) && pm_win_GetLastError()==5); CHECK(!pm_win_ResetEvent(sync) && pm_win_GetLastError()==5);
    CHECK(pm_win_WaitForSingleObject(modify,0)==PM_WAIT_FAILED && pm_win_GetLastError()==5);
    CHECK(!pm_win_SetEvent(zero) && pm_win_GetLastError()==5); CHECK(pm_win_WaitForSingleObject(zero,0)==PM_WAIT_FAILED);
    CHECK(pm_win_SetEvent(modify)); CHECK(pm_win_WaitForSingleObject(sync,0)==PM_WAIT_OBJECT_0);
    CHECK(pm_win_WaitForSingleObject(same,0)==PM_WAIT_TIMEOUT);
    failure_unchanged(context,PROCESS,sync,PROCESS,out,RIGHTS,0,0,5);
    failure_unchanged(context,PROCESS,source,PROCESS,out,0x1f0003,0,0,87);
    failure_unchanged(context,NULL,source,PROCESS,out,0,0,2,6);
    failure_unchanged(context,PROCESS,source,NULL,out,0,0,2,6);
    failure_unchanged(context,PROCESS,source,PROCESS,out,0,1,2,87);
    failure_unchanged(context,PROCESS,source,PROCESS,out,0,0,1,87);
    failure_unchanged(context,PROCESS,source,PROCESS,out,0,0,3,87);
    failure_unchanged(context,PROCESS,source,PROCESS,out,0,0,4,87);
    failure_unchanged(context,PROCESS,PROCESS,PROCESS,out,0,0,2,6);
    failure_unchanged(context,PROCESS,source,PROCESS,NULL,0,0,2,998);
    failure_unchanged(context,PROCESS,source,PROCESS,(void *)1,0,0,2,998);
    uint64_t unowned=0x8877665544332211;
    failure_unchanged(context,PROCESS,source,PROCESS,&unowned,0,0,2,998); CHECK(unowned==UINT64_C(0x8877665544332211));
    fail_handle_write=1; failure_unchanged(context,PROCESS,source,PROCESS,out,0,0,2,998);
    CHECK(pm_win_SetEvent(source)); CHECK(pm_win_WaitForSingleObject(same,0)==0);
    CHECK(pm_win_CloseHandle(source)); CHECK(!pm_win_SetEvent(source) && pm_win_GetLastError()==6);
    CHECK(pm_win_SetEvent(same)); CHECK(pm_win_WaitForSingleObject(sync,0)==0);
    CHECK(pm_win_CloseHandle(sync)); CHECK(pm_win_CloseHandle(modify)); CHECK(pm_win_CloseHandle(zero));
    CHECK(find_event(context,same)->references==1);
    fail_destroy=1; CHECK(!pm_win_CloseHandle(same) && pm_win_GetLastError()==31);
    CHECK(find_event(context,same)->references==1 && handle_count(context)==1);
    CHECK(pm_win_SetEvent(same)); CHECK(pm_win_WaitForSingleObject(same,0)==0); CHECK(pm_win_CloseHandle(same));
    failure_unchanged(context,PROCESS,same,PROCESS,out,0,0,2,6);
}
static void duplicate_semaphore(pm_winapi_events *context) {
    void *source=pm_win_CreateSemaphoreExA(NULL,0,3,NULL,0,RIGHTS); CHECK(source);
    void *alias=duplicate(source,0,PM_DUPLICATE_SAME_ACCESS);
    CHECK(find_event(context,source)==find_event(context,alias)); CHECK(pm_win_ReleaseSemaphore(alias,2,NULL));
    CHECK(pm_win_WaitForSingleObject(source,0)==0); CHECK(pm_win_WaitForSingleObject(alias,0)==0);
    CHECK(pm_win_WaitForSingleObject(source,0)==PM_WAIT_TIMEOUT);
    CHECK(pm_win_CloseHandle(source)); CHECK(pm_win_ReleaseSemaphore(alias,1,NULL)); CHECK(pm_win_WaitForSingleObject(alias,0)==0);
    CHECK(pm_win_CloseHandle(alias));
}
static void duplicate_capacity(pm_winapi_events *context) {
    void *handles[PM_EVENTS_MAX_HANDLES]; handles[0]=event(0,RIGHTS);
    for (unsigned i=1;i<PM_EVENTS_MAX_HANDLES;++i) handles[i]=duplicate(handles[0],0,PM_DUPLICATE_SAME_ACCESS);
    CHECK(handle_count(context)==PM_EVENTS_MAX_HANDLES && find_event(context,handles[0])->references==PM_EVENTS_MAX_HANDLES);
    failure_unchanged(context,PROCESS,handles[0],PROCESS,out,0,0,2,8);
    CHECK(!pm_win_CreateEventExA(NULL,NULL,0,RIGHTS) && pm_win_GetLastError()==8);
    CHECK(!pm_win_CreateSemaphoreExA(NULL,0,1,NULL,0,RIGHTS) && pm_win_GetLastError()==8);
    CHECK(pm_win_CloseHandle(handles[1])); void *replacement=duplicate(handles[0],0,2); CHECK(replacement!=handles[1]);
    CHECK(!pm_win_CloseHandle(handles[1]) && pm_win_GetLastError()==6); handles[1]=replacement;
    for (unsigned i=0;i<PM_EVENTS_MAX_HANDLES;++i) CHECK(pm_win_CloseHandle(handles[i])); CHECK(!handle_count(context));
}
static void duplicate_wait_alias(pm_winapi_events *context) {
    void *source=event(0,RIGHTS),*wait_handle=duplicate(source,PM_EVENT_SYNCHRONIZE,0),*signal_handle=duplicate(source,PM_EVENT_MODIFY_STATE,0);
    begin_gate(0); waiter_args arg={context,wait_handle,999,0,0}; pthread_t thread;
    CHECK(pthread_create(&thread,NULL,waiter,&arg)==0); await_count(&entered,1);
    CHECK(pm_win_CloseHandle(source)); /* Different alias can close during this wait. */
    CHECK(!pm_win_CloseHandle(wait_handle) && pm_win_GetLastError()==170);
    CHECK(find_event(context,wait_handle)->references==2);
    CHECK(pm_win_SetEvent(signal_handle)); CHECK(pthread_join(thread,NULL)==0); CHECK(arg.result==0 && arg.last==456);
    CHECK(pm_win_CloseHandle(signal_handle)); CHECK(pm_win_CloseHandle(wait_handle));
}
static void duplicate_two_waiters(pm_winapi_events *context,int semaphore) {
    void *source=semaphore?pm_win_CreateSemaphoreExA(NULL,0,2,NULL,0,RIGHTS):event(0,RIGHTS);
    CHECK(source);
    void *alias=duplicate(source,PM_EVENT_SYNCHRONIZE,0),*signal=duplicate(source,PM_EVENT_MODIFY_STATE,0);
    begin_gate(1);
    waiter_args args[2]={{context,source,999,0,0},{context,alias,999,0,0}}; pthread_t threads[2];
    for (unsigned i=0;i<2;++i) CHECK(pthread_create(&threads[i],NULL,waiter,&args[i])==0);
    await_count(&entered,2);
    CHECK(pthread_mutex_lock(&context->mutex)==0);
    CHECK(find_handle(context,source)->waiters==1 && find_handle(context,alias)->waiters==1);
    CHECK(find_event(context,source)->waiters==2 && find_event(context,source)->references==3);
    CHECK(pthread_mutex_unlock(&context->mutex)==0);
    CHECK(!pm_win_CloseHandle(source) && pm_win_GetLastError()==170);
    CHECK(!pm_win_CloseHandle(alias) && pm_win_GetLastError()==170);
    CHECK(semaphore?pm_win_ReleaseSemaphore(signal,1,NULL):pm_win_SetEvent(signal));
    await_count(&parked,2);
    CHECK(semaphore?pm_win_ReleaseSemaphore(signal,1,NULL):pm_win_SetEvent(signal));
    CHECK(pm_win_WaitForSingleObject(source,0)==PM_WAIT_TIMEOUT);
    CHECK(pm_win_WaitForSingleObject(alias,0)==PM_WAIT_TIMEOUT);
    CHECK(pthread_mutex_lock(&context->mutex)==0);
    event_slot *object=find_event(context,source); unsigned grants=0;
    for (unsigned i=0;i<PM_EVENTS_MAX_BINDINGS;++i) grants+=object->waiting[i].active && object->waiting[i].granted;
    CHECK(grants==2 && object->waiters==2);
    CHECK(pthread_mutex_unlock(&context->mutex)==0);
    CHECK(pm_win_CloseHandle(signal));
    release_gate();
    for (unsigned i=0;i<2;++i) { CHECK(pthread_join(threads[i],NULL)==0); CHECK(args[i].result==0 && args[i].last==456); }
    CHECK(!find_handle(context,source)->waiters && !find_handle(context,alias)->waiters);
    CHECK(!find_event(context,source)->waiters && find_event(context,source)->references==2);
    CHECK(pm_win_CloseHandle(source)); CHECK(pm_win_CloseHandle(alias));
}
static void *foreign_output(void *pointer) {
    waiter_args *arg=pointer; CHECK(pm_winapi_events_bind(arg->context));
    CHECK(!pm_win_DuplicateHandle(PROCESS,arg->handle,PROCESS,out,0,0,2) && pm_win_GetLastError()==998);
    CHECK(pm_winapi_events_unbind()); return NULL;
}
static void duplicate_memory_and_context(pm_winapi_events *context,pm_winapi_memory *memory,void *allocation,size_t page,void *old) {
    void *source=event(0,RIGHTS); unsigned before=handle_count(context);
    unsigned char *saved=out; out=(unsigned char *)allocation+page-3;
    void *cross=duplicate(source,0,2); CHECK(pm_win_CloseHandle(cross)); /* unaligned 8-byte cross-page write */
    CHECK(pm_win_VirtualProtect((unsigned char *)allocation+page,1,PM_PAGE_READONLY,old));
    failure_unchanged(context,PROCESS,source,PROCESS,out,0,0,2,998);
    CHECK(pm_win_VirtualProtect((unsigned char *)allocation+page,1,PM_PAGE_READWRITE,old)); out=saved;
    failure_unchanged(context,PROCESS,source,PROCESS,(unsigned char *)allocation+2*page-7,0,0,2,998);
    failure_unchanged(context,PROCESS,source,PROCESS,(void *)(UINTPTR_MAX-3),0,0,2,998);
    CHECK(pm_winapi_memory_unbind()); failure_unchanged(context,PROCESS,source,PROCESS,out,0,0,2,998);
    CHECK(pm_winapi_memory_bind(memory)); CHECK(handle_count(context)==before);
    pthread_t thread; waiter_args arg={context,source,0,0,0}; CHECK(pthread_create(&thread,NULL,foreign_output,&arg)==0); CHECK(pthread_join(thread,NULL)==0);
    CHECK(pm_winapi_events_unbind()); pm_winapi_events *other=pm_winapi_events_create(); CHECK(other && pm_winapi_events_bind(other));
    CHECK(!pm_win_DuplicateHandle(PROCESS,source,PROCESS,out,0,0,2) && pm_win_GetLastError()==6);
    CHECK(pm_winapi_events_unbind()); CHECK(pm_winapi_events_destroy(&other)); CHECK(pm_winapi_events_bind(context));
    CHECK(pm_win_CloseHandle(source));
}
static void duplicate_resolver(void) {
    uintptr_t address=1;
    CHECK(pm_winapi_events_resolve(NULL,"kernelbase.dll","DuplicateHandle",0,0,&address) && address==(uintptr_t)&pm_win_DuplicateHandle);
    CHECK(!pm_winapi_events_resolve(NULL,"ntdll.dll","DuplicateHandle",0,0,&address) && !address);
    CHECK(!pm_winapi_events_resolve(NULL,"kernel32.dll","DuplicateHandle",1,0,&address) && !address);
}
int main(void) {
    duplicate_resolver(); char error[128]; pm_winapi_memory *memory=pm_winapi_memory_create(error,sizeof error); CHECK(memory);
    size_t page=pm_winapi_memory_page_size(memory),rounded; void *allocation=NULL,*old=NULL;
    CHECK(pm_winapi_memory_allocate(memory,2*page,&allocation,&rounded)); CHECK(rounded==2*page);
    CHECK(pm_winapi_memory_allocate(memory,page,&old,&rounded)); out=(unsigned char *)allocation+5; memset(allocation,0xa7,2*page);
    CHECK(pm_winapi_memory_bind(memory)); pm_winapi_events *context=pm_winapi_events_create(); CHECK(context && pm_winapi_events_bind(context));
    duplicate_basics(context); duplicate_semaphore(context); duplicate_capacity(context); duplicate_wait_alias(context);
    duplicate_two_waiters(context,0); duplicate_two_waiters(context,1);
    duplicate_memory_and_context(context,memory,allocation,page,old);
    void *source=event(0,RIGHTS); (void)duplicate(source,0,2); CHECK(pm_winapi_events_unbind());
    fail_destroy=1; CHECK(!pm_winapi_events_destroy(&context) && context && context->slots[0].references==2);
    CHECK(pm_winapi_events_destroy(&context) && !context);
    context=pm_winapi_events_create(); CHECK(context && pm_winapi_events_bind(context)); source=event(0,RIGHTS);
    atomic_store(&next_token,UINTPTR_MAX); failure_unchanged(context,PROCESS,source,PROCESS,out,0,0,2,8);
    CHECK(pm_win_CloseHandle(source)); CHECK(pm_winapi_events_unbind()); CHECK(pm_winapi_events_destroy(&context));
    CHECK(pm_winapi_memory_unbind()); CHECK(pm_winapi_memory_destroy(&memory) && !memory); CHECK(!live_conditions);
    CHECK(pthread_cond_destroy(&gate_condition)==0); CHECK(pthread_mutex_destroy(&gate)==0);
    printf("PASS: %u DuplicateHandle checks; shared objects, distinct rights/waits, owned output, rollback and cleanup\n",atomic_load(&checks));
    return 0;
}
