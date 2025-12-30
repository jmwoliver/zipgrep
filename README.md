# zrep

A high-performance grep implementation written in Zig, inspired by [ripgrep](https://github.com/BurntSushi/ripgrep).

zrep recursively searches directories for a regex pattern while respecting `.gitignore` files, with colorized output and parallel file searching.

## Features

- **Fast literal search** using SIMD-accelerated byte matching
- **Basic regex support** with `.`, `*`, `+`, `?`, `|`, and character classes
- **Parallel file searching** across multiple CPU cores
- **Gitignore support** - automatically respects `.gitignore` patterns
- **Colorized output** - file paths, line numbers, and matches are highlighted
- **Memory-mapped I/O** for efficient large file handling
- **Small binary** - ~500KB compared to ripgrep's 6.5MB

## Installation

### Homebrew (macOS)

```bash
brew install jmwoliver/tap/zrep
```

### Building from source

Requires [Zig](https://ziglang.org/) 0.15.0 or later.

```bash
# Clone the repository
git clone https://github.com/jmwoliver/zrep.git
cd zrep

# Build release version
zig build -Doptimize=ReleaseFast

# Binary is at ./zig-out/bin/zrep
```

### Running tests

```bash
zig build test
```

## Usage

```
zrep [OPTIONS] PATTERN [PATH ...]
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
| `-n, --line-number` | Show line numbers (default: on) |
| `-c, --count` | Only show count of matching lines per file |
| `-l, --files-with-matches` | Only show filenames containing matches |
| `--no-ignore` | Don't respect `.gitignore` files |
| `--hidden` | Search hidden files and directories |
| `-j, --threads NUM` | Number of threads to use |
| `-d, --max-depth NUM` | Maximum directory depth to search |
| `--color MODE` | Color mode: `auto`, `always`, `never` (default: `auto`) |

### Examples

```bash
# Search for "TODO" in current directory
zrep TODO

# Search in specific directory
zrep "function" src/

# Case-insensitive search
zrep -i "error" logs/

# Count matches per file
zrep -c "import" .

# List files containing matches
zrep -l "TODO" .

# Force colored output (useful when piping)
zrep --color always "pattern" | less -R

# Search with regex
zrep "fn.*\(" src/       # Find function definitions
zrep "[0-9]+" data/      # Find numbers
zrep "foo|bar" .         # Find "foo" or "bar"

# Ignore gitignore and search everything
zrep --no-ignore "secret" .

# Limit search depth
zrep -d 2 "config" .

# Single-threaded (useful for debugging)
zrep -j 1 "pattern" .
```

## How It Works

### SIMD-Accelerated Search

zrep uses Zig's `@Vector` types for SIMD-accelerated byte searching:

```zig
const Vec = @Vector(16, u8);  // 128-bit vectors on ARM64

pub fn findByte(haystack: []const u8, needle: u8) ?usize {
    const needle_vec: Vec = @splat(needle);
    // Process 16 bytes at a time
    while (i + 16 <= haystack.len) : (i += 16) {
        const chunk: Vec = haystack[i..][0..16].*;
        const matches = chunk == needle_vec;
        if (@reduce(.Or, matches)) {
            return i + @ctz(@as(u16, @bitCast(matches)));
        }
    }
    // ... scalar fallback
}
```

### Regex Engine

zrep implements a Thompson NFA-based regex engine supporting:
- `.` - any character (except newline)
- `*` - zero or more
- `+` - one or more  
- `?` - zero or one
- `|` - alternation
- `[abc]` - character classes
- `[^abc]` - negated character classes
- `[a-z]` - character ranges
- `\n`, `\t`, `\r` - escape sequences

### File I/O Strategy

| Scenario | Strategy |
|----------|----------|
| Files < 128MB | Memory-mapped I/O (zero-copy) |
| Larger files | Buffered reading (64KB chunks) |
| stdin | Buffered reading |

### Parallelism

zrep collects all file paths first, then distributes them evenly across worker threads for parallel searching. This simple approach works well for typical codebases but has more overhead than ripgrep's streaming approach for very large directories.

## Project Structure

```
zrep/
├── build.zig           # Build configuration
├── build.zig.zon       # Package manifest
├── src/
│   ├── main.zig        # CLI entry point
│   ├── simd.zig        # SIMD byte/substring search
│   ├── regex.zig       # Thompson NFA regex engine
│   ├── matcher.zig     # Pattern matching coordinator
│   ├── walker.zig      # Directory traversal
│   ├── reader.zig      # File I/O (mmap + buffered)
│   ├── gitignore.zig   # Gitignore parsing
│   ├── output.zig      # Colorized output
│   └── threadpool.zig  # Thread pool utilities
└── bench/
    └── run_benchmarks.sh  # Benchmark script
```

## Comparison with ripgrep

### Feature Matrix

| Feature | zrep | ripgrep |
|---------|------|---------|
| Literal search speed | ✓ Faster (small dirs) | ✓ Faster (large dirs) |
| Full PCRE2 regex | ✗ Basic only | ✓ Full support |
| Unicode support | ✗ ASCII only | ✓ Full Unicode |
| Binary file detection | ✗ Not yet | ✓ Yes |
| Compressed file search | ✗ No | ✓ Yes |
| JSON output | ✗ No | ✓ Yes |
| Replace mode | ✗ No | ✓ Yes |
| Context lines (-A/-B/-C) | ✗ No | ✓ Yes |
| Word boundary matching | ✗ No | ✓ Yes |
| Multiline matching | ✗ No | ✓ Yes |
| Binary size | ~500 KB | ~6.5 MB |

### When to Use zrep

Use zrep when:

```bash
# Simple literal searches in your project
zrep "TODO" src/
zrep "console.log" .
zrep "import React" components/

# Case-insensitive literal searches
zrep -i "error" logs/

# Basic regex patterns
zrep "fn.*\(" src/           # Function definitions
zrep "[0-9]+" data.txt       # Numbers
zrep "foo|bar" .             # Alternation
zrep "test_.*.zig" src/      # Wildcards

# Counting matches
zrep -c "TODO" .

# Finding files with matches
zrep -l "FIXME" .
```

### When to Use ripgrep Instead

Use ripgrep for these **unsupported patterns**:

```bash
# Word boundaries (\b) - NOT SUPPORTED
rg '\bword\b' .              # Match "word" but not "keyword"
zrep 'word' .                # Would also match "keyword", "words", etc.

# Character class shortcuts - NOT SUPPORTED
rg '\d{3}-\d{4}' .           # Phone numbers (digits)
rg '\w+@\w+\.\w+' .          # Email-like patterns
rg '\s+' .                   # Whitespace
# zrep alternative: use explicit classes
zrep '[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]' .
zrep '[a-zA-Z0-9]+@[a-zA-Z0-9]+' .

# Quantifier ranges {n,m} - NOT SUPPORTED
rg 'a{2,4}' .                # 2 to 4 'a's
rg '.{10,}' .                # 10+ characters
# zrep has no equivalent

# Lookahead/lookbehind - NOT SUPPORTED  
rg '(?<=\$)\d+' .            # Numbers after $
rg 'foo(?=bar)' .            # foo followed by bar
# zrep has no equivalent

# Non-greedy quantifiers - NOT SUPPORTED
rg '".*?"' .                 # Shortest quoted string
# zrep's .* is always greedy

# Backreferences - NOT SUPPORTED
rg '(\w+)\s+\1' .            # Repeated words
# zrep has no equivalent

# Unicode patterns - NOT SUPPORTED
rg '[\p{Greek}]+' .          # Greek letters
rg '\p{Emoji}' .             # Emoji characters
# zrep is ASCII-only

# Multiline patterns - NOT SUPPORTED
rg -U 'start.*?end' .        # Match across lines
# zrep matches line-by-line only

# Context lines - NOT SUPPORTED
rg -A 3 -B 2 'error' .       # Show surrounding lines
# zrep has no equivalent

# Search in compressed files - NOT SUPPORTED
rg -z 'pattern' file.gz
# zrep cannot read compressed files

# Replace mode - NOT SUPPORTED
rg 'old' --replace 'new' .
# zrep is search-only

# JSON output for tooling - NOT SUPPORTED
rg --json 'pattern' .
# zrep outputs text only

# Binary file handling - NOT SUPPORTED
rg --binary 'pattern' binary.exe
# zrep may produce garbled output on binary files

# Very large codebases (90k+ files)
rg 'pattern' ~/linux         # ripgrep is ~1.5x faster here
```

### Quick Reference: Regex Support

| Pattern | zrep | ripgrep | Example |
|---------|------|---------|---------|
| Literal text | ✓ | ✓ | `hello` |
| Any character | ✓ `.` | ✓ | `h.llo` → hello, hallo |
| Zero or more | ✓ `*` | ✓ | `ab*c` → ac, abc, abbc |
| One or more | ✓ `+` | ✓ | `ab+c` → abc, abbc |
| Optional | ✓ `?` | ✓ | `colou?r` → color, colour |
| Alternation | ✓ `\|` | ✓ | `cat\|dog` |
| Character class | ✓ `[abc]` | ✓ | `[aeiou]` |
| Negated class | ✓ `[^abc]` | ✓ | `[^0-9]` |
| Range | ✓ `[a-z]` | ✓ | `[A-Za-z]` |
| Escape sequences | ✓ `\n\t\r` | ✓ | `line1\nline2` |
| Word boundary | ✗ | ✓ `\b` | `\bword\b` |
| Digit | ✗ | ✓ `\d` | `\d+` |
| Word char | ✗ | ✓ `\w` | `\w+` |
| Whitespace | ✗ | ✓ `\s` | `\s+` |
| Quantifier range | ✗ | ✓ `{n,m}` | `a{2,4}` |
| Non-greedy | ✗ | ✓ `*?` `+?` | `".*?"` |
| Lookahead | ✗ | ✓ `(?=)` | `foo(?=bar)` |
| Lookbehind | ✗ | ✓ `(?<=)` | `(?<=\$)\d+` |
| Backreference | ✗ | ✓ `\1` | `(\w+)\s+\1` |
| Named groups | ✗ | ✓ `(?P<name>)` | `(?P<word>\w+)` |
| Unicode classes | ✗ | ✓ `\p{L}` | `\p{Greek}` |

### Decision Flowchart

```
Is your pattern a simple literal string?
  → YES: Use zrep (faster for small/medium projects)
  
Does your regex use \b, \d, \w, \s, {n,m}, or lookahead?
  → YES: Use ripgrep (zrep doesn't support these)
  
Do you need to search 50,000+ files?
  → YES: Use ripgrep (better parallel directory traversal)
  
Do you need context lines (-A/-B/-C)?
  → YES: Use ripgrep
  
Do you need JSON output or replace mode?
  → YES: Use ripgrep
  
Otherwise:
  → Use zrep (1.5-1.7x faster on typical projects)
```

## Why Zig?

zrep demonstrates several Zig advantages for systems programming:

1. **Explicit SIMD** - `@Vector` provides portable SIMD without relying on autovectorization
2. **No hidden allocations** - All memory allocation is explicit and controllable
3. **No garbage collector** - Predictable performance with zero GC pauses
4. **Compile-time execution** - `comptime` enables zero-cost abstractions
5. **Small binaries** - No runtime overhead

## Areas of Improvement

- [ ] Parallel directory traversal (like ripgrep's crossbeam-based walker)
- [ ] Full Unicode support
- [ ] Binary file detection
- [ ] More regex features (`\d`, `\w`, `\s`, lookahead, etc.)
- [ ] Context lines (`-A`, `-B`, `-C` flags)
- [ ] JSON output format
- [ ] Replace mode (`--replace`)

## License

MIT License - see LICENSE file for details.

## Acknowledgments

- [ripgrep](https://github.com/BurntSushi/ripgrep) by Andrew Gallant - the gold standard for grep tools
- [BurntSushi's blog post](https://blog.burntsushi.net/ripgrep/) explaining ripgrep's design decisions

