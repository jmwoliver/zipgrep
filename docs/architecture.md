# zrep Codebase Deep Dive: A Newcomer's Guide

This report provides a comprehensive analysis of the zrep codebase - a high-performance grep implementation written in Zig. It covers key Zig language concepts, algorithms, data structures, and optimizations that make zrep work efficiently.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Key Zig Concepts Used](#key-zig-concepts-used)
3. [Core Algorithms](#core-algorithms)
4. [Data Structures](#data-structures)
5. [Performance Optimizations](#performance-optimizations)
6. [File-by-File Breakdown](#file-by-file-breakdown)

---

## Architecture Overview

### High-Level Flow

```
User Input --> Argument Parsing --> Pattern Compilation --> Parallel Directory Walking --> File Search --> Output
```

### Module Structure

| File | Purpose |
|------|---------|
| `main.zig` | Entry point, argument parsing, configuration |
| `parallel_walker.zig` | Multi-threaded directory traversal with work-stealing |
| `matcher.zig` | Pattern matching facade (literal vs regex) |
| `regex.zig` | NFA-based regex engine with literal pre-filtering |
| `simd.zig` | SIMD-accelerated string search |
| `literal.zig` | Extract literal substrings from regex for optimization |
| `deque.zig` | Lock-free work-stealing deque (Chase-Lev algorithm) |
| `gitignore.zig` | Gitignore pattern parsing and matching |
| `output.zig` | Result formatting and thread-safe output |
| `reader.zig` | File reading utilities |

---

## Key Zig Concepts Used

### 1. Explicit Memory Allocation

Zig requires explicit allocator passing - no hidden allocations:

```zig
// From main.zig:38-43
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // ...
}
```

**Why this matters**: You always know where memory comes from. The `ArenaAllocator` pattern is used because:
- Bulk allocation is faster than individual allocations
- Single `deinit()` frees everything at once
- No need to track individual allocations

### 2. Error Handling with Error Unions

Zig uses `!` to denote functions that can fail:

```zig
// From matcher.zig:19
pub fn init(allocator: std.mem.Allocator, pattern: []const u8, ignore_case: bool, word_boundary: bool) !Matcher {
```

The `try` keyword propagates errors up the call stack:

```zig
// From regex.zig:136
var re = try compiler.compile(pattern);
```

**Key pattern - `errdefer`**: Runs cleanup only if an error occurs:

```zig
// From regex.zig:137
errdefer compiler.states.deinit(allocator);
```

### 3. `defer` for Resource Cleanup

`defer` ensures cleanup happens when scope exits (success or failure):

```zig
// From parallel_walker.zig:295-296
var dir = std.fs.cwd().openDir(work.path, .{ .iterate = true }) catch return;
defer dir.close();
```

### 4. Optionals (`?T`)

Zig uses `?T` for values that may or may not exist:

```zig
// From regex.zig:11-16
const State = struct {
    transition: Transition,
    out1: ?usize = null,  // May or may not have a next state
    out2: ?usize = null,
};
```

Accessing optionals requires explicit unwrapping:

```zig
// From matcher.zig:132
const lower_pat = self.lower_pattern orelse return null;
```

### 5. Comptime (Compile-Time Computation)

Zig can execute code at compile time:

```zig
// From simd.zig:6-11
pub const VECTOR_WIDTH: usize = if (builtin.cpu.arch == .x86_64)
    if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) 32 else 16
else if (builtin.cpu.arch == .aarch64)
    16 // NEON is 128-bit
else
    16;
```

This selects the optimal SIMD width at compile time based on CPU architecture.

### 6. Generic Types (Compile-Time Polymorphism)

Zig uses `comptime` parameters for generics:

```zig
// From deque.zig:15
pub fn Buffer(comptime T: type) type {
    return struct {
        ptr: [*]T,
        capacity: usize,
        // ...
    };
}
```

Usage:
```zig
const BufferT = Buffer(T);  // Creates a specific type
```

### 7. Tagged Unions

Zig's `union(enum)` provides type-safe variants:

```zig
// From regex.zig:19-30
const Transition = union(enum) {
    any: void,           // Matches any character
    char: u8,            // Matches specific character
    char_class: CharClass,
    epsilon: void,       // No input consumed
    match: void,         // Accepting state
};
```

Switching on tagged unions:
```zig
return switch (transition) {
    .any => c != '\n',
    .char => |ch| ch == c,
    .char_class => |*cc| cc.contains(c),
    .epsilon, .match => false,
};
```

### 8. Slices vs Arrays

Zig distinguishes between fixed-size arrays and slices (fat pointers):

```zig
// Array - size known at compile time
const bitmap: [32]u8 = [_]u8{0} ** 32;

// Slice - size known at runtime (pointer + length)
const pattern: []const u8 = "hello";
```

### 9. Atomic Operations

For thread safety without locks:

```zig
// From parallel_walker.zig:63-66
done: std.atomic.Value(bool),
active_workers: std.atomic.Value(usize),

// Usage:
self.done.store(true, .release);
if (self.done.load(.acquire)) { ... }
```

Memory orderings (`.acquire`, `.release`, `.seq_cst`) control visibility guarantees between threads.

---

## Core Algorithms

### 1. Thompson's NFA Construction (regex.zig)

The regex engine implements Thompson's construction to build an NFA (Non-deterministic Finite Automaton):

```
Pattern: "ab*c"

NFA States:
[0: 'a'] --> [1: 'b'] --> [2: split] --> [3: 'c'] --> [4: match]
                ^               |
                +---------------+  (epsilon loop for *)
```

**Key insight**: The NFA uses a **bitset** to track all active states simultaneously:

```zig
// From regex.zig:63-90
const StateBitset = struct {
    bits: [MAX_STATES / 64]u64,  // 256 states = 4 u64 words

    pub fn set(self: *StateBitset, idx: usize) void {
        self.bits[idx / 64] |= @as(u64, 1) << @intCast(idx % 64);
    }

    pub fn isSet(self: *const StateBitset, idx: usize) bool {
        return (self.bits[idx / 64] & (@as(u64, 1) << @intCast(idx % 64))) != 0;
    }
};
```

**Why bitsets?** No allocations during matching - the bitset is stack-allocated.

### 2. Literal Pre-Filtering (literal.zig + regex.zig)

Before running the full regex, extract literal substrings for fast filtering:

```
Pattern: "hello.*world"
Extracted: "hello" (prefix)

Search strategy:
1. Use SIMD to find "hello" in text (fast)
2. Only run regex from positions where "hello" was found
```

Three extraction strategies (in priority order):
1. **Prefix**: `"hello.*"` -> extract `"hello"` (most efficient)
2. **Suffix**: `".*world"` -> extract `"world"`
3. **Inner**: `"[a-z]+FOO[a-z]+"` -> extract `"FOO"`

```zig
// From regex.zig:183-191
pub fn find(self: *const Regex, input: []const u8) ?MatchResult {
    if (self.literal_info) |info| {
        return switch (info.position) {
            .prefix => self.findWithPrefixFilter(input, info.literal),
            .suffix => self.findWithSuffixFilter(input, info.literal),
            .inner => self.findWithInnerFilter(input, info),
        };
    }
    return self.findBruteForce(input);
}
```

### 3. Chase-Lev Work-Stealing Deque (deque.zig)

A lock-free data structure for efficient parallel work distribution:

```
Worker 0 (owner):     [A, B, C, D]  <-- push/pop from bottom (LIFO)
                        ^
Worker 1 (stealer):    steal from top (FIFO) -->
Worker 2 (stealer):    steal from top (FIFO) -->
```

**Key properties**:
- Owner pushes/pops from bottom (no contention with self)
- Stealers compete for items at top using CAS (compare-and-swap)
- LIFO for owner = depth-first traversal (good cache locality)
- FIFO for stealers = breadth-first stealing (load balancing)

```zig
// From deque.zig:263-286 - Steal operation
pub fn steal(self: *Self) Result {
    const t = self.deque.top.load(.acquire);
    const b = self.deque.bottom.load(.seq_cst);

    if (t >= b) return .empty;

    const buffer = self.deque.buffer.load(.acquire);
    const item = buffer.get(@intCast(@mod(t, @as(isize, @intCast(buffer.capacity)))));

    // CAS to claim the item
    if (self.deque.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic)) |_| {
        return .retry;  // Another stealer won
    }
    return .{ .success = item };
}
```

### 4. Glob Pattern Matching (gitignore.zig)

Implements glob matching with backtracking:

```zig
// From gitignore.zig:69-158
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var star_p: ?usize = null;  // Last * position in pattern
    var star_t: usize = 0;      // Text position when * was seen

    while (t < text.len) {
        switch (pattern[p]) {
            '*' => {
                if (pattern[p + 1] == '*') {
                    // ** matches across path separators
                    // ... recursive handling
                }
                star_p = p;  // Remember for backtracking
                star_t = t;
                p += 1;
            },
            // ... other cases
        }

        // No match? Backtrack to last *
        if (star_p) |sp| {
            p = sp + 1;
            star_t += 1;
            t = star_t;
            continue;
        }
        return false;
    }
}
```

---

## Data Structures

### 1. Character Class Bitmap (regex.zig:32-60)

Efficiently represent character sets like `[a-zA-Z0-9]`:

```zig
const CharClass = struct {
    bitmap: [32]u8,  // 256 bits = all ASCII characters
    negated: bool,

    pub fn contains(self: *const CharClass, c: u8) bool {
        const in_set = (self.bitmap[c / 8] & (@as(u8, 1) << @intCast(c % 8))) != 0;
        return if (self.negated) !in_set else in_set;
    }
};
```

**Why 32 bytes?** 256 bits covers all 256 possible byte values. Each bit represents one character.

### 2. Work Item (parallel_walker.zig:11-36)

Represents a directory to process:

```zig
pub const WorkItem = struct {
    path: []const u8,
    depth: usize,

    // Uses thread-safe page_allocator - safe for concurrent alloc/free
    const allocator = std.heap.page_allocator;
};
```

### 3. Configuration Struct (main.zig:17-36)

All search options in one place:

```zig
pub const Config = struct {
    pattern: []const u8,
    paths: []const []const u8,
    ignore_case: bool = false,
    line_number: bool = true,
    count_only: bool = false,
    files_with_matches: bool = false,
    no_ignore: bool = false,
    hidden: bool = false,
    word_boundary: bool = false,
    max_depth: ?usize = null,
    num_threads: ?usize = null,
    color: ColorMode = .auto,
    heading: HeadingMode = .auto,
    glob_patterns: []const GlobPattern = &.{},
};
```

---

## Performance Optimizations

### 1. SIMD-Ready Architecture (simd.zig)

Platform-specific vector width selection at compile time:

```zig
pub const VECTOR_WIDTH: usize = if (builtin.cpu.arch == .x86_64)
    if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) 32 else 16
else if (builtin.cpu.arch == .aarch64)
    16 // NEON
else
    16;

pub const Vec = @Vector(VECTOR_WIDTH, u8);
```

### 2. First-Byte Acceleration (simd.zig:18-66)

Quick filter on first character before full comparison:

```zig
pub fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    const first_byte = needle[0];

    while (pos <= haystack.len - needle.len) {
        // Find next occurrence of first byte (fast)
        while (i < haystack[pos..].len) : (i += 1) {
            if (haystack[pos + i] == first_byte) {
                // Found potential match - verify rest
                if (std.mem.eql(u8, haystack[pos + 1..][0..rest.len], rest)) {
                    return pos;
                }
            }
        }
    }
}
```

### 3. Arena Allocator for Bulk Operations (main.zig:39-43)

Single allocation strategy eliminates per-object overhead:

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();  // One call frees everything
```

### 4. Thread-Local Arena Allocators (parallel_walker.zig:176-179)

Each worker thread has its own arena - no contention:

```zig
fn workerThreadFn(self: *ParallelWalker, worker_id: usize) void {
    var thread_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer thread_arena.deinit();
    // All allocations in this thread use thread_arena
}
```

### 5. Per-File Output Buffering (parallel_walker.zig:380-410)

Batch output to reduce mutex contention:

```zig
var file_buf = output.FileBuffer.init(alloc, self.config, ...);
defer file_buf.deinit();

// Collect all matches for this file
while (line_iter.next()) |line| {
    if (self.pattern_matcher.findFirst(line.content)) |match| {
        try file_buf.addMatch(...);
    }
}

// Single mutex lock to flush all matches
try self.out.flushFileBuffer(&file_buf);
```

### 6. Binary File Detection (parallel_walker.zig:374-378)

Skip binary files early (check first 8KB for NUL bytes):

```zig
const check_len = @min(data.len, 8192);
for (data[0..check_len]) |byte| {
    if (byte == 0) return;  // Binary file, skip
}
```

### 7. Literal vs Regex Fast Path (matcher.zig:20-33)

Detect if pattern is literal (no metacharacters):

```zig
const is_literal = !containsRegexMetaChars(pattern);

if (is_literal) {
    // Use fast SIMD string search
} else {
    // Compile and use regex engine
}
```

### 8. Work-Stealing Load Balancing (parallel_walker.zig:212-228)

Idle workers steal from busy workers:

```zig
fn trySteal(self: *ParallelWalker, worker_id: usize) ?*WorkItem {
    for (1..self.num_threads) |offset| {
        const target = (worker_id + offset) % self.num_threads;
        var stealer = self.deques[target].?.stealer();

        switch (stealer.steal()) {
            .success => |item| return item,
            .empty => break,
            .retry => continue,
        }
    }
    return null;
}
```

---

## File-by-File Breakdown

### main.zig
- **Entry point**: `main()` at line 38
- **Argument parsing**: `parseArgs()` at line 55
- **Config struct**: Lines 17-36
- Uses arena allocator for entire program lifetime

### parallel_walker.zig
- **ParallelWalker struct**: Lines 46-133
- **Worker thread function**: `workerThreadFn()` at line 173
- **Work stealing**: `trySteal()` at line 213
- **Directory processing**: `processDirectory()` at line 286
- **File search**: `searchFile()` at line 367

### matcher.zig
- **Matcher struct**: Lines 10-44
- **Literal detection**: `containsRegexMetaChars()` at line 151
- **Word boundary matching**: `isWordBoundaryMatch()` at line 98
- Facade pattern - delegates to SIMD or regex based on pattern

### regex.zig
- **NFA State**: Lines 10-17
- **Transition types**: Lines 19-30
- **StateBitset**: Lines 63-125 (no-allocation state tracking)
- **Regex compiler**: Lines 354-656
- **Literal extraction integration**: Lines 141-154

### simd.zig
- **Vector width selection**: Lines 4-11 (comptime)
- **Substring search**: `findSubstring()` at line 18
- First-byte acceleration pattern

### deque.zig
- **Buffer (circular array)**: Lines 15-71
- **Deque**: Lines 88-174
- **Worker (owner operations)**: Lines 179-248
- **Stealer (theft operations)**: Lines 253-293
- Chase-Lev algorithm implementation

### literal.zig
- **LiteralInfo**: Lines 4-17
- **Best literal extraction**: `extractBestLiteral()` at line 26
- **Literal scoring**: `scoreLiteral()` at line 375 (rarity-based)

### gitignore.zig
- **Glob matching**: `globMatch()` at line 69
- **GitignoreMatcher**: Lines 311-452
- **GitignoreState** (thread-local): Lines 457-652
- Supports proper scoping per-directory

---

## Summary

zrep achieves high performance through:

1. **Smart algorithm selection**: Literal patterns bypass regex entirely
2. **SIMD-ready design**: Platform-optimal vector widths at compile time
3. **Lock-free parallelism**: Work-stealing deques minimize contention
4. **Zero-allocation matching**: Bitsets track NFA states on stack
5. **Batch I/O**: Per-file output buffering reduces mutex contention
6. **Early rejection**: Literal pre-filtering, binary file detection

The codebase demonstrates idiomatic Zig patterns:
- Explicit memory management with allocators
- Error handling via error unions and `try`/`errdefer`
- Compile-time computation with `comptime`
- Generic programming with type functions
- Safe concurrency with atomics and proper memory orderings
