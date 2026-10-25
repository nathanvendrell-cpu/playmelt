#include "winapi_subset.h"

#include <limits.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static unsigned checks;
static unsigned failures;
#define CHECK(condition) do { \
    ++checks; \
    if (!(condition)) { \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); ++failures; \
    } \
} while (0)

typedef uint32_t (PM_WINAPI *get_error_fn)(void);
typedef void (PM_WINAPI *set_error_fn)(uint32_t);
typedef uint32_t (PM_WINAPI *get_pid_fn)(void);
typedef int32_t (PM_WINAPI *query_counter_fn)(int64_t *);
typedef uint64_t (PM_WINAPI *get_tick_fn)(void);
typedef void (PM_WINAPI *get_filetime_fn)(pm_filetime *);

static uintptr_t resolve(const char *name) {
    uintptr_t address = 0;
    CHECK(pm_winapi_resolve(NULL, "KERNEL32.DLL", name, 0, 0, &address) == 1);
    CHECK(address != 0);
    if (!address) exit(EXIT_FAILURE);
    return address;
}

static void test_resolver(void) {
    const char *names[] = {"GetLastError", "SetLastError", "GetCurrentProcessId",
        "QueryPerformanceCounter", "QueryPerformanceFrequency", "GetTickCount64",
        "GetSystemTimeAsFileTime"};
    const char *dlls[] = {"kernel32.dll", "KERNEL32.DLL", "KeRnElBaSe.DlL"};
    for (size_t n = 0; n < sizeof(names)/sizeof(*names); ++n) {
        const uintptr_t canonical = resolve(names[n]);
        for (size_t d = 0; d < sizeof(dlls)/sizeof(*dlls); ++d) {
            uintptr_t address = 0;
            CHECK(pm_winapi_resolve(NULL, dlls[d], names[n], 0, 0, &address) == 1);
            CHECK(address == canonical);
        }
    }
    struct invalid_import { const char *dll; const char *name; int ordinal; };
    const struct invalid_import invalid[] = {
        {NULL, "GetLastError", 0}, {"", "GetLastError", 0},
        {"kernel32", "GetLastError", 0}, {"kernel32.dll ", "GetLastError", 0},
        {"C:\\Windows\\kernel32.dll", "GetLastError", 0},
        {"kernel32.dll.evil", "GetLastError", 0},
        {"api-ms-win-core-errorhandling-l1-1-0.dll", "GetLastError", 0},
        {"user32.dll", "GetLastError", 0}, {"kernel32.dll", NULL, 0},
        {"kernel32.dll", "", 0}, {"kernel32.dll", "getlasterror", 0},
        {"kernel32.dll", "VirtualAlloc", 0}, {"kernel32.dll", "GetLastError", 1},
        {"kernel32.dll", "GetLastError", -1}
    };
    pm_win_SetLastError(UINT32_C(0xfedcba98));
    for (size_t i = 0; i < sizeof(invalid)/sizeof(*invalid); ++i) {
        uintptr_t address = UINTPTR_MAX;
        CHECK(pm_winapi_resolve(NULL, invalid[i].dll, invalid[i].name, 1,
                                invalid[i].ordinal, &address) == 0);
        CHECK(address == 0);
    }
    CHECK(pm_winapi_resolve(NULL, "kernel32.dll", "GetLastError", 0, 0, NULL) == 0);
    CHECK(pm_win_GetLastError() == UINT32_C(0xfedcba98));
}

static void test_arithmetic(void) {
    uint64_t out = 99;
    CHECK(pm_winapi_ticks_to_nanoseconds(6, 125, 3, &out) && out == 250);
    CHECK(pm_winapi_ticks_to_nanoseconds(1, 125, 3, &out) && out == 41);
    CHECK(pm_winapi_ticks_to_nanoseconds(UINT64_MAX, UINT32_MAX, UINT32_MAX,
                                        &out) && out == UINT64_MAX);
    CHECK(pm_winapi_ticks_to_nanoseconds(0, 1, 1, &out) && out == 0);
    out = 99;
    CHECK(!pm_winapi_ticks_to_nanoseconds(UINT64_MAX, 2, 1, &out) && out == 99);
    CHECK(!pm_winapi_ticks_to_nanoseconds(1, 0, 1, &out) && out == 99);
    CHECK(!pm_winapi_ticks_to_nanoseconds(1, 1, 0, &out) && out == 99);
    CHECK(!pm_winapi_ticks_to_nanoseconds(1, 1, 1, NULL));
    CHECK(pm_winapi_unix_to_filetime(0, 0, &out) && out == UINT64_C(116444736000000000));
    CHECK(pm_winapi_unix_to_filetime(-INT64_C(11644473600), 0, &out) && out == 0);
    CHECK(pm_winapi_unix_to_filetime(-INT64_C(11644473600), 199, &out) && out == 1);
    CHECK(pm_winapi_unix_to_filetime(-1, 999999999, &out) &&
          out == UINT64_C(116444735999999999));
    /* Last representable FILETIME, followed by its first overflowing quantum. */
    CHECK(pm_winapi_unix_to_filetime(INT64_C(1833029933770), 955161500, &out) &&
          out == UINT64_MAX);
    out = 99;
    CHECK(!pm_winapi_unix_to_filetime(INT64_C(1833029933770), 955161600, &out) && out == 99);
    CHECK(!pm_winapi_unix_to_filetime(-INT64_C(11644473601), 999999999, &out) && out == 99);
    CHECK(!pm_winapi_unix_to_filetime(INT64_MAX, 0, &out) && out == 99);
    CHECK(!pm_winapi_unix_to_filetime(INT64_MIN, 0, &out) && out == 99);
    CHECK(!pm_winapi_unix_to_filetime(0, -1, &out) && out == 99);
    CHECK(!pm_winapi_unix_to_filetime(0, 1000000000, &out) && out == 99);
    CHECK(!pm_winapi_unix_to_filetime(0, 0, NULL));
}

struct thread_group {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned ready;
    int go;
    get_error_fn get_error;
    set_error_fn set_error;
};
struct worker_args { struct thread_group *group; uint32_t value; int valid; };

static void *error_worker(void *opaque) {
    struct worker_args *args = opaque;
    struct thread_group *group = args->group;
    args->valid = group->get_error() == 0;
    group->set_error(args->value);
    pthread_mutex_lock(&group->mutex);
    ++group->ready;
    pthread_cond_broadcast(&group->condition);
    while (!group->go) pthread_cond_wait(&group->condition, &group->mutex);
    pthread_mutex_unlock(&group->mutex);
    /* Both workers set their values before either checks; a shared global fails. */
    args->valid = args->valid && group->get_error() == args->value;
    return NULL;
}

static void test_thread_errors(get_error_fn get_error, set_error_fn set_error) {
    struct thread_group group = { .mutex = PTHREAD_MUTEX_INITIALIZER,
        .condition = PTHREAD_COND_INITIALIZER, .get_error = get_error, .set_error = set_error };
    struct worker_args args[2] = {{&group, UINT32_C(0x12345678), 0},
                                  {&group, UINT32_C(0x87654321), 0}};
    pthread_t threads[2];
    unsigned started = 0;
    set_error(UINT32_MAX);
    for (unsigned i = 0; i < 2; ++i) {
        int result = pthread_create(&threads[i], NULL, error_worker, &args[i]);
        CHECK(result == 0);
        if (result != 0) break;
        ++started;
    }
    pthread_mutex_lock(&group.mutex);
    while (group.ready < started) pthread_cond_wait(&group.condition, &group.mutex);
    group.go = 1;
    pthread_cond_broadcast(&group.condition);
    pthread_mutex_unlock(&group.mutex);
    /* Join every created worker, also on a partial pthread_create failure. */
    for (unsigned i = 0; i < started; ++i) {
        CHECK(pthread_join(threads[i], NULL) == 0);
        CHECK(args[i].valid);
    }
    CHECK(get_error() == UINT32_MAX);
    CHECK(pthread_cond_destroy(&group.condition) == 0);
    CHECK(pthread_mutex_destroy(&group.mutex) == 0);
}

static void test_api_calls(void) {
    /* All imported calls below use MS x64 function pointer types, not host ABI. */
    const get_error_fn get_error = (get_error_fn)resolve("GetLastError");
    const set_error_fn set_error = (set_error_fn)resolve("SetLastError");
    const get_pid_fn get_pid = (get_pid_fn)resolve("GetCurrentProcessId");
    const query_counter_fn counter = (query_counter_fn)resolve("QueryPerformanceCounter");
    const query_counter_fn frequency = (query_counter_fn)resolve("QueryPerformanceFrequency");
    const get_tick_fn ticks = (get_tick_fn)resolve("GetTickCount64");
    const get_filetime_fn filetime = (get_filetime_fn)resolve("GetSystemTimeAsFileTime");
    test_thread_errors(get_error, set_error);
    CHECK(get_pid() == (uint32_t)getpid());
    CHECK(get_pid() != 0);
    int64_t f1 = 0, f2 = 0, c1 = -1, c2 = -1;
    CHECK(frequency(&f1) == 1 && f1 == INT64_C(1000000000));
    CHECK(counter(&c1) == 1 && c1 >= 0);
    const uint64_t tick = ticks();
    CHECK(counter(&c2) == 1 && c2 >= c1);
    CHECK(tick >= (uint64_t)c1 / 1000000 && tick <= (uint64_t)c2 / 1000000);
    CHECK(frequency(&f2) == 1 && f2 == f1);

    mach_timebase_info_data_t base = {0};
    CHECK(mach_timebase_info(&base) == KERN_SUCCESS);
    uint64_t before_ns = 0, after_ns = 0;
    CHECK(pm_winapi_ticks_to_nanoseconds(mach_continuous_time(), base.numer,
                                       base.denom, &before_ns));
    CHECK(counter(&c1) == 1);
    CHECK(pm_winapi_ticks_to_nanoseconds(mach_continuous_time(), base.numer,
                                       base.denom, &after_ns));
    CHECK((uint64_t)c1 >= before_ns && (uint64_t)c1 <= after_ns);

    struct timespec before = {0}, after = {0};
    pm_filetime ft = {0};
    CHECK(clock_gettime(CLOCK_REALTIME, &before) == 0);
    filetime(&ft);
    CHECK(clock_gettime(CLOCK_REALTIME, &after) == 0);
    uint64_t before_ft = 0, after_ft = 0;
    CHECK(pm_winapi_unix_to_filetime(before.tv_sec, (int32_t)before.tv_nsec, &before_ft));
    CHECK(pm_winapi_unix_to_filetime(after.tv_sec, (int32_t)after.tv_nsec, &after_ft));
    const uint64_t current_ft = ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    /* A simultaneous wall-clock adjustment can invalidate this bounded check;
     * it must remain visible as a failure, never repaired by using a fake time. */
    CHECK(current_ft >= before_ft && current_ft <= after_ft);
    CHECK(get_error() == UINT32_MAX); /* successful calls preserve thread error */
    CHECK(counter(NULL) == 0 && get_error() == PM_ERROR_INVALID_PARAMETER);
    set_error(0);
    CHECK(frequency(NULL) == 0 && get_error() == PM_ERROR_INVALID_PARAMETER);
    set_error(0);
    filetime(NULL);
    CHECK(get_error() == PM_ERROR_INVALID_PARAMETER);
}

int main(void) {
    test_resolver();
    test_arithmetic();
    test_api_calls();
    printf("WinAPI subset direct CPU: %u checks, %u failures; no PE/game/GPU executed\n",
           checks, failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
