#ifndef PLAYMELT_WINAPI_EVENTS_H
#define PLAYMELT_WINAPI_EVENTS_H
#include "winapi_subset.h"
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pm_winapi_events pm_winapi_events;
#define PM_EVENTS_MAX_EVENTS 16u
#define PM_EVENTS_MAX_BINDINGS 8u
#define PM_EVENTS_MAX_WAIT_MS 100u
#define PM_CREATE_EVENT_MANUAL_RESET 1u
#define PM_CREATE_EVENT_INITIAL_SET 2u
#define PM_EVENT_MODIFY_STATE 2u
#define PM_EVENT_SYNCHRONIZE 0x00100000u
#define PM_WAIT_OBJECT_0 0u
#define PM_WAIT_TIMEOUT 258u
#define PM_WAIT_FAILED UINT32_MAX

/* HOST ABI. A context owns at most 16 anonymous events. It may be explicitly
 * bound by up to 8 host pthreads at once, one context per thread. No CreateThread,
 * inherited/named events, ACLs, other handle types or Windows kernel objects.
 * The creating thread owns destroy: it must serialize context lifetime against
 * all bind attempts, join its workers, then destroy. Destroy refuses any binding
 * or waiter; once destruction starts, it closes admission permanently and
 * retains context/undestroyed resources on OS failure for destroy retry.
 * Thread exit removes only that thread's binding, never destroys live events.
 * Bind/unbind/destroy preserve LastError. destroy(&NULL) succeeds.
 *
 * C context pointers are trusted live host handles, not guest HANDLEs. Guest
 * handles are nonzero integer tokens, never dereferenced, globally monotonically
 * issued and never reused in this module instance; exhaustion fails closed.
 * Stale, foreign-context and arbitrary handles fail, including after slot reuse.
 * There is no protection against unloading/reloading this host module or a
 * malicious C host corrupting its internals. No public memory registration.
 *
 * DEFERRED pthread cancellation is temporarily disabled across API invariants,
 * including waits, and restored only after waiter removal + mutex unlock. A
 * pending cancellation can take effect at restoration/next cancellation point;
 * TLS destructor can then release the binding. Asynchronous cancellation is an
 * unsupported host precondition: callers must not enable it around these APIs.
 * No internal threads, polling or permanent timers are created.
 */
pm_winapi_events *pm_winapi_events_create(void);
int pm_winapi_events_bind(pm_winapi_events *context);
int pm_winapi_events_unbind(void);
int pm_winapi_events_destroy(pm_winapi_events **context);

/* Windows x64 ABI, restricted real event semantics. Create accepts ONLY NULL
 * attributes/name (pointers are rejected without dereferencing), flags 0..3 and
 * a nonzero subset of EVENT_MODIFY_STATE|SYNCHRONIZE. EVENT_ALL_ACCESS, generic
 * access and all other rights are deliberately unsupported. Set/Reset require
 * MODIFY_STATE; Wait requires SYNCHRONIZE; Close needs no extra access bit.
 * Manual events stay signaled until reset; auto events release one consumer and
 * coalesce repeated Set calls when no waiting consumer exists (no semaphore /
 * FIFO guarantee). Pending waits have individual grants: Set+Reset cannot erase
 * an attributed wake, two Set calls may grant two different pending waits, and
 * a new Wait(0) cannot steal their grants. Reset clears only persistent state.
 *
 * Wait accepts 0..100ms only. INFINITE and longer waits fail INVALID_PARAMETER,
 * never manufacture a timeout. A fixed monotone deadline and Darwin relative
 * condvar waits handle spurious wakes without restarting the timeout. Scheduler
 * latency can delay return; this is not a real-time bound or Windows sleep-state
 * emulation. Only imports, not actual DXGI call arguments, have been observed.
 * Only PM_WAIT_OBJECT_0, TIMEOUT, FAILED can be returned.
 * Closing an event with a pending waiter deterministically fails BUSY(170) and
 * preserves it (Windows leaves this race undefined; this is our stricter policy).
 * OS cond-signal failure leaves the previous logical state unchanged; waits
 * never report success just because a condvar woke. Failed cond-destroy retains
 * the live handle for retry. No unsupported operation pretends success.
 *
 * Success, including timeout, preserves LastError. Failure policy: invalid
 * parameters87, missing context/unknown handle6, denied rights5, capacity/token
 * exhaustion8, waiter-close170, other pthread/clock failures31. These are real
 * error values, not a promise of Windows error precedence. Host mutex ownership
 * invariants must not be violated externally. No SEH/APC/cross-process handles.
 */
void *PM_WINAPI pm_win_CreateEventExA(void *attributes,const char *name,
    uint32_t flags,uint32_t access);
int32_t PM_WINAPI pm_win_SetEvent(void *handle);
int32_t PM_WINAPI pm_win_ResetEvent(void *handle);
uint32_t PM_WINAPI pm_win_WaitForSingleObject(void *handle,uint32_t milliseconds);
int32_t PM_WINAPI pm_win_CloseHandle(void *handle);

/* Five named imports on kernel32/kernelbase only, then original base resolver.
 * Host ABI, no binding side effect; unknown/ordinal requests clear output. */
int pm_winapi_events_resolve(void *context,const char *dll,const char *name,
    uint16_t ordinal,int by_ordinal,uintptr_t *address);
#ifdef __cplusplus
}
#endif
#endif
