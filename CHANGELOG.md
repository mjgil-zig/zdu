# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `--help` / `-h` flag showing usage and all available options
- `--version` / `-v` flag printing version string
- `--format <human|json>` flag for controlling `--no-tui` output format
- `--max-depth <n>` flag to limit recursion depth
- `--show-hidden` flag to include dotfiles in scanning and output
- `--summarize` flag (default for `--no-tui`) to show totals only
- `--bench` flag to run internal worker vs stack benchmark
- Library API: `zdu.scan()` and `zdu.scanAndFormat()` now accept an `allocator` parameter
- Library API: `zdu.scan()` respects `opts.parallel` and `opts.num_threads` via `scanParallel()`
- Escape key support for canceling delete confirmation dialogs

### Changed

- Extracted `src/Cache.zig` module from `main.zig` for cross-platform cache I/O
- Extracted `src/Scan.zig` module from `main.zig` for all scanning strategies
- Deduplicated POSIX stat helpers between library and CLI by exporting shared helpers from `lib/zdu.zig`
- TUI help bar text updated to clarify Enter/Right on files triggers delete

### Fixed

- Windows ADS path mismatch for cwd `.` and `..`
- Strip `\?\` prefix from `GetFinalPathNameByHandleW` for Windows ADS paths

## [0.2.0] - 2025-05-20

### Added

- Parallel cache refresh with dynamic directory-subtree splitting
- Cached directory stats (v3) storing size, file count, dir count, and expiration
- `--parallel` and `--jobs` flags for multi-worker scanning
- `--refresh-cache` flag to force cache recomputation
- `--cache-ttl` flag to trust cached stats within a TTL
- Windows support with NTFS alternate data streams for cache storage

### Changed

- Consolidated scan and cache helpers across platforms
- Improved scan path metadata handling
- Optimized `--no-tui` summary scanning

### Fixed

- Limited macOS stat fallback to x86_64

## [0.1.0] - 2025-05-10

### Added

- Initial release
- Interactive TUI for browsing directory sizes
- Metadata cache via xattrs on Linux/macOS
- Delete confirmation with `[Y/n]` prompt
- `--no-tui` mode for scriptable size output
