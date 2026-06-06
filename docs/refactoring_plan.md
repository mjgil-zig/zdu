# Refactoring Plan: All Files Below 800 LOC

## Current State

| File | Lines | Status |
|------|-------|--------|
| `src/main.zig` | 3298 | ❌ Over limit |
| `lib/zdu.zig` | 876 | ❌ Over limit |
| `src/Scan.zig` | 701 | ✅ OK |
| `src/Cache.zig` | 672 | ✅ OK |
| `build.zig` | 66 | ✅ OK |

**Goal:** Split `src/main.zig` and `lib/zdu.zig` so every file is under 800 lines while keeping all tests passing.

---

## New File Layout

### Library (`lib/`)

| File | Purpose | Est. Lines |
|------|---------|------------|
| `lib/zdu.zig` | Public API: types, `scan()`, `scanAndFormat()`, `scanParallel()`, tests | ~660 |
| `lib/stat.zig` | POSIX stat helpers, `fileSizeOnDiskAt()` variants | ~85 |
| `lib/format.zig` | Output formatting: `writeEntry()`, `writeHumanSummary()`, `writeJsonString()`, etc. | ~90 |
| `lib/walk.zig` | Directory walking: `walkDirStreaming()`, `walkDirTotals()`, `entryKindAndSize()` | ~205 |

### Source (`src/`)

| File | Purpose | Est. Lines |
|------|---------|------------|
| `src/Platform.zig` | OS-specific extern declarations and stat wrappers | ~140 |
| `src/Model.zig` | Core `Model` struct, lifecycle, entries, selection, stats propagation | ~620 |
| `src/ModelLoad.zig` | Directory loading, eager + loading modes, parallel scan entry tasks | ~520 |
| `src/ModelEvent.zig` | `handleEvent()`, mouse/keyboard input, `moveSelection()` | ~380 |
| `src/ModelNav.zig` | `navigateInto()`, `navigateUp()`, `deleteSelected()`, `confirmDelete()` | ~270 |
| `src/ModelDraw.zig` | `draw()`, `drawLoading()`, `drawEntryLine()`, `writeText()`, `formatSize()` | ~230 |
| `src/Cli.zig` | `Config`, `parseArgs()`, `runNoTui()`, `printHelp()`, benchmarks | ~360 |
| `src/main.zig` | `main()`, test helpers, integration tests, cache tests | ~580 |

---

## Step-by-Step Refactoring

### Phase 1: Extract `lib/` submodules

These are the safest changes because they only touch the library boundary.

#### 1.1 Create `lib/stat.zig`

Move from `lib/zdu.zig`:
- `have_posix_stat`, `PosixStat`, `c_stat`
- `posixStatIsRegular`, `posixStatIsDirectory`, `posixStatApparentSize`, `posixStatAllocatedSize`
- `cStatAt`
- `fileSizeOnDiskAt`, `fileSizeOnDiskWithLibcAt`, `fileSizeOnDiskFallbackAt`

Update `lib/zdu.zig` to `pub const` re-export anything `src/` or tests reference directly.

#### 1.2 Create `lib/format.zig`

Move from `lib/zdu.zig`:
- `writeEntry`
- `writeHumanSummary`
- `writeJsonSummaryFields`
- `writeJsonString`
- `formatResult`

Keep the `Format` enum in `lib/zdu.zig` because it is public API; `format.zig` can import it.

#### 1.3 Create `lib/walk.zig`

Move from `lib/zdu.zig`:
- `SizedKind`
- `entryKindAndSize`
- `recordEntry`
- `walkDirStreaming`
- `walkDirTotals`

`lib/zdu.zig` will import `stat.zig`, `format.zig`, and `walk.zig`.

#### 1.4 Verify library tests

Run `zig build test` after each extraction. The `lib/zdu.zig` tests should still pass because the public API surface does not change.

---

### Phase 2: Extract `src/Platform.zig`

Move from `src/main.zig`:
- `have_posix_stat`, `PosixStat`, `c_stat`, `c_time`, `darwin_xattr`, `windows_ads`
- `posixStatIsRegular`, `posixStatApparentSize`, `posixStatAllocatedSize`

`src/main.zig` and `src/Model.zig` will import `Platform` where needed. `Cache.zig` and `Scan.zig` keep their own platform bindings because they are already self-contained.

---

### Phase 3: Split the `Model` struct across files

The `Model` struct in `src/main.zig` is ~1,340 lines of non-test code. We split it using `pub usingnamespace` so methods remain callable as `model.loadDir()`, `model.draw()`, etc.

#### 3.1 Create `src/Model.zig` (core)

Keep in `src/Model.zig`:
- The `Model` struct definition with all fields
- Nested types: `Options`, `Entry`, `EntryRole`, `ConfirmDelete`, `ScanFrame`, `EntryScanTask`, `EntryScanContext`, `Loading`
- Lifecycle: `init`, `initWithCache`, `initWithOptions`, `initLoading*`, `deinit`, `createModel`, `freeState`, `freeLoading`, `freeEntries`, `freeEntryItems`, `freeEntryItem`
- Entry helpers: `allocEntryOwned`, `allocItemPath`, `allocEntryPath`, `statsFromEntry`, `updateEntryStats`, `updateParentEntryStats`, `updateSummaryEntryStats`, `removeEntryAt`
- Sort/compute: `sortEntries`, `totalItemStats`, `currentDirStatsFromEntries`, `totalItemSize`, `entryRoleRank`, `isSelectableEntry`, `initialSelectedIndex`, `prependRootSummary`, `prependRootSummaryToEntries`, `hasStickyRootSummary`, `stickyRootRows`, `minScrollableEntryIndex`, `firstScrollableEntryIndex`, `ensureSelectionVisible`, `computeDirSize`, `knownDirStats`
- Widget glue: `widget`, `typeErasedEventHandler`, `typeErasedDrawFn`
- Stats propagation: `entryPathMatches`, `subtractEntryStatsByPath`, `propagateDeletedStats`
- `pub usingnamespace @import("ModelLoad.zig");`
- `pub usingnamespace @import("ModelDraw.zig");`
- `pub usingnamespace @import("ModelEvent.zig");`
- `pub usingnamespace @import("ModelNav.zig");`

Tests to keep here:
- "selection scrolling follows the viewport"
- "root summary stays sticky while long root list scrolls"
- "model does not process /proc"

#### 3.2 Create `src/ModelLoad.zig`

Define free functions that become methods via `usingnamespace`:
- `appendParentEntry`, `appendInitialEntries`
- `primeDirXattrs`
- `sortEntryScanTasks`, `entryScanWorkerCount`, `nextEntryScanTask`, `entryScanWorker`
- `scanEntryTasks`
- `loadDirParallel`, `loadDir`, `beginLoading`
- `advanceLoading`, `advanceLoadingStep`, `finalizeLoadingEntry`

Inside `ModelLoad.zig`:
```zig
const Model = @import("Model.zig").Model;
```

Zig handles this circular import lazily because `Model` is only used in function signatures, not at container-scope initialization.

Tests to move here:
- "loading writes each nested directory cache..."
- "TUI refresh-cache serial loading ignores fresh stale child cache"
- "TUI refresh-cache parallel jobs scan entries"
- "TUI scan options propagate when navigating into child directories"
- "parallel root scan matches serial stack scan"
- "dynamic parallel scan splits nested children..."
- "parallel worker count can exceed initial task count..."

#### 3.3 Create `src/ModelEvent.zig`

Define free functions:
- `handleEvent`
- `entryIndexForMouseRow`
- `moveSelection`

Tests to move here:
- "backspace navigates up when parent exists"
- "backspace quits when at root"
- "left arrow at root does not quit"
- "left arrow navigates up when parent exists"
- "enter on parent entry navigates up"
- "down key skips root summary row"
- "down key on an empty list does not underflow"
- "Escape cancels delete confirmation"
- "right-click on directory opens delete confirmation"
- "mouse clicks outside the visible list are ignored"
- "root summary row is not clickable"
- "mouse motion uses pointer only for selectable rows"

#### 3.4 Create `src/ModelNav.zig`

Define free functions:
- `navigateInto`
- `navigateUp`
- `deleteSelected`
- `confirmDelete`
- `cancelDelete`

Tests to move here:
- "navigateInto adds parent entry and navigateUp restores cwd"
- "delete walks parent chain and updates cached stats..."
- "uppercase Y confirms delete"
- "delete propagation skips missing cache..."
- "delete propagation skips stale undersized cache"
- "delete delta updates cached ancestors by walking the model chain"

#### 3.5 Create `src/ModelDraw.zig`

Define free functions:
- `draw`
- `drawLoading`
- `drawEntryLine`
- `writeText`
- `formatSize`
- `formatDuration`

No dedicated draw tests exist today; the draw behavior is exercised through event tests that check `ctx.redraw`. This file stays small.

---

### Phase 4: Extract CLI code

#### 4.1 Create `src/Cli.zig`

Move from `src/main.zig`:
- `version`
- `Config`
- `formatSizeHuman`
- `printHelp`
- `parseArgs`
- `parseBoolArg`
- `benchmarkWorkerLoad`, `benchmarkStackLoad`, `runBenchmarks`
- `runNoTui`

Tests to move here:
- All `parseArgs` tests (15 tests)

---

### Phase 5: Clean up `src/main.zig`

What remains in `src/main.zig`:
- `main()` entry point
- Shared test helpers:
  - `testEventContext`
  - `findEntryIndex`, `findFirstDirIndex`
  - `finishLoading`
  - `zduTestExpectUtf16AsciiEqual`
  - `zduTestTmpPath`, `zduTestWriteFile`
  - `zduTestRequireCachedSize`, `zduTestRequireCachedStats`
  - `zduTestEncodeCacheRecord`, `zduTestEncodeStatsCacheRecord`
  - `zduTestSetRawDirSizeXattr`, `zduTestSetRawDirStatsXattr`
- Cache-related tests:
  - "directory size xattr round trip"
  - "Windows ADS relative paths..."
  - "Windows ADS path helper..."
  - "Windows ADS cache round trip..."
  - "Windows ADS cache falls back to legacy v2..."
  - "Windows ADS cache rejects wrong-length stats stream"
  - "dir stats xattr cache stores file counts..."
  - "expired dir size cache is recomputed and refreshed"
  - "refresh cache ignores a still-fresh stats record"
  - "computeDirSize counts allocated bytes for sparse files"
- Integration tests:
  - "integration: --help prints usage"
  - "integration: --version prints version"
  - "integration: --no-tui --summarize prints summary"

Update `src/main.zig` imports:
```zig
const Model = @import("Model.zig").Model;
const Cli = @import("Cli.zig");
```

Update `build.zig`:
- The `test_module` root source file stays `src/main.zig`.
- Add `src/Model.zig`, `src/ModelLoad.zig`, etc. as additional testable modules if needed. In Zig, tests inside files imported by `src/main.zig` are discovered automatically, so no build.zig changes are required for test discovery.

---

## Testing Strategy

After **each phase**, run:

```bash
zig build test
```

If tests fail:
1. Check that imports were updated correctly.
2. Check that `pub` visibility was preserved for anything referenced across files.
3. Check that `usingnamespace` functions are accessible as methods.
4. Check that test helpers in `src/main.zig` are still reachable from tests in sub-files (they are imported via the module graph).

Because Zig compiles the whole module graph, tests in `src/ModelLoad.zig` can call helpers defined in `src/main.zig` as long as `src/main.zig` imports `ModelLoad.zig` or vice versa. The simplest way to ensure this is to have `src/main.zig` import all sub-modules, which it naturally will because it uses `Model` and `Cli`.

---

## Estimated Final Line Counts

| File | Est. Lines |
|------|------------|
| `lib/zdu.zig` | ~660 |
| `lib/stat.zig` | ~85 |
| `lib/format.zig` | ~90 |
| `lib/walk.zig` | ~205 |
| `src/Platform.zig` | ~140 |
| `src/Model.zig` | ~620 |
| `src/ModelLoad.zig` | ~520 |
| `src/ModelEvent.zig` | ~380 |
| `src/ModelNav.zig` | ~270 |
| `src/ModelDraw.zig` | ~230 |
| `src/Cli.zig` | ~360 |
| `src/main.zig` | ~580 |
| `src/Scan.zig` | ~701 |
| `src/Cache.zig` | ~672 |
| `build.zig` | ~66 |

**All files under 800 LOC. All existing tests preserved.**
