#!/bin/bash

# zrep vs ripgrep benchmark suite
# Requires: hyperfine, ripgrep (rg), and a test corpus

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ZREP="$PROJECT_ROOT/zig-out/bin/zrep"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== zrep Benchmark Suite ===${NC}"
echo ""

# Check prerequisites
if ! command -v hyperfine &> /dev/null; then
    echo -e "${RED}Error: hyperfine is required. Install with: brew install hyperfine${NC}"
    exit 1
fi

if ! command -v rg &> /dev/null; then
    echo -e "${RED}Error: ripgrep (rg) is required. Install with: brew install ripgrep${NC}"
    exit 1
fi

if [ ! -f "$ZREP" ]; then
    echo -e "${YELLOW}Building zrep in release mode...${NC}"
    cd "$PROJECT_ROOT"
    zig build -Doptimize=ReleaseFast
fi

# Test corpus - use the zrep source itself for small tests
# For real benchmarks, use a larger codebase like linux kernel
TEST_DIR="${TEST_DIR:-$PROJECT_ROOT}"
LARGE_TEST_DIR="${LARGE_TEST_DIR:-$HOME/linux}"

echo -e "${YELLOW}Test directory: $TEST_DIR${NC}"
echo ""

# Benchmark 1: Simple literal search (small corpus)
echo -e "${GREEN}=== Benchmark 1: Simple Literal Search ===${NC}"
hyperfine --warmup 3 \
    "rg 'const' $TEST_DIR/src" \
    "$ZREP 'const' $TEST_DIR/src" \
    --export-markdown "$SCRIPT_DIR/results_literal.md" \
    2>/dev/null || true

echo ""

# Benchmark 2: Case insensitive search
echo -e "${GREEN}=== Benchmark 2: Case Insensitive Search ===${NC}"
hyperfine --warmup 3 \
    "rg -i 'error' $TEST_DIR/src" \
    "$ZREP -i 'error' $TEST_DIR/src" \
    --export-markdown "$SCRIPT_DIR/results_case_insensitive.md" \
    2>/dev/null || true

echo ""

# Benchmark 3: Regex search
echo -e "${GREEN}=== Benchmark 3: Regex Search ===${NC}"
hyperfine --warmup 3 \
    "rg 'fn\s+\w+' $TEST_DIR/src" \
    "$ZREP 'fn.+' $TEST_DIR/src" \
    --export-markdown "$SCRIPT_DIR/results_regex.md" \
    2>/dev/null || true

echo ""

# Benchmark 4: Count matches only
echo -e "${GREEN}=== Benchmark 4: Count Matches ===${NC}"
hyperfine --warmup 3 \
    "rg -c 'const' $TEST_DIR/src" \
    "$ZREP -c 'const' $TEST_DIR/src" \
    --export-markdown "$SCRIPT_DIR/results_count.md" \
    2>/dev/null || true

echo ""

# Benchmark 5: Large codebase (if available)
if [ -d "$LARGE_TEST_DIR" ]; then
    echo -e "${GREEN}=== Benchmark 5: Large Codebase (Linux Kernel) ===${NC}"
    hyperfine --warmup 2 --runs 5 \
        "rg 'TODO' $LARGE_TEST_DIR" \
        "$ZREP 'TODO' $LARGE_TEST_DIR" \
        --export-markdown "$SCRIPT_DIR/results_large.md" \
        2>/dev/null || true
    
    echo ""
    
    echo -e "${GREEN}=== Benchmark 6: Large Codebase with --no-ignore ===${NC}"
    hyperfine --warmup 2 --runs 5 \
        "rg --no-ignore 'TODO' $LARGE_TEST_DIR" \
        "$ZREP --no-ignore 'TODO' $LARGE_TEST_DIR" \
        --export-markdown "$SCRIPT_DIR/results_large_no_ignore.md" \
        2>/dev/null || true
else
    echo -e "${YELLOW}Skipping large codebase benchmarks (set LARGE_TEST_DIR to enable)${NC}"
fi

echo ""
echo -e "${GREEN}=== Benchmarks Complete ===${NC}"
echo "Results saved to $SCRIPT_DIR/results_*.md"

