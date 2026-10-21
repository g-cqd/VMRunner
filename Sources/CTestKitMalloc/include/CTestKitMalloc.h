#ifndef CADTESTKIT_MALLOC_H
#define CADTESTKIT_MALLOC_H

#include <stdint.h>

/// Process-wide heap-allocation counting for test perf guards (e.g. TestKit's `expectAllocations`).
///
/// On Darwin this installs libmalloc's logging hook (`malloc_logger`) — a documented-in-practice
/// tooling seam Instruments uses. It is enabled only in TEST / tooling builds and never ships in an
/// App-Store binary, so the private symbol is acceptable here. On other platforms the counter is a
/// no-op and `adtk_malloc_counting_available()` returns 0, so the Swift oracle degrades gracefully.
///
/// The count is per thread: only allocations made on the thread that called `begin`,
/// until it calls `end`, are counted, so parallel tests cannot disturb it. Count a SYNCHRONOUS region. Measurements must not overlap — TestKit's `mallocDelta` serializes them. A
/// `begin` while the counting hook is already installed is ignored rather than chaining the hook to
/// itself.

/// 1 when allocation counting is available on this platform (Darwin), 0 otherwise.
int adtk_malloc_counting_available(void);

/// Reset the counter, install the counting hook (chaining to any previously installed hook) and count the
/// calling thread.
void adtk_malloc_count_begin(void);

/// Window mode, for a measurement that is opened and closed by a thread other than the one it counts: like `begin`, but
/// the thread to count is named (its `pthread_self()` as an integer), and `count_end` may be called from any thread.
/// Allocations on that thread before this call are not counted.
void adtk_malloc_window_begin(uintptr_t thread);

/// Restore the previous hook and return the number of allocations observed since `begin`.
uint64_t adtk_malloc_count_end(void);

#endif /* CADTESTKIT_MALLOC_H */
