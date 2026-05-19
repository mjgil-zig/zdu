# zdu

## Installation

```bash
curl -fsSL https://mjgil.com/zdu/install.sh | bash
```

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

## Cache behavior

`zdu` stores recursive directory statistics in filesystem xattrs. The v3 cache record stores:

- total allocated size
- recursive file count
- recursive directory count
- expiration time

The older size-only v2 xattr is still written for compatibility and can still be read as a fallback, but v3 is preferred when present.

By default:

- On every fresh process start, the initial loading screen recomputes directory stats from the filesystem.
- That initial scan writes directory stats back to xattrs from the bottom up.
- There is no in-process session-size cache.
- Post-startup navigation reads directory stats from xattrs only.

With cache enabled:

- `--cache-ttl <seconds>` allows a fresh process start to trust existing xattrs.
- Defaults to 60 seconds if `--cache-ttl` is provided without a value.
- If an xattr is present and still within the TTL, the initial load may read it directly instead of recomputing that directory.
- If the xattr is missing or expired, the initial load recomputes the directory and writes a fresh xattr.

### Keeping the cache warm

Use `--refresh-cache` when you want a non-interactive run to recompute and rewrite cache entries instead of trusting existing ones. A common setup is a local cron job that refreshes every 30 minutes and writes a 30-minute TTL:

```cron
*/30 * * * * /usr/local/bin/zdu --no-tui --refresh-cache --cache-ttl 1800 /path/to/scan >/dev/null 2>&1
```

For a little scheduling slack, set the TTL slightly longer than the cadence:

```cron
*/30 * * * * /usr/local/bin/zdu --no-tui --refresh-cache --cache-ttl 2100 /path/to/scan >/dev/null 2>&1
```

A GitHub Actions schedule can do the same thing on a self-hosted runner that has access to the real filesystem and preserves xattrs:

```yaml
name: Warm zdu cache

on:
  schedule:
    - cron: "*/30 * * * *"
  workflow_dispatch:

jobs:
  warm-cache:
    runs-on: self-hosted
    steps:
      - name: Refresh zdu xattr cache
        run: zdu --no-tui --refresh-cache --cache-ttl 1800 "$ZDU_SCAN_PATH"
```

## Delete behavior

Deleting a file or directory updates cached parent directory stats by subtracting the deleted entry's known `{size, file_count, dir_count}` while walking up the current navigation chain. It does not rescan or recompute children after the delete.

If a parent directory has neither loaded summary stats nor a readable xattr, that parent cache update is skipped instead of forcing a recompute.

The delete confirmation prompt highlights the uppercase `Y` in `[Y/n]`; pressing uppercase `Y` confirms, `Enter` confirms, and lowercase `n` cancels.

## Parallel cache refresh

`--parallel` enables a no-TUI root scan that splits immediate child directories into work items. The scheduler sorts those items by cached recursive file count, so larger cached subtrees are scheduled first. Each worker uses the stack-machine scanner and writes directory stats bottom-up.

```bash
zdu --no-tui --parallel --jobs 8 --refresh-cache --cache-ttl 1800 /path/to/scan
```

This is most useful with a warm v3 cache, because cached file counts give the scheduler a better estimate of subtree cost.

## How

`zdu` computes directory sizes and recursive file counts, stores them in xattrs, and then reuses those xattrs for navigation and weighted parallel scheduling.

The library API is summary-oriented: `scan()` returns totals without retaining per-entry names or paths, and `scanAndFormat()` streams entry output directly to the supplied writer.

## CLI

- `zdu [path]`
- `zdu --cache-ttl 300 [path]`
- `zdu --cache-ttl [path]` (defaults to 60s)
- `zdu --no-tui [path]`
- `zdu --no-tui --refresh-cache --cache-ttl 1800 [path]`
- `zdu --no-tui --parallel --jobs 8 --refresh-cache --cache-ttl 1800 [path]`
