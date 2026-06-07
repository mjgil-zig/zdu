# zdu

[![CI](https://github.com/mjgil-zig/zdu/actions/workflows/ci.yaml/badge.svg)](https://github.com/mjgil-zig/zdu/actions/workflows/ci.yaml)
[![Coverage](https://img.shields.io/badge/coverage-82.5%25-brightgreen)](ARCHITECTURE.md#testing)

A fast, low-memory disk usage analyzer with an interactive TUI and a scriptable CLI.

## Installation

### macOS and Linux

```bash
curl -fsSL https://mjgil.com/zdu/install.sh | bash
```

### Windows

```powershell
irm https://mjgil.com/zdu/install.ps1 | iex
```

The Windows installer downloads the native `zdu-<arch>-windows.zip` release asset, verifies its checksum when available, installs `zdu.exe`, and adds the install directory to the user PATH unless `-NoModifyPath` is passed.

## Performance

### Speed (fast)
| Variant | Command | Real (s) | User (s) | Sys (s) |
|---|---|---:|---:|---:|
| **zdu** | `zdu --no-tui "/home/user/git"` | **1.15** | **0.88** | **0.28** |

### Memory Usage
| Directory Size | `zdu --no-tui` Memory | Other Tools Memory |
|---|---:|---:|
| 10k files | ~8 MB | ~50 MB |
| 100k files | ~8 MB | ~450 MB |
| 1M files | **~8 MB** | **800 MB+** |
| 10M files | **~8.2 MB** | **2 GB+** |

The TUI keeps the visible directory entries for the current directory. During the initial loading scan it fills those entries in place; it no longer keeps a separate pending-entry list or a second finalized-entry list.

## CLI Reference

```
Usage: zdu [options] [path]

Options:
  -h, --help              Show this help message and exit
  -v, --version           Show version and exit
  --no-tui                Print total size and exit (no interactive UI)
  --format <human|json>   Output format for --no-tui (default: human)
  --max-depth <n>         Limit recursion depth
  --show-hidden           Include dotfiles in output
  --summarize             Show totals only (default for --no-tui)
  --cache-ttl [seconds]   Trust cached stats within TTL (default 60s if no value)
  --refresh-cache         Recompute and rewrite cache entries
  --parallel              Enable parallel directory scanning
  --jobs, -j <n>          Number of parallel workers (implies --parallel)
  --bench                 Run benchmark and exit
```

### Examples

**Interactive TUI (default)**
```bash
zdu
zdu /home/user/git
```

**Quick size check**
```bash
zdu --no-tui /home/user/git
# 17.2M
```

**JSON output**
```bash
zdu --no-tui --format json /home/user/git
# {
#   "total_size": 18022400,
#   "total_files": 1423,
#   "total_dirs": 87
# }
```

**Limit recursion depth**
```bash
zdu --no-tui --max-depth 2 /home/user/git
```

**Include hidden files**
```bash
zdu --no-tui --show-hidden /home/user/git
```

**Show per-entry breakdown**
```bash
zdu --no-tui --format human --summarize=false /home/user/git
# Entries:
#   src/          8.4M
#   lib/          3.1M
#   docs/         1.2M
#
# Summary:
#   Total size: 17.2M
#   Files: 1423
#   Directories: 87
```

**Parallel scan with cache refresh**
```bash
zdu --no-tui --parallel --jobs 8 --refresh-cache --cache-ttl 1800 /path/to/scan
```

**Benchmark mode**
```bash
zdu --bench /home/user/git
# worker_thread_ms=1150
# stack_machine_ms=1230
```

## Cache behavior

`zdu` stores recursive directory statistics in filesystem metadata: xattrs on Linux/macOS and NTFS alternate data streams on Windows. The v3 cache record stores:

- total allocated size
- recursive file count
- recursive directory count
- expiration time

The older size-only v2 cache record is still written for compatibility and can still be read as a fallback, but v3 is preferred when present.

On Windows, `zdu` stores the same cache records in NTFS alternate data streams attached to each directory, using `:user.zdu.dir_stats.v3:$DATA` and `:user.zdu.dir_size.v2:$DATA`. If the target filesystem does not support alternate data streams, cache reads simply miss and cache writes are ignored.

By default:

- On every fresh process start, the initial loading screen recomputes directory stats from the filesystem.
- That initial scan writes directory stats back to the metadata cache from the bottom up.
- There is no in-process session-size cache.
- Post-startup navigation reads directory stats from the metadata cache only.

With cache enabled:

- `--cache-ttl <seconds>` allows a fresh process start to trust existing cache records.
- Defaults to 60 seconds if `--cache-ttl` is provided without a value.
- If a cache record is present and still within the TTL, the initial load may read it directly instead of recomputing that directory.
- If the cache record is missing or expired, the initial load recomputes the directory and writes a fresh record.

### Keeping the cache warm

Use `--refresh-cache` when you want a non-interactive run to recompute and rewrite cache entries instead of trusting existing ones. A common setup is a local cron job that refreshes every 30 minutes and writes a 30-minute TTL:

```cron
*/30 * * * * /usr/local/bin/zdu --no-tui --refresh-cache --cache-ttl 1800 /path/to/scan >/dev/null 2>&1
```

For a little scheduling slack, set the TTL slightly longer than the cadence:

```cron
*/30 * * * * /usr/local/bin/zdu --no-tui --refresh-cache --cache-ttl 2100 /path/to/scan >/dev/null 2>&1
```

## Delete behavior

Deleting a file or directory updates cached parent directory stats by subtracting the deleted entry's known `{size, file_count, dir_count}` while walking up the current navigation chain. It does not rescan or recompute children after the delete.

If a parent directory has neither loaded summary stats nor a readable cache record, that parent cache update is skipped instead of forcing a recompute.

The delete confirmation prompt highlights the uppercase `Y` in `[Y/n]`; pressing uppercase `Y` confirms, `Enter` confirms, lowercase `n` cancels, and `Escape` cancels.

## Parallel cache refresh

`--parallel` enables dynamic directory-subtree splitting. The scheduler starts with immediate child directories, then lets workers split newly discovered large child directories into additional work items. Cached recursive file counts are used as cost estimates, so larger cached subtrees are scheduled first; when estimates are unavailable, workers still split while the shared queue is underfed.

Parent directories wait for any split child futures before writing their own cache record, so directory stats are still written bottom-up even when work is split dynamically across workers. `--jobs` is not capped by the number of immediate child directories; a single huge top-level directory can still fan out into multiple nested worker tasks.

The same flags work in both modes. In TUI mode, startup and directory-entry scans carry `--refresh-cache`, `--parallel`, and `--jobs` into the model. In no-TUI mode, the root summary scan uses the same dynamic scheduler and prints the final total.

```bash
zdu --no-tui --parallel --jobs 8 --refresh-cache --cache-ttl 1800 /path/to/scan
```

```bash
zdu --parallel --jobs 8 --refresh-cache --cache-ttl 1800 /path/to/scan
```

This is most useful with a warm v3 cache, because cached file counts give the scheduler a better estimate of subtree cost.

## How

`zdu` computes directory sizes and recursive file counts, stores them in the metadata cache, and then reuses those records for navigation and weighted parallel scheduling.

The library API is summary-oriented: `scan()` returns totals without retaining per-entry names or paths, and `scanAndFormat()` streams entry output directly to the supplied writer.
