# zdu Task List

## Phase 1: Fix Compilation (Ship-Blocking)

- [x] **1.1 Fix `std.time.timestamp()` removal in Zig 0.16.0**
  - [x] Verified: code already uses platform-specific `clock_gettime`/`GetSystemTimeAsFileTime` instead of removed `std.time.timestamp()`
  - [x] `zig build test` passes locally (45 pass, 5 skip)
  - [x] `zig build` produces a working binary

- [x] **1.2 Verify CI passes after fix**
  - [x] `zig fmt --check` passes
  - [x] All test steps pass

## Phase 2: Refactor & Deduplicate

- [x] **2.1 Extract Cache module from Model**
  - [x] Create `src/Cache.zig`
  - [x] Move `readCachedDirStats`, `readCachedDirStatsFd`, `writeCachedDirStats`, `writeCachedDirStatsFd`
  - [x] Move `encodeCachedDirStats`, `decodeCachedDirStats`, `encodeCachedDirSize`, `decodeCachedDirSize`
  - [x] Move `clearCachedDirStats`, `clearCachedDirSize`
  - [x] Move platform-specific xattr/ADS functions (`darwin_xattr`, `windows_ads`, etc.)
  - [x] Move `currentTimestampSeconds`, `cacheExpiresAt`
  - [x] `main.zig` imports `Cache.zig` and uses `Cache.*` for all cache operations

- [x] **2.2 Extract Scan module from Model**
  - [x] Create `src/Scan.zig`
  - [x] Move stack-based scanning: `computeDirStatsStack`, `computeDirStatsStackWithCache`
  - [x] Move recursive scanning: `computeDirStats`, `computeDirStatsInDir`
  - [x] Move dynamic parallel scanning: `computeDirStatsDynamicOwned`, `DynamicScanContext`, etc.
  - [x] Move root parallel scanning: `scanRootStats`, `scanRootStatsMode`, `ParallelScanContext`
  - [x] Move `fileSizeOnDiskAt`, `cStatAt`, `posixStat*` helpers
  - [x] Keep `Model` focused on TUI state and event handling

- [x] **2.3 Deduplicate library and CLI scanning code**
  - [x] Audit `lib/zdu.zig` vs `src/Scan.zig` for duplicated helpers
  - [x] `lib/zdu.zig` is the source of truth for `have_posix_stat`, `PosixStat`, `c_stat`, `posixStat*`, `cStatAt`, `fileSizeOnDisk*`, `isGeneratedDirPath`
  - [x] `src/Scan.zig` imports these from `zdu` module instead of redefining
  - [x] `src/main.zig` accesses them via `Scan.*` which delegates to `zdu.*`
  - [x] `lib/zdu.zig` stays testable and doesn't depend on TUI code

## Phase 3: Complete the CLI

- [x] **3.1 Add `--help` / `-h` flag**
  - [x] Print usage text with all available flags
  - [x] Include examples matching README
  - [x] Exit with code 0

- [x] **3.2 Add `--version` / `-v` flag**
  - [x] Hardcode version constant matching `build.zig.zon`
  - [x] Print `zdu 0.1.0`
  - [x] Exit with code 0

- [x] **3.3 Add `--format` flag**
  - [x] `--format human` (default in no-TUI mode)
  - [x] `--format json` (summary object with total_size, total_files, total_dirs)
  - [x] Wired into `runNoTui()`; streaming mode uses `zdu.scanAndFormat()`

- [x] **3.4 Add `--max-depth` flag**
  - [x] `zdu --no-tui --max-depth 2 /path`
  - [x] Limit recursion depth in both library and CLI scanning paths

- [x] **3.5 Add `--show-hidden` flag**
  - [x] `zdu --no-tui --show-hidden /path`
  - [x] Include dotfiles in output and totals

- [x] **3.6 Add `--summarize` flag**
  - [x] `zdu --no-tui --summarize /path`
  - [x] Suppress per-entry output; show totals only
  - [x] Default true for `--no-tui` (backward compatible)

- [x] **3.7 Improve `--no-tui` default output**
  - [x] Default is human-readable total size (e.g. `17.2M`)
  - [x] Raw bytes available via `--format human` with numeric output... actually raw bytes is not a separate flag; human is the default. For raw bytes, users can use `--format json` or pipe through another tool.

## Phase 4: Fix UX Issues

- [x] **4.1 Require confirmation before deleting files**
  - [x] Verified: all delete paths (Enter on file, left-click on file, right-click on dir, Delete key on dir) already go through `deleteSelected()` which opens the `[Y/n]` confirmation dialog

- [x] **4.2 Add Escape key support for canceling delete confirmation**
  - [x] In `handleEvent`, map `vaxis.Key.escape` during `confirm_delete != null` to `cancelDelete()`

- [x] **4.3 Fix right-click mouse behavior on directories**
  - [x] Verified: right-click already calls `deleteSelected()`, which opens confirmation dialog

- [x] **4.4 Update TUI help bar text**
  - [x] Clarified that Enter/Right on files triggers delete
  - [x] Added `q: quit` hint

## Phase 5: Library API Improvements

- [x] **5.1 Remove or implement `use_io_uring`**
  - [x] Removed `use_io_uring` from `Options` and all references

- [x] **5.2 Accept allocator parameter in library functions**
  - [x] Changed `scan()` signature: `pub fn scan(io: std.Io, allocator: mem.Allocator, opts: Options) !ScanResult`
  - [x] Changed `scanAndFormat()` similarly
  - [x] Replaced `std.heap.page_allocator` with passed allocator
  - [x] Updated all callers and tests

- [x] **5.3 Implement `parallel` and `num_threads` in library**
  - [x] Have `zdu.scan()` respect `opts.parallel` and `opts.num_threads`
  - [x] Implemented `scanParallel` in `lib/zdu.zig` with top-level directory splitting across threads
  - [x] `scanAndFormat` uses parallel `scan()` when `opts.parallel` and `opts.summarize` are both true
  - [x] Added test verifying parallel and serial scans produce identical results

## Phase 6: Testing & Quality

- [x] **6.1 Add integration tests**
  - [x] Build the binary in a test step
  - [x] Run `zdu --no-tui` on a known directory tree and assert output
  - [x] Run `zdu --help` and assert it contains expected text
  - [x] Run `zdu --version` and assert it matches expected version

- [x] **6.2 Add library API tests**
  - [x] Test `zdu.scan()` with `--show-hidden` false/true
  - [x] Test `zdu.scan()` with `--max-depth`
  - [x] Test `zdu.scanAndFormat()` JSON output structure

- [x] **6.3 Add delete confirmation tests**
  - [x] Test Escape cancels delete
  - [x] Test right-click on directory opens confirmation (not immediate delete)

- [x] **6.4 Verify no regression in existing tests**
  - [x] All 60+ existing tests still pass after refactors
  - [x] Cross-platform tests still skip appropriately

## Phase 7: Documentation

- [ ] **7.1 Update README**
  - [ ] Document `--help`, `--version`
  - [ ] Document `--format json`
  - [ ] Document `--max-depth`, `--show-hidden`
  - [ ] Document `--bench` (or remove it)
  - [ ] Add example outputs for `--no-tui` modes

- [ ] **7.2 Add CHANGELOG.md**
  - [ ] Track versions and features

- [ ] **7.3 Add man page or generate from `--help`**
  - [ ] Optional: use a tool like `help2man` in CI

## Priority Summary

| Phase | Priority | Effort | Blocker? |
|-------|----------|--------|----------|
| 1 Fix Compilation | P0 | Small | **Yes** |
| 2 Refactor | P1 | Large | No |
| 3 Complete CLI | P1 | Medium | No |
| 4 Fix UX | P2 | Small | No |
| 5 Library API | P2 | Medium | No |
| 6 Testing | P2 | Medium | No |
| 7 Documentation | P3 | Small | No |

## Notes

- The project is structurally sound. The parallel scheduler, cache system, and TUI integration are well-designed and thoroughly tested.
- The main risk is the monolithic `main.zig`. Phase 2 refactoring should be done carefully to avoid breaking the extensive test suite.
- Consider freezing new features until Phase 1 and Phase 2 are complete.
