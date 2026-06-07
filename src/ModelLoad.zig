const builtin = @import("builtin");
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const zdu = @import("zdu");
const Cache = @import("Cache.zig");
const Scan = @import("Scan.zig");
const mem = std.mem;
const Model = @import("Model.zig").Model;

pub fn loadDir(model: *Model) !void {
    if (model.parallel) return model.loadDirParallel();

    model.freeLoading();
    model.freeEntries();

    if (zdu.isGeneratedDirPath(model.cwd)) return;

    var dir = std.Io.Dir.cwd().openDir(model.io, model.cwd, .{ .iterate = true }) catch return;
    defer dir.close(model.io);

    var entries_list: std.ArrayList(Model.Entry) = .empty;
    defer entries_list.deinit(model.allocator);
    errdefer Model.freeEntryItems(model.allocator, entries_list.items);

    try Model.appendParentEntry(model, &entries_list);
    try appendInitialEntries(model, dir, &entries_list, .eager);

    Model.sortEntries(entries_list.items);

    if (model.parent == null) {
        try Model.prependRootSummary(model.allocator, &entries_list, model.cwd);
    }

    Cache.writeCachedDirStatsFd(dir, Model.currentDirStatsFromEntries(entries_list.items), model.cache_ttl_seconds);
    model.entries = try entries_list.toOwnedSlice(model.allocator);
    model.resetEntryView();
}

pub fn loadDirParallel(model: *Model) !void {
    model.freeLoading();
    model.freeEntries();

    if (zdu.isGeneratedDirPath(model.cwd)) return;

    var dir = std.Io.Dir.cwd().openDir(model.io, model.cwd, .{ .iterate = true }) catch return;
    defer dir.close(model.io);

    var entries_list: std.ArrayList(Model.Entry) = .empty;
    defer entries_list.deinit(model.allocator);
    errdefer Model.freeEntryItems(model.allocator, entries_list.items);

    var tasks: std.ArrayList(Model.EntryScanTask) = .empty;
    defer {
        for (tasks.items) |task| model.allocator.free(task.path);
        tasks.deinit(model.allocator);
    }

    try Model.appendParentEntry(model, &entries_list);

    var iter = dir.iterate();
    while (iter.next(model.io) catch null) |entry| {
        const is_dir = entry.kind == .directory;
        if (!is_dir and entry.kind != .file) continue;

        if (is_dir) {
            const full_path = try std.fs.path.join(model.allocator, &.{ model.cwd, entry.name });
            var owns_full_path = true;
            errdefer if (owns_full_path) model.allocator.free(full_path);
            if (zdu.isGeneratedDirPath(full_path)) {
                model.allocator.free(full_path);
                owns_full_path = false;
                continue;
            }

            const cached = if (!model.refresh_cache and model.cache_ttl_seconds > 0)
                Cache.readCachedDirStats(full_path, model.allocator)
            else
                null;
            const stats = cached orelse Model.DirStats{};
            const entry_index = entries_list.items.len;
            try entries_list.append(model.allocator, try Model.allocEntryOwned(
                model.allocator,
                entry.name,
                null,
                stats,
                true,
                .item,
            ));

            if (cached == null) {
                try tasks.append(model.allocator, .{
                    .path = full_path,
                    .entry_index = entry_index,
                    .estimate_files = if (Cache.readCachedDirStats(full_path, model.allocator)) |cached_stats| cached_stats.file_count else 0,
                });
                owns_full_path = false;
            } else {
                model.allocator.free(full_path);
                owns_full_path = false;
            }
        } else {
            try entries_list.append(model.allocator, try Model.allocEntryOwned(
                model.allocator,
                entry.name,
                null,
                Scan.fileEntryStats(Scan.fileSizeOnDiskAt(dir, entry.name, model.io)),
                false,
                .item,
            ));
        }
    }

    sortEntryScanTasks(tasks.items);
    try model.scanEntryTasks(tasks.items, entries_list.items);

    Model.sortEntries(entries_list.items);

    if (model.parent == null) {
        try Model.prependRootSummary(model.allocator, &entries_list, model.cwd);
    }

    Cache.writeCachedDirStatsFd(dir, Model.currentDirStatsFromEntries(entries_list.items), model.cache_ttl_seconds);
    model.entries = try entries_list.toOwnedSlice(model.allocator);
    model.resetEntryView();
}

pub fn beginLoading(model: *Model) !void {
    if (model.parallel) {
        try model.loadDirParallel();
        return;
    }

    model.freeLoading();
    model.freeEntries();

    if (zdu.isGeneratedDirPath(model.cwd)) return;

    var dir = std.Io.Dir.cwd().openDir(model.io, model.cwd, .{ .iterate = true }) catch return;

    var entries_list: std.ArrayList(Model.Entry) = .empty;
    defer entries_list.deinit(model.allocator);
    errdefer Model.freeEntryItems(model.allocator, entries_list.items);
    errdefer dir.close(model.io);

    try Model.appendParentEntry(model, &entries_list);
    try appendInitialEntries(model, dir, &entries_list, .loading);

    model.entries = try entries_list.toOwnedSlice(model.allocator);
    model.loading = .{
        .root_dir = dir,
        .started_at = .now(model.io, .awake),
    };
    model.spinner_frame = 0;
    model.resetEntryView();
}

pub fn advanceLoading(model: *Model) !void {
    var loading = &model.loading.?;
    const start = std.Io.Timestamp.now(model.io, .awake);

    while (try model.advanceLoadingStep()) {
        const now = std.Io.Timestamp.now(model.io, .awake);
        if (start.durationTo(now).nanoseconds >= 16 * std.time.ns_per_ms) break;
    }

    loading = &model.loading.?;
    if (loading.processed < model.entries.len) return;

    Model.sortEntries(model.entries);

    if (model.parent == null) {
        try model.prependRootSummaryToEntries();
    }

    loading.root_dir.close(model.io);
    loading.scan_stack.deinit(model.allocator);
    model.loading = null;
    model.resetEntryView();
}

pub fn advanceLoadingStep(model: *Model) !bool {
    const loading = if (model.loading) |*loading| loading else return false;

    if (loading.scan_stack.items.len > 0) {
        var frame = &loading.scan_stack.items[loading.scan_stack.items.len - 1];
        if (frame.iter.next(model.io) catch null) |entry| {
            if (entry.kind == .file) {
                const stats = Scan.fileEntryStats(Scan.fileSizeOnDiskAt(frame.dir, entry.name, model.io));
                Scan.addStats(&frame.total, stats);
                loading.processed_bytes += stats.size;
                return true;
            }

            if (entry.kind == .directory) {
                switch (Scan.openChildDirForScan(frame.dir, model.io, entry.name, model.cache_ttl_seconds, !model.refresh_cache) orelse return true) {
                    .cached_stats => |cached_stats| {
                        Scan.addStats(&frame.total, cached_stats);
                        loading.processed_bytes += cached_stats.size;
                        loading.processed_dirs += 1;
                        return true;
                    },
                    .dir => |dir| {
                        loading.processed_dirs += 1;
                        try pushLoadingFrame(loading, model.allocator, model.io, dir, frame.entry_index);
                        return true;
                    },
                }
            }

            return true;
        }

        const completed = loading.scan_stack.pop().?;
        Cache.writeCachedDirStatsFd(completed.dir, completed.total, model.cache_ttl_seconds);
        completed.dir.close(model.io);

        if (loading.scan_stack.items.len > 0) {
            Scan.addStats(&loading.scan_stack.items[loading.scan_stack.items.len - 1].total, completed.total);
        } else {
            try model.finalizeLoadingEntry(completed.entry_index, completed.total, true);
        }
        return true;
    }

    if (loading.entry_index >= model.entries.len) return false;

    const idx = loading.entry_index;
    const entry = &model.entries[idx];
    if (entry.role != .item) {
        loading.processed += 1;
        loading.entry_index += 1;
        return true;
    }

    if (!entry.is_dir) {
        const stats = Scan.fileEntryStats(Scan.fileSizeOnDiskAt(loading.root_dir, entry.name, model.io));
        loading.processed_bytes += stats.size;
        try model.finalizeLoadingEntry(idx, stats, false);
        return true;
    }

    switch (Scan.openChildDirForScan(loading.root_dir, model.io, entry.name, model.cache_ttl_seconds, !model.refresh_cache) orelse {
        try model.finalizeLoadingEntry(idx, .{}, false);
        return true;
    }) {
        .cached_stats => |cached_stats| {
            loading.processed_bytes += cached_stats.size;
            loading.processed_dirs += 1;
            try model.finalizeLoadingEntry(idx, cached_stats, true);
            return true;
        },
        .dir => |dir| {
            loading.processed_dirs += 1;
            try pushLoadingFrame(loading, model.allocator, model.io, dir, idx);
            return true;
        },
    }
}

pub fn finalizeLoadingEntry(model: *Model, entry_index: usize, stats: Model.DirStats, cache_written: bool) !void {
    const loading = &model.loading.?;
    if (entry_index < model.entries.len) {
        model.entries[entry_index].size = stats.size;
        model.entries[entry_index].file_count = stats.file_count;
        model.entries[entry_index].dir_count = stats.dir_count;
        if (!cache_written and model.entries[entry_index].is_dir and model.entries[entry_index].role == .item) {
            const full_path = try model.allocEntryPath(model.entries[entry_index]);
            defer model.allocator.free(full_path);
            Cache.writeCachedDirStats(full_path, stats, model.cache_ttl_seconds, model.allocator);
        }
    }
    loading.processed += 1;
    loading.entry_index += 1;
}

pub fn prependRootSummaryToEntries(model: *Model) !void {
    const total_stats = Model.currentDirStatsFromEntries(model.entries);

    const updated = try model.allocator.alloc(Model.Entry, model.entries.len + 1);
    errdefer model.allocator.free(updated);
    updated[0] = try Model.allocEntryOwned(model.allocator, "", model.cwd, total_stats, true, .summary);
    @memcpy(updated[1..], model.entries);
    model.allocator.free(model.entries);
    model.entries = updated;
    if (model.loading) |loading| {
        Cache.writeCachedDirStatsFd(loading.root_dir, total_stats, model.cache_ttl_seconds);
    } else {
        Cache.writeCachedDirStats(model.cwd, total_stats, model.cache_ttl_seconds, model.allocator);
    }
}

pub fn pushLoadingFrame(loading: *Model.Loading, allocator: mem.Allocator, io: std.Io, dir: std.Io.Dir, entry_index: usize) !void {
    var owned_dir = dir;
    errdefer owned_dir.close(io);
    try loading.scan_stack.append(allocator, .{
        .dir = owned_dir,
        .iter = owned_dir.iterateAssumeFirstIteration(),
        .entry_index = entry_index,
        .total = .{ .dir_count = 1 },
    });
}

pub fn appendInitialEntries(model: *Model, dir: std.Io.Dir, entries_list: *std.ArrayList(Model.Entry), mode: Model.InitialEntryMode) !void {
    var iter = dir.iterate();
    while (iter.next(model.io) catch null) |entry| {
        const is_dir = entry.kind == .directory;
        const stats: Model.DirStats = switch (mode) {
            .eager => if (is_dir) blk: {
                const full_path = try std.fs.path.join(model.allocator, &.{ model.cwd, entry.name });
                defer model.allocator.free(full_path);
                if (zdu.isGeneratedDirPath(full_path)) continue;
                if (model.refresh_cache) {
                    break :blk Scan.computeDirStatsRefreshing(full_path, model.allocator, model.io, model.cache_ttl_seconds);
                }
                break :blk Cache.readCachedDirStats(full_path, model.allocator) orelse .{};
            } else Scan.fileEntryStats(Scan.fileSizeOnDiskAt(dir, entry.name, model.io)),
            .loading => blk: {
                if (is_dir) {
                    const full_path = try std.fs.path.join(model.allocator, &.{ model.cwd, entry.name });
                    defer model.allocator.free(full_path);
                    if (zdu.isGeneratedDirPath(full_path)) continue;
                }
                break :blk if (is_dir) Model.DirStats{} else Scan.fileEntryStats(0);
            },
        };

        try entries_list.append(model.allocator, try Model.allocEntryOwned(
            model.allocator,
            entry.name,
            null,
            stats,
            is_dir,
            .item,
        ));
    }
}

pub fn sortEntryScanTasks(tasks: []Model.EntryScanTask) void {
    mem.sortUnstable(Model.EntryScanTask, tasks, {}, struct {
        fn less(_: void, a: Model.EntryScanTask, b: Model.EntryScanTask) bool {
            if (a.estimate_files != b.estimate_files) return a.estimate_files > b.estimate_files;
            return mem.lessThan(u8, a.path, b.path);
        }
    }.less);
}

pub fn entryScanWorkerCount(parallel: bool, requested: usize, task_count: usize) usize {
    if (!parallel or task_count == 0) return 1;
    const detected = if (requested == 0) std.Thread.getCpuCount() catch 1 else requested;
    return @max(@as(usize, 1), detected);
}

pub fn nextEntryScanTask(ctx: *Model.EntryScanContext) ?usize {
    ctx.mutex.lockUncancelable(ctx.io);
    defer ctx.mutex.unlock(ctx.io);

    if (ctx.next_index >= ctx.tasks.len) return null;
    const idx = ctx.next_index;
    ctx.next_index += 1;
    return idx;
}

pub fn entryScanWorker(ctx: *Model.EntryScanContext) void {
    while (nextEntryScanTask(ctx)) |idx| {
        ctx.results[idx] = if (ctx.refresh_cache) blk: {
            break :blk Scan.computeDirStatsStackRefreshing(ctx.tasks[idx].path, ctx.allocator, ctx.io, ctx.cache_ttl_seconds) catch .{};
        } else blk: {
            break :blk Scan.computeDirStatsStack(ctx.tasks[idx].path, ctx.allocator, ctx.io, ctx.cache_ttl_seconds) catch .{};
        };
    }
}

pub fn scanEntryTasks(model: *Model, tasks: []const Model.EntryScanTask, entries: []Model.Entry) !void {
    if (tasks.len == 0) return;

    const worker_count = entryScanWorkerCount(model.parallel, model.num_threads, tasks.len);
    if (worker_count > 1) {
        const inputs = try model.allocator.alloc(Scan.DynamicScanInput, tasks.len);
        defer model.allocator.free(inputs);
        for (tasks, 0..) |task, i| {
            inputs[i] = .{
                .path = task.path,
                .estimate_files = task.estimate_files,
            };
        }

        const results = try Scan.computeDynamicScanInputs(model.io, model.allocator, inputs, .{
            .cache_ttl_seconds = model.cache_ttl_seconds,
            .refresh_cache = model.refresh_cache,
            .parallel = model.parallel,
            .num_threads = model.num_threads,
        }, worker_count);
        defer model.allocator.free(results);

        for (tasks, results) |task, stats| {
            if (task.entry_index < entries.len) Model.updateEntryStats(&entries[task.entry_index], stats);
        }
        return;
    }

    for (tasks) |task| {
        const stats = if (model.refresh_cache) blk: {
            break :blk try Scan.computeDirStatsStackRefreshing(task.path, model.allocator, model.io, model.cache_ttl_seconds);
        } else blk: {
            break :blk try Scan.computeDirStatsStack(task.path, model.allocator, model.io, model.cache_ttl_seconds);
        };
        if (task.entry_index < entries.len) Model.updateEntryStats(&entries[task.entry_index], stats);
    }
}
