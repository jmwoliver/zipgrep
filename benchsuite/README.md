# zipgrep Benchmark Suite

Comprehensive benchmark suite for comparing zipgrep (zg) against other grep tools.
Ported from [ripgrep's benchsuite](https://github.com/BurntSushi/ripgrep/tree/master/benchsuite).

## Quick Start

```bash
# Download test corpora (first time only, ~2GB)
./benchsuite/benchsuite --download

# Run all benchmarks
./benchsuite/benchsuite

# Run specific benchmarks
./benchsuite/benchsuite linux        # All Linux kernel benchmarks
./benchsuite/benchsuite subtitles    # All subtitles benchmarks
```

## Tools Compared

| Tool | Description |
|------|-------------|
| `zg` | zipgrep - the tool being benchmarked |
| `rg` | [ripgrep](https://github.com/BurntSushi/ripgrep) |

Additional tools (currently disabled in benchsuite, can be re-enabled):
- `grep` - GNU grep
- `ag` - [The Silver Searcher](https://github.com/ggreer/the_silver_searcher)
- `ugrep` - [ugrep](https://github.com/Genivia/ugrep)

## Available Benchmarks

### Linux Kernel Benchmarks

Search the Linux kernel source tree (~1.5GB, 70k+ files).

| Benchmark | Pattern | Description |
|-----------|---------|-------------|
| `linux_literal` | `PM_RESUME` | Basic literal string search |
| `linux_literal_casei` | `PM_RESUME` | Case-insensitive literal search |
| `linux_word` | `PM_RESUME` | Word boundary matching (`-w`) |
| `linux_re_suffix` | `[A-Z]+_RESUME` | Regex with literal suffix |
| `linux_alternates` | `ERR_SYS\|PME_TURN_OFF\|...` | Alternation pattern |
| `linux_alternates_casei` | (same) | Case-insensitive alternation |
| `linux_no_literal` | `\w{5}\s+\w{5}\s+...` | Complex regex (no literal optimization) |

### Subtitles Benchmarks

Search a large single text file (~450MB, English subtitles corpus).

| Benchmark | Pattern | Description |
|-----------|---------|-------------|
| `subtitles_literal` | `Sherlock Holmes` | Basic literal search |
| `subtitles_literal_casei` | `Sherlock Holmes` | Case-insensitive |
| `subtitles_word` | `Sherlock Holmes` | Word boundary matching |
| `subtitles_alternates` | `Sherlock Holmes\|John Watson\|...` | Alternation |
| `subtitles_no_literal` | `\w{5}\s+\w{5}\s+\w{5}` | Complex regex |

## Usage

```bash
# List all available benchmarks
./benchsuite/benchsuite --list

# Run all benchmarks (default: 10 runs, 3 warmup)
./benchsuite/benchsuite

# Run with custom iterations
./benchsuite/benchsuite --runs 5 --warmup 2

# Skip tools that aren't installed
./benchsuite/benchsuite --allow-missing

# Output raw CSV data
./benchsuite/benchsuite --raw > results.csv

# Use a custom corpus directory
./benchsuite/benchsuite --dir /path/to/corpora
```

## Viewing Results

Results are automatically saved to `benchsuite/runs/{date}/`:
- `{timestamp}_results.md` - Markdown tables (human-readable)
- `{timestamp}_results.csv` - CSV data (for analysis/graphing)

Example: `benchsuite/runs/2026-01-01/2026-01-01_14-30-45_results.md`

### Markdown Output Example

```markdown
## linux_literal

| Tool | Mean (ms) | Stddev | Min | Max |
|------|-----------|--------|-----|-----|
| zg   | 42.1      | 1.1    | 40  | 44  |
| rg   | 45.2      | 1.3    | 43  | 48  |
```

### CSV Output Example

```csv
benchmark,tool,mean_ms,stddev_ms,min_ms,max_ms,runs
linux_literal,zg,42.10,1.10,40.00,44.00,10
linux_literal,rg,45.20,1.30,43.00,48.00,10
```

## Test Corpora

Corpora are downloaded to `~/.cache/zipgrep-bench/` by default.

| Corpus | Size | Description |
|--------|------|-------------|
| `linux` | ~1.5GB | Linux kernel source (shallow clone) |
| `subtitles-en` | ~450MB | OpenSubtitles English corpus |

## Dependencies

- Python 3.6+
- `curl` - for downloading corpora
- `git` - for cloning Linux kernel
- `rg` - `brew install ripgrep`
