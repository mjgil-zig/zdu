# zdu Architecture

`zdu` is a disk-usage analyzer written in Zig. It provides both an interactive terminal UI (TUI) and a non-interactive CLI mode.

## Overview

Key differentiators from standard `du`:

- **Persistent metadata cache** — stores recursive directory stats in filesystem metadata (xattrs on Linux/macOS, NTFS alternate data streams on Windows)
- **Low memory footprint** — ~8 MB even for millions of files by not retaining full tree structures
- **Parallel scanning** — dynamic work-stealing scheduler for multi-threaded directory traversal
- **In-TUI navigation** — browse directories with keyboard/mouse, delete files/directories with live cache updates

## Directory Layout

```
src/
├── main.zig           # Root entry point (10 lines)
├── Cli.zig            # CLI parsing, --no-tui, benchmarks (285 lines)
├── Model.zig          # TUI state machine core (662 lines)
├── ModelLoad.zig      # Directory loading & parallel scanning (410 lines)
├── ModelEvent.zig     # Keyboard/mouse event handling (214 lines)
├── ModelNav.zig       # Navigation & delete confirmation (88 lines)
├── ModelDraw.zig      # TUI rendering & formatting (112 lines)
├── Scan.zig           # Serial & parallel scanning strategies (701 lines)
├── Cache.zig          # xattr/ADS cache read/write (672 lines)
└── main_test.zig      # Unit & integration tests (1,565 lines)

lib/
├── zdu.zig            # Public library API re-exports (554 lines)
├── stat.zig           # POSIX stat helpers (75 lines)
├── walk.zig           # Directory walking (199 lines)
└── format.zig         # Output formatting (89 lines)
```

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                          CLI Entry                          │
│                     src/main.zig:main()                     │
│                         (delegates to)                      │
│                      src/Cli.zig:main()                     │
└─────────────────────┬───────────────────────────────────────┘
                      │
        ┌─────────────┴─────────────┐
        ▼                         ▼
┌──────────────┐          ┌──────────────┐
│  --no-tui    │          │    TUI       │
│  runNoTui()  │          │  vxfw App    │
│   (Cli.zig)  │          │  (Model)     │
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
│           (Scan.zig + lib/*.zig)           │
└─────────────────────────────────────────────┘
                      │
        ┌─────────────┴─────────────┐
        ▼                         ▼
┌──────────────┐          ┌──────────────┐
│   Library    │          │    Cache     │
│ lib/zdu.zig  │          │  xattr/ADS   │
│  stat.zig    │          │  (Cache.zig) │
│  walk.zig    │          │              │
│  format.zig  │          │              │
└──────────────┘          └──────────────┘
```

## Components

### Cli (`src/Cli.zig`)

Entry point for the application. Parses command-line arguments into a `Config` struct, then either:
- Runs in TUI mode by constructing a `Model` and handing it to `vxfw.App`
- Runs in `--no-tui` mode via `runNoTui()` for streaming or summarized output
- Runs benchmarks when `--bench` is passed

### Model (`src/Model.zig` + submodules)

The TUI state machine. Implements the `vxfw.Widget` interface and manages:

- **Entry list** — current directory entries with roles (`summary`, `parent`, `item`)
- **Selection & scrolling** — keyboard/mouse-driven navigation with sticky root summary
- **Loading state** — incremental background scanning with spinner animation
- **Delete confirmation** — modal dialog with `[Y/n]` prompt
- **Parent chain** — linked list of `Model` instances for navigation history

The struct definition and small helpers live in `Model.zig`. Larger behaviors are split into submodules and accessed via thin wrapper methods:

| Submodule | Responsibility |
|-----------|---------------|
| `ModelLoad.zig` | Directory loading, eager/parallel scanning, cache priming |
| `ModelEvent.zig` | Keyboard and mouse event routing |
| `ModelNav.zig` | Navigate into/out of directories, delete with confirmation |
| `ModelDraw.zig` | Render the TUI surface: entry list, loading spinner, dialogs |

### Scan (`src/Scan.zig`)

Implements multiple scanning strategies used by both the TUI and the CLI:

**Serial Stack Scan** — iterative DFS using an explicit `ArrayList(StackFrame)` to avoid stack overflow on deep trees. Reads cache at each directory entry; writes cache bottom-up on completion.

**Recursive Scan** — simpler recursive version used by `runNoTui` fallback and some eager-load paths.

**Dynamic Parallel Scan** — work-stealing scheduler:
1. Starts with top-level child directories as tasks
2. Each worker processes a directory iteratively (stack-based)
3. When a child directory exceeds `dynamic_split_min_files` (4096), it is enqueued as a new task for idle workers
4. Parent directories wait on child futures before writing their own cache record

**Entry Parallel Scan** — used during TUI directory loading when `--parallel` is enabled. Each immediate child directory becomes a task; tasks are sorted by estimated file count (from cache) so larger subtrees are processed first.

### Cache (`src/Cache.zig`)

Cross-platform cache storage using filesystem metadata.

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

| Platform | Mechanism | Names |
|----------|-----------|-------|
| Linux | `getxattr`/`setxattr`/`fgetxattr` | `user.zdu.dir_stats.v3`, `user.zdu.dir_size.v2` |
| macOS | `getxattr`/`setxattr` (XNU) | Same as Linux |
| Windows | NTFS Alternate Data Streams (ADS) | `:user.zdu.dir_stats.v3:$DATA`, `:user.zdu.dir_size.v2:$DATA` |

### Library (`lib/zdu.zig`)

Public API for non-TUI consumers. Re-exports from `lib/stat.zig`, `lib/walk.zig`, and `lib/format.zig`:

```zig
pub const Format = enum { human, json };

pub const Options = struct {
    path: []const u8,
    format: Format,
    summarize: bool,
    show_hidden: bool,
    max_depth: ?usize,
    parallel: bool,
    num_threads: usize,
};

pub fn scan(io: std.Io, allocator: mem.Allocator, opts: Options) !ScanResult;
pub fn scanAndFormat(io: std.Io, allocator: mem.Allocator, opts: Options, writer: anytype) !void;
```

`lib/stat.zig` provides POSIX stat helpers and file-size-on-disk functions. `lib/walk.zig` provides directory walking logic. `lib/format.zig` provides output formatting for human-readable and JSON output.

## Data Flow

### TUI Mode Startup

```
Cli.main() → Cli.parseArgs() → Model.initLoadingWithOptions()
    → ModelLoad.beginLoading() → load entries with empty DirStats
    → vxfw.App.run() → ModelEvent.handleEvent(.init)
        → ctx.tick() → ModelEvent.handleEvent(.tick)
            → Model.advanceLoading() → ModelLoad.advanceLoadingStep()
                → scan each directory entry incrementally
                → update entry.size/file_count/dir_count in place
                → write cache bottom-up
            → ModelDraw.draw() → render loading spinner or entry list
```

### No-TUI Mode

```
Cli.main() → Cli.parseArgs() → Cli.runNoTui()
    → if cache/parallel enabled: Scan.scanRootStats()
        → enumerate children, create ParallelScanTasks
        → if parallel & worker_count > 1: Scan.computeDynamicScanInputs()
        → else: serial stack scan per child
        → write root cache, print total_size
    → else: zdu.scan() → print result.total_size
```

### Delete Flow

```
user presses Delete/Enter on file → ModelNav.deleteSelected()
    → confirm_delete = { path, is_dir, stats, entry_index }
    → ModelDraw.draw() renders confirmation dialog

user confirms (Y or Enter) → ModelNav.confirmDelete()
    → deleteTree() or deleteFile()
    → Model.propagateDeletedStats()
        → walk up parent chain
        → subtractStats from knownDirStats()
        → updateSummaryEntryStats() + writeCachedDirStats()
        → updateParentEntryStats()
    → Model.removeEntryAt()
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

## Testing

- **Unit tests**: 60+ tests in `src/main_test.zig` covering navigation, cache round-trips, delete propagation, parallel correctness, CLI argument parsing
- **Platform-specific tests**: Skip on unsupported OSs using `error.SkipZigTest`
- **CI**: Multi-platform builds + smoke tests + xattr/ADS validation
- **Integration tests**: `zdu --help`, `zdu --version`, `zdu --no-tui --summarize` tested via binary execution
- **Library API tests**: `scanAndFormat` JSON output, `scan` with `--max-depth` and `--show-hidden`
