// Auto-reset event ping-pong. No game, graphics, network, saves or file writes.
// Run only after reviewing the parent harness and ensuring its private prefix is idle.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdio>
#include <cstring>

struct State { HANDLE request; HANDLE response; volatile LONG stop; volatile LONG worker_error; ULONGLONG deadline; };
static DWORD remaining(ULONGLONG deadline) {
    ULONGLONG now=GetTickCount64();
    return now>=deadline ? 0 : static_cast<DWORD>(deadline-now);
}
static DWORD WINAPI worker(void *raw) {
    State *s=static_cast<State *>(raw);
    for (;;) {
        DWORD wait=WaitForSingleObject(s->request,remaining(s->deadline));
        if (wait!=WAIT_OBJECT_0) { InterlockedExchange(&s->worker_error,wait==WAIT_FAILED ? static_cast<LONG>(GetLastError()) : -1); return 1; }
        if (InterlockedCompareExchange(&s->stop,0,0)) return 0;
        if (!SetEvent(s->response)) { InterlockedExchange(&s->worker_error,static_cast<LONG>(GetLastError())); return 1; }
    }
}
static unsigned long long ticks(FILETIME f) { return (static_cast<unsigned long long>(f.dwHighDateTime)<<32)|f.dwLowDateTime; }
int main(int argc,char **argv) {
    if (argc!=2 || !std::strlen(argv[1]) || std::strlen(argv[1])>128) return 2;
    for (const char *p=argv[1];*p;++p) if (!((*p>='a'&&*p<='z')||(*p>='A'&&*p<='Z')||(*p>='0'&&*p<='9')||*p=='-'||*p=='_')) return 2;
    const unsigned rounds=20000;
    static State state{};state.deadline=GetTickCount64()+12000;
    state.request=CreateEventW(nullptr,FALSE,FALSE,nullptr);state.response=CreateEventW(nullptr,FALSE,FALSE,nullptr);
    if (!state.request || !state.response) { if(state.request) CloseHandle(state.request);if(state.response) CloseHandle(state.response);return 3; }
    LARGE_INTEGER freq{},start{},finish{};FILETIME create{},exit{},kernel0{},user0{},kernel1{},user1{};
    if (!QueryPerformanceFrequency(&freq) || !freq.QuadPart || !GetProcessTimes(GetCurrentProcess(),&create,&exit,&kernel0,&user0)) { CloseHandle(state.request);CloseHandle(state.response);return 3; }
    HANDLE thread=CreateThread(nullptr,0,worker,&state,0,nullptr);
    if (!thread) { CloseHandle(state.request);CloseHandle(state.response);return 3; }
    unsigned completed=0;DWORD error=0;QueryPerformanceCounter(&start);
    for (;completed<rounds;++completed) {
        if (!SetEvent(state.request)) { error=GetLastError();break; }
        DWORD wait=WaitForSingleObject(state.response,remaining(state.deadline));
        if (wait!=WAIT_OBJECT_0) { error=wait==WAIT_FAILED?GetLastError():WAIT_TIMEOUT;break; }
    }
    QueryPerformanceCounter(&finish);BOOL times=GetProcessTimes(GetCurrentProcess(),&create,&exit,&kernel1,&user1);
    InterlockedExchange(&state.stop,1);SetEvent(state.request);
    DWORD joined=WaitForSingleObject(thread,2000);LONG worker_error=InterlockedCompareExchange(&state.worker_error,0,0);
    bool ok=completed==rounds && !error && !worker_error && joined==WAIT_OBJECT_0 && times;
    std::printf("{\"nonce\":\"%s\",\"rounds_requested\":%u,\"rounds_completed\":%u,\"qpc_ticks\":%lld,\"qpc_frequency\":%lld,\"cpu_times_valid\":%s,\"cpu_100ns\":%llu,\"main_error\":%lu,\"worker_error\":%ld,\"thread_joined\":%s,\"ok\":%s}\n",argv[1],rounds,completed,finish.QuadPart-start.QuadPart,freq.QuadPart,times?"true":"false",times?(ticks(kernel1)-ticks(kernel0)+ticks(user1)-ticks(user0)):0,static_cast<unsigned long>(error),static_cast<long>(worker_error),joined==WAIT_OBJECT_0?"true":"false",ok?"true":"false");
    // A timed-out worker may still reference these handles/State; process exit
    // reclaims them safely rather than closing objects under a running thread.
    if (joined==WAIT_OBJECT_0) { CloseHandle(thread);CloseHandle(state.request);CloseHandle(state.response); }
    return ok?0:1;
}
