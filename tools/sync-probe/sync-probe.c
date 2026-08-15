/*
 * Focused Windows scheduler diagnostic for comparing Wine engines.
 * Build on macOS with:
 *   x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror \
 *       sync-probe.c -o sync-probe.exe
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

typedef BOOL (WINAPI *wait_on_address_fn)(volatile void *, void *, SIZE_T, DWORD);
typedef VOID (WINAPI *wake_by_address_single_fn)(void *);

static wait_on_address_fn wait_on_address;
static wake_by_address_single_fn wake_by_address_single;

typedef struct
{
    void *main_fiber;
    DWORD fls_index;
    CONDITION_VARIABLE condition;
    SRWLOCK lock;
    LARGE_INTEGER frequency;
    int fiber_value_initially_clear;
    int fiber_value_survived_switch;
    int wake_passed;
    int timeout_passed;
    int stage;
} fiber_context;

static const char main_fiber_marker;
static const char worker_fiber_marker;

static double elapsed_ms(LARGE_INTEGER start, LARGE_INTEGER end, LARGE_INTEGER frequency)
{
    return (double)(end.QuadPart - start.QuadPart) * 1000.0 / (double)frequency.QuadPart;
}

static DWORD WINAPI wake_condition_after_50ms(void *context)
{
    CONDITION_VARIABLE *condition = context;
    Sleep(50);
    WakeConditionVariable(condition);
    return 0;
}

static DWORD WINAPI wake_address_after_50ms(void *context)
{
    volatile LONG *value = context;
    Sleep(50);
    InterlockedExchange(value, 1);
    wake_by_address_single((void *)value);
    return 0;
}

static int check_condition_timeout(LARGE_INTEGER frequency)
{
    CONDITION_VARIABLE condition = CONDITION_VARIABLE_INIT;
    SRWLOCK lock = SRWLOCK_INIT;
    LARGE_INTEGER start, end;
    BOOL result;
    DWORD error;

    AcquireSRWLockExclusive(&lock);
    QueryPerformanceCounter(&start);
    SetLastError(ERROR_SUCCESS);
    result = SleepConditionVariableSRW(&condition, &lock, 50, 0);
    error = GetLastError();
    QueryPerformanceCounter(&end);
    ReleaseSRWLockExclusive(&lock);

    printf("condition-timeout result=%d error=%lu elapsed_ms=%.3f\n",
           result, (unsigned long)error, elapsed_ms(start, end, frequency));
    return !result && error == ERROR_TIMEOUT && elapsed_ms(start, end, frequency) >= 40.0;
}

static int check_condition_wake(LARGE_INTEGER frequency)
{
    CONDITION_VARIABLE condition = CONDITION_VARIABLE_INIT;
    SRWLOCK lock = SRWLOCK_INIT;
    LARGE_INTEGER start, end;
    HANDLE thread;
    BOOL result;
    DWORD error;

    thread = CreateThread(NULL, 0, wake_condition_after_50ms, &condition, 0, NULL);
    if (!thread)
    {
        printf("condition-wake CreateThread error=%lu\n", (unsigned long)GetLastError());
        return 0;
    }

    AcquireSRWLockExclusive(&lock);
    QueryPerformanceCounter(&start);
    SetLastError(ERROR_SUCCESS);
    result = SleepConditionVariableSRW(&condition, &lock, 2000, 0);
    error = GetLastError();
    QueryPerformanceCounter(&end);
    ReleaseSRWLockExclusive(&lock);
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);

    printf("condition-wake result=%d error=%lu elapsed_ms=%.3f\n",
           result, (unsigned long)error, elapsed_ms(start, end, frequency));
    return result && elapsed_ms(start, end, frequency) >= 40.0
        && elapsed_ms(start, end, frequency) < 1000.0;
}

static int check_wait_on_address_timeout(LARGE_INTEGER frequency)
{
    volatile LONG value = 0;
    LONG compare = 0;
    LARGE_INTEGER start, end;
    BOOL result;
    DWORD error;

    QueryPerformanceCounter(&start);
    SetLastError(ERROR_SUCCESS);
    result = wait_on_address(&value, &compare, sizeof(value), 50);
    error = GetLastError();
    QueryPerformanceCounter(&end);

    printf("address-timeout result=%d error=%lu elapsed_ms=%.3f\n",
           result, (unsigned long)error, elapsed_ms(start, end, frequency));
    return !result && error == ERROR_TIMEOUT && elapsed_ms(start, end, frequency) >= 40.0;
}

static int check_wait_on_address_wake(LARGE_INTEGER frequency)
{
    volatile LONG value = 0;
    LONG compare = 0;
    LARGE_INTEGER start, end;
    HANDLE thread;
    BOOL result;
    DWORD error;

    thread = CreateThread(NULL, 0, wake_address_after_50ms, (void *)&value, 0, NULL);
    if (!thread)
    {
        printf("address-wake CreateThread error=%lu\n", (unsigned long)GetLastError());
        return 0;
    }

    QueryPerformanceCounter(&start);
    SetLastError(ERROR_SUCCESS);
    result = wait_on_address(&value, &compare, sizeof(value), 2000);
    error = GetLastError();
    QueryPerformanceCounter(&end);
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);

    printf("address-wake result=%d error=%lu value=%ld elapsed_ms=%.3f\n",
           result, (unsigned long)error, (long)value, elapsed_ms(start, end, frequency));
    return result && value == 1 && elapsed_ms(start, end, frequency) >= 40.0
        && elapsed_ms(start, end, frequency) < 1000.0;
}

static VOID WINAPI scheduler_fiber(void *parameter)
{
    fiber_context *context = parameter;
    LARGE_INTEGER start, end;
    HANDLE thread;
    BOOL result;
    DWORD error;

    context->fiber_value_initially_clear = FlsGetValue(context->fls_index) == NULL;
    if (!FlsSetValue(context->fls_index, (void *)&worker_fiber_marker))
    {
        context->stage = -1;
        SwitchToFiber(context->main_fiber);
        return;
    }

    thread = CreateThread(NULL, 0, wake_condition_after_50ms, &context->condition, 0, NULL);
    if (!thread)
    {
        context->stage = -2;
        SwitchToFiber(context->main_fiber);
        return;
    }

    AcquireSRWLockExclusive(&context->lock);
    QueryPerformanceCounter(&start);
    SetLastError(ERROR_SUCCESS);
    result = SleepConditionVariableSRW(&context->condition, &context->lock, 2000, 0);
    error = GetLastError();
    QueryPerformanceCounter(&end);
    ReleaseSRWLockExclusive(&context->lock);
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
    context->wake_passed = result && error == ERROR_SUCCESS
        && elapsed_ms(start, end, context->frequency) >= 40.0
        && elapsed_ms(start, end, context->frequency) < 1000.0;
    context->stage = 1;
    SwitchToFiber(context->main_fiber);

    context->fiber_value_survived_switch =
        FlsGetValue(context->fls_index) == (void *)&worker_fiber_marker;
    AcquireSRWLockExclusive(&context->lock);
    QueryPerformanceCounter(&start);
    SetLastError(ERROR_SUCCESS);
    result = SleepConditionVariableSRW(&context->condition, &context->lock, 50, 0);
    error = GetLastError();
    QueryPerformanceCounter(&end);
    ReleaseSRWLockExclusive(&context->lock);
    context->timeout_passed = !result && error == ERROR_TIMEOUT
        && elapsed_ms(start, end, context->frequency) >= 40.0;
    context->stage = 2;
    SwitchToFiber(context->main_fiber);
}

static int check_fiber_scheduler(LARGE_INTEGER frequency)
{
    fiber_context context = {0};
    void *fiber;
    int main_value_survived_switch;
    int passed;

    context.frequency = frequency;
    InitializeConditionVariable(&context.condition);
    InitializeSRWLock(&context.lock);
    context.fls_index = FlsAlloc(NULL);
    if (context.fls_index == FLS_OUT_OF_INDEXES)
    {
        printf("fiber-scheduler FlsAlloc error=%lu\n", (unsigned long)GetLastError());
        return 0;
    }

    context.main_fiber = ConvertThreadToFiber(NULL);
    if (!context.main_fiber)
    {
        printf("fiber-scheduler ConvertThreadToFiber error=%lu\n",
               (unsigned long)GetLastError());
        FlsFree(context.fls_index);
        return 0;
    }
    if (!FlsSetValue(context.fls_index, (void *)&main_fiber_marker))
    {
        printf("fiber-scheduler FlsSetValue error=%lu\n", (unsigned long)GetLastError());
        ConvertFiberToThread();
        FlsFree(context.fls_index);
        return 0;
    }

    fiber = CreateFiber(0, scheduler_fiber, &context);
    if (!fiber)
    {
        printf("fiber-scheduler CreateFiber error=%lu\n", (unsigned long)GetLastError());
        ConvertFiberToThread();
        FlsFree(context.fls_index);
        return 0;
    }

    SwitchToFiber(fiber);
    main_value_survived_switch =
        FlsGetValue(context.fls_index) == (void *)&main_fiber_marker;
    if (context.stage == 1)
        SwitchToFiber(fiber);

    passed = context.stage == 2
        && context.fiber_value_initially_clear
        && context.fiber_value_survived_switch
        && main_value_survived_switch
        && context.wake_passed
        && context.timeout_passed;
    printf("fiber-scheduler stage=%d initial_clear=%d fiber_fls=%d main_fls=%d "
           "wake=%d timeout=%d\n",
           context.stage, context.fiber_value_initially_clear,
           context.fiber_value_survived_switch, main_value_survived_switch,
           context.wake_passed, context.timeout_passed);

    DeleteFiber(fiber);
    ConvertFiberToThread();
    FlsFree(context.fls_index);
    return passed;
}

static int check_clock_coherence(LARGE_INTEGER frequency)
{
    volatile unsigned char *shared_data = (volatile unsigned char *)(uintptr_t)0x7ffe0000;
    volatile LONGLONG *shared_qpc_frequency = (volatile LONGLONG *)(shared_data + 0x300);
    LARGE_INTEGER start, end, previous, current;
    ULARGE_INTEGER file_start, file_end;
    ULONGLONG tick_start, tick_end;
    FILETIME file_time;
    double qpc_ms, file_ms;
    int monotonic = 1;
    int i;

    QueryPerformanceCounter(&previous);
    for (i = 0; i < 100000; ++i)
    {
        QueryPerformanceCounter(&current);
        if (current.QuadPart < previous.QuadPart)
            monotonic = 0;
        previous = current;
    }
    QueryPerformanceCounter(&start);
    tick_start = GetTickCount64();
    GetSystemTimePreciseAsFileTime(&file_time);
    file_start.LowPart = file_time.dwLowDateTime;
    file_start.HighPart = file_time.dwHighDateTime;
    Sleep(50);
    QueryPerformanceCounter(&end);
    tick_end = GetTickCount64();
    GetSystemTimePreciseAsFileTime(&file_time);
    file_end.LowPart = file_time.dwLowDateTime;
    file_end.HighPart = file_time.dwHighDateTime;

    qpc_ms = elapsed_ms(start, end, frequency);
    file_ms = (double)(file_end.QuadPart - file_start.QuadPart) / 10000.0;
    printf("clock-coherence frequency=%lld shared_frequency=%lld bypass=%u shift=%u "
           "qpc_ms=%.3f tick_ms=%llu file_ms=%.3f monotonic=%d\n",
           (long long)frequency.QuadPart, (long long)*shared_qpc_frequency,
           (unsigned int)shared_data[0x3c6], (unsigned int)shared_data[0x3c7],
           qpc_ms, (unsigned long long)(tick_end - tick_start), file_ms, monotonic);
    return monotonic && qpc_ms >= 40.0 && qpc_ms < 1000.0
        && tick_end - tick_start >= 40 && tick_end - tick_start < 1000
        && file_ms >= 40.0 && file_ms < 1000.0;
}

int main(void)
{
    LARGE_INTEGER frequency;
    HMODULE kernelbase;
    union
    {
        FARPROC generic;
        wait_on_address_fn wait;
        wake_by_address_single_fn wake;
    } address_proc;
    int passed = 0;

    kernelbase = GetModuleHandleW(L"kernelbase.dll");
    address_proc.generic = GetProcAddress(kernelbase, "WaitOnAddress");
    wait_on_address = address_proc.wait;
    address_proc.generic = GetProcAddress(kernelbase, "WakeByAddressSingle");
    wake_by_address_single = address_proc.wake;
    if (!wait_on_address || !wake_by_address_single)
    {
        printf("kernelbase address-wait exports unavailable\n");
        return 1;
    }

    if (!QueryPerformanceFrequency(&frequency))
    {
        printf("QueryPerformanceFrequency error=%lu\n", (unsigned long)GetLastError());
        return 1;
    }

    passed += check_condition_timeout(frequency);
    passed += check_condition_wake(frequency);
    passed += check_wait_on_address_timeout(frequency);
    passed += check_wait_on_address_wake(frequency);
    passed += check_fiber_scheduler(frequency);
    passed += check_clock_coherence(frequency);
    printf("summary passed=%d total=6\n", passed);
    return passed == 6 ? 0 : 1;
}
