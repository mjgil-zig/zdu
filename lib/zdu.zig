const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const builtin = @import("builtin");

pub const Format = enum {
    human,
    json,
};

pub const Options = struct {
    path: []const u8,
    format: Format,
    summarize: bool,
    show_hidden: bool,
    max_depth: ?usize,
    max_entries: ?usize,
    parallel: bool,
    num_threads: usize,
};

pub const ScanResult = struct {
    total_size: u64,
    total_files: u64,
    total_dirs: u64,
    scan_time_ms: u64,
    error_count: u64,
};

pub const ScanTotals = struct {
    total_size: u64 = 0,
    total_files: u64 = 0,
    total_dirs: u64 = 0,
    error_count: u64 = 0,
    entry_count: usize = 0,
};

pub fn isGeneratedDirPath(path: []const u8) bool {
    return mem.eql(u8, path, "/proc") or mem.startsWith(u8, path, "/proc/");
}

pub fn pathNeedsGeneratedDirChecks(path: []const u8) bool {
    return mem.eql(u8, path, "/") or isGeneratedDirPath(path);
}

// Re-export stat helpers
pub const have_posix_stat = @import("stat.zig").have_posix_stat;
pub const PosixStat = @import("stat.zig").PosixStat;
pub const c_stat = @import("stat.zig").c_stat;
pub const posixStatIsRegular = @import("stat.zig").posixStatIsRegular;
pub const posixStatIsDirectory = @import("stat.zig").posixStatIsDirectory;
pub const posixStatApparentSize = @import("stat.zig").posixStatApparentSize;
pub const posixStatAllocatedSize = @import("stat.zig").posixStatAllocatedSize;
pub const cStatAt = @import("stat.zig").cStatAt;
pub const fileSizeOnDiskAt = @import("stat.zig").fileSizeOnDiskAt;
pub const fileSizeOnDiskWithLibcAt = @import("stat.zig").fileSizeOnDiskWithLibcAt;
pub const fileSizeOnDiskFallbackAt = @import("stat.zig").fileSizeOnDiskFallbackAt;

// Re-export walk helpers
const walk = @import("walk.zig");
pub const SizedKind = walk.SizedKind;
pub const entryKindAndSize = walk.entryKindAndSize;
pub const recordEntry = walk.recordEntry;
pub const walkDirStreaming = walk.walkDirStreaming;
pub const walkDirTotals = walk.walkDirTotals;

// Re-export format helpers
const fmt = @import("format.zig");
pub const writeEntry = fmt.writeEntry;
pub const writeHumanSummary = fmt.writeHumanSummary;
pub const writeJsonSummaryFields = fmt.writeJsonSummaryFields;
pub const writeJsonString = fmt.writeJsonString;
pub const formatResult = fmt.formatResult;

pub fn scanAndFormat(io: std.Io, allocator: mem.Allocator, opts: Options, writer: anytype) !void {
    if (isGeneratedDirPath(opts.path)) {
        switch (opts.format) {
            .human => try writer.writeAll("Entries:\n\nSummary:\n  Total size: 0\n  Files: 0\n  Directories: 0\n  Scan time: 0ms\n  Errors: 0\n"),
            .json => try writer.writeAll("{\n  \"entries\": [\n  ],\n  \"total_size\": 0,\n  \"total_files\": 0,\n  \"total_dirs\": 0,\n  \"scan_time_ms\": 0,\n  \"error_count\": 0\n}\n"),
        }
        return;
    }

    // Use parallel scan for summarize mode; streaming output requires serial walk
    if (opts.parallel and opts.summarize) {
        const result = try scan(io, allocator, opts);
        switch (opts.format) {
            .human => try writeHumanSummary(writer, result),
            .json => {
                try writer.writeAll("{\n  \"entries\": [\n  ],\n");
                try writeJsonSummaryFields(writer, result);
                try writer.writeAll("}\n");
            },
        }
        return;
    }

    var totals: ScanTotals = .{};
    var first_json_entry = true;

    switch (opts.format) {
        .human => {
            if (!opts.summarize) try writer.writeAll("Entries:\n");
        },
        .json => try writer.writeAll("{\n  \"entries\": [\n"),
    }

    var dir = try std.Io.Dir.cwd().openDir(io, opts.path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    try walkDirStreaming(
        allocator,
        io,
        writer,
        opts,
        opts.path,
        dir,
        &iter,
        0,
        &first_json_entry,
        &totals,
    );

    switch (opts.format) {
        .human => {
            if (!opts.summarize) try writer.writeAll("\n");
            try writeHumanSummary(writer, .{
                .total_size = totals.total_size,
                .total_files = totals.total_files,
                .total_dirs = totals.total_dirs,
                .scan_time_ms = 0,
                .error_count = totals.error_count,
            });
        },
        .json => {
            try writer.writeAll("  ],\n");
            try writeJsonSummaryFields(writer, .{
                .total_size = totals.total_size,
                .total_files = totals.total_files,
                .total_dirs = totals.total_dirs,
                .scan_time_ms = 0,
                .error_count = totals.error_count,
            });
            try writer.writeAll("}\n");
        },
    }
}

pub fn scan(io: std.Io, allocator: mem.Allocator, opts: Options) !ScanResult {
    if (isGeneratedDirPath(opts.path)) {
        return .{
            .total_size = 0,
            .total_files = 0,
            .total_dirs = 0,
            .scan_time_ms = 0,
            .error_count = 0,
        };
    }

    const start = std.Io.Timestamp.now(io, .awake);
    var totals: ScanTotals = .{};

    var dir = try std.Io.Dir.cwd().openDir(io, opts.path, .{ .iterate = true });
    defer dir.close(io);

    if (opts.parallel and opts.num_threads != 1) {
        try scanParallel(allocator, io, opts, opts.path, dir, &totals);
    } else {
        var iter = dir.iterate();
        const check_generated_paths = pathNeedsGeneratedDirChecks(opts.path);
        try walkDirTotals(allocator, io, opts, if (check_generated_paths) opts.path else null, check_generated_paths, dir, &iter, 0, &totals);
    }

    const end = std.Io.Timestamp.now(io, .awake);
    return .{
        .total_size = totals.total_size,
        .total_files = totals.total_files,
        .total_dirs = totals.total_dirs,
        .scan_time_ms = @as(u64, @intCast(@divFloor(start.durationTo(end).nanoseconds, std.time.ns_per_ms))),
        .error_count = totals.error_count,
    };
}

fn scanParallel(
    allocator: mem.Allocator,
    io: std.Io,
    opts: Options,
    root_path: []const u8,
    dir: std.Io.Dir,
    totals: *ScanTotals,
) !void {
    const SubDir = struct {
        name: []const u8,
        full_path: []const u8,
    };

    var subdirs: std.ArrayList(SubDir) = .empty;
    defer {
        for (subdirs.items) |sd| {
            allocator.free(sd.name);
            allocator.free(sd.full_path);
        }
        subdirs.deinit(allocator);
    }

    var iter = dir.iterate();
    const check_generated_paths = pathNeedsGeneratedDirChecks(root_path);
    while (iter.next(io) catch null) |entry| {
        const kind = entryKindAndSize(io, dir, entry.name, entry.kind, &totals.error_count) catch continue;
        if (kind.is_file) {
            recordEntry(kind.size, false, true, totals);
            totals.entry_count += 1;
        } else if (kind.is_dir) {
            recordEntry(0, true, false, totals);
            totals.entry_count += 1;
            const full_path = if (check_generated_paths)
                try fs.path.join(allocator, &.{ root_path, entry.name })
            else
                try allocator.dupe(u8, entry.name);
            if (isGeneratedDirPath(full_path)) {
                allocator.free(full_path);
                continue;
            }
            try subdirs.append(allocator, .{ .name = try allocator.dupe(u8, entry.name), .full_path = full_path });
        }
    }

    if (subdirs.items.len == 0) return;

    const worker_count = if (opts.num_threads == 0)
        std.Thread.getCpuCount() catch 1
    else
        opts.num_threads;
    const actual_workers = @min(worker_count, subdirs.items.len);
    if (actual_workers <= 1) {
        for (subdirs.items) |sd| {
            var subdir = dir.openDir(io, sd.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch continue;
            defer subdir.close(io);
            var subiter = subdir.iterate();
            try walkDirTotals(allocator, io, opts, sd.full_path, check_generated_paths, subdir, &subiter, 1, totals);
        }
        return;
    }

    const ThreadCtx = struct {
        io: std.Io,
        allocator: mem.Allocator,
        opts: Options,
        dir: std.Io.Dir,
        subdirs: []const SubDir,
        start: usize,
        end: usize,
        check_gen: bool,
        result: ScanTotals,
    };

    const per_thread = subdirs.items.len / actual_workers;
    const remainder = subdirs.items.len % actual_workers;

    var contexts = try allocator.alloc(ThreadCtx, actual_workers);
    defer allocator.free(contexts);

    var threads = try allocator.alloc(std.Thread, actual_workers);
    defer allocator.free(threads);

    var start_idx: usize = 0;
    for (0..actual_workers) |i| {
        const count = per_thread + if (i < remainder) @as(usize, 1) else 0;
        const end_idx = start_idx + count;

        contexts[i] = .{
            .io = io,
            .allocator = allocator,
            .opts = opts,
            .dir = dir,
            .subdirs = subdirs.items,
            .start = start_idx,
            .end = end_idx,
            .check_gen = check_generated_paths,
            .result = .{},
        };

        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(ctx: *ThreadCtx) void {
                for (ctx.subdirs[ctx.start..ctx.end]) |sd| {
                    var subdir = ctx.dir.openDir(ctx.io, sd.name, .{
                        .iterate = true,
                        .follow_symlinks = false,
                    }) catch continue;
                    defer subdir.close(ctx.io);
                    var subiter = subdir.iterate();
                    walkDirTotals(ctx.allocator, ctx.io, ctx.opts, sd.full_path, ctx.check_gen, subdir, &subiter, 1, &ctx.result) catch {
                        ctx.result.error_count += 1;
                    };
                }
            }
        }.run, .{&contexts[i]});

        start_idx = end_idx;
    }

    for (threads) |thread| thread.join();

    for (contexts) |ctx| {
        totals.total_size += ctx.result.total_size;
        totals.total_files += ctx.result.total_files;
        totals.total_dirs += ctx.result.total_dirs;
        totals.error_count += ctx.result.error_count;
        totals.entry_count += ctx.result.entry_count;
    }
}

test "Options defaults" {
    const opts = Options{
        .path = ".",
        .format = .human,
        .summarize = false,
        .show_hidden = false,
        .max_depth = null,
        .max_entries = null,
        .parallel = false,
        .num_threads = 1,
    };
    try std.testing.expect(!opts.parallel);
    try std.testing.expectEqual(@as(usize, 1), opts.num_threads);
}

test "Format enum values" {
    try std.testing.expectEqual(Format.human, .human);
    try std.testing.expectEqual(Format.json, .json);
}

test "ScanResult init" {
    const result = ScanResult{
        .total_size = 1024,
        .total_files = 5,
        .total_dirs = 2,
        .scan_time_ms = 100,
        .error_count = 0,
    };
    try std.testing.expectEqual(@as(u64, 1024), result.total_size);
    try std.testing.expectEqual(@as(u64, 5), result.total_files);
    try std.testing.expectEqual(@as(u64, 2), result.total_dirs);
}

test "scan skips /proc entirely" {
    const result = try scan(std.testing.io, std.testing.allocator, .{
        .path = "/proc",
        .format = .human,
        .summarize = false,
        .show_hidden = true,
        .max_depth = null,
        .max_entries = null,
        .parallel = false,
        .num_threads = 1,
    });

    try std.testing.expectEqual(@as(u64, 0), result.total_size);
    try std.testing.expectEqual(@as(u64, 0), result.total_files);
    try std.testing.expectEqual(@as(u64, 0), result.total_dirs);
    try std.testing.expectEqual(@as(u64, 0), result.error_count);
}

test "scan parallel produces same results as serial" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a small directory tree
    {
        try tmp.dir.createDirPath(std.testing.io, "a/b");
        var f1 = try tmp.dir.createFile(std.testing.io, "a/file1.txt", .{});
        defer f1.close(std.testing.io);
        try f1.writeStreamingAll(std.testing.io, "hello");
        var f2 = try tmp.dir.createFile(std.testing.io, "a/b/file2.txt", .{});
        defer f2.close(std.testing.io);
        try f2.writeStreamingAll(std.testing.io, "world");
        try tmp.dir.createDirPath(std.testing.io, "c");
        var f3 = try tmp.dir.createFile(std.testing.io, "c/file3.txt", .{});
        defer f3.close(std.testing.io);
        try f3.writeStreamingAll(std.testing.io, "!!!");
    }

    const path = try fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
    });
    defer std.testing.allocator.free(path);

    const serial = try scan(std.testing.io, std.testing.allocator, .{
        .path = path,
        .format = .human,
        .summarize = true,
        .show_hidden = true,
        .max_depth = null,
        .max_entries = null,
        .parallel = false,
        .num_threads = 1,
    });

    const parallel = try scan(std.testing.io, std.testing.allocator, .{
        .path = path,
        .format = .human,
        .summarize = true,
        .show_hidden = true,
        .max_depth = null,
        .max_entries = null,
        .parallel = true,
        .num_threads = 4,
    });

    try std.testing.expectEqual(serial.total_size, parallel.total_size);
    try std.testing.expectEqual(serial.total_files, parallel.total_files);
    try std.testing.expectEqual(serial.total_dirs, parallel.total_dirs);
    try std.testing.expectEqual(serial.error_count, parallel.error_count);
}

test "scan respects show_hidden" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "visible");
    var visible = try tmp.dir.createFile(std.testing.io, "visible.txt", .{});
    defer visible.close(std.testing.io);
    try visible.writeStreamingAll(std.testing.io, "visible");

    var hidden = try tmp.dir.createFile(std.testing.io, ".hidden.txt", .{});
    defer hidden.close(std.testing.io);
    try hidden.writeStreamingAll(std.testing.io, "hidden");

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const without_hidden = try scan(std.testing.io, std.testing.allocator, .{
        .path = path,
        .format = .human,
        .summarize = true,
        .show_hidden = false,
        .max_depth = null,
        .max_entries = null,
        .parallel = false,
        .num_threads = 1,
    });

    const with_hidden = try scan(std.testing.io, std.testing.allocator, .{
        .path = path,
        .format = .human,
        .summarize = true,
        .show_hidden = true,
        .max_depth = null,
        .max_entries = null,
        .parallel = false,
        .num_threads = 1,
    });

    try std.testing.expect(with_hidden.total_files > without_hidden.total_files);
    try std.testing.expect(with_hidden.total_size > without_hidden.total_size);
}

test "scan respects max_depth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "a/b");
    var f1 = try tmp.dir.createFile(std.testing.io, "a/file1.txt", .{});
    defer f1.close(std.testing.io);
    try f1.writeStreamingAll(std.testing.io, "hello");
    var f2 = try tmp.dir.createFile(std.testing.io, "a/b/file2.txt", .{});
    defer f2.close(std.testing.io);
    try f2.writeStreamingAll(std.testing.io, "world");

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const unlimited = try scan(std.testing.io, std.testing.allocator, .{
        .path = path,
        .format = .human,
        .summarize = true,
        .show_hidden = true,
        .max_depth = null,
        .max_entries = null,
        .parallel = false,
        .num_threads = 1,
    });

    const depth1 = try scan(std.testing.io, std.testing.allocator, .{
        .path = path,
        .format = .human,
        .summarize = true,
        .show_hidden = true,
        .max_depth = 1,
        .max_entries = null,
        .parallel = false,
        .num_threads = 1,
    });

    try std.testing.expect(unlimited.total_files > depth1.total_files);
    try std.testing.expect(unlimited.total_dirs > depth1.total_dirs);
}

test "scanAndFormat produces valid JSON" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "subdir");
    var f = try tmp.dir.createFile(std.testing.io, "subdir/file.txt", .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, "data");

    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
    });
    defer std.testing.allocator.free(path);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    const writer_wrapper = struct {
        list: *std.ArrayList(u8),
        pub fn writeAll(self: @This(), data: []const u8) !void {
            try self.list.appendSlice(std.testing.allocator, data);
        }
        pub fn print(self: @This(), comptime fmt_str: []const u8, args: anytype) !void {
            const formatted = try std.fmt.allocPrint(std.testing.allocator, fmt_str, args);
            defer std.testing.allocator.free(formatted);
            try self.list.appendSlice(std.testing.allocator, formatted);
        }
    }{ .list = &output };

    try scanAndFormat(std.testing.io, std.testing.allocator, .{
        .path = path,
        .format = .json,
        .summarize = true,
        .show_hidden = true,
        .max_depth = null,
        .max_entries = null,
        .parallel = false,
        .num_threads = 1,
    }, writer_wrapper);

    const json = output.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_size\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_dirs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scan_time_ms\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"error_count\"") != null);
}
