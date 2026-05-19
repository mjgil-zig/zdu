const builtin = @import("builtin");
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const zdu = @import("zdu");
const mem = std.mem;

const c_stat = struct {
    extern "c" fn fstatat(dirfd: std.c.fd_t, path: [*:0]const u8, buf: *std.c.Stat, flag: u32) c_int;
};

const darwin_xattr = struct {
    extern "c" fn time(timer: ?*i64) i64;
    extern "c" fn getxattr(
        path: [*:0]const u8,
        name: [*:0]const u8,
        value: ?*anyopaque,
        size: usize,
        position: u32,
        options: i32,
    ) isize;
    extern "c" fn setxattr(
        path: [*:0]const u8,
        name: [*:0]const u8,
        value: ?*const anyopaque,
        size: usize,
        position: u32,
        options: i32,
    ) c_int;
    extern "c" fn removexattr(
        path: [*:0]const u8,
        name: [*:0]const u8,
        options: c_int,
    ) c_int;
    extern "c" fn fgetxattr(
        fd: std.c.fd_t,
        name: [*:0]const u8,
        value: ?*anyopaque,
        size: usize,
        position: u32,
        options: c_int,
    ) isize;
    extern "c" fn fsetxattr(
        fd: std.c.fd_t,
        name: [*:0]const u8,
        value: ?*const anyopaque,
        size: usize,
        position: u32,
        options: c_int,
    ) c_int;
};

pub const Model = struct {
    io: std.Io,
    allocator: mem.Allocator,
    cwd: []u8,
    entries: []Entry = &.{},
    loading: ?Loading = null,
    selected: usize = 0,
    scroll_offset: usize = 0,
    last_visible_rows: usize = 0,
    confirm_delete: ?ConfirmDelete = null,
    parent: ?*Model = null,
    spinner_frame: usize = 0,
    cache_ttl_seconds: u64 = 0,
    refresh_cache: bool = false,
    parallel: bool = false,
    num_threads: usize = 0,

    const loading_frames = [_][]const u8{ "|", "/", "-", "\\" };
    const loading_tick_ms: u32 = 16;
    const dir_size_xattr_name: [:0]const u8 = "user.zdu.dir_size.v2";
    const dir_stats_xattr_name: [:0]const u8 = "user.zdu.dir_stats.v3";

    const CachedDirSize = struct {
        size: u64,
        expires_at: u64,
    };

    const CachedDirStats = struct {
        size: u64,
        file_count: u64,
        dir_count: u64,
        expires_at: u64,
    };

    const DirStats = struct {
        size: u64 = 0,
        file_count: u64 = 0,
        dir_count: u64 = 0,
    };

    pub const Options = struct {
        cache_ttl_seconds: u64 = 0,
        refresh_cache: bool = false,
        parallel: bool = false,
        num_threads: usize = 0,
    };

    const EntryRole = enum {
        summary,
        parent,
        item,
    };

    const Entry = struct {
        name: []u8,
        path: ?[]u8 = null,
        size: u64,
        file_count: u64 = 0,
        dir_count: u64 = 0,
        is_dir: bool,
        role: EntryRole = .item,
    };

    const ConfirmDelete = struct {
        path: []u8,
        is_dir: bool,
        stats: DirStats,
        entry_index: usize,
    };

    const ScanFrame = struct {
        dir: std.Io.Dir,
        iter: std.Io.Dir.Iterator,
        entry_index: usize,
        total: DirStats = .{ .dir_count = 1 },
    };

    const CachedOrOpenDir = union(enum) {
        cached_stats: DirStats,
        dir: std.Io.Dir,
    };

    const EntryScanTask = struct {
        path: []u8,
        entry_index: usize,
        estimate_files: u64,
    };

    const EntryScanContext = struct {
        io: std.Io,
        allocator: mem.Allocator,
        cache_ttl_seconds: u64,
        refresh_cache: bool,
        tasks: []const EntryScanTask,
        results: []DirStats,
        next_index: usize = 0,
        mutex: std.Io.Mutex = .init,
    };

    const Loading = struct {
        processed: usize = 0,
        entry_index: usize = 0,
        processed_bytes: u64 = 0,
        processed_dirs: u64 = 0,
        root_dir: std.Io.Dir,
        scan_stack: std.ArrayList(ScanFrame) = .empty,
        started_at: std.Io.Timestamp,
    };

    fn createModel(io: std.Io, allocator: mem.Allocator, cwd: []const u8, options: Options) !*Model {
        const model = try allocator.create(Model);
        errdefer allocator.destroy(model);

        const owned_cwd = try allocator.dupe(u8, cwd);
        errdefer allocator.free(owned_cwd);

        model.* = .{
            .io = io,
            .allocator = allocator,
            .cwd = owned_cwd,
            .cache_ttl_seconds = options.cache_ttl_seconds,
            .refresh_cache = options.refresh_cache,
            .parallel = options.parallel,
            .num_threads = options.num_threads,
        };
        return model;
    }

    fn allocEntryOwned(
        allocator: mem.Allocator,
        name: []const u8,
        path: ?[]const u8,
        stats: DirStats,
        is_dir: bool,
        role: EntryRole,
    ) !Entry {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        var owned_path: ?[]u8 = null;
        errdefer if (owned_path) |value| allocator.free(value);
        if (path) |value| {
            owned_path = try allocator.dupe(u8, value);
        }

        return .{
            .name = owned_name,
            .path = owned_path,
            .size = stats.size,
            .file_count = stats.file_count,
            .dir_count = stats.dir_count,
            .is_dir = is_dir,
            .role = role,
        };
    }

    fn fileEntryStats(size: u64) DirStats {
        return .{ .size = size, .file_count = 1, .dir_count = 0 };
    }

    fn dirEntryStats(size: u64, file_count: u64, dir_count: u64) DirStats {
        return .{ .size = size, .file_count = file_count, .dir_count = dir_count };
    }

    fn addStats(total: *DirStats, value: DirStats) void {
        total.size += value.size;
        total.file_count += value.file_count;
        total.dir_count += value.dir_count;
    }

    fn subtractStats(total: DirStats, value: DirStats) ?DirStats {
        if (value.size > total.size) return null;
        if (value.file_count > total.file_count) return null;
        if (value.dir_count > total.dir_count) return null;
        return .{
            .size = total.size - value.size,
            .file_count = total.file_count - value.file_count,
            .dir_count = total.dir_count - value.dir_count,
        };
    }

    fn statsFromEntry(entry: Entry) DirStats {
        if (entry.is_dir) {
            return .{
                .size = entry.size,
                .file_count = entry.file_count,
                .dir_count = if (entry.dir_count == 0) 1 else entry.dir_count,
            };
        }
        return .{ .size = entry.size, .file_count = 1, .dir_count = 0 };
    }

    fn pushLoadingFrame(loading: *Loading, allocator: mem.Allocator, io: std.Io, dir: std.Io.Dir, entry_index: usize) !void {
        var owned_dir = dir;
        errdefer owned_dir.close(io);
        try loading.scan_stack.append(allocator, .{
            .dir = owned_dir,
            .iter = owned_dir.iterateAssumeFirstIteration(),
            .entry_index = entry_index,
            .total = .{ .dir_count = 1 },
        });
    }

    fn pushDirStatsFrame(stack: *std.ArrayList(StackFrame), allocator: mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
        var owned_dir = dir;
        errdefer owned_dir.close(io);
        try stack.append(allocator, .{
            .dir = owned_dir,
            .iter = owned_dir.iterateAssumeFirstIteration(),
        });
    }

    fn openChildDirForScan(parent_dir: std.Io.Dir, io: std.Io, name: []const u8, cache_ttl_seconds: u64, read_cache: bool) ?CachedOrOpenDir {
        var dir = parent_dir.openDir(io, name, .{ .iterate = true }) catch return null;
        if (read_cache and cache_ttl_seconds > 0) {
            if (readCachedDirStatsFd(dir)) |cached_stats| {
                dir.close(io);
                return .{ .cached_stats = cached_stats };
            }
        }
        return .{ .dir = dir };
    }

    pub fn init(io: std.Io, allocator: mem.Allocator, cwd: []const u8) !*Model {
        return initWithCache(io, allocator, cwd, 0);
    }

    pub fn initWithCache(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !*Model {
        return initWithOptions(io, allocator, cwd, .{ .cache_ttl_seconds = cache_ttl_seconds });
    }

    pub fn initWithOptions(io: std.Io, allocator: mem.Allocator, cwd: []const u8, options: Options) !*Model {
        const model = try createModel(io, allocator, cwd, options);
        errdefer model.deinit();
        try model.primeDirXattrs();
        try model.loadDir();
        return model;
    }

    pub fn initLoading(io: std.Io, allocator: mem.Allocator, cwd: []const u8) !*Model {
        return initLoadingWithCache(io, allocator, cwd, 0);
    }

    pub fn initLoadingWithCache(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !*Model {
        return initLoadingWithOptions(io, allocator, cwd, .{ .cache_ttl_seconds = cache_ttl_seconds });
    }

    pub fn initLoadingWithOptions(io: std.Io, allocator: mem.Allocator, cwd: []const u8, options: Options) !*Model {
        const model = try createModel(io, allocator, cwd, options);
        errdefer model.deinit();
        try model.beginLoading();
        return model;
    }

    pub fn deinit(model: *Model) void {
        if (model.parent) |parent| {
            parent.deinit();
        }
        model.freeState();
        model.allocator.destroy(model);
    }

    fn freeEntryItems(allocator: mem.Allocator, entries: []Entry) void {
        for (entries) |entry| {
            allocator.free(entry.name);
            if (entry.path) |path| allocator.free(path);
        }
    }

    fn freeState(model: *Model) void {
        model.freeLoading();
        model.allocator.free(model.cwd);
        freeEntryItems(model.allocator, model.entries);
        model.allocator.free(model.entries);
        if (model.confirm_delete) |confirm| {
            model.allocator.free(confirm.path);
        }
    }

    fn freeLoading(model: *Model) void {
        if (model.loading) |*loading| {
            loading.root_dir.close(model.io);
            for (loading.scan_stack.items) |*frame| {
                frame.dir.close(model.io);
            }
            loading.scan_stack.deinit(model.allocator);
            model.loading = null;
        }
    }

    fn freeEntries(model: *Model) void {
        freeEntryItems(model.allocator, model.entries);
        model.allocator.free(model.entries);
        model.entries = &.{};
        model.resetEntryView();
    }

    fn entriesStorageBytes(entries: []Entry) u64 {
        var bytes: u64 = @as(u64, @intCast(entries.len * @sizeOf(Entry)));
        for (entries) |entry| {
            bytes += entry.name.len;
            if (entry.path) |path| bytes += path.len;
        }
        return bytes;
    }

    fn allocItemPath(allocator: mem.Allocator, cwd: []const u8, name: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ cwd, name });
    }

    fn allocEntryPath(model: *Model, entry: Entry) ![]u8 {
        if (entry.path) |path| return model.allocator.dupe(u8, path);
        return allocItemPath(model.allocator, model.cwd, entry.name);
    }

    fn resetEntryView(model: *Model) void {
        model.selected = initialSelectedIndex(model.entries);
        model.scroll_offset = 0;
        model.last_visible_rows = 0;
    }

    fn sortEntries(entries: []Entry) void {
        mem.sortUnstable(Entry, entries, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                if (entryRoleRank(a.role) != entryRoleRank(b.role)) return entryRoleRank(a.role) < entryRoleRank(b.role);
                if (a.size != b.size) return a.size > b.size;
                return mem.lessThan(u8, a.name, b.name);
            }
        }.less);
    }

    fn totalItemStats(entries: []const Entry) DirStats {
        var total: DirStats = .{};
        for (entries) |entry| {
            if (entry.role == .item) addStats(&total, statsFromEntry(entry));
        }
        return total;
    }

    fn currentDirStatsFromEntries(entries: []const Entry) DirStats {
        var stats = totalItemStats(entries);
        stats.dir_count += 1;
        return stats;
    }

    fn totalItemSize(entries: []const Entry) u64 {
        return totalItemStats(entries).size;
    }

    const InitialEntryMode = enum {
        eager,
        loading,
    };

    fn appendParentEntry(model: *Model, entries_list: *std.ArrayList(Entry)) !void {
        if (model.parent) |parent| {
            try entries_list.append(model.allocator, try allocEntryOwned(
                model.allocator,
                "..",
                parent.cwd,
                readCachedDirStats(parent.cwd, model.allocator) orelse .{},
                true,
                .parent,
            ));
        }
    }

    fn appendInitialEntries(model: *Model, dir: std.Io.Dir, entries_list: *std.ArrayList(Entry), mode: InitialEntryMode) !void {
        var iter = dir.iterate();
        while (iter.next(model.io) catch null) |entry| {
            const is_dir = entry.kind == .directory;
            const stats: DirStats = switch (mode) {
                .eager => if (is_dir) blk: {
                    const full_path = try std.fs.path.join(model.allocator, &.{ model.cwd, entry.name });
                    defer model.allocator.free(full_path);
                    if (zdu.isGeneratedDirPath(full_path)) continue;
                    if (model.refresh_cache) {
                        break :blk computeDirStatsRefreshing(full_path, model.allocator, model.io, model.cache_ttl_seconds);
                    }
                    break :blk readCachedDirStats(full_path, model.allocator) orelse .{};
                } else fileEntryStats(fileSizeOnDiskAt(dir, entry.name, model.io)),
                .loading => blk: {
                    if (is_dir) {
                        const full_path = try std.fs.path.join(model.allocator, &.{ model.cwd, entry.name });
                        defer model.allocator.free(full_path);
                        if (zdu.isGeneratedDirPath(full_path)) continue;
                    }
                    break :blk if (is_dir) DirStats{} else fileEntryStats(0);
                },
            };

            try entries_list.append(model.allocator, try allocEntryOwned(
                model.allocator,
                entry.name,
                null,
                stats,
                is_dir,
                .item,
            ));
        }
    }

    fn primeDirXattrs(model: *Model) !void {
        if (zdu.isGeneratedDirPath(model.cwd)) return;

        var dir = std.Io.Dir.cwd().openDir(model.io, model.cwd, .{ .iterate = true }) catch return;
        defer dir.close(model.io);

        var iter = dir.iterate();
        while (iter.next(model.io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            const full_path = try std.fs.path.join(model.allocator, &.{ model.cwd, entry.name });
            defer model.allocator.free(full_path);
            if (zdu.isGeneratedDirPath(full_path)) continue;

            _ = if (model.refresh_cache)
                computeDirStatsRefreshing(full_path, model.allocator, model.io, model.cache_ttl_seconds)
            else
                computeDirStats(full_path, model.allocator, model.io, model.cache_ttl_seconds);
        }
    }

    fn sortEntryScanTasks(tasks: []EntryScanTask) void {
        mem.sortUnstable(EntryScanTask, tasks, {}, struct {
            fn less(_: void, a: EntryScanTask, b: EntryScanTask) bool {
                if (a.estimate_files != b.estimate_files) return a.estimate_files > b.estimate_files;
                return mem.lessThan(u8, a.path, b.path);
            }
        }.less);
    }

    fn entryScanWorkerCount(parallel: bool, requested: usize, task_count: usize) usize {
        if (!parallel or task_count <= 1) return 1;
        const detected = if (requested == 0) std.Thread.getCpuCount() catch 1 else requested;
        return @max(@as(usize, 1), @min(detected, task_count));
    }

    fn nextEntryScanTask(ctx: *EntryScanContext) ?usize {
        ctx.mutex.lockUncancelable(ctx.io);
        defer ctx.mutex.unlock(ctx.io);

        if (ctx.next_index >= ctx.tasks.len) return null;
        const idx = ctx.next_index;
        ctx.next_index += 1;
        return idx;
    }

    fn entryScanWorker(ctx: *EntryScanContext) void {
        while (nextEntryScanTask(ctx)) |idx| {
            ctx.results[idx] = if (ctx.refresh_cache) blk: {
                break :blk computeDirStatsStackRefreshing(ctx.tasks[idx].path, ctx.allocator, ctx.io, ctx.cache_ttl_seconds) catch .{};
            } else blk: {
                break :blk computeDirStatsStack(ctx.tasks[idx].path, ctx.allocator, ctx.io, ctx.cache_ttl_seconds) catch .{};
            };
        }
    }

    fn scanEntryTasks(model: *Model, tasks: []const EntryScanTask, entries: []Entry) !void {
        if (tasks.len == 0) return;

        const worker_count = entryScanWorkerCount(model.parallel, model.num_threads, tasks.len);
        if (worker_count > 1) {
            const results = try model.allocator.alloc(DirStats, tasks.len);
            defer model.allocator.free(results);
            for (results) |*result| result.* = .{};

            var ctx = EntryScanContext{
                .io = model.io,
                .allocator = model.allocator,
                .cache_ttl_seconds = model.cache_ttl_seconds,
                .refresh_cache = model.refresh_cache,
                .tasks = tasks,
                .results = results,
            };

            const threads = try model.allocator.alloc(std.Thread, worker_count);
            defer model.allocator.free(threads);

            var spawned: usize = 0;
            errdefer {
                for (threads[0..spawned]) |thread| thread.join();
            }
            while (spawned < worker_count) : (spawned += 1) {
                threads[spawned] = try std.Thread.spawn(.{}, entryScanWorker, .{&ctx});
            }
            for (threads[0..spawned]) |thread| thread.join();

            for (tasks, results) |task, stats| {
                if (task.entry_index < entries.len) updateEntryStats(&entries[task.entry_index], stats);
            }
            return;
        }

        for (tasks) |task| {
            const stats = if (model.refresh_cache) blk: {
                break :blk try computeDirStatsStackRefreshing(task.path, model.allocator, model.io, model.cache_ttl_seconds);
            } else blk: {
                break :blk try computeDirStatsStack(task.path, model.allocator, model.io, model.cache_ttl_seconds);
            };
            if (task.entry_index < entries.len) updateEntryStats(&entries[task.entry_index], stats);
        }
    }

    fn loadDirParallel(model: *Model) !void {
        model.freeLoading();
        model.freeEntries();

        if (zdu.isGeneratedDirPath(model.cwd)) return;

        var dir = std.Io.Dir.cwd().openDir(model.io, model.cwd, .{ .iterate = true }) catch return;
        defer dir.close(model.io);

        var entries_list: std.ArrayList(Entry) = .empty;
        defer entries_list.deinit(model.allocator);
        errdefer freeEntryItems(model.allocator, entries_list.items);

        var tasks: std.ArrayList(EntryScanTask) = .empty;
        defer {
            for (tasks.items) |task| model.allocator.free(task.path);
            tasks.deinit(model.allocator);
        }

        try appendParentEntry(model, &entries_list);

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
                    readCachedDirStats(full_path, model.allocator)
                else
                    null;
                const stats = cached orelse DirStats{};
                const entry_index = entries_list.items.len;
                try entries_list.append(model.allocator, try allocEntryOwned(
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
                        .estimate_files = if (readCachedDirStats(full_path, model.allocator)) |cached_stats| cached_stats.file_count else 0,
                    });
                    owns_full_path = false;
                } else {
                    model.allocator.free(full_path);
                    owns_full_path = false;
                }
            } else {
                try entries_list.append(model.allocator, try allocEntryOwned(
                    model.allocator,
                    entry.name,
                    null,
                    fileEntryStats(fileSizeOnDiskAt(dir, entry.name, model.io)),
                    false,
                    .item,
                ));
            }
        }

        sortEntryScanTasks(tasks.items);
        try model.scanEntryTasks(tasks.items, entries_list.items);

        sortEntries(entries_list.items);

        if (model.parent == null) {
            try prependRootSummary(model.allocator, &entries_list, model.cwd);
        }

        writeCachedDirStatsFd(dir, currentDirStatsFromEntries(entries_list.items), model.cache_ttl_seconds);
        model.entries = try entries_list.toOwnedSlice(model.allocator);
        model.resetEntryView();
    }

    pub fn loadDir(model: *Model) !void {
        if (model.parallel) return model.loadDirParallel();

        model.freeLoading();
        model.freeEntries();

        if (zdu.isGeneratedDirPath(model.cwd)) return;

        var dir = std.Io.Dir.cwd().openDir(model.io, model.cwd, .{ .iterate = true }) catch return;
        defer dir.close(model.io);

        var entries_list: std.ArrayList(Entry) = .empty;
        defer entries_list.deinit(model.allocator);
        errdefer freeEntryItems(model.allocator, entries_list.items);

        try appendParentEntry(model, &entries_list);
        try appendInitialEntries(model, dir, &entries_list, .eager);

        sortEntries(entries_list.items);

        if (model.parent == null) {
            try prependRootSummary(model.allocator, &entries_list, model.cwd);
        }

        writeCachedDirStatsFd(dir, currentDirStatsFromEntries(entries_list.items), model.cache_ttl_seconds);
        model.entries = try entries_list.toOwnedSlice(model.allocator);
        model.resetEntryView();
    }

    fn beginLoading(model: *Model) !void {
        if (model.parallel) {
            try model.loadDirParallel();
            return;
        }

        model.freeLoading();
        model.freeEntries();

        if (zdu.isGeneratedDirPath(model.cwd)) return;

        var dir = std.Io.Dir.cwd().openDir(model.io, model.cwd, .{ .iterate = true }) catch return;

        var entries_list: std.ArrayList(Entry) = .empty;
        defer entries_list.deinit(model.allocator);
        errdefer freeEntryItems(model.allocator, entries_list.items);
        errdefer dir.close(model.io);

        try appendParentEntry(model, &entries_list);
        try appendInitialEntries(model, dir, &entries_list, .loading);

        model.entries = try entries_list.toOwnedSlice(model.allocator);
        model.loading = .{
            .root_dir = dir,
            .started_at = .now(model.io, .awake),
        };
        model.spinner_frame = 0;
        model.resetEntryView();
    }

    fn advanceLoading(model: *Model) !void {
        var loading = &model.loading.?;
        const start = std.Io.Timestamp.now(model.io, .awake);

        while (try model.advanceLoadingStep()) {
            const now = std.Io.Timestamp.now(model.io, .awake);
            if (start.durationTo(now).nanoseconds >= 16 * std.time.ns_per_ms) break;
        }

        loading = &model.loading.?;
        if (loading.processed < model.entries.len) return;

        sortEntries(model.entries);

        if (model.parent == null) {
            try model.prependRootSummaryToEntries();
        }

        loading.root_dir.close(model.io);
        loading.scan_stack.deinit(model.allocator);
        model.loading = null;
        model.resetEntryView();
    }

    fn advanceLoadingStep(model: *Model) !bool {
        const loading = if (model.loading) |*loading| loading else return false;

        if (loading.scan_stack.items.len > 0) {
            var frame = &loading.scan_stack.items[loading.scan_stack.items.len - 1];
            if (frame.iter.next(model.io) catch null) |entry| {
                if (entry.kind == .file) {
                    const stats = fileEntryStats(fileSizeOnDiskAt(frame.dir, entry.name, model.io));
                    addStats(&frame.total, stats);
                    loading.processed_bytes += stats.size;
                    return true;
                }

                if (entry.kind == .directory) {
                    switch (openChildDirForScan(frame.dir, model.io, entry.name, model.cache_ttl_seconds, !model.refresh_cache) orelse return true) {
                        .cached_stats => |cached_stats| {
                            addStats(&frame.total, cached_stats);
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
            writeCachedDirStatsFd(completed.dir, completed.total, model.cache_ttl_seconds);
            completed.dir.close(model.io);

            if (loading.scan_stack.items.len > 0) {
                addStats(&loading.scan_stack.items[loading.scan_stack.items.len - 1].total, completed.total);
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
            const stats = fileEntryStats(fileSizeOnDiskAt(loading.root_dir, entry.name, model.io));
            loading.processed_bytes += stats.size;
            try model.finalizeLoadingEntry(idx, stats, false);
            return true;
        }

        switch (openChildDirForScan(loading.root_dir, model.io, entry.name, model.cache_ttl_seconds, !model.refresh_cache) orelse {
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

    fn finalizeLoadingEntry(model: *Model, entry_index: usize, stats: DirStats, cache_written: bool) !void {
        const loading = &model.loading.?;
        if (entry_index < model.entries.len) {
            model.entries[entry_index].size = stats.size;
            model.entries[entry_index].file_count = stats.file_count;
            model.entries[entry_index].dir_count = stats.dir_count;
            if (!cache_written and model.entries[entry_index].is_dir and model.entries[entry_index].role == .item) {
                const full_path = try model.allocEntryPath(model.entries[entry_index]);
                defer model.allocator.free(full_path);
                writeCachedDirStats(full_path, stats, model.cache_ttl_seconds, model.allocator);
            }
        }
        loading.processed += 1;
        loading.entry_index += 1;
    }

    fn prependRootSummaryToEntries(model: *Model) !void {
        const total_stats = currentDirStatsFromEntries(model.entries);

        const updated = try model.allocator.alloc(Entry, model.entries.len + 1);
        errdefer model.allocator.free(updated);
        updated[0] = try allocEntryOwned(model.allocator, "", model.cwd, total_stats, true, .summary);
        @memcpy(updated[1..], model.entries);
        model.allocator.free(model.entries);
        model.entries = updated;
        if (model.loading) |loading| {
            writeCachedDirStatsFd(loading.root_dir, total_stats, model.cache_ttl_seconds);
        } else {
            writeCachedDirStats(model.cwd, total_stats, model.cache_ttl_seconds, model.allocator);
        }
    }

    fn entryRoleRank(role: EntryRole) u8 {
        return switch (role) {
            .summary => 0,
            .parent => 1,
            .item => 2,
        };
    }

    fn isSelectableEntry(entry: Entry) bool {
        return entry.role != .summary;
    }

    fn initialSelectedIndex(entries: []Entry) usize {
        if (entries.len <= 1) return 0;
        return switch (entries[0].role) {
            .summary, .parent => 1,
            .item => 0,
        };
    }

    fn prependRootSummary(allocator: mem.Allocator, entries: *std.ArrayList(Entry), cwd: []const u8) !void {
        const total_stats = currentDirStatsFromEntries(entries.items);

        try entries.insert(allocator, 0, try allocEntryOwned(allocator, "", cwd, total_stats, true, .summary));
    }

    fn hasStickyRootSummary(model: *const Model) bool {
        return model.entries.len > 0 and model.entries[0].role == .summary;
    }

    fn stickyRootRows(model: *const Model, visible_rows: usize) usize {
        return if (visible_rows > 0 and model.hasStickyRootSummary()) 1 else 0;
    }

    fn minScrollableEntryIndex(model: *const Model) usize {
        return if (model.hasStickyRootSummary()) 1 else 0;
    }

    fn firstScrollableEntryIndex(model: *const Model) usize {
        return @max(model.scroll_offset, model.minScrollableEntryIndex());
    }

    fn ensureSelectionVisible(model: *Model, visible_rows: usize) void {
        if (visible_rows == 0) {
            model.scroll_offset = 0;
            return;
        }

        const min_scroll = model.minScrollableEntryIndex();
        const sticky_rows = model.stickyRootRows(visible_rows);
        const scrollable_rows = visible_rows - sticky_rows;

        if (scrollable_rows == 0) {
            model.scroll_offset = min_scroll;
            return;
        }

        model.scroll_offset = @max(model.scroll_offset, min_scroll);

        if (model.selected < model.scroll_offset) {
            model.scroll_offset = @max(model.selected, min_scroll);
        } else if (model.selected >= model.scroll_offset + scrollable_rows) {
            model.scroll_offset = model.selected - scrollable_rows + 1;
        }

        const scrollable_len = model.entries.len -| min_scroll;
        if (scrollable_len <= scrollable_rows) {
            model.scroll_offset = min_scroll;
        } else {
            const max_scroll = model.entries.len - scrollable_rows;
            model.scroll_offset = @min(@max(model.scroll_offset, min_scroll), max_scroll);
        }
    }

    fn computeDirSize(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) u64 {
        return computeDirStats(path, allocator, io, cache_ttl_seconds).size;
    }

    const StackFrame = struct {
        dir: std.Io.Dir,
        iter: std.Io.Dir.Iterator,
        total: DirStats = .{ .dir_count = 1 },
    };

    fn computeDirStats(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) DirStats {
        return computeDirStatsWithCache(path, allocator, io, cache_ttl_seconds, true);
    }

    fn computeDirStatsRefreshing(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) DirStats {
        return computeDirStatsWithCache(path, allocator, io, cache_ttl_seconds, false);
    }

    fn computeDirStatsWithCache(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64, read_cache: bool) DirStats {
        if (zdu.isGeneratedDirPath(path)) return .{};

        if (read_cache and cache_ttl_seconds > 0) {
            if (readCachedDirStats(path, allocator)) |cached_stats| {
                return cached_stats;
            }
        }

        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return .{ .dir_count = 1 };
        defer dir.close(io);

        return computeDirStatsInDir(dir, io, cache_ttl_seconds, read_cache);
    }

    fn computeDirStatsInDir(dir: std.Io.Dir, io: std.Io, cache_ttl_seconds: u64, read_cache: bool) DirStats {
        if (read_cache and cache_ttl_seconds > 0) {
            if (readCachedDirStatsFd(dir)) |cached_stats| {
                return cached_stats;
            }
        }

        var total: DirStats = .{ .dir_count = 1 };
        var iter = dir.iterateAssumeFirstIteration();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .file) {
                addStats(&total, fileEntryStats(fileSizeOnDiskAt(dir, entry.name, io)));
            } else if (entry.kind == .directory) {
                switch (openChildDirForScan(dir, io, entry.name, cache_ttl_seconds, read_cache) orelse continue) {
                    .cached_stats => |cached_stats| addStats(&total, cached_stats),
                    .dir => |subdir| {
                        defer subdir.close(io);
                        addStats(&total, computeDirStatsInDir(subdir, io, cache_ttl_seconds, read_cache));
                    },
                }
            }
        }
        writeCachedDirStatsFd(dir, total, cache_ttl_seconds);
        return total;
    }

    fn computeDirStatsStack(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) !DirStats {
        return computeDirStatsStackWithCache(path, allocator, io, cache_ttl_seconds, true);
    }

    fn computeDirStatsStackRefreshing(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) !DirStats {
        return computeDirStatsStackWithCache(path, allocator, io, cache_ttl_seconds, false);
    }

    fn computeDirStatsStackWithCache(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64, read_cache: bool) !DirStats {
        var stack: std.ArrayList(StackFrame) = .empty;
        defer {
            for (stack.items) |*frame| {
                frame.dir.close(io);
            }
            stack.deinit(allocator);
        }

        var root_dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return .{ .dir_count = 1 };
        if (read_cache and cache_ttl_seconds > 0) {
            if (readCachedDirStatsFd(root_dir)) |cached_stats| {
                root_dir.close(io);
                return cached_stats;
            }
        }
        try pushDirStatsFrame(&stack, allocator, io, root_dir);

        while (stack.items.len > 0) {
            var frame = &stack.items[stack.items.len - 1];
            if (frame.iter.next(io) catch null) |entry| {
                if (entry.kind == .file) {
                    addStats(&frame.total, fileEntryStats(fileSizeOnDiskAt(frame.dir, entry.name, io)));
                    continue;
                }
                if (entry.kind == .directory) {
                    switch (openChildDirForScan(frame.dir, io, entry.name, cache_ttl_seconds, read_cache) orelse continue) {
                        .cached_stats => |cached_stats| {
                            addStats(&frame.total, cached_stats);
                            continue;
                        },
                        .dir => |subdir| {
                            try pushDirStatsFrame(&stack, allocator, io, subdir);
                            continue;
                        },
                    }
                }
                continue;
            }

            const completed = stack.pop().?;
            writeCachedDirStatsFd(completed.dir, completed.total, cache_ttl_seconds);
            completed.dir.close(io);

            if (stack.items.len > 0) {
                addStats(&stack.items[stack.items.len - 1].total, completed.total);
            } else {
                return completed.total;
            }
        }

        return .{};
    }

    fn fileSizeOnDisk(path: []const u8, allocator: mem.Allocator, io: std.Io) u64 {
        _ = allocator;
        return fileSizeOnDiskAt(std.Io.Dir.cwd(), path, io);
    }

    fn fileSizeOnDiskAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
        return switch (builtin.os.tag) {
            .linux => if (builtin.link_libc) fileSizeOnDiskWithLibcAt(dir, sub_path, io) else fileSizeOnDiskFallbackAt(dir, sub_path, io),
            .macos => if (builtin.cpu.arch == .x86_64)
                fileSizeOnDiskFallbackAt(dir, sub_path, io)
            else if (builtin.link_libc)
                fileSizeOnDiskWithLibcAt(dir, sub_path, io)
            else
                fileSizeOnDiskFallbackAt(dir, sub_path, io),
            else => fileSizeOnDiskFallbackAt(dir, sub_path, io),
        };
    }

    fn cStatAt(dir: std.Io.Dir, sub_path: []const u8) ?std.c.Stat {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (sub_path.len + 1 > path_buf.len) return null;
        @memcpy(path_buf[0..sub_path.len], sub_path);
        path_buf[sub_path.len] = 0;
        var stat: std.c.Stat = undefined;
        if (c_stat.fstatat(dir.handle, @ptrCast(path_buf[0..sub_path.len :0].ptr), &stat, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
            return null;
        }
        return stat;
    }

    fn fileSizeOnDiskWithLibcAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
        const stat = cStatAt(dir, sub_path) orelse return fileSizeOnDiskFallbackAt(dir, sub_path, io);
        const apparent_size: u64 = if (stat.size < 0) 0 else @intCast(stat.size);
        if (!std.c.S.ISREG(stat.mode)) return apparent_size;
        if (stat.blocks <= 0) return apparent_size;
        return @as(u64, @intCast(stat.blocks)) * 512;
    }

    fn fileSizeOnDiskFallbackAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
        const stat = dir.statFile(io, sub_path, .{ .follow_symlinks = false }) catch return 0;
        return stat.size;
    }

    fn readCachedDirSize(path: []const u8, allocator: mem.Allocator) ?u64 {
        if (readCachedDirStats(path, allocator)) |stats| return stats.size;
        return null;
    }

    fn readCachedDirSizeFd(dir: std.Io.Dir) ?u64 {
        if (readCachedDirStatsFd(dir)) |stats| return stats.size;
        return null;
    }

    fn readCachedDirStats(path: []const u8, allocator: mem.Allocator) ?DirStats {
        const now = currentTimestampSeconds() orelse return null;
        const path_z = allocator.dupeZ(u8, path) catch return null;
        defer allocator.free(path_z);
        var buf: [32]u8 = undefined;

        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                const rc = linux.getxattr(path_z.ptr, dir_stats_xattr_name, buf[0..].ptr, buf.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => {
                        if (rc != buf.len) return null;
                        const record = decodeCachedDirStats(&buf);
                        if (record.expires_at < now) return null;
                        return .{
                            .size = record.size,
                            .file_count = record.file_count,
                            .dir_count = record.dir_count,
                        };
                    },
                    else => return readCachedDirStatsV2Z(path_z.ptr, now),
                }
            },
            .macos => {
                const rc = darwin_xattr.getxattr(path_z.ptr, dir_stats_xattr_name, buf[0..].ptr, buf.len, 0, 0);
                switch (std.c.errno(rc)) {
                    .SUCCESS => {
                        if (rc != buf.len) return null;
                        const record = decodeCachedDirStats(&buf);
                        if (record.expires_at < now) return null;
                        return .{
                            .size = record.size,
                            .file_count = record.file_count,
                            .dir_count = record.dir_count,
                        };
                    },
                    else => return readCachedDirStatsV2Z(path_z.ptr, now),
                }
            },
            else => return null,
        }
    }

    fn readCachedDirStatsFd(dir: std.Io.Dir) ?DirStats {
        const now = currentTimestampSeconds() orelse return null;
        var buf: [32]u8 = undefined;

        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                const rc = linux.fgetxattr(dir.handle, dir_stats_xattr_name, buf[0..].ptr, buf.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => {
                        if (rc != buf.len) return null;
                        const record = decodeCachedDirStats(&buf);
                        if (record.expires_at < now) return null;
                        return .{
                            .size = record.size,
                            .file_count = record.file_count,
                            .dir_count = record.dir_count,
                        };
                    },
                    else => return readCachedDirStatsV2Fd(dir, now),
                }
            },
            .macos => {
                const rc = darwin_xattr.fgetxattr(dir.handle, dir_stats_xattr_name, buf[0..].ptr, buf.len, 0, 0);
                switch (std.c.errno(rc)) {
                    .SUCCESS => {
                        if (rc != buf.len) return null;
                        const record = decodeCachedDirStats(&buf);
                        if (record.expires_at < now) return null;
                        return .{
                            .size = record.size,
                            .file_count = record.file_count,
                            .dir_count = record.dir_count,
                        };
                    },
                    else => return readCachedDirStatsV2Fd(dir, now),
                }
            },
            else => return null,
        }
    }

    fn readCachedDirStatsV2Z(path_z: [*:0]const u8, now: u64) ?DirStats {
        var buf: [16]u8 = undefined;

        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                const rc = linux.getxattr(path_z, dir_size_xattr_name, buf[0..].ptr, buf.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => {
                        if (rc != buf.len) return null;
                        const record = decodeCachedDirSize(&buf);
                        if (record.expires_at < now) return null;
                        return .{ .size = record.size };
                    },
                    .NODATA, .NOENT, .OPNOTSUPP, .RANGE => return null,
                    else => return null,
                }
            },
            .macos => {
                const rc = darwin_xattr.getxattr(path_z, dir_size_xattr_name, buf[0..].ptr, buf.len, 0, 0);
                switch (std.c.errno(rc)) {
                    .SUCCESS => {
                        if (rc != buf.len) return null;
                        const record = decodeCachedDirSize(&buf);
                        if (record.expires_at < now) return null;
                        return .{ .size = record.size };
                    },
                    .NOATTR, .NOENT, .OPNOTSUPP, .RANGE => return null,
                    else => return null,
                }
            },
            else => return null,
        }
    }

    fn readCachedDirStatsV2Fd(dir: std.Io.Dir, now: u64) ?DirStats {
        var buf: [16]u8 = undefined;

        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                const rc = linux.fgetxattr(dir.handle, dir_size_xattr_name, buf[0..].ptr, buf.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => {
                        if (rc != buf.len) return null;
                        const record = decodeCachedDirSize(&buf);
                        if (record.expires_at < now) return null;
                        return .{ .size = record.size };
                    },
                    .NODATA, .NOENT, .OPNOTSUPP, .RANGE => return null,
                    else => return null,
                }
            },
            .macos => {
                const rc = darwin_xattr.fgetxattr(dir.handle, dir_size_xattr_name, buf[0..].ptr, buf.len, 0, 0);
                switch (std.c.errno(rc)) {
                    .SUCCESS => {
                        if (rc != buf.len) return null;
                        const record = decodeCachedDirSize(&buf);
                        if (record.expires_at < now) return null;
                        return .{ .size = record.size };
                    },
                    .NOATTR, .NOENT, .OPNOTSUPP, .RANGE => return null,
                    else => return null,
                }
            },
            else => return null,
        }
    }

    fn writeCachedDirSize(path: []const u8, size: u64, cache_ttl_seconds: u64, allocator: mem.Allocator) void {
        writeCachedDirStats(path, .{ .size = size }, cache_ttl_seconds, allocator);
    }

    fn writeCachedDirSizeFd(dir: std.Io.Dir, size: u64, cache_ttl_seconds: u64) void {
        writeCachedDirStatsFd(dir, .{ .size = size }, cache_ttl_seconds);
    }

    fn writeCachedDirStats(path: []const u8, stats: DirStats, cache_ttl_seconds: u64, allocator: mem.Allocator) void {
        const path_z = allocator.dupeZ(u8, path) catch return;
        defer allocator.free(path_z);
        const stats_buf = encodeCachedDirStatsForWrite(stats, cache_ttl_seconds) orelse return;
        const size_buf = encodeCachedDirSizeForWrite(stats.size, cache_ttl_seconds) orelse return;

        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                _ = linux.setxattr(path_z.ptr, dir_stats_xattr_name, stats_buf[0..].ptr, stats_buf.len, 0);
                _ = linux.setxattr(path_z.ptr, dir_size_xattr_name, size_buf[0..].ptr, size_buf.len, 0);
            },
            .macos => {
                _ = darwin_xattr.setxattr(path_z.ptr, dir_stats_xattr_name, stats_buf[0..].ptr, stats_buf.len, 0, 0);
                _ = darwin_xattr.setxattr(path_z.ptr, dir_size_xattr_name, size_buf[0..].ptr, size_buf.len, 0, 0);
            },
            else => {},
        }
    }

    fn writeCachedDirStatsFd(dir: std.Io.Dir, stats: DirStats, cache_ttl_seconds: u64) void {
        const stats_buf = encodeCachedDirStatsForWrite(stats, cache_ttl_seconds) orelse return;
        const size_buf = encodeCachedDirSizeForWrite(stats.size, cache_ttl_seconds) orelse return;

        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                _ = linux.fsetxattr(dir.handle, dir_stats_xattr_name, stats_buf[0..].ptr, stats_buf.len, 0);
                _ = linux.fsetxattr(dir.handle, dir_size_xattr_name, size_buf[0..].ptr, size_buf.len, 0);
            },
            .macos => {
                _ = darwin_xattr.fsetxattr(dir.handle, dir_stats_xattr_name, stats_buf[0..].ptr, stats_buf.len, 0, 0);
                _ = darwin_xattr.fsetxattr(dir.handle, dir_size_xattr_name, size_buf[0..].ptr, size_buf.len, 0, 0);
            },
            else => {},
        }
    }

    fn currentTimestampSeconds() ?u64 {
        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                var ts: linux.timespec = undefined;
                switch (linux.errno(linux.clock_gettime(.REALTIME, &ts))) {
                    .SUCCESS => {
                        if (ts.sec < 0) return null;
                        return @as(u64, @intCast(ts.sec));
                    },
                    else => return null,
                }
            },
            .macos => {
                const now = darwin_xattr.time(null);
                if (now < 0) return null;
                return @as(u64, @intCast(now));
            },
            else => return null,
        }
    }

    fn cacheExpiresAt(cache_ttl_seconds: u64) ?u64 {
        return if (cache_ttl_seconds == 0)
            std.math.maxInt(u64)
        else blk: {
            const now = currentTimestampSeconds() orelse return null;
            break :blk now + cache_ttl_seconds;
        };
    }

    fn encodeCachedDirSizeForWrite(size: u64, cache_ttl_seconds: u64) ?[16]u8 {
        var buf: [16]u8 = undefined;
        encodeCachedDirSize(&buf, .{
            .size = size,
            .expires_at = cacheExpiresAt(cache_ttl_seconds) orelse return null,
        });
        return buf;
    }

    fn encodeCachedDirStatsForWrite(stats: DirStats, cache_ttl_seconds: u64) ?[32]u8 {
        var buf: [32]u8 = undefined;
        encodeCachedDirStats(&buf, .{
            .size = stats.size,
            .file_count = stats.file_count,
            .dir_count = stats.dir_count,
            .expires_at = cacheExpiresAt(cache_ttl_seconds) orelse return null,
        });
        return buf;
    }

    fn encodeCachedDirSize(buf: *[16]u8, record: CachedDirSize) void {
        std.mem.writeInt(u64, buf[0..8], record.size, .little);
        std.mem.writeInt(u64, buf[8..16], record.expires_at, .little);
    }

    fn decodeCachedDirSize(buf: *const [16]u8) CachedDirSize {
        return .{
            .size = std.mem.readInt(u64, buf[0..8], .little),
            .expires_at = std.mem.readInt(u64, buf[8..16], .little),
        };
    }

    fn encodeCachedDirStats(buf: *[32]u8, record: CachedDirStats) void {
        std.mem.writeInt(u64, buf[0..8], record.size, .little);
        std.mem.writeInt(u64, buf[8..16], record.file_count, .little);
        std.mem.writeInt(u64, buf[16..24], record.dir_count, .little);
        std.mem.writeInt(u64, buf[24..32], record.expires_at, .little);
    }

    fn decodeCachedDirStats(buf: *const [32]u8) CachedDirStats {
        return .{
            .size = std.mem.readInt(u64, buf[0..8], .little),
            .file_count = std.mem.readInt(u64, buf[8..16], .little),
            .dir_count = std.mem.readInt(u64, buf[16..24], .little),
            .expires_at = std.mem.readInt(u64, buf[24..32], .little),
        };
    }

    fn clearCachedDirSize(path: []const u8, allocator: mem.Allocator) void {
        const path_z = allocator.dupeZ(u8, path) catch return;
        defer allocator.free(path_z);

        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                _ = linux.removexattr(path_z.ptr, dir_stats_xattr_name);
                _ = linux.removexattr(path_z.ptr, dir_size_xattr_name);
            },
            .macos => {
                _ = darwin_xattr.removexattr(path_z.ptr, dir_stats_xattr_name, 0);
                _ = darwin_xattr.removexattr(path_z.ptr, dir_size_xattr_name, 0);
            },
            else => {},
        }
    }

    fn clearCachedDirStats(path: []const u8, allocator: mem.Allocator) void {
        clearCachedDirSize(path, allocator);
    }

    fn knownDirStats(model: *Model) ?DirStats {
        if (model.entries.len > 0 and model.entries[0].role == .summary) {
            return statsFromEntry(model.entries[0]);
        }
        return readCachedDirStats(model.cwd, model.allocator);
    }

    fn updateEntryStats(entry: *Entry, stats: DirStats) void {
        entry.size = stats.size;
        entry.file_count = stats.file_count;
        entry.dir_count = stats.dir_count;
    }

    fn updateParentEntryStats(model: *Model, stats: DirStats) void {
        for (model.entries) |*entry| {
            if (entry.role == .parent) {
                updateEntryStats(entry, stats);
                return;
            }
        }
    }

    fn updateSummaryEntryStats(model: *Model, stats: DirStats) void {
        if (model.entries.len > 0 and model.entries[0].role == .summary) {
            updateEntryStats(&model.entries[0], stats);
        }
    }

    fn entryPathMatches(model: *Model, entry: Entry, target_path: []const u8) bool {
        if (entry.path) |path| return mem.eql(u8, path, target_path);
        const path = allocItemPath(model.allocator, model.cwd, entry.name) catch return false;
        defer model.allocator.free(path);
        return mem.eql(u8, path, target_path);
    }

    fn subtractEntryStatsByPath(model: *Model, target_path: []const u8, deleted_stats: DirStats) void {
        for (model.entries) |*entry| {
            if (entry.role != .item) continue;
            if (!entryPathMatches(model, entry.*, target_path)) continue;
            if (subtractStats(statsFromEntry(entry.*), deleted_stats)) |updated_stats| {
                updateEntryStats(entry, updated_stats);
            }
            return;
        }
    }

    fn propagateDeletedStats(model: *Model, deleted_stats: DirStats, deleted_path: []const u8) void {
        var current: ?*Model = model;
        var changed_path: []const u8 = deleted_path;
        var child: ?*Model = null;

        while (current) |cursor| {
            const maybe_current_stats = knownDirStats(cursor);
            if (child != null) subtractEntryStatsByPath(cursor, changed_path, deleted_stats);

            if (maybe_current_stats) |current_stats| {
                if (subtractStats(current_stats, deleted_stats)) |updated_stats| {
                    updateSummaryEntryStats(cursor, updated_stats);
                    writeCachedDirStats(cursor.cwd, updated_stats, cursor.cache_ttl_seconds, cursor.allocator);
                    if (child) |child_model| child_model.updateParentEntryStats(updated_stats);
                }
            }

            changed_path = cursor.cwd;
            child = cursor;
            current = cursor.parent;
        }
    }

    fn freeEntryItem(allocator: mem.Allocator, entry: Entry) void {
        allocator.free(entry.name);
        if (entry.path) |path| allocator.free(path);
    }

    fn removeEntryAt(model: *Model, entry_index: usize) !void {
        if (entry_index >= model.entries.len) return;
        const old_entries = model.entries;
        if (old_entries[entry_index].role != .item) return;

        const updated = try model.allocator.alloc(Entry, old_entries.len - 1);
        errdefer model.allocator.free(updated);

        if (entry_index > 0) {
            @memcpy(updated[0..entry_index], old_entries[0..entry_index]);
        }
        if (entry_index + 1 < old_entries.len) {
            @memcpy(updated[entry_index..], old_entries[entry_index + 1 ..]);
        }

        freeEntryItem(model.allocator, old_entries[entry_index]);
        model.allocator.free(old_entries);
        model.entries = updated;
        if (model.selected >= model.entries.len and model.entries.len > 0) model.selected = model.entries.len - 1;
        model.resetEntryView();
    }

    fn entryIndexForMouseRow(model: *Model, mouse_row: i16) ?usize {
        if (mouse_row < 2) return null;

        const sticky_rows = model.stickyRootRows(1);
        if (sticky_rows > 0 and mouse_row == 2) return null;

        const row_offset: i16 = if (sticky_rows > 0) 3 else 2;
        if (mouse_row < row_offset) return null;

        const row = @as(usize, @intCast(mouse_row - row_offset));
        if (row >= model.last_visible_rows) return null;
        const entry_idx = model.firstScrollableEntryIndex() + row;
        if (entry_idx >= model.entries.len) return null;
        if (!isSelectableEntry(model.entries[entry_idx])) return null;
        return entry_idx;
    }

    fn moveSelection(model: *Model, direction: enum { up, down }) void {
        if (model.entries.len == 0) return;

        var idx = model.selected;
        while (true) {
            switch (direction) {
                .up => {
                    if (idx == 0) return;
                    idx -= 1;
                },
                .down => {
                    if (idx + 1 >= model.entries.len) return;
                    idx += 1;
                },
            }
            if (isSelectableEntry(model.entries[idx])) {
                model.selected = idx;
                return;
            }
        }
    }

    pub fn navigateInto(model: *Model) !void {
        if (model.selected >= model.entries.len) return;
        const entry = model.entries[model.selected];
        if (!entry.is_dir or !isSelectableEntry(entry)) return;

        const next_cwd = try model.allocEntryPath(entry);
        errdefer model.allocator.free(next_cwd);

        const io = model.io;
        const allocator = model.allocator;
        const cache_ttl_seconds = model.cache_ttl_seconds;
        const refresh_cache = model.refresh_cache;
        const parallel = model.parallel;
        const num_threads = model.num_threads;

        const parent = try allocator.create(Model);
        errdefer allocator.destroy(parent);
        parent.* = model.*;

        model.* = .{
            .io = io,
            .allocator = allocator,
            .cwd = next_cwd,
            .parent = parent,
            .cache_ttl_seconds = cache_ttl_seconds,
            .refresh_cache = refresh_cache,
            .parallel = parallel,
            .num_threads = num_threads,
        };
        model.loadDir() catch {
            model.allocator.free(model.cwd);
            model.* = parent.*;
            model.allocator.destroy(parent);
        };
    }

    pub fn navigateUp(model: *Model) !void {
        if (model.parent) |parent| {
            model.freeState();
            model.* = parent.*;
            model.allocator.destroy(parent);
        }
    }

    pub fn deleteSelected(model: *Model) !void {
        if (model.selected >= model.entries.len) return;
        const entry = model.entries[model.selected];
        model.confirm_delete = .{
            .path = try model.allocEntryPath(entry),
            .is_dir = entry.is_dir,
            .stats = statsFromEntry(entry),
            .entry_index = model.selected,
        };
    }

    pub fn confirmDelete(model: *Model) !void {
        if (model.confirm_delete) |confirm| {
            defer {
                model.allocator.free(confirm.path);
                model.confirm_delete = null;
            }
            const cwd = std.Io.Dir.cwd();
            if (confirm.is_dir) {
                cwd.deleteTree(model.io, confirm.path) catch return;
            } else {
                cwd.deleteFile(model.io, confirm.path) catch return;
            }
            model.propagateDeletedStats(confirm.stats, confirm.path);
            model.removeEntryAt(confirm.entry_index) catch return;
        }
    }

    pub fn cancelDelete(model: *Model) void {
        if (model.confirm_delete) |confirm| {
            model.allocator.free(confirm.path);
            model.confirm_delete = null;
        }
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const model: *Model = @ptrCast(@alignCast(ptr));
        return model.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) mem.Allocator.Error!vxfw.Surface {
        const model: *Model = @ptrCast(@alignCast(ptr));
        return model.draw(ctx);
    }

    pub fn widget(model: *Model) vxfw.Widget {
        return .{
            .userdata = model,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    pub fn handleEvent(model: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                if (model.loading != null) {
                    try ctx.tick(loading_tick_ms, model.widget());
                    ctx.redraw = true;
                }
                return;
            },
            .tick => {
                if (model.loading != null) {
                    model.spinner_frame = (model.spinner_frame + 1) % loading_frames.len;
                    model.advanceLoading() catch {};
                    if (model.loading != null) {
                        try ctx.tick(loading_tick_ms, model.widget());
                    }
                    ctx.redraw = true;
                }
                return;
            },
            .key_press => |key| {
                if (model.loading != null) {
                    if (key.text) |text| {
                        if (text.len == 1 and text[0] == 'q') {
                            ctx.quit = true;
                            return;
                        }
                    }
                    if (key.codepoint == vaxis.Key.escape and model.parent == null) {
                        ctx.quit = true;
                    }
                    return;
                }

                if (model.confirm_delete != null) {
                    if (key.text) |text| {
                        if (mem.eql(u8, text, "Y")) {
                            model.confirmDelete() catch {};
                            if (model.loading != null) try ctx.tick(loading_tick_ms, model.widget());
                            ctx.redraw = true;
                            return;
                        }
                        if (mem.eql(u8, text, "n")) {
                            model.cancelDelete();
                            ctx.redraw = true;
                            return;
                        }
                    }
                    if (key.codepoint == vaxis.Key.enter) {
                        model.confirmDelete() catch {};
                        if (model.loading != null) try ctx.tick(loading_tick_ms, model.widget());
                        ctx.redraw = true;
                        return;
                    }
                    return;
                }

                if (key.codepoint == vaxis.Key.up) {
                    model.moveSelection(.up);
                    ctx.redraw = true;
                    return;
                }
                if (key.codepoint == vaxis.Key.down) {
                    model.moveSelection(.down);
                    ctx.redraw = true;
                    return;
                }
                if (key.codepoint == vaxis.Key.enter or key.codepoint == vaxis.Key.right) {
                    if (model.selected < model.entries.len) {
                        const entry = model.entries[model.selected];
                        if (!isSelectableEntry(entry)) {
                            return;
                        } else if (entry.role == .parent) {
                            model.navigateUp() catch {};
                        } else if (entry.is_dir) {
                            model.navigateInto() catch {};
                            if (model.loading != null) try ctx.tick(loading_tick_ms, model.widget());
                        } else {
                            model.deleteSelected() catch {};
                        }
                        ctx.redraw = true;
                    }
                    return;
                }
                if (key.codepoint == vaxis.Key.left) {
                    if (model.parent != null) {
                        model.navigateUp() catch {};
                        ctx.redraw = true;
                    }
                    return;
                }
                if (key.codepoint == vaxis.Key.backspace or key.codepoint == vaxis.Key.escape) {
                    if (model.parent == null) {
                        ctx.quit = true;
                    } else {
                        model.navigateUp() catch {};
                        ctx.redraw = true;
                    }
                    return;
                }
                if (key.codepoint == vaxis.Key.delete) {
                    if (model.selected < model.entries.len) {
                        if (model.entries[model.selected].is_dir and isSelectableEntry(model.entries[model.selected])) {
                            model.deleteSelected() catch {};
                            ctx.redraw = true;
                        }
                    }
                    return;
                }
                if (key.text) |text| {
                    if (text.len == 1 and text[0] == 'q') {
                        ctx.quit = true;
                        return;
                    }
                }
            },
            .mouse => |mouse| {
                if (model.loading != null) return;
                if (model.confirm_delete != null) return;
                if (mouse.type == .motion) {
                    const shape: vaxis.Mouse.Shape = if (model.entryIndexForMouseRow(mouse.row) != null) .pointer else .default;
                    try ctx.setMouseShape(shape);
                    return;
                }
                if (mouse.type == .press) {
                    if (mouse.button == .left) {
                        if (model.entryIndexForMouseRow(mouse.row)) |entry_idx| {
                            model.selected = entry_idx;
                            if (model.entries[entry_idx].role == .parent) {
                                model.navigateUp() catch {};
                            } else if (model.entries[entry_idx].is_dir) {
                                model.navigateInto() catch {};
                                if (model.loading != null) try ctx.tick(loading_tick_ms, model.widget());
                            } else {
                                model.deleteSelected() catch {};
                            }
                            ctx.redraw = true;
                            return;
                        }
                    } else if (mouse.button == .right) {
                        if (model.entryIndexForMouseRow(mouse.row)) |entry_idx| {
                            model.selected = entry_idx;
                            if (model.entries[entry_idx].is_dir) {
                                model.deleteSelected() catch {};
                            }
                            ctx.redraw = true;
                            return;
                        }
                    }
                }
            },
            .mouse_enter => {
                try ctx.setMouseShape(.pointer);
            },
            .mouse_leave => {
                try ctx.setMouseShape(.default);
            },
            else => {},
        }
    }

    fn writeText(surface: *vxfw.Surface, allocator: mem.Allocator, text: []const u8, row: u16, start_col: u16, style: vaxis.Style) mem.Allocator.Error!void {
        for (text, 0..) |ch, i| {
            const col: u16 = start_col + @as(u16, @intCast(i));
            const grapheme = try allocator.dupe(u8, &.{ch});
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = grapheme, .width = 1 },
                .style = style,
            });
        }
    }

    fn formatSize(buf: *[32]u8, size: u64) []const u8 {
        const units = "BKMGTPE";
        var val: f64 = @floatFromInt(size);
        var unit_idx: usize = 0;

        while (val >= 1024 and unit_idx < units.len - 1) : (unit_idx += 1) {
            val /= 1024;
        }

        if (unit_idx == 0) {
            return std.fmt.bufPrint(buf, "{d}", .{@as(u64, @intFromFloat(val))}) catch unreachable;
        }
        return std.fmt.bufPrint(buf, "{d:.1}{c}", .{ val, units[unit_idx] }) catch unreachable;
    }

    fn formatDuration(buf: *[32]u8, duration_ms: u64) []const u8 {
        if (duration_ms < std.time.ms_per_s) return std.fmt.bufPrint(buf, "{d}ms", .{duration_ms}) catch unreachable;

        const total_seconds = duration_ms / std.time.ms_per_s;
        if (total_seconds < 60) {
            return std.fmt.bufPrint(buf, "{d}s", .{total_seconds}) catch unreachable;
        }

        const minutes = total_seconds / 60;
        const seconds = total_seconds % 60;
        return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ minutes, seconds }) catch unreachable;
    }

    fn drawLoading(model: *Model, surface: *vxfw.Surface, allocator: mem.Allocator, width: u16, height: u16) mem.Allocator.Error!void {
        var loading = &model.loading.?;
        const total = model.entries.len;
        const done = loading.processed;
        const processed_bytes = loading.processed_bytes;
        const processed_dirs = loading.processed_dirs;
        const elapsed_ns = @max(@as(i128, 0), loading.started_at.durationTo(std.Io.Timestamp.now(model.io, .awake)).nanoseconds);
        var elapsed_buf: [32]u8 = undefined;
        const elapsed_text = formatDuration(&elapsed_buf, @as(u64, @intCast(elapsed_ns / std.time.ns_per_ms)));
        var processed_buf: [32]u8 = undefined;
        const processed_text = formatSize(&processed_buf, processed_bytes);
        const dir_label = if (processed_dirs == 1) "directory" else "directories";

        const title = "Loading directory";
        const spinner = loading_frames[model.spinner_frame];
        const status = try std.fmt.allocPrint(allocator, "{s} {d}/{d} entries", .{ spinner, done, total });
        const detail = try std.fmt.allocPrint(allocator, "Processed: {s}", .{processed_text});
        const meta = try std.fmt.allocPrint(allocator, "{d} {s}   Elapsed: {s}", .{ processed_dirs, dir_label, elapsed_text });

        const start_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(title.len)))) / 2));
        const status_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(status.len)))) / 2));
        const detail_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(detail.len)))) / 2));
        const meta_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(meta.len)))) / 2));
        const center_row = height / 2;

        try writeText(surface, allocator, title, center_row -| 2, start_col, .{ .fg = .{ .index = 15 }, .bold = true });
        try writeText(surface, allocator, status, center_row -| 1, status_col, .{ .fg = .{ .index = 12 } });
        try writeText(surface, allocator, detail, center_row, detail_col, .{ .fg = .{ .index = 10 } });
        try writeText(surface, allocator, meta, center_row + 1, meta_col, .{ .fg = .{ .index = 7 } });
    }

    fn drawEntryLine(model: *Model, surface: *vxfw.Surface, allocator: mem.Allocator, entry_idx: usize, row: u16) mem.Allocator.Error!void {
        const entry = model.entries[entry_idx];
        const prefix = switch (entry.role) {
            .summary => "[ROOT]",
            else => if (entry.is_dir) "[DIR] " else "[FILE]",
        };
        var size_buf: [32]u8 = undefined;
        const size_str = formatSize(&size_buf, entry.size);
        const line = if (entry.is_dir) blk: {
            const file_label = if (entry.file_count == 1) "file" else "files";
            if (entry.name.len == 0) {
                break :blk try std.fmt.allocPrint(allocator, "{s} {s:>10} {d:>8} {s}", .{ prefix, size_str, entry.file_count, file_label });
            }
            break :blk try std.fmt.allocPrint(allocator, "{s} {s:>10} {d:>8} {s} {s}", .{ prefix, size_str, entry.file_count, file_label, entry.name });
        } else try std.fmt.allocPrint(allocator, "{s} {s:>10} {s}", .{ prefix, size_str, entry.name });

        const is_selected = entry_idx == model.selected and isSelectableEntry(entry);
        const style: vaxis.Style = if (is_selected) .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 } } else .{};
        try writeText(surface, allocator, line, row, 0, style);
    }

    pub fn draw(model: *Model, ctx: vxfw.DrawContext) mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 80;
        const height = ctx.max.height orelse 24;

        var surface = try vxfw.Surface.init(ctx.arena, model.widget(), .{ .width = width, .height = height });

        const title = try std.fmt.allocPrint(ctx.arena, "zdu - {s}", .{model.cwd});
        try writeText(&surface, ctx.arena, title, 0, 0, .{ .reverse = true });

        if (model.loading != null) {
            try drawLoading(model, &surface, ctx.arena, width, height);
            return surface;
        }

        const visible_rows = @as(usize, @intCast(height -| 4));
        model.ensureSelectionVisible(visible_rows);

        const sticky_rows = model.stickyRootRows(visible_rows);
        if (sticky_rows > 0) {
            try model.drawEntryLine(&surface, ctx.arena, 0, 2);
        }

        const scrollable_rows = visible_rows - sticky_rows;
        const first_entry = model.firstScrollableEntryIndex();
        const max_entries = @min(model.entries.len -| first_entry, scrollable_rows);
        model.last_visible_rows = max_entries;
        for (0..max_entries) |i| {
            const entry_idx = first_entry + i;
            const row = @as(u16, @intCast(2 + sticky_rows + i));
            try model.drawEntryLine(&surface, ctx.arena, entry_idx, row);
        }

        const help = "up/down: navigate | Enter/Right: open/parent | Delete: del dir | Backspace/Left/Esc: go up";
        try writeText(&surface, ctx.arena, help, height -| 1, 0, .{ .fg = .{ .index = 8 } });

        if (model.confirm_delete) |confirm| {
            const prefix_text = try std.fmt.allocPrint(ctx.arena, "Delete {s}? [", .{confirm.path});
            const suffix_text = "/n]";
            const dialog_len = prefix_text.len + 1 + suffix_text.len;
            const dialog_row = height / 2 -| 1;
            const dialog_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(dialog_len)))) / 2));
            const dialog_style: vaxis.Style = .{ .bg = .{ .index = 1 }, .fg = .{ .index = 15 } };
            const confirm_style: vaxis.Style = .{ .bg = .{ .index = 15 }, .fg = .{ .index = 1 }, .bold = true };
            try writeText(&surface, ctx.arena, prefix_text, dialog_row, dialog_col, dialog_style);
            try writeText(&surface, ctx.arena, "Y", dialog_row, dialog_col + @as(u16, @intCast(prefix_text.len)), confirm_style);
            try writeText(&surface, ctx.arena, suffix_text, dialog_row, dialog_col + @as(u16, @intCast(prefix_text.len + 1)), dialog_style);
        }

        return surface;
    }
};

fn testEventContext(allocator: mem.Allocator, io: std.Io) vxfw.EventContext {
    return .{
        .io = io,
        .alloc = allocator,
        .cmds = .empty,
        .quit = false,
        .redraw = false,
    };
}

fn findEntryIndex(model: *Model, name: []const u8) ?usize {
    for (model.entries, 0..) |entry, idx| {
        if (mem.eql(u8, entry.name, name)) return idx;
    }
    return null;
}

fn findFirstDirIndex(model: *Model) ?usize {
    for (model.entries, 0..) |entry, idx| {
        if (entry.is_dir and entry.role == .item) return idx;
    }
    return null;
}

fn finishLoading(model: *Model, allocator: mem.Allocator, io: std.Io) !void {
    while (model.loading != null) {
        var ctx = testEventContext(allocator, io);
        defer ctx.cmds.deinit(allocator);
        try model.handleEvent(&ctx, .tick);
    }
}

test "navigateInto adds parent entry and navigateUp restores cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const io = std.testing.io;
    const model = try Model.init(io, arena.allocator(), ".");
    defer model.deinit();

    const root_cwd = try arena.allocator().dupe(u8, model.cwd);
    const dir_idx = findFirstDirIndex(model) orelse return error.SkipZigTest;

    try std.testing.expectEqual(Model.EntryRole.summary, model.entries[0].role);
    try std.testing.expectEqualStrings("", model.entries[0].name);
    try std.testing.expectEqual(@as(usize, 1), model.selected);
    const root_size = model.entries[0].size;

    model.selected = dir_idx;
    try model.navigateInto();
    try finishLoading(model, arena.allocator(), io);

    try std.testing.expect(model.parent != null);
    try std.testing.expectEqual(Model.EntryRole.parent, model.entries[0].role);
    try std.testing.expectEqualStrings("..", model.entries[0].name);
    try std.testing.expectEqual(root_size, model.entries[0].size);
    try std.testing.expect(findEntryIndex(model, "..") == 0);
    try std.testing.expectEqual(@as(usize, 1), model.selected);

    try model.navigateUp();
    try std.testing.expect(model.parent == null);
    try std.testing.expectEqualStrings(root_cwd, model.cwd);
}

test "backspace navigates up when parent exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const io = std.testing.io;
    const model = try Model.init(io, arena.allocator(), ".");
    defer model.deinit();

    const dir_idx = findFirstDirIndex(model) orelse return error.SkipZigTest;
    model.selected = dir_idx;
    try model.navigateInto();
    try finishLoading(model, arena.allocator(), io);

    var ctx = testEventContext(arena.allocator(), io);
    defer ctx.cmds.deinit(arena.allocator());

    try model.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.backspace } });

    try std.testing.expect(model.parent == null);
    try std.testing.expect(ctx.redraw);
}

test "backspace quits when at root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const io = std.testing.io;
    const model = try Model.init(io, arena.allocator(), ".");
    defer model.deinit();

    var ctx = testEventContext(arena.allocator(), io);
    defer ctx.cmds.deinit(arena.allocator());

    try model.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.backspace } });

    try std.testing.expect(ctx.quit);
}

test "left arrow at root does not quit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const io = std.testing.io;
    const model = try Model.init(io, arena.allocator(), ".");
    defer model.deinit();

    var ctx = testEventContext(arena.allocator(), io);
    defer ctx.cmds.deinit(arena.allocator());

    try model.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.left } });

    try std.testing.expect(!ctx.quit);
    try std.testing.expect(!ctx.redraw);
    try std.testing.expect(model.parent == null);
}

test "left arrow navigates up when parent exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const io = std.testing.io;
    const model = try Model.init(io, arena.allocator(), ".");
    defer model.deinit();

    const dir_idx = findFirstDirIndex(model) orelse return error.SkipZigTest;
    model.selected = dir_idx;
    try model.navigateInto();
    try finishLoading(model, arena.allocator(), io);

    var ctx = testEventContext(arena.allocator(), io);
    defer ctx.cmds.deinit(arena.allocator());

    try model.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.left } });

    try std.testing.expect(model.parent == null);
    try std.testing.expect(ctx.redraw);
    try std.testing.expect(!ctx.quit);
}

test "enter on parent entry navigates up" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const io = std.testing.io;
    const model = try Model.init(io, arena.allocator(), ".");
    defer model.deinit();

    const dir_idx = findFirstDirIndex(model) orelse return error.SkipZigTest;
    model.selected = dir_idx;
    try model.navigateInto();
    try finishLoading(model, arena.allocator(), io);

    model.selected = findEntryIndex(model, "..") orelse return error.SkipZigTest;

    var ctx = testEventContext(arena.allocator(), io);
    defer ctx.cmds.deinit(arena.allocator());

    try model.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });

    try std.testing.expect(model.parent == null);
    try std.testing.expect(ctx.redraw);
}

test "selection scrolling follows the viewport" {
    var entries = [_]Model.Entry{
        .{ .name = "", .path = "", .size = 0, .is_dir = false },
        .{ .name = "", .path = "", .size = 0, .is_dir = false },
        .{ .name = "", .path = "", .size = 0, .is_dir = false },
        .{ .name = "", .path = "", .size = 0, .is_dir = false },
        .{ .name = "", .path = "", .size = 0, .is_dir = false },
        .{ .name = "", .path = "", .size = 0, .is_dir = false },
    };
    var model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = "",
    };
    model.entries = entries[0..];

    model.selected = 4;
    model.ensureSelectionVisible(3);
    try std.testing.expectEqual(@as(usize, 2), model.scroll_offset);

    model.selected = 1;
    model.ensureSelectionVisible(3);
    try std.testing.expectEqual(@as(usize, 1), model.scroll_offset);
}

test "root summary stays sticky while long root list scrolls" {
    var entries = [_]Model.Entry{
        .{ .name = @constCast(""), .path = @constCast("/tmp/root"), .size = 100, .file_count = 5, .dir_count = 1, .is_dir = true, .role = .summary },
        .{ .name = @constCast("a"), .path = null, .size = 10, .is_dir = true },
        .{ .name = @constCast("b"), .path = null, .size = 9, .is_dir = true },
        .{ .name = @constCast("c"), .path = null, .size = 8, .is_dir = true },
        .{ .name = @constCast("d"), .path = null, .size = 7, .is_dir = true },
        .{ .name = @constCast("e"), .path = null, .size = 6, .is_dir = true },
    };
    var model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = @constCast("/tmp/root"),
        .entries = entries[0..],
        .selected = 5,
    };

    model.ensureSelectionVisible(3);
    model.last_visible_rows = 2;

    try std.testing.expect(model.hasStickyRootSummary());
    try std.testing.expectEqual(@as(usize, 4), model.firstScrollableEntryIndex());
    try std.testing.expectEqual(@as(?usize, null), model.entryIndexForMouseRow(2));
    try std.testing.expectEqual(@as(?usize, 4), model.entryIndexForMouseRow(3));
    try std.testing.expect(model.firstScrollableEntryIndex() != 0);
}

test "directory size xattr round trip" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(dir_path);

    Model.writeCachedDirSize(dir_path, 1234, 60, std.testing.allocator);
    const cached = Model.readCachedDirSize(dir_path, std.testing.allocator);

    if (cached == null) return error.SkipZigTest;
    try std.testing.expectEqual(@as(?u64, 1234), cached);

    Model.clearCachedDirSize(dir_path, std.testing.allocator);
}

test "mouse clicks outside the visible list are ignored" {
    var entries = [_]Model.Entry{
        .{ .name = @constCast("file"), .path = @constCast("/tmp/file"), .size = 1, .is_dir = false },
    };
    var model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = "",
        .entries = entries[0..],
        .last_visible_rows = 1,
    };

    var ctx = testEventContext(std.testing.allocator, std.testing.io);
    defer ctx.cmds.deinit(std.testing.allocator);

    try model.handleEvent(&ctx, .{ .mouse = .{
        .type = .press,
        .button = .left,
        .row = 0,
        .col = 0,
        .mods = .{},
    } });
    try std.testing.expect(!ctx.redraw);

    try model.handleEvent(&ctx, .{ .mouse = .{
        .type = .press,
        .button = .left,
        .row = 5,
        .col = 0,
        .mods = .{},
    } });
    try std.testing.expect(!ctx.redraw);
}

test "root summary row is not clickable" {
    var entries = [_]Model.Entry{
        .{ .name = @constCast(""), .path = @constCast("/tmp"), .size = 10, .is_dir = true, .role = .summary },
        .{ .name = @constCast("child"), .path = @constCast("/tmp/child"), .size = 1, .is_dir = true },
    };
    var model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = "",
        .entries = entries[0..],
        .selected = 1,
        .last_visible_rows = 2,
    };

    var ctx = testEventContext(std.testing.allocator, std.testing.io);
    defer ctx.cmds.deinit(std.testing.allocator);

    try model.handleEvent(&ctx, .{ .mouse = .{
        .type = .press,
        .button = .left,
        .row = 2,
        .col = 0,
        .mods = .{},
    } });

    try std.testing.expectEqual(@as(usize, 1), model.selected);
    try std.testing.expect(!ctx.redraw);
}

test "mouse motion uses pointer only for selectable rows" {
    var entries = [_]Model.Entry{
        .{ .name = @constCast(""), .path = @constCast("/tmp"), .size = 10, .is_dir = true, .role = .summary },
        .{ .name = @constCast("child"), .path = @constCast("/tmp/child"), .size = 1, .is_dir = true },
    };
    var model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = "",
        .entries = entries[0..],
        .last_visible_rows = 2,
    };

    var ctx = testEventContext(std.testing.allocator, std.testing.io);
    defer ctx.cmds.deinit(std.testing.allocator);

    try model.handleEvent(&ctx, .{ .mouse = .{
        .type = .motion,
        .button = .none,
        .row = 2,
        .col = 0,
        .mods = .{},
    } });
    try std.testing.expectEqual(vaxis.Mouse.Shape.default, ctx.cmds.items[0].set_mouse_shape);

    try model.handleEvent(&ctx, .{ .mouse = .{
        .type = .motion,
        .button = .none,
        .row = 3,
        .col = 0,
        .mods = .{},
    } });
    try std.testing.expectEqual(vaxis.Mouse.Shape.pointer, ctx.cmds.items[1].set_mouse_shape);
}

test "down key skips root summary row" {
    var entries = [_]Model.Entry{
        .{ .name = @constCast(""), .path = @constCast("/tmp"), .size = 10, .is_dir = true, .role = .summary },
        .{ .name = @constCast("child"), .path = @constCast("/tmp/child"), .size = 1, .is_dir = true },
    };
    var model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = "",
        .entries = entries[0..],
        .selected = 0,
    };

    var ctx = testEventContext(std.testing.allocator, std.testing.io);
    defer ctx.cmds.deinit(std.testing.allocator);

    try model.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expectEqual(@as(usize, 1), model.selected);
    try std.testing.expect(ctx.redraw);
}

test "down key on an empty list does not underflow" {
    var model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = "",
    };

    var ctx = testEventContext(std.testing.allocator, std.testing.io);
    defer ctx.cmds.deinit(std.testing.allocator);

    try model.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expectEqual(@as(usize, 0), model.selected);
    try std.testing.expect(ctx.redraw);
}

test "delete walks parent chain and updates cached stats without a rescan" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sub");

    {
        var root_file = try tmp.dir.createFile(std.testing.io, "root.bin", .{});
        defer root_file.close(std.testing.io);
        try root_file.writeStreamingAll(std.testing.io, &[_]u8{ 0, 1, 2 });
    }
    {
        var child_file = try tmp.dir.createFile(std.testing.io, "sub/child.bin", .{});
        defer child_file.close(std.testing.io);
        try child_file.writeStreamingAll(std.testing.io, &[_]u8{ 0, 1, 2, 3, 4, 5, 6 });
    }

    const root_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(root_path);
    const child_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sub" });
    defer std.testing.allocator.free(child_path);
    const root_file_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "root.bin" });
    defer std.testing.allocator.free(root_file_path);

    const model = try Model.init(std.testing.io, std.testing.allocator, root_path);
    defer model.deinit();

    model.selected = findEntryIndex(model, "sub") orelse return error.SkipZigTest;
    try model.navigateInto();
    try finishLoading(model, std.testing.allocator, std.testing.io);

    model.selected = findEntryIndex(model, "child.bin") orelse return error.SkipZigTest;
    try model.deleteSelected();
    try model.confirmDelete();

    const remaining_size = Model.fileSizeOnDisk(root_file_path, std.testing.allocator, std.testing.io);
    const child_stats = try zduTestRequireCachedStats(child_path, std.testing.allocator);
    const root_stats = try zduTestRequireCachedStats(root_path, std.testing.allocator);

    try std.testing.expect(findEntryIndex(model, "child.bin") == null);
    try std.testing.expectEqual(@as(u64, 0), child_stats.size);
    try std.testing.expectEqual(@as(u64, 0), child_stats.file_count);
    try std.testing.expectEqual(@as(u64, 1), child_stats.dir_count);
    try std.testing.expectEqual(remaining_size, root_stats.size);
    try std.testing.expectEqual(@as(u64, 1), root_stats.file_count);
    try std.testing.expectEqual(@as(u64, 2), root_stats.dir_count);
    try std.testing.expectEqualStrings("..", model.entries[0].name);
    try std.testing.expectEqual(remaining_size, model.entries[0].size);
    try std.testing.expectEqual(@as(u64, 1), model.entries[0].file_count);
}

test "uppercase Y confirms delete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try zduTestWriteFile(&tmp, "victim.txt", "delete me");

    const root_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(root_path);

    const victim_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "victim.txt" });
    defer std.testing.allocator.free(victim_path);

    const model = try Model.init(std.testing.io, std.testing.allocator, root_path);
    defer model.deinit();

    model.selected = findEntryIndex(model, "victim.txt") orelse return error.SkipZigTest;
    try model.deleteSelected();
    try std.testing.expect(model.confirm_delete != null);

    var ctx = testEventContext(std.testing.allocator, std.testing.io);
    defer ctx.cmds.deinit(std.testing.allocator);

    try model.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'Y', .text = "Y" } });

    try std.testing.expect(model.confirm_delete == null);
    try std.testing.expect(ctx.redraw);
    try std.testing.expect(findEntryIndex(model, "victim.txt") == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, victim_path, .{}));
}

test "delete propagation skips missing cache instead of recomputing" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(root_path);

    Model.clearCachedDirStats(root_path, std.testing.allocator);

    var model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = root_path,
    };

    model.propagateDeletedStats(.{ .size = 1, .file_count = 1 }, root_path);
    try std.testing.expect(Model.readCachedDirStats(root_path, std.testing.allocator) == null);
}

test "delete propagation skips stale undersized cache" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(root_path);

    Model.writeCachedDirStats(root_path, .{ .size = 1, .file_count = 1, .dir_count = 1 }, 60, std.testing.allocator);

    var model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = root_path,
        .cache_ttl_seconds = 60,
    };

    model.propagateDeletedStats(.{ .size = 2, .file_count = 1 }, root_path);

    const cached = try zduTestRequireCachedStats(root_path, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), cached.size);
    try std.testing.expectEqual(@as(u64, 1), cached.file_count);
    try std.testing.expectEqual(@as(u64, 1), cached.dir_count);
}

test "delete delta updates cached ancestors by walking the model chain" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sub");

    const root_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(root_path);
    const child_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sub" });
    defer std.testing.allocator.free(child_path);
    const deleted_path = try std.fs.path.join(std.testing.allocator, &.{ child_path, "victim.txt" });
    defer std.testing.allocator.free(deleted_path);

    Model.writeCachedDirStats(root_path, .{ .size = 100, .file_count = 3, .dir_count = 2 }, 60, std.testing.allocator);
    Model.writeCachedDirStats(child_path, .{ .size = 70, .file_count = 2, .dir_count = 1 }, 60, std.testing.allocator);

    var parent_entries = [_]Model.Entry{
        .{ .name = @constCast(""), .path = root_path, .size = 100, .file_count = 3, .dir_count = 2, .is_dir = true, .role = .summary },
        .{ .name = @constCast("sub"), .path = child_path, .size = 70, .file_count = 2, .dir_count = 1, .is_dir = true },
    };
    var parent_model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = root_path,
        .entries = parent_entries[0..],
        .cache_ttl_seconds = 60,
    };

    var child_entries = [_]Model.Entry{
        .{ .name = @constCast(".."), .path = root_path, .size = 100, .file_count = 3, .dir_count = 2, .is_dir = true, .role = .parent },
    };
    var child_model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = child_path,
        .entries = child_entries[0..],
        .parent = &parent_model,
        .cache_ttl_seconds = 60,
    };

    child_model.propagateDeletedStats(.{ .size = 30, .file_count = 1 }, deleted_path);

    const child_stats = try zduTestRequireCachedStats(child_path, std.testing.allocator);
    const root_stats = try zduTestRequireCachedStats(root_path, std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 40), child_stats.size);
    try std.testing.expectEqual(@as(u64, 1), child_stats.file_count);
    try std.testing.expectEqual(@as(u64, 1), child_stats.dir_count);
    try std.testing.expectEqual(@as(u64, 70), root_stats.size);
    try std.testing.expectEqual(@as(u64, 2), root_stats.file_count);
    try std.testing.expectEqual(@as(u64, 2), root_stats.dir_count);
    try std.testing.expectEqual(@as(u64, 40), parent_entries[1].size);
    try std.testing.expectEqual(@as(u64, 70), child_entries[0].size);
}

test "computeDirSize counts allocated bytes for sparse files" {
    if ((builtin.os.tag != .linux and builtin.os.tag != .macos) or !builtin.link_libc) return error.SkipZigTest;
    // APFS does not expose reliable per-file block allocation info via st_blocks,
    // so we cannot distinguish allocated bytes from apparent size on macOS.
    if (builtin.os.tag == .macos) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var sparse = try tmp.dir.createFile(std.testing.io, "sparse.bin", .{});
        defer sparse.close(std.testing.io);
        try sparse.setLength(std.testing.io, 1024 * 1024 * 1024);
        try sparse.writeStreamingAll(std.testing.io, &[_]u8{0});
    }

    const root_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(root_path);
    const sparse_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sparse.bin" });
    defer std.testing.allocator.free(sparse_path);

    const size = Model.computeDirSize(root_path, std.testing.allocator, std.testing.io, 0);
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, sparse_path, .{});

    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), stat.size);
    try std.testing.expect(size > 0);
    try std.testing.expect(size < stat.size);
}

fn parseBoolArg(value: []const u8) ?bool {
    if (mem.eql(u8, value, "true") or mem.eql(u8, value, "1") or mem.eql(u8, value, "yes")) return true;
    if (mem.eql(u8, value, "false") or mem.eql(u8, value, "0") or mem.eql(u8, value, "no")) return false;
    return null;
}

const RootScanMode = enum {
    worker,
    stack,
};

const RootScanOptions = struct {
    cache_ttl_seconds: u64 = 0,
    refresh_cache: bool = false,
    parallel: bool = false,
    num_threads: usize = 0,
};

const ParallelScanTask = struct {
    path: []u8,
    estimate_files: u64,
};

const ParallelScanContext = struct {
    io: std.Io,
    allocator: mem.Allocator,
    cache_ttl_seconds: u64,
    refresh_cache: bool,
    tasks: []const ParallelScanTask,
    results: []Model.DirStats,
    next_index: usize = 0,
    mutex: std.Io.Mutex = .init,
};

fn sortParallelTasks(tasks: []ParallelScanTask) void {
    mem.sortUnstable(ParallelScanTask, tasks, {}, struct {
        fn less(_: void, a: ParallelScanTask, b: ParallelScanTask) bool {
            if (a.estimate_files != b.estimate_files) return a.estimate_files > b.estimate_files;
            return mem.lessThan(u8, a.path, b.path);
        }
    }.less);
}

fn computeRootTaskStats(io: std.Io, allocator: mem.Allocator, path: []const u8, cache_ttl_seconds: u64, refresh_cache: bool, mode: RootScanMode) !Model.DirStats {
    return switch (mode) {
        .worker => if (refresh_cache)
            Model.computeDirStatsRefreshing(path, allocator, io, cache_ttl_seconds)
        else
            Model.computeDirStats(path, allocator, io, cache_ttl_seconds),
        .stack => if (refresh_cache)
            try Model.computeDirStatsStackRefreshing(path, allocator, io, cache_ttl_seconds)
        else
            try Model.computeDirStatsStack(path, allocator, io, cache_ttl_seconds),
    };
}

fn nextParallelTask(ctx: *ParallelScanContext) ?usize {
    ctx.mutex.lockUncancelable(ctx.io);
    defer ctx.mutex.unlock(ctx.io);

    if (ctx.next_index >= ctx.tasks.len) return null;
    const idx = ctx.next_index;
    ctx.next_index += 1;
    return idx;
}

fn parallelScanWorker(ctx: *ParallelScanContext) void {
    while (nextParallelTask(ctx)) |idx| {
        ctx.results[idx] = computeRootTaskStats(
            ctx.io,
            ctx.allocator,
            ctx.tasks[idx].path,
            ctx.cache_ttl_seconds,
            ctx.refresh_cache,
            .stack,
        ) catch .{};
    }
}

fn resolvedWorkerCount(parallel: bool, requested: usize, task_count: usize) usize {
    if (!parallel or task_count <= 1) return 1;
    const detected = if (requested == 0) std.Thread.getCpuCount() catch 1 else requested;
    return @max(@as(usize, 1), @min(detected, task_count));
}

fn scanRootStatsMode(io: std.Io, allocator: mem.Allocator, cwd: []const u8, opts: RootScanOptions, mode: RootScanMode) !Model.DirStats {
    if (zdu.isGeneratedDirPath(cwd)) return .{};

    var dir = std.Io.Dir.cwd().openDir(io, cwd, .{ .iterate = true }) catch return .{ .dir_count = 1 };
    defer dir.close(io);

    var tasks: std.ArrayList(ParallelScanTask) = .empty;
    defer {
        for (tasks.items) |task| allocator.free(task.path);
        tasks.deinit(allocator);
    }

    var root_stats: Model.DirStats = .{ .dir_count = 1 };
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            const full_path = try std.fs.path.join(allocator, &.{ cwd, entry.name });
            errdefer allocator.free(full_path);
            if (zdu.isGeneratedDirPath(full_path)) {
                allocator.free(full_path);
                continue;
            }
            const estimate_files = if (Model.readCachedDirStats(full_path, allocator)) |cached_stats| cached_stats.file_count else 0;
            try tasks.append(allocator, .{
                .path = full_path,
                .estimate_files = estimate_files,
            });
        } else if (entry.kind == .file) {
            Model.addStats(&root_stats, Model.fileEntryStats(Model.fileSizeOnDiskAt(dir, entry.name, io)));
        }
    }

    sortParallelTasks(tasks.items);

    const worker_count = resolvedWorkerCount(opts.parallel and mode == .stack, opts.num_threads, tasks.items.len);
    if (worker_count > 1) {
        const results = try allocator.alloc(Model.DirStats, tasks.items.len);
        defer allocator.free(results);
        for (results) |*result| result.* = .{};

        var ctx = ParallelScanContext{
            .io = io,
            .allocator = allocator,
            .cache_ttl_seconds = opts.cache_ttl_seconds,
            .refresh_cache = opts.refresh_cache,
            .tasks = tasks.items,
            .results = results,
        };

        const threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);

        var spawned: usize = 0;
        errdefer {
            for (threads[0..spawned]) |thread| thread.join();
        }
        while (spawned < worker_count) : (spawned += 1) {
            threads[spawned] = try std.Thread.spawn(.{}, parallelScanWorker, .{&ctx});
        }
        for (threads[0..spawned]) |thread| thread.join();

        for (results) |stats| Model.addStats(&root_stats, stats);
    } else {
        for (tasks.items) |task| {
            const stats = try computeRootTaskStats(
                io,
                allocator,
                task.path,
                opts.cache_ttl_seconds,
                opts.refresh_cache,
                mode,
            );
            Model.addStats(&root_stats, stats);
        }
    }

    Model.writeCachedDirStats(cwd, root_stats, opts.cache_ttl_seconds, allocator);
    return root_stats;
}

fn scanRootStats(io: std.Io, allocator: mem.Allocator, cwd: []const u8, opts: RootScanOptions) !Model.DirStats {
    return scanRootStatsMode(io, allocator, cwd, opts, .stack);
}

fn scanRootTotal(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64, mode: RootScanMode) !u64 {
    const stats = try scanRootStatsMode(io, allocator, cwd, .{ .cache_ttl_seconds = cache_ttl_seconds }, mode);
    return stats.size;
}

fn benchmarkWorkerLoad(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !u64 {
    const start = std.Io.Timestamp.now(io, .awake);
    _ = try scanRootTotal(io, allocator, cwd, cache_ttl_seconds, .worker);
    const end = std.Io.Timestamp.now(io, .awake);
    return @as(u64, @intCast(@divFloor(start.durationTo(end).nanoseconds, std.time.ns_per_ms)));
}

fn benchmarkStackLoad(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !u64 {
    const start = std.Io.Timestamp.now(io, .awake);
    _ = try scanRootTotal(io, allocator, cwd, cache_ttl_seconds, .stack);

    const end = std.Io.Timestamp.now(io, .awake);
    return @as(u64, @intCast(@divFloor(start.durationTo(end).nanoseconds, std.time.ns_per_ms)));
}

fn runBenchmarks(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !void {
    const worker_ms = try benchmarkWorkerLoad(io, allocator, cwd, cache_ttl_seconds);
    const stack_ms = try benchmarkStackLoad(io, allocator, cwd, cache_ttl_seconds);
    std.debug.print("worker_thread_ms={d}\nstack_machine_ms={d}\n", .{ worker_ms, stack_ms });
}

fn runNoTui(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64, refresh_cache: bool, parallel: bool, num_threads: usize) !void {
    const total_size = blk: {
        if (cache_ttl_seconds > 0 or refresh_cache or parallel) {
            const stats = try scanRootStats(io, allocator, cwd, .{
                .cache_ttl_seconds = cache_ttl_seconds,
                .refresh_cache = refresh_cache,
                .parallel = parallel,
                .num_threads = num_threads,
            });
            break :blk stats.size;
        }

        const result = try zdu.scan(io, .{
            .path = cwd,
            .format = .human,
            .summarize = true,
            .show_hidden = false,
            .max_depth = null,
            .max_entries = null,
            .parallel = parallel,
            .num_threads = if (num_threads == 0) 1 else num_threads,
            .use_io_uring = false,
        });
        break :blk result.total_size;
    };

    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{d}\n", .{total_size});
    try stdout.flush();
}

const Config = struct {
    cwd: []const u8 = ".",
    cache_ttl_seconds: u64 = 0,
    refresh_cache: bool = false,
    parallel: bool = false,
    num_threads: usize = 0,
    bench: bool = false,
    no_tui: bool = false,
};

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (mem.eql(u8, arg, "--cache-ttl")) {
            if (idx + 1 < args.len) {
                const next_arg = args[idx + 1];
                if (std.fmt.parseInt(u64, next_arg, 10)) |val| {
                    config.cache_ttl_seconds = val;
                    idx += 1;
                } else |_| {
                    config.cache_ttl_seconds = 60;
                }
            } else {
                config.cache_ttl_seconds = 60;
            }
        } else if (mem.eql(u8, arg, "--refresh-cache")) {
            config.refresh_cache = true;
        } else if (mem.eql(u8, arg, "--parallel")) {
            config.parallel = true;
        } else if (mem.eql(u8, arg, "--jobs") or mem.eql(u8, arg, "-j")) {
            config.parallel = true;
            if (idx + 1 < args.len) {
                const next_arg = args[idx + 1];
                if (std.fmt.parseInt(usize, next_arg, 10)) |val| {
                    config.num_threads = @max(@as(usize, 1), val);
                    idx += 1;
                } else |_| {
                    config.num_threads = 1;
                }
            } else {
                config.num_threads = 1;
            }
        } else if (mem.eql(u8, arg, "--bench")) {
            config.bench = true;
        } else if (mem.eql(u8, arg, "--no-tui")) {
            config.no_tui = true;
        } else {
            config.cwd = arg;
        }
    }
    return config;
}

pub fn main(init: std.process.Init) !void {
    const temp_allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(temp_allocator);

    const allocator = std.heap.smp_allocator;

    const config = try parseArgs(args);

    if (config.bench) {
        try runBenchmarks(init.io, allocator, config.cwd, config.cache_ttl_seconds);
        return;
    }
    if (config.no_tui) {
        try runNoTui(init.io, allocator, config.cwd, config.cache_ttl_seconds, config.refresh_cache, config.parallel, config.num_threads);
        return;
    }

    const model = try Model.initLoadingWithOptions(init.io, allocator, config.cwd, .{
        .cache_ttl_seconds = config.cache_ttl_seconds,
        .refresh_cache = config.refresh_cache,
        .parallel = config.parallel,
        .num_threads = config.num_threads,
    });
    defer model.deinit();

    var app: vxfw.App = try .init(init.io, allocator, init.environ_map, &.{});
    defer app.deinit();

    try app.run(model.widget(), .{});
}

test "parseArgs: --cache-ttl defaults to 60s" {
    const args = &[_][]const u8{ "zdu", "--cache-ttl" };
    const config = try parseArgs(args);
    try std.testing.expectEqual(@as(u64, 60), config.cache_ttl_seconds);
}

test "parseArgs: --cache-ttl with value" {
    const args = &[_][]const u8{ "zdu", "--cache-ttl", "300" };
    const config = try parseArgs(args);
    try std.testing.expectEqual(@as(u64, 300), config.cache_ttl_seconds);
}

test "parseArgs: --cache-ttl with non-numeric next arg defaults to 60s" {
    const args = &[_][]const u8{ "zdu", "--cache-ttl", "/tmp" };
    const config = try parseArgs(args);
    try std.testing.expectEqual(@as(u64, 60), config.cache_ttl_seconds);
    try std.testing.expectEqualStrings("/tmp", config.cwd);
}

test "parseArgs: full example" {
    const args = &[_][]const u8{ "zdu", "--no-tui", "--cache-ttl", "120", "/home/user" };
    const config = try parseArgs(args);
    try std.testing.expect(config.no_tui);
    try std.testing.expectEqual(@as(u64, 120), config.cache_ttl_seconds);
    try std.testing.expectEqualStrings("/home/user", config.cwd);
}

test "parseArgs: --refresh-cache" {
    const args = &[_][]const u8{ "zdu", "--no-tui", "--refresh-cache", "--cache-ttl", "1800", "/home/user" };
    const config = try parseArgs(args);
    try std.testing.expect(config.no_tui);
    try std.testing.expect(config.refresh_cache);
    try std.testing.expectEqual(@as(u64, 1800), config.cache_ttl_seconds);
    try std.testing.expectEqualStrings("/home/user", config.cwd);
}

test "parseArgs: --parallel and --jobs" {
    const args = &[_][]const u8{ "zdu", "--no-tui", "--parallel", "--jobs", "8", "/home/user" };
    const config = try parseArgs(args);
    try std.testing.expect(config.no_tui);
    try std.testing.expect(config.parallel);
    try std.testing.expectEqual(@as(usize, 8), config.num_threads);
    try std.testing.expectEqualStrings("/home/user", config.cwd);
}

test "parseArgs: refresh cache parallel and jobs apply to TUI" {
    const args = &[_][]const u8{ "zdu", "--refresh-cache", "--parallel", "--jobs", "3", "--cache-ttl", "1800", "/home/user" };
    const config = try parseArgs(args);
    try std.testing.expect(!config.no_tui);
    try std.testing.expect(config.refresh_cache);
    try std.testing.expect(config.parallel);
    try std.testing.expectEqual(@as(usize, 3), config.num_threads);
    try std.testing.expectEqual(@as(u64, 1800), config.cache_ttl_seconds);
    try std.testing.expectEqualStrings("/home/user", config.cwd);
}

test "parseArgs: -j implies parallel" {
    const args = &[_][]const u8{ "zdu", "--no-tui", "-j", "4", "/home/user" };
    const config = try parseArgs(args);
    try std.testing.expect(config.no_tui);
    try std.testing.expect(config.parallel);
    try std.testing.expectEqual(@as(usize, 4), config.num_threads);
    try std.testing.expectEqualStrings("/home/user", config.cwd);
}

test "parallel scan tasks are sorted by cached file count" {
    var tasks = [_]ParallelScanTask{
        .{ .path = @constCast("small"), .estimate_files = 1 },
        .{ .path = @constCast("large"), .estimate_files = 10 },
        .{ .path = @constCast("middle"), .estimate_files = 5 },
    };

    sortParallelTasks(tasks[0..]);

    try std.testing.expectEqualStrings("large", tasks[0].path);
    try std.testing.expectEqualStrings("middle", tasks[1].path);
    try std.testing.expectEqualStrings("small", tasks[2].path);
}

fn zduTestTmpPath(
    allocator: mem.Allocator,
    tmp: *std.testing.TmpDir,
    sub_path: []const u8,
) ![]u8 {
    return std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        sub_path,
    });
}

fn zduTestWriteFile(
    tmp: *std.testing.TmpDir,
    sub_path: []const u8,
    contents: []const u8,
) !void {
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, contents);
}

fn zduTestRequireCachedSize(path: []const u8, allocator: mem.Allocator) !u64 {
    return Model.readCachedDirSize(path, allocator) orelse error.TestUnexpectedResult;
}

fn zduTestRequireCachedStats(path: []const u8, allocator: mem.Allocator) !Model.DirStats {
    return Model.readCachedDirStats(path, allocator) orelse error.TestUnexpectedResult;
}

fn zduTestEncodeCacheRecord(buf: *[16]u8, size: u64, expires_at: u64) void {
    std.mem.writeInt(u64, buf[0..8], size, .little);
    std.mem.writeInt(u64, buf[8..16], expires_at, .little);
}

fn zduTestEncodeStatsCacheRecord(buf: *[32]u8, stats: Model.DirStats, expires_at: u64) void {
    std.mem.writeInt(u64, buf[0..8], stats.size, .little);
    std.mem.writeInt(u64, buf[8..16], stats.file_count, .little);
    std.mem.writeInt(u64, buf[16..24], stats.dir_count, .little);
    std.mem.writeInt(u64, buf[24..32], expires_at, .little);
}

fn zduTestSetRawDirSizeXattr(
    path: []const u8,
    bytes: []const u8,
    allocator: mem.Allocator,
) !void {
    Model.clearCachedDirStats(path, allocator);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.setxattr(
                path_z.ptr,
                Model.dir_size_xattr_name,
                bytes.ptr,
                bytes.len,
                0,
            );
            if (std.os.linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
        },
        .macos => {
            const rc = darwin_xattr.setxattr(
                path_z.ptr,
                Model.dir_size_xattr_name,
                bytes.ptr,
                bytes.len,
                0,
                0,
            );
            if (std.c.errno(rc) != .SUCCESS) return error.SkipZigTest;
        },
        else => return error.SkipZigTest,
    }
}

fn zduTestSetRawDirStatsXattr(
    path: []const u8,
    bytes: []const u8,
    allocator: mem.Allocator,
) !void {
    Model.clearCachedDirStats(path, allocator);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.setxattr(
                path_z.ptr,
                Model.dir_stats_xattr_name,
                bytes.ptr,
                bytes.len,
                0,
            );
            if (std.os.linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
        },
        .macos => {
            const rc = darwin_xattr.setxattr(
                path_z.ptr,
                Model.dir_stats_xattr_name,
                bytes.ptr,
                bytes.len,
                0,
                0,
            );
            if (std.c.errno(rc) != .SUCCESS) return error.SkipZigTest;
        },
        else => return error.SkipZigTest,
    }
}

test "loading writes each nested directory cache with that directory's own size" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root/a/b");
    try tmp.dir.createDirPath(std.testing.io, "root/a/c");

    var b_bytes = [_]u8{'b'} ** 4096;
    var c_bytes = [_]u8{'c'} ** 8192;

    try zduTestWriteFile(&tmp, "root/a/b/file.dat", b_bytes[0..]);
    try zduTestWriteFile(&tmp, "root/a/c/file.dat", c_bytes[0..]);

    const root_path = try zduTestTmpPath(allocator, &tmp, "root");
    defer allocator.free(root_path);

    const a_path = try zduTestTmpPath(allocator, &tmp, "root/a");
    defer allocator.free(a_path);

    const b_path = try zduTestTmpPath(allocator, &tmp, "root/a/b");
    defer allocator.free(b_path);

    const c_path = try zduTestTmpPath(allocator, &tmp, "root/a/c");
    defer allocator.free(c_path);

    Model.clearCachedDirSize(a_path, allocator);
    Model.clearCachedDirSize(b_path, allocator);
    Model.clearCachedDirSize(c_path, allocator);

    var model = try Model.initLoadingWithCache(std.testing.io, allocator, root_path, 0);
    defer model.deinit();

    while (model.loading != null) {
        try model.advanceLoading();
    }

    const a_cached = try zduTestRequireCachedSize(a_path, allocator);
    const b_cached = try zduTestRequireCachedSize(b_path, allocator);
    const c_cached = try zduTestRequireCachedSize(c_path, allocator);
    const a_stats = try zduTestRequireCachedStats(a_path, allocator);
    const b_stats = try zduTestRequireCachedStats(b_path, allocator);
    const c_stats = try zduTestRequireCachedStats(c_path, allocator);

    try std.testing.expect(b_cached > 0);
    try std.testing.expect(c_cached > 0);

    try std.testing.expect(a_cached > b_cached);
    try std.testing.expect(a_cached > c_cached);
    try std.testing.expectEqual(a_cached, b_cached + c_cached);
    try std.testing.expectEqual(@as(u64, 2), a_stats.file_count);
    try std.testing.expectEqual(@as(u64, 3), a_stats.dir_count);
    try std.testing.expectEqual(@as(u64, 1), b_stats.file_count);
    try std.testing.expectEqual(@as(u64, 1), b_stats.dir_count);
    try std.testing.expectEqual(@as(u64, 1), c_stats.file_count);
    try std.testing.expectEqual(@as(u64, 1), c_stats.dir_count);
}

test "scanRootStats refreshes v3 stats cache with file counts" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root/a");
    try zduTestWriteFile(&tmp, "root/a/one.dat", &[_]u8{1});
    try zduTestWriteFile(&tmp, "root/a/two.dat", &[_]u8{ 2, 3 });

    const root_path = try zduTestTmpPath(allocator, &tmp, "root");
    defer allocator.free(root_path);
    const a_path = try zduTestTmpPath(allocator, &tmp, "root/a");
    defer allocator.free(a_path);

    Model.clearCachedDirSize(root_path, allocator);
    Model.clearCachedDirSize(a_path, allocator);

    const stats = try scanRootStats(std.testing.io, allocator, root_path, .{
        .cache_ttl_seconds = 1800,
        .refresh_cache = true,
    });

    try std.testing.expectEqual(@as(u64, 2), stats.file_count);
    try std.testing.expectEqual(@as(u64, 2), stats.dir_count);

    const root_cached = try zduTestRequireCachedStats(root_path, allocator);
    const a_cached = try zduTestRequireCachedStats(a_path, allocator);

    try std.testing.expectEqual(@as(u64, 2), root_cached.file_count);
    try std.testing.expectEqual(@as(u64, 2), root_cached.dir_count);
    try std.testing.expectEqual(@as(u64, 2), a_cached.file_count);
    try std.testing.expectEqual(@as(u64, 1), a_cached.dir_count);
}

test "dir stats xattr cache stores file counts and rejects expired or malformed records" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root/d");

    const dir_path = try zduTestTmpPath(allocator, &tmp, "root/d");
    defer allocator.free(dir_path);

    Model.clearCachedDirSize(dir_path, allocator);

    const written_stats: Model.DirStats = .{ .size = 1234, .file_count = 9, .dir_count = 2 };
    Model.writeCachedDirStats(dir_path, written_stats, 60, allocator);

    const fresh = Model.readCachedDirStats(dir_path, allocator) orelse return error.SkipZigTest;
    try std.testing.expectEqual(written_stats.size, fresh.size);
    try std.testing.expectEqual(written_stats.file_count, fresh.file_count);
    try std.testing.expectEqual(written_stats.dir_count, fresh.dir_count);

    var dir = std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(std.testing.io);

    const fresh_fd = Model.readCachedDirStatsFd(dir) orelse return error.SkipZigTest;
    try std.testing.expectEqual(written_stats.size, fresh_fd.size);
    try std.testing.expectEqual(written_stats.file_count, fresh_fd.file_count);
    try std.testing.expectEqual(written_stats.dir_count, fresh_fd.dir_count);

    const now = Model.currentTimestampSeconds() orelse return error.SkipZigTest;

    var expired_record: [32]u8 = undefined;
    zduTestEncodeStatsCacheRecord(
        &expired_record,
        .{ .size = 5678, .file_count = 3, .dir_count = 1 },
        if (now == 0) 0 else now - 1,
    );

    try zduTestSetRawDirStatsXattr(dir_path, expired_record[0..], allocator);
    try std.testing.expect(Model.readCachedDirStats(dir_path, allocator) == null);

    var malformed_record: [31]u8 = undefined;
    @memset(malformed_record[0..], 0xaa);

    try zduTestSetRawDirStatsXattr(dir_path, malformed_record[0..], allocator);
    try std.testing.expect(Model.readCachedDirStats(dir_path, allocator) == null);

    var legacy_record: [16]u8 = undefined;
    zduTestEncodeCacheRecord(
        &legacy_record,
        7777,
        now + 60,
    );

    try zduTestSetRawDirSizeXattr(dir_path, legacy_record[0..], allocator);
    const legacy = Model.readCachedDirStats(dir_path, allocator) orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u64, 7777), legacy.size);
    try std.testing.expectEqual(@as(u64, 0), legacy.file_count);
    try std.testing.expectEqual(@as(u64, 0), legacy.dir_count);
}

test "expired dir size cache is recomputed and refreshed" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root/d");

    var bytes = [_]u8{'x'} ** 4096;
    try zduTestWriteFile(&tmp, "root/d/file.dat", bytes[0..]);

    const dir_path = try zduTestTmpPath(allocator, &tmp, "root/d");
    defer allocator.free(dir_path);

    const now = Model.currentTimestampSeconds() orelse return error.SkipZigTest;

    var expired_record: [16]u8 = undefined;
    zduTestEncodeCacheRecord(
        &expired_record,
        999_999_999,
        if (now == 0) 0 else now - 1,
    );

    try zduTestSetRawDirSizeXattr(dir_path, expired_record[0..], allocator);

    const stats = Model.computeDirStats(
        dir_path,
        allocator,
        std.testing.io,
        60,
    );

    try std.testing.expect(stats.size > 0);
    try std.testing.expect(stats.size != 999_999_999);

    const refreshed = try zduTestRequireCachedSize(dir_path, allocator);
    try std.testing.expectEqual(stats.size, refreshed);
}

test "refresh cache ignores a still-fresh stats record" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root/d");
    try zduTestWriteFile(&tmp, "root/d/actual.dat", "actual contents");

    const dir_path = try zduTestTmpPath(allocator, &tmp, "root/d");
    defer allocator.free(dir_path);

    const stale: Model.DirStats = .{ .size = 999_999, .file_count = 99, .dir_count = 99 };
    Model.writeCachedDirStats(dir_path, stale, 1800, allocator);

    const refreshed = Model.computeDirStatsRefreshing(dir_path, allocator, std.testing.io, 1800);
    try std.testing.expect(refreshed.size != stale.size);
    try std.testing.expectEqual(@as(u64, 1), refreshed.file_count);
    try std.testing.expectEqual(@as(u64, 1), refreshed.dir_count);

    const cached = try zduTestRequireCachedStats(dir_path, allocator);
    try std.testing.expectEqual(refreshed.size, cached.size);
    try std.testing.expectEqual(refreshed.file_count, cached.file_count);
    try std.testing.expectEqual(refreshed.dir_count, cached.dir_count);
}

test "parallel root scan matches serial stack scan" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root/a");
    try tmp.dir.createDirPath(std.testing.io, "root/b");
    try zduTestWriteFile(&tmp, "root/a/one.txt", "1");
    try zduTestWriteFile(&tmp, "root/a/two.txt", "22");
    try zduTestWriteFile(&tmp, "root/b/three.txt", "333");
    try zduTestWriteFile(&tmp, "root/four.txt", "4444");

    const root_path = try zduTestTmpPath(allocator, &tmp, "root");
    defer allocator.free(root_path);

    const serial = try scanRootStats(std.testing.io, allocator, root_path, .{
        .cache_ttl_seconds = 1800,
        .refresh_cache = true,
        .parallel = false,
        .num_threads = 1,
    });

    const parallel = try scanRootStats(std.testing.io, allocator, root_path, .{
        .cache_ttl_seconds = 1800,
        .refresh_cache = true,
        .parallel = true,
        .num_threads = 2,
    });

    try std.testing.expectEqual(serial.size, parallel.size);
    try std.testing.expectEqual(serial.file_count, parallel.file_count);
    try std.testing.expectEqual(serial.dir_count, parallel.dir_count);
    try std.testing.expectEqual(@as(u64, 4), parallel.file_count);
    try std.testing.expectEqual(@as(u64, 3), parallel.dir_count);
}

test "TUI refresh-cache parallel jobs scan entries" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root/a");
    try tmp.dir.createDirPath(std.testing.io, "root/b");
    try zduTestWriteFile(&tmp, "root/a/one.txt", "1");
    try zduTestWriteFile(&tmp, "root/a/two.txt", "22");
    try zduTestWriteFile(&tmp, "root/b/three.txt", "333");

    const root_path = try zduTestTmpPath(allocator, &tmp, "root");
    defer allocator.free(root_path);

    const model = try Model.initLoadingWithOptions(std.testing.io, allocator, root_path, .{
        .cache_ttl_seconds = 1800,
        .refresh_cache = true,
        .parallel = true,
        .num_threads = 2,
    });
    defer model.deinit();

    try std.testing.expect(model.loading == null);
    try std.testing.expect(model.refresh_cache);
    try std.testing.expect(model.parallel);
    try std.testing.expectEqual(@as(usize, 2), model.num_threads);
    try std.testing.expectEqual(Model.EntryRole.summary, model.entries[0].role);
    try std.testing.expectEqual(@as(u64, 3), model.entries[0].file_count);
    try std.testing.expectEqual(@as(u64, 3), model.entries[0].dir_count);

    const a_idx = findEntryIndex(model, "a") orelse return error.SkipZigTest;
    const b_idx = findEntryIndex(model, "b") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u64, 2), model.entries[a_idx].file_count);
    try std.testing.expectEqual(@as(u64, 1), model.entries[a_idx].dir_count);
    try std.testing.expectEqual(@as(u64, 1), model.entries[b_idx].file_count);
    try std.testing.expectEqual(@as(u64, 1), model.entries[b_idx].dir_count);
}

test "TUI scan options propagate when navigating into child directories" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root/sub");
    try zduTestWriteFile(&tmp, "root/sub/file.txt", "child");

    const root_path = try zduTestTmpPath(allocator, &tmp, "root");
    defer allocator.free(root_path);

    const model = try Model.initLoadingWithOptions(std.testing.io, allocator, root_path, .{
        .cache_ttl_seconds = 1800,
        .refresh_cache = true,
        .parallel = true,
        .num_threads = 2,
    });
    defer model.deinit();

    model.selected = findEntryIndex(model, "sub") orelse return error.SkipZigTest;
    try model.navigateInto();

    try std.testing.expect(model.parent != null);
    try std.testing.expect(model.loading == null);
    try std.testing.expect(model.refresh_cache);
    try std.testing.expect(model.parallel);
    try std.testing.expectEqual(@as(usize, 2), model.num_threads);
    try std.testing.expectEqual(@as(u64, 1800), model.cache_ttl_seconds);
}

test "TUI refresh-cache serial loading ignores fresh stale child cache" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root/d");
    try zduTestWriteFile(&tmp, "root/d/actual.txt", "actual");

    const root_path = try zduTestTmpPath(allocator, &tmp, "root");
    defer allocator.free(root_path);
    const d_path = try zduTestTmpPath(allocator, &tmp, "root/d");
    defer allocator.free(d_path);

    Model.writeCachedDirStats(d_path, .{ .size = 999_999, .file_count = 99, .dir_count = 99 }, 1800, allocator);

    const model = try Model.initLoadingWithOptions(std.testing.io, allocator, root_path, .{
        .cache_ttl_seconds = 1800,
        .refresh_cache = true,
        .parallel = false,
    });
    defer model.deinit();
    try finishLoading(model, allocator, std.testing.io);

    const d_idx = findEntryIndex(model, "d") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u64, 1), model.entries[d_idx].file_count);
    try std.testing.expectEqual(@as(u64, 1), model.entries[d_idx].dir_count);
    try std.testing.expect(model.entries[d_idx].size != 999_999);
}

test "model does not process /proc" {
    var model = try Model.init(std.testing.io, std.testing.allocator, "/proc");
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 0), model.entries.len);
    try std.testing.expect(model.loading == null);
}
