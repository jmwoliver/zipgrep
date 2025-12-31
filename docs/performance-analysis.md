# zrep Performance Analysis and Optimization Plan

## Executive Summary

After deep analysis of zrep's architecture, I've identified **critical performance bottlenecks** and optimization opportunities. The codebase has a solid foundation but several areas are leaving significant performance on the table compared to ripgrep.

---

## Current Architecture Overview

### Hot Path Flow
```
main.zig -> parallel_walker.zig -> processDirectory() -> searchFile()
                                                              |
                                                              v
reader.zig (mmap/read) -> LineIterator -> matcher.zig -> regex.zig/simd.zig
                                                              |
                                                              v
                                                         output.zig
```

### What's Working Well
- Work-stealing deque (Chase-Lev algorithm) - excellent design
- Arena allocators for thread-local memory
- Literal pre-filtering before regex
- mmap for files under 128MB with MADV_SEQUENTIAL

---

## Critical Performance Issues Identified

### 1. SIMD Implementation is NOT Actually SIMD (CRITICAL)

**File:** [simd.zig:18-66](src/simd.zig#L18-L66)

The `findSubstring` function declares SIMD vectors but **never uses them**. It's doing scalar byte-by-byte comparison:

```zig
// This is scalar, NOT SIMD!
while (i < haystack[pos..].len) : (i += 1) {
    if (haystack[pos + i] == first_byte) { ... }
}
```

**Impact:** This is likely 8-16x slower than true SIMD search. Ripgrep uses `memchr` with AVX2/NEON intrinsics.

**Fix:** Implement actual SIMD vectorized search using `@Vector` operations with `@reduce`.

### 2. findNewline is Also Scalar (CRITICAL)

**File:** [simd.zig:85-91](src/simd.zig#L85-L91)

```zig
pub fn findNewline(haystack: []const u8) ?usize {
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == '\n') return i;
    }
    return null;
}
```

This is called for **every line** in **every file**. Should use SIMD.

### 3. Case-Insensitive Search is O(n*m) (HIGH)

**File:** [matcher.zig:131-156](src/matcher.zig#L131-L156)

```zig
fn findLiteralIgnoreCaseWithWordBoundary(self: *const Matcher, haystack: []const u8) ?MatchResult {
    var i: usize = 0;
    outer: while (i <= haystack.len - lower_pat.len) : (i += 1) {
        for (lower_pat, 0..) |pc, j| {
            const hc = std.ascii.toLower(haystack[i + j]);  // toLower called per byte!
            if (hc != pc) continue :outer;
        }
    }
}
```

**Impact:** `toLower` is called for every byte comparison. Should pre-compute case-folded version or use SIMD.

### 4. NFA State Iteration Creates Branches (MEDIUM-HIGH)

**File:** [regex.zig:327-339](src/regex.zig#L327-L339)

The NFA matcher iterates through a bitset and processes states one-by-one:

```zig
var iter = current_states.iterator();
while (iter.next()) |state_idx| {
    const state = self.states.items[state_idx];
    if (self.matchTransition(state.transition, c)) { ... }
}
```

This creates unpredictable branches. Could be optimized with:
- DFA compilation for common patterns
- Bitset operations instead of iteration for simple patterns

### 5. Output Buffer Growing Dynamically (MEDIUM)

**File:** [output.zig:57](src/output.zig#L57)

`FileBuffer` uses `ArrayListUnmanaged` which reallocates on growth. Pre-sizing or using a fixed buffer would reduce allocations.

### 6. Binary File Detection Per-File (LOW-MEDIUM)

**File:** [parallel_walker.zig:374-378](src/parallel_walker.zig#L374-L378)

Binary detection scans first 8KB byte-by-byte looking for NUL:

```zig
for (data[0..check_len]) |byte| {
    if (byte == 0) return;
}
```

Should use SIMD to find NUL bytes.

### 7. Path String Allocations (MEDIUM)

**File:** [parallel_walker.zig:324](src/parallel_walker.zig#L324)

`std.fs.path.join` allocates for every directory entry:

```zig
const full_path = std.fs.path.join(alloc, &.{ work.path, entry.name }) catch continue;
```

Could use stack-allocated buffer with `std.fmt.bufPrint`.

---

## Profiling Recommendations

### 1. Instruments (macOS) - CPU Profiling
```bash
# Time Profiler
xcrun xctrace record --template 'Time Profiler' --launch -- ./zig-out/bin/zrep "pattern" ~/large-codebase

# System Call Analysis
xcrun xctrace record --template 'System Calls' --launch -- ./zig-out/bin/zrep "pattern" ~/large-codebase
```

### 2. perf (Linux)
```bash
# CPU cycles and cache misses
perf stat -e cycles,instructions,cache-references,cache-misses,branch-misses \
    ./zig-out/bin/zrep "pattern" ~/large-codebase

# Flame graph
perf record -g ./zig-out/bin/zrep "pattern" ~/large-codebase
perf script | stackcollapse-perf.pl | flamegraph.pl > zrep.svg
```

### 3. dtrace (macOS) - Syscall Analysis
```bash
# Count syscalls
sudo dtrace -n 'syscall:::entry /execname == "zrep"/ { @[probefunc] = count(); }' \
    -c './zig-out/bin/zrep "pattern" ~/large-codebase'

# I/O latency
sudo dtrace -n 'syscall::read:entry /execname == "zrep"/ { self->ts = timestamp; }
               syscall::read:return /self->ts/ { @["read latency (ns)"] = quantize(timestamp - self->ts); self->ts = 0; }'
```

### 4. Zig's Built-in Profiler
```bash
# Build with profiling
zig build -Doptimize=ReleaseFast -Denable-tracy=true

# Or use Zig's sampling profiler
zig build -Doptimize=ReleaseSafe --verbose-air
```

### 5. Valgrind/Cachegrind (Linux)
```bash
# Cache analysis
valgrind --tool=cachegrind ./zig-out/bin/zrep "pattern" ~/codebase
cg_annotate cachegrind.out.* > cache_report.txt
```

### 6. hyperfine (Benchmarking)
Already in use. Add more granular benchmarks:
```bash
# Test specific patterns
hyperfine --warmup 3 \
    'rg "literal_string" ~/linux' \
    './zig-out/bin/zrep "literal_string" ~/linux' \
    --export-json bench_literal.json

# Test with different thread counts
hyperfine --warmup 3 \
    './zig-out/bin/zrep -j1 "pattern" ~/linux' \
    './zig-out/bin/zrep -j4 "pattern" ~/linux' \
    './zig-out/bin/zrep -j8 "pattern" ~/linux'
```

---

## Optimization Implementation Plan

### Phase 1: SIMD Hot Path (Highest Impact)

#### 1.1 Implement True SIMD Substring Search
**File:** `src/simd.zig`

```zig
pub fn findSubstringSimd(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    const first_byte = needle[0];
    const first_vec: Vec = @splat(first_byte);

    var pos: usize = 0;
    while (pos + VECTOR_WIDTH <= haystack.len - needle.len + 1) {
        const chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const cmp = chunk == first_vec;
        const mask = @as(u32, @bitCast(cmp));

        if (mask != 0) {
            const offset = @ctz(mask);
            const candidate = pos + offset;
            if (std.mem.eql(u8, haystack[candidate..][0..needle.len], needle)) {
                return candidate;
            }
        }
        pos += VECTOR_WIDTH;
    }
    // Scalar fallback for remainder
    return findSubstringScalar(haystack[pos..], needle);
}
```

#### 1.2 SIMD Newline Finding
```zig
pub fn findNewlineSimd(haystack: []const u8) ?usize {
    const newline_vec: Vec = @splat('\n');
    var pos: usize = 0;

    while (pos + VECTOR_WIDTH <= haystack.len) {
        const chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const cmp = chunk == newline_vec;
        if (@reduce(.Or, cmp)) {
            const mask = @as(u32, @bitCast(cmp));
            return pos + @ctz(mask);
        }
        pos += VECTOR_WIDTH;
    }
    // Scalar fallback
    for (haystack[pos..], pos..) |byte, i| {
        if (byte == '\n') return i;
    }
    return null;
}
```

### Phase 2: Case-Insensitive Optimization

#### 2.1 Pre-compute Case Tables or Use SIMD
**File:** `src/matcher.zig`

Option A: Use SIMD with bit manipulation for ASCII case folding:
```zig
// ASCII case folding: set bit 5 for letters to make lowercase
fn toLowerSimd(vec: Vec) Vec {
    const a_vec: Vec = @splat('A');
    const z_vec: Vec = @splat('Z');
    const is_upper = (vec >= a_vec) & (vec <= z_vec);
    const case_bit: Vec = @splat(0x20);
    return vec | (is_upper & case_bit);
}
```

### Phase 3: Memory Optimizations

#### 3.1 Stack-Allocated Path Buffer
**File:** `src/parallel_walker.zig`

```zig
fn processDirectory(...) void {
    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    // ...
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{work.path, entry.name}) catch continue;
}
```

#### 3.2 Pre-sized Output Buffers
**File:** `src/output.zig`

```zig
pub fn init(...) FileBuffer {
    var buffer = std.ArrayListUnmanaged(u8){};
    buffer.ensureTotalCapacity(allocator, 4096) catch {};  // Pre-allocate
    return .{ .buffer = buffer, ... };
}
```

### Phase 4: Regex Engine Optimization

#### 4.1 DFA Compilation for Simple Patterns
For patterns like `[A-Z]+` or `\d+`, compile to a DFA instead of NFA simulation.

#### 4.2 Better Literal Extraction
Improve literal extraction to handle more patterns and longer literals.

---

## Data-Oriented Design Principles to Apply

1. **Structure of Arrays (SoA)**: Consider separating NFA state data into separate arrays by field type for better cache utilization during matching.

2. **Hot/Cold Splitting**: Move rarely-used fields (like error handling data) to separate structures.

3. **Prefetching**: Add `@prefetch` hints before accessing file data or state arrays.

4. **Alignment**: Ensure critical data structures are cache-line aligned (64 bytes).

5. **Branch Elimination**: Use branchless techniques where possible:
   ```zig
   // Instead of:
   if (c >= 'A' and c <= 'Z') c += 32;
   // Use:
   c |= ((c >= 'A') & (c <= 'Z')) << 5;
   ```

---

## Files to Modify

| Priority | File | Changes |
|----------|------|---------|
| P0 | `src/simd.zig` | Implement actual SIMD for substring/newline search |
| P0 | `src/matcher.zig` | SIMD case-insensitive search |
| P1 | `src/parallel_walker.zig` | Stack-allocated path buffers, SIMD binary detection |
| P1 | `src/reader.zig` | SIMD newline integration |
| P2 | `src/regex.zig` | DFA compilation, better literal extraction |
| P2 | `src/output.zig` | Pre-sized buffers |

---

## Expected Performance Gains

| Optimization | Estimated Improvement |
|--------------|----------------------|
| True SIMD substring search | 4-8x for literal patterns |
| SIMD newline finding | 2-4x for line iteration |
| SIMD case-insensitive | 2-4x for `-i` flag |
| Stack-allocated paths | 10-20% overall |
| Pre-sized buffers | 5-10% overall |
| DFA compilation | 2-10x for simple regex |

**Total potential improvement: 2-5x faster than current implementation**

---

## Deliverables (Analysis Only)

This plan provides:
1. Complete bottleneck analysis with code locations
2. Profiling tool commands and setup instructions
3. Optimization strategies with pseudocode examples
4. Expected impact estimates

You will implement the changes yourself based on this analysis.

---

## Additional Profiling Deep-Dive

### Memory Allocation Profiling

#### Using Zig's Debug Allocator
Wrap the main allocator to track allocations:

```zig
// In main.zig, for debugging
const debug_allocator = std.heap.DebugAllocator(.{
    .stack_trace_frames = 10,
    .log_to_stderr = true,
}).init(std.heap.page_allocator);
```

#### macOS malloc debugging
```bash
# Track all allocations
MallocStackLogging=1 ./zig-out/bin/zrep "pattern" ~/codebase 2> malloc.log
# Analyze with
leaks --atExit -- ./zig-out/bin/zrep "pattern" ~/codebase
```

### I/O Analysis

#### File descriptor and mmap analysis
```bash
# macOS - track file operations
sudo fs_usage -f filesys zrep

# Linux - strace for syscalls
strace -c -f ./zig-out/bin/zrep "pattern" ~/codebase 2>&1 | head -50

# Detailed I/O timing
strace -T -e read,mmap,open ./zig-out/bin/zrep "pattern" ~/codebase
```

#### Check if mmap is being used effectively
```bash
# Watch memory mapping during execution
vmmap $(pgrep zrep) | grep -E "(MALLOC|mapped)"
```

### Cache Performance Analysis

#### CPU Cache Behavior (Linux perf)
```bash
perf stat -e L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses \
    ./zig-out/bin/zrep "pattern" ~/large-codebase

# Calculate miss rate: misses / loads * 100
```

#### Branch Prediction
```bash
perf stat -e branches,branch-misses ./zig-out/bin/zrep "pattern" ~/codebase
# Aim for <5% branch miss rate
```

### Thread Contention Analysis

#### Lock contention visualization
```bash
# macOS
sudo spindump -i 5 -o zrep_spin.txt $(pgrep zrep)

# Linux - mutex contention
perf lock record ./zig-out/bin/zrep "pattern" ~/codebase
perf lock report
```

---

## Recommended Profiling Workflow

### Step 1: Baseline Measurement
```bash
# Run comprehensive benchmark
hyperfine --warmup 3 --min-runs 10 \
    'rg "TODO" ~/large-codebase' \
    './zig-out/bin/zrep "TODO" ~/large-codebase' \
    --export-json baseline.json
```

### Step 2: Identify Hotspots
```bash
# macOS Instruments Time Profiler
xcrun xctrace record --template 'Time Profiler' \
    --output zrep_profile.trace \
    --launch -- ./zig-out/bin/zrep "pattern" ~/large-codebase

# Open in Instruments.app for analysis
open zrep_profile.trace
```

### Step 3: Syscall Analysis
```bash
# Count which syscalls dominate
sudo dtruss -c ./zig-out/bin/zrep "pattern" ~/large-codebase 2>&1 | tail -20
```

### Step 4: Memory Analysis
```bash
# Check for excessive allocations
MallocStackLogging=lite leaks --atExit -- ./zig-out/bin/zrep "pattern" ~/codebase
```

### Step 5: Compare with ripgrep
```bash
# Profile ripgrep the same way to see what it does differently
xcrun xctrace record --template 'Time Profiler' \
    --output rg_profile.trace \
    --launch -- rg "pattern" ~/large-codebase
```

---

## Quick Wins to Verify First

Before major rewrites, verify these quick hypotheses:

### Hypothesis 1: SIMD is the main bottleneck
```bash
# Create a test with pure literal search vs regex
hyperfine \
    './zig-out/bin/zrep "EXACT_LITERAL" ~/linux' \
    './zig-out/bin/zrep "EXACT.*LITERAL" ~/linux'
```
If literal is much faster than regex, focus on regex optimization.
If both are slow, focus on SIMD.

### Hypothesis 2: I/O is limiting
```bash
# Compare with files already in cache
# First run loads files, second should be faster
./zig-out/bin/zrep "pattern" ~/codebase > /dev/null
./zig-out/bin/zrep "pattern" ~/codebase > /dev/null  # Should be faster

# If second run isn't significantly faster, I/O isn't the bottleneck
```

### Hypothesis 3: Thread overhead
```bash
# Compare single vs multi-threaded
hyperfine \
    './zig-out/bin/zrep -j1 "pattern" ~/codebase' \
    './zig-out/bin/zrep -j4 "pattern" ~/codebase' \
    './zig-out/bin/zrep -j8 "pattern" ~/codebase'
```
If single-threaded is faster, there's contention or thread overhead.

---

## Architecture-Specific Notes

### Apple Silicon (M1/M2/M3)
- NEON is 128-bit, so VECTOR_WIDTH=16 is correct
- Apple's Accelerate framework has optimized string functions
- Consider using `memchr` from libc which Apple has optimized

### x86_64 with AVX2
- 256-bit vectors (VECTOR_WIDTH=32)
- Can process 32 bytes per iteration
- Important: ensure data is 32-byte aligned for best performance

### x86_64 without AVX2
- Falls back to SSE (128-bit)
- Still 4x faster than scalar for many operations

---

## Summary: Top 5 Things to Profile

1. **Time in `findSubstring` / `findNewline`** - Are these truly the hotspots?
2. **Branch misprediction rate** - Is the NFA matcher causing pipeline stalls?
3. **Cache miss rate** - Is data access pattern causing cache thrashing?
4. **Memory allocation count** - Are we allocating too much per-file?
5. **Syscall overhead** - Are we making too many read/stat calls?

Run the profiling workflow above and share the results - this will confirm which optimizations will have the biggest impact on your specific workloads and hardware.