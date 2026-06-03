# zdu Design Document

## Overview

`zdu` is a disk-usage analyzer written in Zig. It provides both an interactive terminal UI (TUI) and a non-interactive CLI mode. Key differentiators from standard `du`:

- **Persistent metadata cache**: stores recursive directory stats in filesystem metadata (xattrs on Linux/macOS, NTFS alternate data streams on Windows)
- **Low memory footprint**: ~8 MB even for millions of files by not retaining full tree structures
- **Parallel scanning**: dynamic work-stealing scheduler for multi-threaded directory traversal
- **In-TUI navigation**: browse directories with keyboard/mouse, delete files/directories with live cache updates

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                          CLI Entry                          │
│                     src/main.zig:main()                     │
└─────────────────────┬───────────────────────────────────────┘
                      │
        ┌─────────────┴─────────────┐
        ▼                         ▼
┌──────────────┐          ┌──────────────┐
│  --no-tui    │          │    TUI       │
│  runNoTui()  │          │  vxfw App    │
└──────┬───────┘          └──────┬───────┘
       │                         │
       ▼                         ▼
┌─────────────────────────────────────────────┐
│              Scanning Layer                  │
│  ┌────────────┐  ┌────────────┐            │
│  │  Serial    │  │  Parallel  │            │
│  │  StackScan │  │  Dynamic   │            │
│  └────────────┘  │  Splitting │            │
│                  └────────────┘            │
└─────────────────────────────────────────────┘
                      │
        ┌─────────────┴─────────────┐
        ▼                         ▼
┌──────────────┐          ┌──────────────┐
│   Library    │          │    Cache     │
│ lib/zdu.zig  │          │  xattr/ADS   │
└──────────────┘          └──────────────┘
```

## Directory Layout

```
zdu/
├── build.zig              # Zig build configuration
├── build.zig.zon          # Dependency manifest (vaxis 0.6.0)
├── src/
│   └── main.zig           # CLI + TUI Model (~4,200 lines)
├── lib/
│   └── zdu.zig            # Public library API (~540 lines)
├── docs/
│   ├── design.md          # This document
│   └── todo.md            # Task list to finish
├── .github/workflows/
│   ├── ci.yaml            # Multi-platform CI
│   └── release.yaml       # Release builds + GitHub publish
├── install.sh             # macOS/Linux installer
├── install.ps1            # Windows installer
└── README.md
```

## Key Components

### 1. Model (TUI State Machine)

**File**: `src/main.zig` lines 130–2512

The `Model` struct is the heart of the application. It implements the `vxfw.Widget` interface and manages:

- **Entry list**: current directory entries with roles (`summary`, `parent`, `item`)
- **Selection & scrolling**: keyboard/mouse-driven navigation with sticky root summary
- **Loading state**: incremental background scanning with spinner animation
- **Delete confirmation**: modal dialog with `[Y/n]` prompt
- **Parent chain**: linked list of `Model` instances for navigation history

```zig
pub const Model = struct {
    io: std.Io,
    allocator: mem.Allocator,
    cwd: []u8,
    entries: []Entry = &.{},
    loading: ?Loading = null,
    selected: usize = 0,
    scroll_offset: usize = 0,
    parent: ?*Model = null,
    confirm_delete: ?ConfirmDelete = null,
    // ... cache & parallel options
};
```

#### Entry Roles

| Role      | Display     | Selectable | Action on Enter        |
|-----------|-------------|------------|------------------------|
| `summary` | `[ROOT]`    | No         | —                      |
| `parent`  | `..`        | Yes        | Navigate up            |
| `item`    | File or dir | Yes        | Open dir / Delete file |

### 2. Scanning Strategies

#### Serial Stack Scan
**Functions**: `computeDirStatsStack`, `computeDirStatsStackWithCache`

Iterative DFS using an explicit `ArrayList(StackFrame)` to avoid stack overflow on deep trees. Reads cache at each directory entry; writes cache bottom-up on completion.

#### Recursive Scan (with cache fallback)
**Functions**: `computeDirStats`, `computeDirStatsInDir`

Simpler recursive version used by `runNoTui` fallback and some eager-load paths.

#### Dynamic Parallel Scan
**Functions**: `computeDirStatsDynamicOwned`, `computeDynamicScanInputs`

Work-stealing scheduler:
1. Starts with top-level child directories as tasks
2. Each worker processes a directory iteratively (stack-based)
3. When a child directory exceeds `dynamic_split_min_files` (4096), it is enqueued as a new task for idle workers
4. Parent directories wait on child futures before writing their own cache record

This ensures cache writes remain bottom-up even with dynamic splitting.

#### Entry Parallel Scan
**Functions**: `scanEntryTasks`, `loadDirParallel`

Used during TUI directory loading when `--parallel` is enabled. Each immediate child directory becomes a task; tasks are sorted by estimated file count (from cache) so larger subtrees are processed first.

### 3. Cache System

#### v3 Record (32 bytes, little-endian)
```
bytes 0–7:   total allocated size (u64)
bytes 8–15:  recursive file count (u64)
bytes 16–23: recursive directory count (u64)
bytes 24–31: expiration timestamp (u64)
```

#### v2 Record (16 bytes, legacy fallback)
```
bytes 0–7:   total allocated size (u64)
bytes 8–15:  expiration timestamp (u64)
```

#### Platform Implementation

| Platform | Mechanism                        | Names |
|----------|----------------------------------|-------|
| Linux    | `getxattr`/`setxattr`/`fgetxattr`| `user.zdu.dir_stats.v3`, `user.zdu.dir_size.v2` |
| macOS    | `getxattr`/`setxattr` (XNU)      | Same as Linux |
| Windows  | NTFS Alternate Data Streams (ADS)| `:user.zdu.dir_stats.v3:$DATA`, `:user.zdu.dir_size.v2:$DATA` |

#### Cache Lifecycle

- **Fresh process, no TTL**: always recomputes on initial scan, writes cache bottom-up
- **With `--cache-ttl N`**: trusts existing cache if unexpired; recomputes and refreshes if missing/expired
- **With `--refresh-cache`**: ignores existing cache, always recomputes and writes
- **Post-navigation**: reads cache directly without rescanning
- **After delete**: subtracts deleted entry stats from parent caches while walking up the navigation chain

### 4. Library API (`lib/zdu.zig`)

```zig
pub const Format = enum { human, json };

pub const Options = struct {
    path: []const u8,
    format: Format,
    summarize: bool,
    show_hidden: bool,
    max_depth: ?usize,
    max_entries: ?usize,
    parallel: bool,       // currently ignored by library
    num_threads: usize,   // currently ignored by library
    use_io_uring: bool,   // currently dead code
};

pub const ScanResult = struct {
    total_size: u64,
    total_files: u64,
    total_dirs: u64,
    scan_time_ms: u64,
    error_count: u64,
};

pub fn scan(io: std.Io, opts: Options) !ScanResult;
pub fn scanAndFormat(io: std.Io, opts: Options, writer: anytype) !void;
```

**Current behavior**: `scanAndFormat` performs a streaming walk, emitting entries to `writer` in either human or JSON format. `scan` aggregates totals without retaining per-entry data.

**Problem**: The CLI barely uses this library. Most real work is done by `Model`'s internal scanning functions.

### 5. CLI Argument Parsing

**File**: `src/main.zig` lines 3431–3484

```zig
const Config = struct {
    cwd: []const u8 = ".",
    cache_ttl_seconds: u64 = 0,
    refresh_cache: bool = false,
    parallel: bool = false,
    num_threads: usize = 0,
    bench: bool = false,
    no_tui: bool = false,
};
```

Supported flags:
- `zdu [path]`
- `zdu --cache-ttl [N] [path]` (defaults to 60s if no N)
- `zdu --no-tui [path]`
- `zdu --refresh-cache --cache-ttl N [path]`
- `zdu --parallel --jobs N ... [path]`
- `zdu --bench [path]` (undocumented)

Missing flags: `--help`, `--version`, `--format`, `--max-depth`, `--show-hidden`, `--summarize`

## Data Flow

### TUI Mode Startup

```
main() → parseArgs() → Model.initLoadingWithOptions()
    → beginLoading() → load entries with empty DirStats
    → vxfw.App.run() → handleEvent(.init)
        → ctx.tick() → handleEvent(.tick)
            → advanceLoading() → advanceLoadingStep()
                → scan each directory entry incrementally
                → update entry.size/file_count/dir_count in place
                → write cache bottom-up
            → draw() → render loading spinner or entry list
```

### No-TUI Mode

```
main() → parseArgs() → runNoTui()
    → if cache/parallel enabled: scanRootStats()
        → enumerate children, create ParallelScanTasks
        → if parallel & worker_count > 1: computeDynamicScanInputs()
        → else: serial stack scan per child
        → write root cache, print total_size
    → else: zdu.scan() → print result.total_size
```

### Delete Flow

```
user presses Delete/Enter on file → deleteSelected()
    → confirm_delete = { path, is_dir, stats, entry_index }
    → draw() renders confirmation dialog

user confirms (Y or Enter) → confirmDelete()
    → deleteTree() or deleteFile()
    → propagateDeletedStats()
        → walk up parent chain
        → subtractStats from knownDirStats()
        → updateSummaryEntryStats() + writeCachedDirStats()
        → updateParentEntryStats()
    → removeEntryAt()
```

## Platform-Specific Notes

### Linux
- Requires `libc` linkage for `fstatat` to get allocated block counts (`st_blocks`)
- xattrs require appropriate filesystem support (ext4, xfs, btrfs)
- Kernel-enforced xattr size limits apply (~64 KB typical)

### macOS
- Uses the same xattr APIs as Linux but via `libc` shims
- APFS does not expose reliable per-file block allocation for sparse files, so `st_blocks` is less useful
- x86_64 macOS falls back to `statFile` size instead of `fstatat` blocks

### Windows
- NTFS alternate data streams are used for cache storage
- If the filesystem does not support ADS (e.g., FAT32), cache operations silently fail
- Path handling requires `\?\` prefix or explicit `.\` prefix for relative paths
- Uses raw `kernel32` imports (`CreateFileW`, `ReadFile`, `WriteFile`, etc.)

## Performance Characteristics

- **Memory**: O(visible entries) in TUI mode, not O(total files). During scan, only the current directory's frame stack is held.
- **Cache I/O**: One 32-byte write per directory on first scan. On warm cache, navigation is O(1) per directory.
- **Parallel scaling**: Best with warm v3 cache because cached file counts provide accurate cost estimates for the scheduler.

## Known Issues & Technical Debt

1. **`std.time.timestamp()` removed in Zig 0.16.0** — compilation fails
2. **Library/CLI duplication** — `fileSizeOnDiskAt`, `cStatAt`, `posixStat*` exist in both `lib/zdu.zig` and `src/main.zig`
3. **`use_io_uring` dead code** — declared but never referenced
4. **`page_allocator` hardcoded** — `lib/zdu.zig` uses it instead of accepting an allocator
5. **Missing CLI flags** — library supports JSON, max-depth, show-hidden; CLI does not expose them
6. **No `--help` or `--version`** — users must read README
7. **Surprising file delete UX** — Enter on a file triggers immediate deletion without confirmation
8. **Mouse right-click deletes directories** — no confirmation dialog
9. **Model is 4,200 lines** — violates single-responsibility principle

## Testing Strategy

- **Unit tests**: 60+ tests embedded in `src/main.zig` covering navigation, cache round-trips, delete propagation, parallel correctness
- **Platform-specific tests**: Skip on unsupported OSs using `error.SkipZigTest`
- **CI**: Multi-platform builds + smoke tests + xattr/ADS validation
- **Gaps**: No binary-level integration tests, no library API coverage for `scanAndFormat`, no CLI `--help` tests
