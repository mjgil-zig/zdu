# Refactoring Task List

Derived from `docs/refactoring_plan.md`. All tasks must be completed with tests passing after each phase.

## Phase 1: Extract `lib/` submodules

| # | Task | Status |
|---|------|--------|
| 1 | Extract `lib/stat.zig` from `lib/zdu.zig` (POSIX stat helpers, `fileSizeOnDiskAt` variants) | Pending |
| 2 | Extract `lib/format.zig` from `lib/zdu.zig` (`writeEntry`, `writeHumanSummary`, `writeJsonString`, `formatResult`) | Pending |
| 3 | Extract `lib/walk.zig` from `lib/zdu.zig` (`walkDirStreaming`, `walkDirTotals`, `entryKindAndSize`, `recordEntry`) | Pending |
| 4 | **Checkpoint:** Run `zig build test` and verify all library tests pass | Pending |

## Phase 2: Extract platform bindings

| # | Task | Status |
|---|------|--------|
| 5 | Extract `src/Platform.zig` from `src/main.zig` (extern declarations, stat wrappers) | Pending |
| 6 | **Checkpoint:** Run `zig build test` and verify all tests pass | Pending |

## Phase 3: Split `Model` struct across files

| # | Task | Status |
|---|------|--------|
| 7 | Create `src/Model.zig` with core struct, lifecycle, entry helpers, selection, stats propagation | Pending |
| 8 | Extract `src/ModelLoad.zig` (loading methods + related tests) | Pending |
| 9 | Extract `src/ModelEvent.zig` (event handling + related tests) | Pending |
| 10 | Extract `src/ModelNav.zig` (navigation / delete + related tests) | Pending |
| 11 | Extract `src/ModelDraw.zig` (draw methods) | Pending |
| 12 | Wire up `pub usingnamespace` imports in `src/Model.zig` | Pending |
| 13 | **Checkpoint:** Run `zig build test` and verify all Model tests pass | Pending |

## Phase 4: Extract CLI code

| # | Task | Status |
|---|------|--------|
| 14 | Extract `src/Cli.zig` (`Config`, `parseArgs`, `runNoTui`, `printHelp`, benchmarks + tests) | Pending |
| 15 | **Checkpoint:** Run `zig build test` and verify CLI tests pass | Pending |

## Phase 5: Clean up `src/main.zig`

| # | Task | Status |
|---|------|--------|
| 16 | Reduce `src/main.zig` to `main()`, shared test helpers, cache tests, and integration tests | Pending |
| 17 | Update `build.zig` if any new module paths are needed | Pending |
| 18 | **Checkpoint:** Run `zig build test` and verify all tests pass | Pending |
| 19 | Validate every file in the project is under 800 LOC | Pending |

## Completion Criteria

- [ ] `zig build test` passes with zero failures
- [ ] No source file exceeds 800 lines of code
- [ ] Public API of `lib/zdu.zig` remains unchanged
- [ ] `Model` methods remain callable as `model.loadDir()`, `model.draw()`, etc.
