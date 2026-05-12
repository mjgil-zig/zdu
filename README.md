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

By default:

- On every fresh process start, the initial loading screen recomputes directory sizes from the filesystem.
- That initial scan writes directory sizes back to xattrs from the bottom up.
- There is no in-process session-size cache.
- Post-startup navigation reads directory sizes from xattrs only.

With cache enabled:

- `--cache-ttl <seconds>` allows a fresh process start to trust existing xattrs.
- Defaults to 60 seconds if `--cache-ttl` is provided without a value.
- If an xattr is present and still within the TTL, the initial load may read it directly instead of recomputing that directory.
- If the xattr is missing or expired, the initial load recomputes the directory and writes a fresh xattr.

Delete behavior:

- Deleting a file or directory writes updated xattrs for every parent directory up to the root of the current navigation chain.
- The active view is reloaded after deletion.

## How

`zdu` computes directory sizes, stores them in xattrs, and then reuses those xattrs for navigation.

The library API is summary-oriented: `scan()` returns totals without retaining per-entry names or paths, and `scanAndFormat()` streams entry output directly to the supplied writer.

## CLI

- `zdu [path]`
- `zdu --cache-ttl 300 [path]`
- `zdu --cache-ttl [path]` (defaults to 60s)
- `zdu --no-tui [path]`
