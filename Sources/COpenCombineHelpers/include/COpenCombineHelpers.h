// COpenCombineHelpers.h — the small C layer OpenCombine expects (locks, identifier, breakpoint).
//
// API copied from OpenCombine's COpenCombineHelpers so its Swift sources can be compiled
// unmodified apart from module qualification; the implementation is a pthread-based version of
// the same primitives (Android has no os_unfair_lock).
#ifndef COPENCOMBINEHELPERS_H
#define COPENCOMBINEHELPERS_H

#include <stdint.h>

#if __has_attribute(swift_name)
# define OPENCOMBINE_SWIFT_NAME(_name) __attribute__((swift_name(#_name)))
#else
# define OPENCOMBINE_SWIFT_NAME(_name)
#endif

#ifdef __cplusplus
extern "C" {
#endif

uint64_t opencombine_next_combine_identifier(void)
    OPENCOMBINE_SWIFT_NAME(__nextCombineIdentifier());

typedef struct OpenCombineUnfairLock {
    void* _Nonnull opaque;
} OPENCOMBINE_SWIFT_NAME(__UnfairLock) OpenCombineUnfairLock;
OpenCombineUnfairLock opencombine_unfair_lock_alloc(void) OPENCOMBINE_SWIFT_NAME(__UnfairLock.allocate());
void opencombine_unfair_lock_lock(OpenCombineUnfairLock) OPENCOMBINE_SWIFT_NAME(__UnfairLock.lock(self:));
void opencombine_unfair_lock_unlock(OpenCombineUnfairLock) OPENCOMBINE_SWIFT_NAME(__UnfairLock.unlock(self:));
void opencombine_unfair_lock_assert_owner(OpenCombineUnfairLock) OPENCOMBINE_SWIFT_NAME(__UnfairLock.assertOwner(self:));
void opencombine_unfair_lock_dealloc(OpenCombineUnfairLock) OPENCOMBINE_SWIFT_NAME(__UnfairLock.deallocate(self:));

typedef struct OpenCombineUnfairRecursiveLock {
    void* _Nonnull opaque;
} OPENCOMBINE_SWIFT_NAME(__UnfairRecursiveLock) OpenCombineUnfairRecursiveLock;
OpenCombineUnfairRecursiveLock opencombine_unfair_recursive_lock_alloc(void) OPENCOMBINE_SWIFT_NAME(__UnfairRecursiveLock.allocate());
void opencombine_unfair_recursive_lock_lock(OpenCombineUnfairRecursiveLock) OPENCOMBINE_SWIFT_NAME(__UnfairRecursiveLock.lock(self:));
void opencombine_unfair_recursive_lock_unlock(OpenCombineUnfairRecursiveLock) OPENCOMBINE_SWIFT_NAME(__UnfairRecursiveLock.unlock(self:));
void opencombine_unfair_recursive_lock_dealloc(OpenCombineUnfairRecursiveLock) OPENCOMBINE_SWIFT_NAME(__UnfairRecursiveLock.deallocate(self:));

void opencombine_stop_in_debugger(void) OPENCOMBINE_SWIFT_NAME(__stopInDebugger());

#ifdef __cplusplus
}
#endif

#endif
