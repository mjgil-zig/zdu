const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const builtin = @import("builtin");

pub const have_posix_stat = builtin.link_libc and (builtin.os.tag == .linux or builtin.os.tag == .macos);
pub const PosixStat = if (have_posix_stat) std.c.Stat else struct {
    size: i64 = 0,
    mode: u32 = 0,
    blocks: i64 = 0,
};

pub const c_stat = if (have_posix_stat) struct {
    extern "c" fn fstatat(dirfd: std.c.fd_t, path: [*:0]const u8, buf: *std.c.Stat, flag: u32) c_int;
} else struct {};

pub fn posixStatIsRegular(stat: PosixStat) bool {
    if (comptime !have_posix_stat) return false;
    return std.c.S.ISREG(stat.mode);
}

pub fn posixStatIsDirectory(stat: PosixStat) bool {
    if (comptime !have_posix_stat) return false;
    return std.c.S.ISDIR(stat.mode);
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

const ScanTotals = struct {
    total_size: u64 = 0,
    total_files: u64 = 0,
    total_dirs: u64 = 0,
    error_count: u64 = 0,
    entry_count: usize = 0,
};

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

pub fn isGeneratedDirPath(path: []const u8) bool {
    return mem.eql(u8, path, "/proc") or mem.startsWith(u8, path, "/proc/");
}

pub fn pathNeedsGeneratedDirChecks(path: []const u8) bool {
    return mem.eql(u8, path, "/") or isGeneratedDirPath(path);
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

fn walkDirStreaming(
    allocator: mem.Allocator,
    io: std.Io,
    writer: anytype,
    opts: Options,
    current_path: []const u8,
    dir: std.Io.Dir,
    iter: *std.Io.Dir.Iterator,
    depth: usize,
    first_json_entry: *bool,
    totals: *ScanTotals,
) !void {
    if (opts.max_depth) |max_depth| {
        if (depth >= max_depth) return;
    }

    while (true) {
        const maybe_entry = iter.next(io) catch {
            totals.error_count += 1;
            return;
        };
        const entry = maybe_entry orelse break;
        if (!opts.show_hidden and entry.name[0] == '.') continue;
        if (opts.max_entries) |max_entries| {
            if (totals.entry_count >= max_entries) return;
        }

        const full_path = try fs.path.join(allocator, &.{ current_path, entry.name });
        defer allocator.free(full_path);

        const kind = try entryKindAndSize(io, dir, entry.name, entry.kind, &totals.error_count);
        const is_dir = kind.is_dir;
        const is_file = kind.is_file;

        if (is_dir and isGeneratedDirPath(full_path)) continue;

        recordEntry(kind.size, is_dir, is_file, totals);

        if (!opts.summarize) {
            try writeEntry(writer, opts.format, entry.name, full_path, kind.size, is_dir, depth, first_json_entry);
        }
        totals.entry_count += 1;

        if (is_dir and (opts.max_depth == null or depth < opts.max_depth.?)) {
            var subdir = dir.openDir(io, entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch {
                totals.error_count += 1;
                continue;
            };
            defer subdir.close(io);

            var subiter = subdir.iterate();
            try walkDirStreaming(
                allocator,
                io,
                writer,
                opts,
                full_path,
                subdir,
                &subiter,
                depth + 1,
                first_json_entry,
                totals,
            );
        }
    }
}

fn walkDirTotals(
    allocator: mem.Allocator,
    io: std.Io,
    opts: Options,
    current_path: ?[]const u8,
    check_generated_paths: bool,
    dir: std.Io.Dir,
    iter: *std.Io.Dir.Iterator,
    depth: usize,
    totals: *ScanTotals,
) !void {
    if (opts.max_depth) |max_depth| {
        if (depth >= max_depth) return;
    }

    while (true) {
        const maybe_entry = iter.next(io) catch {
            totals.error_count += 1;
            return;
        };
        const entry = maybe_entry orelse break;
        if (!opts.show_hidden and entry.name[0] == '.') continue;
        if (opts.max_entries) |max_entries| {
            if (totals.entry_count >= max_entries) return;
        }

        const kind = try entryKindAndSize(io, dir, entry.name, entry.kind, &totals.error_count);
        const is_dir = kind.is_dir;
        const is_file = kind.is_file;

        if (is_dir and (opts.max_depth == null or depth < opts.max_depth.?)) {
            var full_path: ?[]const u8 = null;
            defer if (full_path) |path| allocator.free(path);

            if (check_generated_paths) {
                const parent_path = current_path orelse unreachable;
                full_path = try fs.path.join(allocator, &.{ parent_path, entry.name });
                if (isGeneratedDirPath(full_path.?)) continue;
            }

            recordEntry(kind.size, is_dir, is_file, totals);
            totals.entry_count += 1;

            var subdir = dir.openDir(io, entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch {
                totals.error_count += 1;
                continue;
            };
            defer subdir.close(io);

            var subiter = subdir.iterate();
            try walkDirTotals(
                allocator,
                io,
                opts,
                full_path,
                check_generated_paths and pathNeedsGeneratedDirChecks(full_path.?),
                subdir,
                &subiter,
                depth + 1,
                totals,
            );
            continue;
        }

        recordEntry(kind.size, is_dir, is_file, totals);
        totals.entry_count += 1;
    }
}

const SizedKind = struct {
    is_dir: bool,
    is_file: bool,
    size: u64,
};

fn entryKindAndSize(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    initial_kind: anytype,
    error_count: *u64,
) !SizedKind {
    if (initial_kind == .directory) {
        return .{ .is_dir = true, .is_file = false, .size = 0 };
    }

    if (comptime have_posix_stat) {
        const stat = cStatAt(dir, name) orelse {
            error_count.* += 1;
            return .{ .is_dir = false, .is_file = initial_kind == .file, .size = 0 };
        };
        const is_dir = posixStatIsDirectory(stat);
        const is_file = posixStatIsRegular(stat);
        const size = posixStatAllocatedSize(stat);
        return .{ .is_dir = is_dir, .is_file = is_file, .size = size };
    }

    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch {
        error_count.* += 1;
        return .{ .is_dir = false, .is_file = initial_kind == .file, .size = 0 };
    };
    return .{
        .is_dir = stat.kind == .directory,
        .is_file = stat.kind == .file,
        .size = stat.size,
    };
}

fn recordEntry(size: u64, is_dir: bool, is_file: bool, totals: *ScanTotals) void {
    if (is_file) {
        totals.total_size += size;
        totals.total_files += 1;
    } else if (is_dir) {
        totals.total_dirs += 1;
    }
}

fn writeEntry(
    writer: anytype,
    format: Format,
    name: []const u8,
    path: []const u8,
    size: u64,
    is_dir: bool,
    depth: usize,
    first_json_entry: *bool,
) !void {
    switch (format) {
        .human => {
            const prefix = if (is_dir) "d" else "f";
            try writer.print("{s} {:>10} {s}\n", .{ prefix, size, path });
        },
        .json => {
            if (!first_json_entry.*) {
                try writer.writeAll(",\n");
            }
            first_json_entry.* = false;
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"name\": ");
            try writeJsonString(writer, name);
            try writer.writeAll(",\n");
            try writer.writeAll("      \"path\": ");
            try writeJsonString(writer, path);
            try writer.writeAll(",\n");
            try writer.print("      \"size\": {},\n", .{size});
            try writer.print("      \"is_dir\": {},\n", .{is_dir});
            try writer.print("      \"depth\": {}\n", .{depth});
            try writer.writeAll("    }");
        },
    }
}

fn writeHumanSummary(writer: anytype, result: ScanResult) !void {
    try writer.writeAll("Summary:\n");
    try writer.print("  Total size: {}\n", .{result.total_size});
    try writer.print("  Files: {}\n", .{result.total_files});
    try writer.print("  Directories: {}\n", .{result.total_dirs});
    try writer.print("  Scan time: {}ms\n", .{result.scan_time_ms});
    try writer.print("  Errors: {}\n", .{result.error_count});
}

fn writeJsonSummaryFields(writer: anytype, result: ScanResult) !void {
    try writer.print("  \"total_size\": {},\n", .{result.total_size});
    try writer.print("  \"total_files\": {},\n", .{result.total_files});
    try writer.print("  \"total_dirs\": {},\n", .{result.total_dirs});
    try writer.print("  \"scan_time_ms\": {},\n", .{result.scan_time_ms});
    try writer.print("  \"error_count\": {}\n", .{result.error_count});
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    const hex = "0123456789abcdef";
    try writer.writeAll("\"");
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                const escaped = [_]u8{ '\\', 'u', '0', '0', hex[@as(usize, byte >> 4)], hex[@as(usize, byte & 0x0f)] };
                try writer.writeAll(&escaped);
            },
            else => try writer.writeAll(&[_]u8{byte}),
        }
    }
    try writer.writeAll("\"");
}

pub fn formatResult(result: ScanResult, opts: Options, writer: anytype) !void {
    switch (opts.format) {
        .human => try writeHumanSummary(writer, result),
        .json => {
            try writer.writeAll("{\n");
            try writer.writeAll("  \"entries\": [\n");
            try writer.writeAll("  ],\n");
            try writeJsonSummaryFields(writer, result);
            try writer.writeAll("}\n");
        },
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
        for (subdirs.items) |sd| allocator.free(sd.full_path);
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
            try subdirs.append(allocator, .{ .name = entry.name, .full_path = full_path });
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

    const ThreadResult = struct {
        totals: ScanTotals = .{},
    };

    const per_thread = subdirs.items.len / actual_workers;
    const remainder = subdirs.items.len % actual_workers;

    var thread_results = try allocator.alloc(ThreadResult, actual_workers);
    defer allocator.free(thread_results);
    for (thread_results) |*tr| tr.* = .{};

    var threads = try allocator.alloc(std.Thread, actual_workers);
    defer allocator.free(threads);

    var start_idx: usize = 0;
    for (0..actual_workers) |i| {
        const count = per_thread + if (i < remainder) @as(usize, 1) else 0;
        const end_idx = start_idx + count;

        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(
                thread_io: std.Io,
                thread_alloc: mem.Allocator,
                thread_opts: Options,
                thread_dir: std.Io.Dir,
                items: []const SubDir,
                check_gen: bool,
                result: *ThreadResult,
            ) void {
                for (items) |sd| {
                    var subdir = thread_dir.openDir(thread_io, sd.name, .{
                        .iterate = true,
                        .follow_symlinks = false,
                    }) catch continue;
                    defer subdir.close(thread_io);
                    var subiter = subdir.iterate();
                    walkDirTotals(thread_alloc, thread_io, thread_opts, sd.full_path, check_gen, subdir, &subiter, 1, &result.totals) catch {
                        result.totals.error_count += 1;
                    };
                }
            }
        }.run, .{ io, allocator, opts, dir, subdirs.items[start_idx..end_idx], check_generated_paths, &thread_results[i] });

        start_idx = end_idx;
    }

    for (threads) |thread| thread.join();

    for (thread_results) |tr| {
        totals.total_size += tr.totals.total_size;
        totals.total_files += tr.totals.total_files;
        totals.total_dirs += tr.totals.total_dirs;
        totals.error_count += tr.totals.error_count;
        totals.entry_count += tr.totals.entry_count;
    }
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
        pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
            const formatted = try std.fmt.allocPrint(std.testing.allocator, fmt, args);
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
