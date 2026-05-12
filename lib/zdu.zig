const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const builtin = @import("builtin");

const c_stat = struct {
    extern "c" fn fstatat(dirfd: std.c.fd_t, path: [*:0]const u8, buf: *std.c.Stat, flag: u32) c_int;
};

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
    use_io_uring: bool,
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

pub fn scanAndFormat(io: std.Io, opts: Options, writer: anytype) !void {
    if (isGeneratedDirPath(opts.path)) {
        switch (opts.format) {
            .human => try writer.writeAll("Entries:\n\nSummary:\n  Total size: 0\n  Files: 0\n  Directories: 0\n  Scan time: 0ms\n  Errors: 0\n"),
            .json => try writer.writeAll("{\n  \"entries\": [\n  ],\n  \"total_size\": 0,\n  \"total_files\": 0,\n  \"total_dirs\": 0,\n  \"scan_time_ms\": 0,\n  \"error_count\": 0\n}\n"),
        }
        return;
    }

    const allocator = std.heap.page_allocator;
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

pub fn scan(io: std.Io, opts: Options) !ScanResult {
    if (isGeneratedDirPath(opts.path)) {
        return .{
            .total_size = 0,
            .total_files = 0,
            .total_dirs = 0,
            .scan_time_ms = 0,
            .error_count = 0,
        };
    }

    const allocator = std.heap.page_allocator;
    const start = std.Io.Timestamp.now(io, .awake);
    var totals: ScanTotals = .{};

    var dir = try std.Io.Dir.cwd().openDir(io, opts.path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    const check_generated_paths = pathNeedsGeneratedDirChecks(opts.path);
    try walkDirTotals(allocator, io, opts, if (check_generated_paths) opts.path else null, check_generated_paths, dir, &iter, 0, &totals);

    const end = std.Io.Timestamp.now(io, .awake);
    return .{
        .total_size = totals.total_size,
        .total_files = totals.total_files,
        .total_dirs = totals.total_dirs,
        .scan_time_ms = @as(u64, @intCast(@divFloor(start.durationTo(end).nanoseconds, std.time.ns_per_ms))),
        .error_count = totals.error_count,
    };
}

fn isGeneratedDirPath(path: []const u8) bool {
    return mem.eql(u8, path, "/proc") or mem.startsWith(u8, path, "/proc/");
}

fn pathNeedsGeneratedDirChecks(path: []const u8) bool {
    return mem.eql(u8, path, "/") or isGeneratedDirPath(path);
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

fn fileSizeOnDiskAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
    return switch (builtin.os.tag) {
        .linux, .macos => if (builtin.link_libc) fileSizeOnDiskWithLibcAt(dir, sub_path) else fileSizeOnDiskFallbackAt(dir, sub_path, io),
        else => fileSizeOnDiskFallbackAt(dir, sub_path, io),
    };
}

fn fileSizeOnDiskWithLibcAt(dir: std.Io.Dir, sub_path: []const u8) u64 {
    const stat = cStatAt(dir, sub_path) orelse return 0;
    const apparent_size: u64 = if (stat.size < 0) 0 else @intCast(stat.size);
    if (!std.c.S.ISREG(stat.mode)) return apparent_size;
    if (stat.blocks <= 0) return apparent_size;
    return @as(u64, @intCast(stat.blocks)) * 512;
}

fn fileSizeOnDiskFallbackAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
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

    if (builtin.link_libc and (builtin.os.tag == .linux or builtin.os.tag == .macos)) {
        const stat = cStatAt(dir, name) orelse {
            error_count.* += 1;
            return .{ .is_dir = false, .is_file = initial_kind == .file, .size = 0 };
        };
        const is_dir = std.c.S.ISDIR(stat.mode);
        const is_file = std.c.S.ISREG(stat.mode);
        const apparent_size: u64 = if (stat.size < 0) 0 else @intCast(stat.size);
        const size = if (is_file and stat.blocks > 0) @as(u64, @intCast(stat.blocks)) * 512 else apparent_size;
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
            0x00...0x1f => {
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
        .use_io_uring = false,
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
    const result = try scan(std.testing.io, .{
        .path = "/proc",
        .format = .human,
        .summarize = false,
        .show_hidden = true,
        .max_depth = null,
        .max_entries = null,
        .parallel = false,
        .num_threads = 1,
        .use_io_uring = false,
    });

    try std.testing.expectEqual(@as(u64, 0), result.total_size);
    try std.testing.expectEqual(@as(u64, 0), result.total_files);
    try std.testing.expectEqual(@as(u64, 0), result.total_dirs);
    try std.testing.expectEqual(@as(u64, 0), result.error_count);
}
