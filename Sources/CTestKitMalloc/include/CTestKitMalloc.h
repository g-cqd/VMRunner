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

/// Reset the counter and install the counting hook (chaining to any previously installed hook).
void adtk_malloc_count_begin(void);

/// Restore the previous hook and return the number of allocations observed since `begin`.
uint64_t adtk_malloc_count_end(void);

#endif /* CADTESTKIT_MALLOC_H */
