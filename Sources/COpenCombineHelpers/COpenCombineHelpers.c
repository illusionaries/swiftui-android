// pthread-based implementation of OpenCombine's helper primitives (Android has no unfair locks).
#include "COpenCombineHelpers.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#if defined(__ANDROID__)
#include <android/log.h>
#endif

static _Atomic uint64_t g_next_identifier = 1;

uint64_t opencombine_next_combine_identifier(void) {
    return atomic_fetch_add_explicit(&g_next_identifier, 1, memory_order_relaxed);
}

typedef struct { pthread_mutex_t mutex; } lock_box;

OpenCombineUnfairLock opencombine_unfair_lock_alloc(void) {
    lock_box *box = (lock_box *)calloc(1, sizeof(lock_box));
    pthread_mutex_init(&box->mutex, NULL);
    OpenCombineUnfairLock lock = { (void *)box };
    return lock;
}

void opencombine_unfair_lock_lock(OpenCombineUnfairLock lock) {
    pthread_mutex_lock(&((lock_box *)lock.opaque)->mutex);
}

void opencombine_unfair_lock_unlock(OpenCombineUnfairLock lock) {
    pthread_mutex_unlock(&((lock_box *)lock.opaque)->mutex);
}

void opencombine_unfair_lock_assert_owner(OpenCombineUnfairLock lock) {
    (void)lock;  /* pthread mutexes are not owner-checkable; ownership checks are a debug aid. */
}

void opencombine_unfair_lock_dealloc(OpenCombineUnfairLock lock) {
    pthread_mutex_destroy(&((lock_box *)lock.opaque)->mutex);
    free(lock.opaque);
}

OpenCombineUnfairRecursiveLock opencombine_unfair_recursive_lock_alloc(void) {
    lock_box *box = (lock_box *)calloc(1, sizeof(lock_box));
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&box->mutex, &attr);
    pthread_mutexattr_destroy(&attr);
    OpenCombineUnfairRecursiveLock lock = { (void *)box };
    return lock;
}

void opencombine_unfair_recursive_lock_lock(OpenCombineUnfairRecursiveLock lock) {
    pthread_mutex_lock(&((lock_box *)lock.opaque)->mutex);
}

void opencombine_unfair_recursive_lock_unlock(OpenCombineUnfairRecursiveLock lock) {
    pthread_mutex_unlock(&((lock_box *)lock.opaque)->mutex);
}

void opencombine_unfair_recursive_lock_dealloc(OpenCombineUnfairRecursiveLock lock) {
    pthread_mutex_destroy(&((lock_box *)lock.opaque)->mutex);
    free(lock.opaque);
}

void opencombine_stop_in_debugger(void) {
#if defined(__ANDROID__)
    __android_log_print(ANDROID_LOG_DEBUG, "Combine", "breakpoint");
#endif
}
