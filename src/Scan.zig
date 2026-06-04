const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
const Cache = @import("Cache.zig");

pub const DirStats = Cache.DirStats;

pub const have_posix_stat = builtin.link_libc and (builtin.os.tag == .linux or builtin.os.tag == .macos);
pub const PosixStat = if (have_posix_stat) std.c.Stat else struct {
    size: i64 = 0,
    mode: u32 = 0,
    blocks: i64 = 0,
};

const c_stat = if (have_posix_stat) struct {
    extern "c" fn fstatat(dirfd: std.c.fd_t, path: [*:0]const u8, buf: *std.c.Stat, flag: u32) c_int;
} else struct {};

pub fn posixStatIsRegular(stat: PosixStat) bool {
    if (comptime !have_posix_stat) return false;
    return std.c.S.ISREG(stat.mode);
}

pub fn posixStatApparentSize(stat: PosixStat) u64 {
    return if (stat.size < 0) 0 else @intCast(stat.size);
}

pub fn posixStatAllocatedSize(stat: PosixStat) u64 {
    const apparent_size = posixStatApparentSize(stat);
    if (!posixStatIsRegular(stat)) return apparent_size;
    if (stat.blocks <= 0) return apparent_size;
    return @as(u64, @intCast(stat.blocks)) * 512;
}

pub fn cStatAt(dir: std.Io.Dir, sub_path: []const u8) ?PosixStat {
    if (comptime !have_posix_stat) return null;

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (sub_path.len + 1 > path_buf.len) return null;
    @memcpy(path_buf[0..sub_path.len], sub_path);
    path_buf[sub_path.len] = 0;
    var stat: PosixStat = undefined;
    if (c_stat.fstatat(dir.handle, @ptrCast(path_buf[0..sub_path.len :0].ptr), &stat, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
        return null;
    }
    return stat;
}

pub fn fileSizeOnDiskAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
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

pub fn fileSizeOnDiskWithLibcAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
    if (comptime !have_posix_stat) return fileSizeOnDiskFallbackAt(dir, sub_path, io);

    const stat = cStatAt(dir, sub_path) orelse return fileSizeOnDiskFallbackAt(dir, sub_path, io);
    return posixStatAllocatedSize(stat);
}

pub fn fileSizeOnDiskFallbackAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
    const stat = dir.statFile(io, sub_path, .{ .follow_symlinks = false }) catch return 0;
    return stat.size;
}

pub fn fileEntryStats(size: u64) DirStats {
    return .{ .size = size, .file_count = 1, .dir_count = 0 };
}

pub fn dirEntryStats(size: u64, file_count: u64, dir_count: u64) DirStats {
    return .{ .size = size, .file_count = file_count, .dir_count = dir_count };
}

pub fn addStats(total: *DirStats, value: DirStats) void {
    total.size += value.size;
    total.file_count += value.file_count;
    total.dir_count += value.dir_count;
}

pub fn subtractStats(total: DirStats, value: DirStats) ?DirStats {
    if (value.size > total.size) return null;
    if (value.file_count > total.file_count) return null;
    if (value.dir_count > total.dir_count) return null;
    return .{
        .size = total.size - value.size,
        .file_count = total.file_count - value.file_count,
        .dir_count = total.dir_count - value.dir_count,
    };
}

pub const CachedOrOpenDir = union(enum) {
    cached_stats: DirStats,
    dir: std.Io.Dir,
};

pub const StackFrame = struct {
    dir: std.Io.Dir,
    iter: std.Io.Dir.Iterator,
    total: DirStats = .{ .dir_count = 1 },
};

pub fn pushDirStatsFrame(stack: *std.ArrayList(StackFrame), allocator: mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    var owned_dir = dir;
    errdefer owned_dir.close(io);
    try stack.append(allocator, .{
        .dir = owned_dir,
        .iter = owned_dir.iterateAssumeFirstIteration(),
    });
}

pub fn openChildDirForScan(parent_dir: std.Io.Dir, io: std.Io, name: []const u8, cache_ttl_seconds: u64, read_cache: bool) ?CachedOrOpenDir {
    var dir = parent_dir.openDir(io, name, .{ .iterate = true }) catch return null;
    if (read_cache and cache_ttl_seconds > 0) {
        if (Cache.readCachedDirStatsFd(dir)) |cached_stats| {
            dir.close(io);
            return .{ .cached_stats = cached_stats };
        }
    }
    return .{ .dir = dir };
}

pub fn computeDirStats(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) DirStats {
    return computeDirStatsWithCache(path, allocator, io, cache_ttl_seconds, true);
}

pub fn computeDirStatsRefreshing(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) DirStats {
    return computeDirStatsWithCache(path, allocator, io, cache_ttl_seconds, false);
}

pub fn computeDirStatsWithCache(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64, read_cache: bool) DirStats {
    if (isGeneratedDirPath(path)) return .{};

    if (read_cache and cache_ttl_seconds > 0) {
        if (Cache.readCachedDirStats(path, allocator)) |cached_stats| {
            return cached_stats;
        }
    }

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return .{ .dir_count = 1 };
    defer dir.close(io);

    return computeDirStatsInDir(dir, io, cache_ttl_seconds, read_cache);
}

pub fn computeDirStatsInDir(dir: std.Io.Dir, io: std.Io, cache_ttl_seconds: u64, read_cache: bool) DirStats {
    if (read_cache and cache_ttl_seconds > 0) {
        if (Cache.readCachedDirStatsFd(dir)) |cached_stats| {
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
    Cache.writeCachedDirStatsFd(dir, total, cache_ttl_seconds);
    return total;
}

pub fn computeDirStatsStack(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) !DirStats {
    return computeDirStatsStackWithCache(path, allocator, io, cache_ttl_seconds, true);
}

pub fn computeDirStatsStackRefreshing(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) !DirStats {
    return computeDirStatsStackWithCache(path, allocator, io, cache_ttl_seconds, false);
}

pub fn computeDirStatsStackWithCache(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64, read_cache: bool) !DirStats {
    var stack: std.ArrayList(StackFrame) = .empty;
    defer {
        for (stack.items) |*frame| {
            frame.dir.close(io);
        }
        stack.deinit(allocator);
    }

    var root_dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return .{ .dir_count = 1 };
    if (read_cache and cache_ttl_seconds > 0) {
        if (Cache.readCachedDirStatsFd(root_dir)) |cached_stats| {
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
        Cache.writeCachedDirStatsFd(completed.dir, completed.total, cache_ttl_seconds);
        completed.dir.close(io);

        if (stack.items.len > 0) {
            addStats(&stack.items[stack.items.len - 1].total, completed.total);
        } else {
            return completed.total;
        }
    }

    return .{};
}

pub fn isGeneratedDirPath(path: []const u8) bool {
    return mem.eql(u8, path, "/proc") or mem.startsWith(u8, path, "/proc/");
}

pub fn pathNeedsGeneratedDirChecks(path: []const u8) bool {
    return mem.eql(u8, path, "/") or isGeneratedDirPath(path);
}

pub const dynamic_split_min_files: u64 = 4096;
pub const dynamic_wait_sleep_ns: u64 = 100_000;
pub const dynamic_worker_stack_size: usize = 3 * 1024 * 1024;

pub const DynamicScanInput = struct {
    path: []const u8,
    estimate_files: u64,
};

pub const DynamicScanFuture = struct {
    mutex: std.Io.Mutex = .init,
    done: bool = false,
    stats: DirStats = .{},
};

pub const DynamicScanTask = struct {
    path: []u8,
    estimate_files: u64,
    future: *DynamicScanFuture,
};

pub const DynamicWork = union(enum) {
    task: DynamicScanTask,
    wait,
    done,
};

pub const DynamicScanContext = struct {
    io: std.Io,
    allocator: mem.Allocator,
    cache_ttl_seconds: u64,
    refresh_cache: bool,
    worker_count: usize,
    split_threshold_files: u64 = dynamic_split_min_files,
    tasks: std.ArrayList(DynamicScanTask) = .empty,
    active_tasks: usize = 0,
    mutex: std.Io.Mutex = .init,
};

pub const DynamicFrame = struct {
    path: []u8,
    dir: std.Io.Dir,
    iter: std.Io.Dir.Iterator,
    total: DirStats = .{ .dir_count = 1 },
    pending: std.ArrayList(*DynamicScanFuture) = .empty,
};

pub fn dynamicTaskLess(a: DynamicScanTask, b: DynamicScanTask) bool {
    if (a.estimate_files != b.estimate_files) return a.estimate_files > b.estimate_files;
    return mem.lessThan(u8, a.path, b.path);
}

pub fn deinitDynamicContext(ctx: *DynamicScanContext) void {
    for (ctx.tasks.items) |task| ctx.allocator.free(task.path);
    ctx.tasks.deinit(ctx.allocator);
}

pub fn enqueueDynamicTask(ctx: *DynamicScanContext, path: []u8, future: *DynamicScanFuture, estimate_files: u64) bool {
    ctx.mutex.lockUncancelable(ctx.io);
    defer ctx.mutex.unlock(ctx.io);

    ctx.tasks.append(ctx.allocator, .{
        .path = path,
        .estimate_files = estimate_files,
        .future = future,
    }) catch return false;
    return true;
}

pub fn takeDynamicWork(ctx: *DynamicScanContext) DynamicWork {
    ctx.mutex.lockUncancelable(ctx.io);
    defer ctx.mutex.unlock(ctx.io);

    if (ctx.tasks.items.len > 0) {
        var best_index: usize = 0;
        var i: usize = 1;
        while (i < ctx.tasks.items.len) : (i += 1) {
            if (dynamicTaskLess(ctx.tasks.items[i], ctx.tasks.items[best_index])) best_index = i;
        }
        const task = ctx.tasks.swapRemove(best_index);
        ctx.active_tasks += 1;
        return .{ .task = task };
    }

    if (ctx.active_tasks == 0) return .done;
    return .wait;
}

pub fn finishDynamicTask(ctx: *DynamicScanContext) void {
    ctx.mutex.lockUncancelable(ctx.io);
    defer ctx.mutex.unlock(ctx.io);

    if (ctx.active_tasks > 0) ctx.active_tasks -= 1;
}

pub fn completeDynamicFuture(io: std.Io, future: *DynamicScanFuture, stats: DirStats) void {
    future.mutex.lockUncancelable(io);
    defer future.mutex.unlock(io);

    future.stats = stats;
    future.done = true;
}

pub fn readDynamicFuture(io: std.Io, future: *DynamicScanFuture) ?DirStats {
    future.mutex.lockUncancelable(io);
    defer future.mutex.unlock(io);

    if (!future.done) return null;
    return future.stats;
}

pub fn dynamicWorkPressure(ctx: *DynamicScanContext) usize {
    ctx.mutex.lockUncancelable(ctx.io);
    defer ctx.mutex.unlock(ctx.io);

    return ctx.tasks.items.len + ctx.active_tasks;
}

pub fn shouldSplitDynamicChild(ctx: *DynamicScanContext, estimate_files: u64) bool {
    if (ctx.worker_count <= 1) return false;
    if (estimate_files >= ctx.split_threshold_files and estimate_files > 0) return true;
    return dynamicWorkPressure(ctx) < ctx.worker_count;
}

pub fn cleanupDynamicFrame(frame: *DynamicFrame, allocator: mem.Allocator, io: std.Io) void {
    for (frame.pending.items) |future| allocator.destroy(future);
    frame.pending.deinit(allocator);
    frame.dir.close(io);
    allocator.free(frame.path);
}

pub fn pushDynamicFrame(stack: *std.ArrayList(DynamicFrame), allocator: mem.Allocator, io: std.Io, path: []u8, dir: std.Io.Dir) bool {
    var owned_dir = dir;
    stack.append(allocator, .{
        .path = path,
        .dir = owned_dir,
        .iter = owned_dir.iterateAssumeFirstIteration(),
    }) catch {
        owned_dir.close(io);
        allocator.free(path);
        return false;
    };
    return true;
}

pub fn waitDynamicFuture(ctx: *DynamicScanContext, future: *DynamicScanFuture) DirStats {
    while (true) {
        if (readDynamicFuture(ctx.io, future)) |stats| return stats;

        switch (takeDynamicWork(ctx)) {
            .task => |task| runDynamicTask(ctx, task),
            .wait => _ = ctx.io.sleep(.fromNanoseconds(dynamic_wait_sleep_ns), .awake) catch {},
            .done => return .{},
        }
    }
}

pub fn completeDynamicFrame(ctx: *DynamicScanContext, frame: *DynamicFrame) DirStats {
    for (frame.pending.items) |future| {
        const stats = waitDynamicFuture(ctx, future);
        addStats(&frame.total, stats);
        ctx.allocator.destroy(future);
    }
    Cache.writeCachedDirStatsFd(frame.dir, frame.total, ctx.cache_ttl_seconds);
    return frame.total;
}

pub fn splitDynamicChild(ctx: *DynamicScanContext, frame: *DynamicFrame, child_path: []u8, estimate_files: u64) bool {
    if (!shouldSplitDynamicChild(ctx, estimate_files)) return false;

    const future = ctx.allocator.create(DynamicScanFuture) catch return false;
    future.* = .{};

    frame.pending.append(ctx.allocator, future) catch {
        ctx.allocator.destroy(future);
        return false;
    };

    if (enqueueDynamicTask(ctx, child_path, future, estimate_files)) return true;

    _ = frame.pending.pop();
    ctx.allocator.destroy(future);
    return false;
}

pub fn computeDirStatsDynamicOwned(ctx: *DynamicScanContext, root_path: []u8) DirStats {
    if (isGeneratedDirPath(root_path)) {
        ctx.allocator.free(root_path);
        return .{};
    }

    var root_dir = std.Io.Dir.cwd().openDir(ctx.io, root_path, .{ .iterate = true }) catch {
        ctx.allocator.free(root_path);
        return .{ .dir_count = 1 };
    };

    if (!ctx.refresh_cache and ctx.cache_ttl_seconds > 0) {
        if (Cache.readCachedDirStatsFd(root_dir)) |cached_stats| {
            root_dir.close(ctx.io);
            ctx.allocator.free(root_path);
            return cached_stats;
        }
    }

    var stack: std.ArrayList(DynamicFrame) = .empty;
    defer {
        for (stack.items) |*frame| cleanupDynamicFrame(frame, ctx.allocator, ctx.io);
        stack.deinit(ctx.allocator);
    }

    if (!pushDynamicFrame(&stack, ctx.allocator, ctx.io, root_path, root_dir)) return .{};

    while (stack.items.len > 0) {
        var frame = &stack.items[stack.items.len - 1];
        if (frame.iter.next(ctx.io) catch null) |entry| {
            if (entry.kind == .file) {
                addStats(&frame.total, fileEntryStats(fileSizeOnDiskAt(frame.dir, entry.name, ctx.io)));
                continue;
            }
            if (entry.kind != .directory) continue;

            const child_path = std.fs.path.join(ctx.allocator, &.{ frame.path, entry.name }) catch continue;
            if (isGeneratedDirPath(child_path)) {
                ctx.allocator.free(child_path);
                continue;
            }

            const cached = if (ctx.cache_ttl_seconds > 0) Cache.readCachedDirStats(child_path, ctx.allocator) else null;
            if (!ctx.refresh_cache) {
                if (cached) |cached_stats| {
                    addStats(&frame.total, cached_stats);
                    ctx.allocator.free(child_path);
                    continue;
                }
            }

            const estimate_files = if (cached) |cached_stats| cached_stats.file_count else 0;
            if (splitDynamicChild(ctx, frame, child_path, estimate_files)) continue;

            const child_dir = frame.dir.openDir(ctx.io, entry.name, .{ .iterate = true }) catch {
                ctx.allocator.free(child_path);
                continue;
            };
            if (!pushDynamicFrame(&stack, ctx.allocator, ctx.io, child_path, child_dir)) continue;
            continue;
        }

        var completed = stack.pop().?;
        const completed_stats = completeDynamicFrame(ctx, &completed);
        completed.pending.deinit(ctx.allocator);
        completed.dir.close(ctx.io);
        ctx.allocator.free(completed.path);

        if (stack.items.len > 0) {
            addStats(&stack.items[stack.items.len - 1].total, completed_stats);
        } else {
            return completed_stats;
        }
    }

    return .{};
}

pub fn runDynamicTask(ctx: *DynamicScanContext, task: DynamicScanTask) void {
    defer finishDynamicTask(ctx);
    const stats = computeDirStatsDynamicOwned(ctx, task.path);
    completeDynamicFuture(ctx.io, task.future, stats);
}

pub fn dynamicScanWorker(ctx: *DynamicScanContext) void {
    while (true) {
        switch (takeDynamicWork(ctx)) {
            .task => |task| runDynamicTask(ctx, task),
            .wait => _ = ctx.io.sleep(.fromNanoseconds(dynamic_wait_sleep_ns), .awake) catch {},
            .done => return,
        }
    }
}

pub fn runDynamicScanWorkers(ctx: *DynamicScanContext, worker_count: usize) !void {
    const threads = try ctx.allocator.alloc(std.Thread, worker_count);
    defer ctx.allocator.free(threads);

    var spawned: usize = 0;
    errdefer {
        for (threads[0..spawned]) |thread| thread.join();
    }
    while (spawned < worker_count) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{
            .stack_size = dynamic_worker_stack_size,
        }, dynamicScanWorker, .{ctx});
    }
    for (threads[0..spawned]) |thread| thread.join();
}

pub const Options = struct {
    cache_ttl_seconds: u64 = 0,
    refresh_cache: bool = false,
    parallel: bool = false,
    num_threads: usize = 0,
};

pub fn computeDynamicScanInputs(io: std.Io, allocator: mem.Allocator, inputs: []const DynamicScanInput, options: Options, worker_count: usize) ![]DirStats {
    const results = try allocator.alloc(DirStats, inputs.len);
    errdefer allocator.free(results);
    for (results) |*result| result.* = .{};

    const futures = try allocator.alloc(DynamicScanFuture, inputs.len);
    defer allocator.free(futures);
    for (futures) |*future| future.* = .{};

    var ctx = DynamicScanContext{
        .io = io,
        .allocator = allocator,
        .cache_ttl_seconds = options.cache_ttl_seconds,
        .refresh_cache = options.refresh_cache,
        .worker_count = worker_count,
    };
    defer deinitDynamicContext(&ctx);

    for (inputs, 0..) |input, i| {
        const owned_path = try allocator.dupe(u8, input.path);
        if (!enqueueDynamicTask(&ctx, owned_path, &futures[i], input.estimate_files)) {
            allocator.free(owned_path);
            return error.OutOfMemory;
        }
    }

    try runDynamicScanWorkers(&ctx, worker_count);

    for (futures, 0..) |*future, i| {
        results[i] = readDynamicFuture(io, future) orelse .{};
    }
    return results;
}

pub const RootScanMode = enum {
    worker,
    stack,
};

pub const RootScanOptions = struct {
    cache_ttl_seconds: u64 = 0,
    refresh_cache: bool = false,
    parallel: bool = false,
    num_threads: usize = 0,
};

pub const ParallelScanTask = struct {
    path: []u8,
    estimate_files: u64,
};

pub const ParallelScanContext = struct {
    io: std.Io,
    allocator: mem.Allocator,
    cache_ttl_seconds: u64,
    refresh_cache: bool,
    tasks: []const ParallelScanTask,
    results: []DirStats,
    next_index: usize = 0,
    mutex: std.Io.Mutex = .init,
};

pub fn sortParallelTasks(tasks: []ParallelScanTask) void {
    mem.sortUnstable(ParallelScanTask, tasks, {}, struct {
        fn less(_: void, a: ParallelScanTask, b: ParallelScanTask) bool {
            if (a.estimate_files != b.estimate_files) return a.estimate_files > b.estimate_files;
            return mem.lessThan(u8, a.path, b.path);
        }
    }.less);
}

pub fn computeRootTaskStats(io: std.Io, allocator: mem.Allocator, path: []const u8, cache_ttl_seconds: u64, refresh_cache: bool, mode: RootScanMode) !DirStats {
    return switch (mode) {
        .worker => if (refresh_cache)
            computeDirStatsRefreshing(path, allocator, io, cache_ttl_seconds)
        else
            computeDirStats(path, allocator, io, cache_ttl_seconds),
        .stack => if (refresh_cache)
            try computeDirStatsStackRefreshing(path, allocator, io, cache_ttl_seconds)
        else
            try computeDirStatsStack(path, allocator, io, cache_ttl_seconds),
    };
}

pub fn nextParallelTask(ctx: *ParallelScanContext) ?usize {
    ctx.mutex.lockUncancelable(ctx.io);
    defer ctx.mutex.unlock(ctx.io);

    if (ctx.next_index >= ctx.tasks.len) return null;
    const idx = ctx.next_index;
    ctx.next_index += 1;
    return idx;
}

pub fn parallelScanWorker(ctx: *ParallelScanContext) void {
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

pub fn resolvedWorkerCount(parallel: bool, requested: usize, task_count: usize) usize {
    if (!parallel or task_count == 0) return 1;
    const detected = if (requested == 0) std.Thread.getCpuCount() catch 1 else requested;
    return @max(@as(usize, 1), detected);
}

pub fn scanRootStatsMode(io: std.Io, allocator: mem.Allocator, cwd: []const u8, opts: RootScanOptions, mode: RootScanMode) !DirStats {
    if (isGeneratedDirPath(cwd)) return .{};

    var dir = std.Io.Dir.cwd().openDir(io, cwd, .{ .iterate = true }) catch return .{ .dir_count = 1 };
    defer dir.close(io);

    var tasks: std.ArrayList(ParallelScanTask) = .empty;
    defer {
        for (tasks.items) |task| allocator.free(task.path);
        tasks.deinit(allocator);
    }

    var root_stats: DirStats = .{ .dir_count = 1 };
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            const full_path = try std.fs.path.join(allocator, &.{ cwd, entry.name });
            errdefer allocator.free(full_path);
            if (isGeneratedDirPath(full_path)) {
                allocator.free(full_path);
                continue;
            }
            const estimate_files = if (Cache.readCachedDirStats(full_path, allocator)) |cached_stats| cached_stats.file_count else 0;
            try tasks.append(allocator, .{
                .path = full_path,
                .estimate_files = estimate_files,
            });
        } else if (entry.kind == .file) {
            addStats(&root_stats, fileEntryStats(fileSizeOnDiskAt(dir, entry.name, io)));
        }
    }

    sortParallelTasks(tasks.items);

    const worker_count = resolvedWorkerCount(opts.parallel and mode == .stack, opts.num_threads, tasks.items.len);
    if (worker_count > 1) {
        const inputs = try allocator.alloc(DynamicScanInput, tasks.items.len);
        defer allocator.free(inputs);
        for (tasks.items, 0..) |task, i| {
            inputs[i] = .{
                .path = task.path,
                .estimate_files = task.estimate_files,
            };
        }

        const results = try computeDynamicScanInputs(io, allocator, inputs, .{
            .cache_ttl_seconds = opts.cache_ttl_seconds,
            .refresh_cache = opts.refresh_cache,
            .parallel = opts.parallel,
            .num_threads = opts.num_threads,
        }, worker_count);
        defer allocator.free(results);

        for (results) |stats| addStats(&root_stats, stats);
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
            addStats(&root_stats, stats);
        }
    }

    Cache.writeCachedDirStats(cwd, root_stats, opts.cache_ttl_seconds, allocator);
    return root_stats;
}

pub fn scanRootStats(io: std.Io, allocator: mem.Allocator, cwd: []const u8, opts: RootScanOptions) !DirStats {
    return scanRootStatsMode(io, allocator, cwd, opts, .stack);
}

pub fn scanRootTotal(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64, mode: RootScanMode) !u64 {
    const stats = try scanRootStatsMode(io, allocator, cwd, .{ .cache_ttl_seconds = cache_ttl_seconds }, mode);
    return stats.size;
}

pub fn readCachedDirSize(path: []const u8, allocator: mem.Allocator) ?u64 {
    if (Cache.readCachedDirStats(path, allocator)) |stats| return stats.size;
    return null;
}

pub fn readCachedDirSizeFd(dir: std.Io.Dir) ?u64 {
    if (Cache.readCachedDirStatsFd(dir)) |stats| return stats.size;
    return null;
}

pub fn fileSizeOnDisk(path: []const u8, allocator: mem.Allocator, io: std.Io) u64 {
    _ = allocator;
    return fileSizeOnDiskAt(std.Io.Dir.cwd(), path, io);
}
