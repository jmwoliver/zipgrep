# zipgrep

A high-performance grep implementation written in Zig, inspired by [ripgrep](https://github.com/BurntSushi/ripgrep).

zipgrep recursively searches directories for a regex pattern while respecting `.gitignore` files, with colorized output and parallel file searching.

## Features

- **Fast literal search** using SIMD-accelerated byte matching
- **Multi-literal search** using packed SIMD fingerprints or Aho-Corasick
- **Regex acceleration** using required-literal filters and bounded DFAs over a Thompson/Pike NFA
- **Unicode-aware regexes** with scalar character classes, Unicode 16.0 Perl `\w`, and simple case folding
- **Word boundary matching** with exact Unicode semantics via `-w`
- **Parallel file searching** using a thread pool across multiple CPU cores
- **Inherited gitignore support** - applies repository and nested `.gitignore` rules
- **Glob file filtering** with `-g` flag for include/exclude patterns
- **NUL-based binary handling** with ripgrep-like recursive and explicit-file behavior
- **Colorized output** - file paths, line numbers, and matches are highlighted
- **Smart output formatting** - auto-detects TTY vs pipe for heading/color defaults
- **Bounded I/O memory** using rolling stream buffers or reclaimable 8 MiB mmap windows
- **Early termination** for `-q` and `-l`, including cross-worker cancellation
- **Small binary** - about 2.2 MiB versus 5.2 MiB for the Linux musl ripgrep binary used below

## Installation

### Homebrew (macOS)

```bash
brew install jmwoliver/tap/zipgrep
```

### Building from source

Requires [Zig](https://ziglang.org/) 0.15.2.

```bash
# Clone the repository
git clone https://github.com/jmwoliver/zipgrep.git
cd zipgrep

# Build release version
zig build -Doptimize=ReleaseFast

# Binary is at ./zig-out/bin/zg
```

### Running tests

```bash
zig build test
zig build test-integration -Doptimize=ReleaseFast
```

## Usage

```
zg [OPTIONS] PATTERN [PATH ...]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `PATTERN` | The pattern to search for (literal string or regex) |
| `PATH` | Files or directories to search (default: current directory) |

### Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-i, --ignore-case` | Case insensitive search |
| `-w, --word-regexp` | Match whole words only |
| `-n, --line-number` | Show line numbers (automatic for TTY output) |
| `-c, --count` | Only show count of matching lines per file |
| `-l, --files-with-matches` | Only show filenames containing matches |
| `-q, --quiet` | Suppress output and stop after the first match |
| `-g, --glob GLOB` | Include/exclude files or directories (supports `!` for negation) |
| `--no-ignore` | Don't respect `.gitignore` files |
| `--hidden` | Search hidden files and directories |
| `-j, --threads NUM` | Number of threads to use (default: CPU count, capped at 8) |
| `-d, --max-depth NUM` | Maximum directory depth to search |
| `--color MODE` | Color mode: `auto`, `always`, `never` (default: `auto`) |
| `--heading` | Group matches by file with headers (default for TTY) |
| `--no-heading` | Print `file:line:content` format (default for pipes) |

### Examples

```bash
# Search for "TODO" in current directory
zg TODO

# Search in specific directory
zg "function" src/

# Case-insensitive search
zg -i "error" logs/

# Word boundary matching (matches "test" but not "testing" or "contest")
zg -w "test" src/

# Count matches per file
zg -c "import" .

# List files containing matches
zg -l "TODO" .

# Force colored output (useful when piping)
zg --color always "pattern" | less -R

# Search with regex
zg "fn.*\(" src/       # Find function definitions
zg "[0-9]+" data/      # Find numbers
zg "foo|bar" .         # Find "foo" or "bar"

# File filtering with globs
zg "fn main" -g '*.zig'                  # Only search .zig files
zg "import" -g '*.zig' -g '!*_test.zig'  # Exclude test files
zg "TODO" -g '!vendor/'                  # Exclude vendor directory
zg "config" -g '*.json' -g '*.yaml'      # Search multiple file types

# Output format control
zg --heading "pattern" .      # Grouped output with file headers
zg --no-heading "pattern" .   # Flat file:line:content format

# Ignore gitignore and search everything
zg --no-ignore "secret" .

# Search hidden files
zg --hidden "config" .

# Limit search depth
zg -d 2 "config" .

# Control thread count
zg -j 1 "pattern" .    # Single-threaded (useful for debugging)
zg -j 8 "pattern" .    # Use 8 threads
```

## How It Works

### Sampled-Pair SIMD Fingerprinting

One key optimization is **two-byte fingerprinting**: sampling the input, choosing two selective bytes from a pattern, and searching for both at their required offsets simultaneously. This sharply reduces false positives compared with a single-byte filter (based on ripgrep's "packed pair" approach from the memchr crate).

```zig
// Instead of filtering on one byte, select two bytes from the pattern.
const first_vec: Vec = @splat(first_byte);
const second_vec: Vec = @splat(second_byte);

// Load both positions in one pass
const first_chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
const second_chunk: Vec = haystack[pos + offset..][0..VECTOR_WIDTH].*;

// Only positions where BOTH bytes match are candidates
const mask = @as(MaskType, @bitCast(first_chunk == first_vec)) &
             @as(MaskType, @bitCast(second_chunk == second_vec));
```

For case-insensitive search, this checks **4 byte combinations** per position (upper/lower × first/second).

### Architecture-Aware Vectorization

zipgrep selects a practical SIMD width for each target:
- **AVX2** (32 bytes) on x86_64 with AVX2 support
- **NEON** (16 bytes) on ARM64 (Apple Silicon, etc.)
- **Fallback** (16 bytes) on other architectures

### Packed and Aho-Corasick Multi-Pattern Search

Pure-literal alternations such as `ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT` bypass the regex VM. Small sets use packed SIMD fingerprints (including Teddy-style filters); larger sets use Aho-Corasick:

- **O(n) search**: Single pass through input regardless of number of patterns
- **Dense transition tables**: O(1) byte lookup using 256-entry arrays per state
- **Automatic detection**: Pure-literal alternation patterns are routed to AC automaton

### Literal Extraction & Scoring

Before applying regex matching, zipgrep extracts literal substrings for SIMD pre-filtering:

```zig
switch (info.position) {
    .prefix => // "hello.*" -> scan for "hello" first
    .suffix => // ".*_PLATFORM" -> scan for "_PLATFORM" first
    .inner =>  // "[a-z]+_FOO_[a-z]+" -> scan for "_FOO_" first
}
```

The scoring system selects the most selective literal:
- Longer literals score higher (better filtering)
- Rare characters (`_`, `Q`, `X`, `Z`, digits) score higher than common letters (`e`, `t`, `a`, ` `)

### Buffer-First Search

Instead of processing files line-by-line, zipgrep searches the entire buffer for the pattern first, then only processes lines that contain matches:

- **256 KiB rolling buffer**: Amortizes syscalls while keeping recursive-worker RSS low
- **8 MiB mmap windows**: Explicit large files avoid copies, with processed pages released via `MADV_DONTNEED`
- **SIMD newline counting**: Uses vectorized `@popCount` for fast line number calculation
- **Complete-line retention**: Correctly handles matches and output across read boundaries, including arbitrarily long lines

### Regex Engine

zipgrep implements a Thompson NFA-based regex engine with:
- **Bitset state tracking**: No allocations during matching (256-state bitset)
- **Ordered Pike execution**: Preserves leftmost-first alternation and greedy quantifier semantics
- **Bounded DFA execution**: Accelerates compatible line and count searches without unbounded state growth
- **Literal pre-filtering**: SIMD finds candidates before NFA evaluation
- **Greedy pattern optimization**: For `.*SUFFIX` patterns, reduces O(n²) to O(n)

Supported syntax includes `.`, `*`, `+`, `?`, `{m}`, `{m,}`, `{m,n}`, grouping, alternation, `^`, `$`, Unicode literals and class ranges, negated classes, `\d`/`\D`, `\s`/`\S`, `\w`/`\W`, escaped metacharacters, and `\t`/`\r`. Search remains line-oriented, so patterns containing a literal newline or `\n` are rejected.

### Parallelism

zipgrep uses parallel directory traversal with work stealing:
- **Parallel traversal**: Directory walking and file searching happen concurrently
- **Safe work stealing**: Owner-LIFO/stealer-FIFO deques use synchronized claims so an owning work item can never be processed twice
- **Configurable**: Use `-j N` to control thread count (automatic mode uses up to 8 CPU cores)
- **Batched output**: Each file is emitted under one output lock; explicit `-j 1` inputs retain command-line order

### File I/O Strategy

| Scenario | Strategy |
|----------|----------|
| Explicit regular file ≥1 MiB | mmap, processed in 8 MiB windows with page reclamation |
| Recursive/small file | Streaming with a 256 KiB rolling buffer |
| stdin | Streaming with a 256 KiB rolling buffer |
| Pathological long line | Rolling buffer grows only to the longest retained line |

## Benchmarks

Warm-cache medians below compare a `ReleaseFast` build with ripgrep 15.2.0 invoked using `--no-config`. They were measured on an 8-vCPU Intel Xeon Linux orb in August 2026. Results are workload- and hardware-dependent; they are evidence for these corpora, not a claim that any implementation wins universally.

These tables record the focused measurements used during the optimization work. Raw samples and the exact harness are not committed, and the checked-in `benchsuite` does not currently reproduce the count, quiet, list, stdin, color, or RSS scenarios below. Treat the figures as reported results rather than independently reproducible benchmark artifacts.

### 512 MiB English subtitle file

| Mode and pattern | zg | rg | zg / rg |
|------------------|---:|---:|--------:|
| count `Sherlock` | 105.0 ms | 113.0 ms | **0.93** |
| count absent literal | 93.3 ms | 106.8 ms | **0.87** |
| count `.` | 607.1 ms | 1294.2 ms | **0.47** |
| count `-w .` | 646.0 ms | 1541.9 ms | **0.42** |
| count `[^abc]+` | 640.9 ms | 1956.7 ms | **0.33** |
| count <code>-i 'Sherlock&#124;John'</code> | 117.0 ms | 205.5 ms | **0.57** |
| sparse matching output | 116.5 ms | 125.1 ms | **0.93** |
| dense matching output | 1096.7 ms | 1983.4 ms | **0.55** |
| quiet, early match | 0.5 ms | 1.8 ms | **0.26** |
| quiet, absent match | 103.9 ms | 129.6 ms | **0.80** |
| stdin count `Sherlock` | 111.6 ms | 120.8 ms | **0.92** |

On a 128 MiB slice, dense forced-color output took 658 ms versus 4403 ms; sparse forced-color output took 28.7 ms versus 32.4 ms. Output bytes were compared exactly, including all non-overlapping highlighted matches.

### Linux source tree (1.7 GiB, 79K files)

| Mode | zg | rg | zg / rg |
|------|---:|---:|--------:|
| absent, `-q -j1` | 774.7 ms | 863.8 ms | **0.90** |
| absent, `-q -j8` | 107.9 ms | 177.8 ms | **0.61** |
| early match, `-q -j8` | 2.8 ms | 7.8 ms | **0.36** |
| list files, `-l -j8` | 113.5 ms | 182.0 ms | **0.62** |
| count files, `-c -j8` | 125.6 ms | 194.7 ms | **0.65** |

Sorted recursive normal, list, and count output was byte-for-byte identical for the benchmark pattern.

### Peak resident memory

GNU `time` maximum RSS (median of three runs):

| Workload | zg | rg |
|----------|---:|---:|
| 512 MiB explicit-file count | 4.5 MiB | 513 MiB |
| 512 MiB stdin count | 0.6 MiB | 4.4 MiB |
| 2 MiB single long line | 0.6 MiB | 5.5 MiB |
| 1.7 GiB recursive absent search, `-j8` | 3.2 MiB | 13.4 MiB |

## Project Structure

```
zipgrep/
├── build.zig             # Build configuration
├── build.zig.zon         # Package manifest
├── src/
│   ├── main.zig          # CLI entry point and argument parsing
│   ├── simd.zig          # SIMD byte/substring search (two-byte fingerprinting)
│   ├── regex.zig         # Thompson NFA regex engine
│   ├── literal.zig       # Literal extraction and alternation detection
│   ├── aho_corasick.zig  # Aho-Corasick multi-pattern search
│   ├── matcher.zig       # Pattern matching coordinator
│   ├── walker.zig        # Directory traversal and binary detection
│   ├── parallel_walker.zig # Parallel directory traversal with work stealing
│   ├── reader.zig        # Streaming file I/O with buffer-first search
│   ├── gitignore.zig     # Gitignore and glob pattern parsing
│   ├── output.zig        # Colorized output formatting
│   └── deque.zig         # Double-ended queue for work distribution
├── tests/                # Integration tests
└── benchsuite/           # Benchmark suite
```

## Comparison with ripgrep

### Feature Matrix

This comparison targets ripgrep 15.2.0. Ripgrep uses its Rust finite-automata regex engine by default; look-around, backreferences, and other PCRE2-only constructs require a build with PCRE2 and the `-P`/`--pcre2` flag.

| Feature | zipgrep | ripgrep 15.2.0 |
|---------|---------|----------------|
| Performance | Faster in the reported warm-cache workloads above | Workload dependent |
| Regex engine | Custom bounded Thompson/Pike NFA with bounded DFA acceleration | Rust regex automata by default; optional PCRE2 via `-P` |
| Counted repetition | ✓ `{m}`, `{m,}`, `{m,n}`; subject to a 256-state NFA limit | ✓ |
| Lazy quantifiers and captures | ✗ | ✓ in the default engine |
| Look-around and pattern backreferences | ✗ | ✓ with `-P`; not supported by the default engine |
| Unicode scalars | ✓ literals, `.`, bracket literals/ranges, and simple case folding | ✓ |
| Unicode classes | Unicode 16.0 `\w`; ASCII `\d` and `\s`; no `\p{...}` | Broad Unicode classes, properties, scripts, and case folding |
| Word matching | ✓ Unicode-aware `-w`; no `\b` syntax | ✓ `-w` and Unicode `\b` |
| File glob filtering | ✓ basic `-g` include/exclude patterns | ✓ `-g`, file types, and richer traversal controls |
| Ignore sources | Repository and nested `.gitignore` | `.gitignore`, `.ignore`, `.rgignore`, Git excludes, global excludes, and explicit ignore files |
| Binary handling | NUL-based; recursive and explicit-file modes; no binary controls and stdin differs | NUL-based with explicit/implicit policies, `--binary`, and `-a/--text` |
| Context lines (`-A`/`-B`/`-C`) | ✗ | ✓ |
| Multiline matching | ✗ | ✓ with `-U`; dot-all is configured separately |
| Compressed streams | ✗ | ✓ gzip, bzip2, xz, LZ4, LZMA, Brotli, and Zstd via external helpers |
| JSON output | ✗ | ✓ |
| Output replacement | ✗ | ✓; changes output, not files |
| Encoding/transcoding | ✗ raw bytes plus UTF-8-aware regex paths | ✓ BOM detection and `--encoding` |
| Binary size | About 2.2 MiB | About 5.2 MiB for the Linux musl binary used in the benchmarks |

### What zipgrep Supports

zipgrep is a good fit for fast line-oriented searching when its smaller CLI and regex surface are sufficient:

```bash
# Simple literal searches in your project
zg "TODO" src/
zg "console.log" .
zg "import React" components/

# Case-insensitive literal searches
zg -i "error" logs/

# Word boundary matching
zg -w "test" src/          # Matches "test" but not "testing"
zg -w "main" .             # Find exact "main" word

# Basic regex patterns
zg "fn.*\(" src/           # Function definitions
zg "[0-9]+" data.txt       # Numbers
zg "foo|bar" .             # Alternation
zg "test_.*.zig" src/      # Wildcards

# Shorthand classes and counted repetition
zg '\d{3}-\d{4}' data.txt   # ASCII digits
zg '\w{2,8}' names.txt      # Unicode Perl word characters

# Unicode literals, ranges, case folding, and word matching
zg '[α-ω]+' text.txt
zg -i 'école' text.txt
zg -w 'cache' text.txt

# File filtering
zg "TODO" -g '*.py'        # Only Python files
zg "import" -g '!vendor/'  # Exclude vendor directory

# Counting matches
zg -c "TODO" .

# Finding files with matches
zg -l "FIXME" .
```

### When to Use ripgrep Instead

Use ripgrep when a search needs features outside zipgrep's intentionally smaller surface:

```bash
# Unicode properties and Unicode semantics for \d and \s
rg '\p{Greek}+' .
rg '\d+' .                   # Includes non-ASCII decimal digits

# Word-boundary assertions, lazy quantifiers, captures, and inline flags
rg '\bword\b' .
rg '".*?"' .
rg '(?P<name>\w+)' .
rg '(?i:error)' .

# Look-around and pattern backreferences require PCRE2
rg -P '(?<=\$)\d+' .
rg -P '(\w+)\s+\1' .

# Cross-line matching; -U permits newlines and (?s:...) makes dot match them
rg -U '(?s:start.*?end)' .

# Context, structured output, and output replacement
rg -A 3 -B 2 'error' .
rg --json 'pattern' .
rg 'old' --replace 'new' .

# Search supported compressed streams
rg -z 'pattern' file.gz

# Control binary policy or emit binary bytes as text
rg --binary 'pattern' binary.exe
rg -a 'pattern' binary.exe

# Multiple patterns, pattern files, fixed strings, types, and encodings
rg -e 'TODO' -e 'FIXME' .
rg -f patterns.txt .
rg -F 'literal.*text' .
rg -tpy 'import' .
rg --encoding utf-16le 'name' data.txt
```

Despite the historical name of ripgrep's `-z/--search-zip` flag, it searches supported compressed streams; it does not traverse members of ZIP or tar archives.

### Quick Reference: Regex Support

| Pattern | zipgrep | ripgrep | Example |
|---------|--------|---------|---------|
| Literal text | ✓ | ✓ | `hello` |
| Any Unicode scalar except newline | ✓ `.` | ✓ | `h.llo` → hello, hallo |
| Zero or more | ✓ `*` | ✓ | `ab*c` → ac, abc, abbc |
| One or more | ✓ `+` | ✓ | `ab+c` → abc, abbc |
| Optional | ✓ `?` | ✓ | `colou?r` → color, colour |
| Counted repetition | ✓, bounded by NFA size | ✓ | `a{2,4}` |
| Alternation | ✓ <code>&#124;</code> | ✓ | <code>cat&#124;dog</code> |
| Plain grouping | ✓, no captures exposed | ✓, capturing | <code>(cat&#124;dog)+</code> |
| Character class | ✓ `[abc]` | ✓ | `[aeiou]` |
| Negated class | ✓ `[^abc]` | ✓ | `[^0-9]` |
| Unicode literal/range | ✓ | ✓ | `[α-ω]+` |
| Tab/carriage-return escapes | ✓ `\t`/`\r` | ✓ | `key\tvalue` |
| Newline escape/cross-line match | ✗ | ✓ with `-U` | `line1\nline2` |
| Whole-word mode | ✓ Unicode-aware `-w` | ✓ `-w` | `zg -w "word"` |
| Word-boundary assertion | ✗ | ✓ `\b` | `\bword\b` |
| Digit | ✓ ASCII `\d` | ✓ Unicode `\d` | `\d+` |
| Word char | ✓ Unicode 16.0 `\w` | ✓ Unicode `\w` | `\w+` |
| Whitespace | ✓ ASCII `\s` | ✓ Unicode `\s` | `\s+` |
| Non-greedy | ✗ | ✓ `*?` `+?` | `".*?"` |
| Captures/named groups | ✗ | ✓ | `(?P<word>\w+)` |
| Inline flags | ✗ | ✓ | `(?i:error)` |
| Lookahead | ✗ | ✓ with `-P` | `foo(?=bar)` |
| Lookbehind | ✗ | ✓ with `-P` | `(?<=\$)\d+` |
| Pattern backreference | ✗ | ✓ with `-P` | `(\w+)\s+\1` |
| Unicode classes | ✗ | ✓ `\p{L}` | `\p{Greek}` |

## Why Zig?

zipgrep demonstrates several Zig advantages for systems programming:

1. **Explicit SIMD** - `@Vector` provides portable SIMD without relying on autovectorization
2. **No hidden allocations** - All memory allocation is explicit and controllable
3. **No garbage collector** - Predictable performance with zero GC pauses
4. **Compile-time execution** - `comptime` enables zero-cost abstractions
5. **Small binaries** - No runtime overhead

## Areas of Improvement

- [ ] Unicode properties/scripts, Unicode `\d`/`\s`, `\b`, and Unicode/byte mode controls
- [ ] Lazy quantifiers, captures, named/non-capturing groups, inline flags, look-around, and backreferences
- [ ] Multiline matching
- [ ] Context lines (`-A`, `-B`, `-C` flags)
- [ ] JSON output format
- [ ] Replace mode (`--replace`)
- [ ] Compressed stream search (`.gz`, `.bz2`, `.xz`, `.zst`, etc.)
- [ ] Binary stdin parity and `--binary`/`-a` controls
- [ ] `.ignore`, `.rgignore`, Git exclude files, richer gitignore semantics, file types, and symlink controls
- [ ] Multiple/pattern-file/fixed-string input, encoding support, stable sorting, and machine-oriented output controls
- [ ] A reproducible benchmark harness covering the published timing and RSS scenarios

## License

MIT License - see LICENSE file for details.

## Acknowledgments

- [ripgrep](https://github.com/BurntSushi/ripgrep) by Andrew Gallant - the gold standard for grep tools
- [BurntSushi's blog post](https://blog.burntsushi.net/ripgrep/) explaining ripgrep's design decisions
