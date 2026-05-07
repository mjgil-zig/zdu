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

pub const Entry = struct {
    name: []const u8,
    path: []const u8,
    size: u64,
    is_dir: bool,
    is_file: bool,
    is_symlink: bool,
    depth: usize,
};

pub const ScanResult = struct {
    entries: []Entry,
    total_size: u64,
    total_files: u64,
    total_dirs: u64,
    scan_time_ms: u64,
    error_count: u64,
};

pub fn scanAndFormat(io: std.Io, opts: Options, writer: anytype) !void {
    if (opts.summarize) {
        const result = try scan(io, opts);
        try formatResult(result, opts, writer);
        return;
    }

    const allocator = std.heap.page_allocator;
    var total_size: u64 = 0;
    var total_files: u64 = 0;
    var total_dirs: u64 = 0;
    var error_count: u64 = 0;
    var entry_count: usize = 0;
    var first_json_entry = true;

    switch (opts.format) {
        .human => try writer.writeAll("Entries:\n"),
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
        &entry_count,
        &first_json_entry,
        &total_size,
        &total_files,
        &total_dirs,
        &error_count,
    );

    switch (opts.format) {
        .human => {
            try writer.writeAll("\nSummary:\n");
            try writer.print("  Total size: {}\n", .{total_size});
            try writer.print("  Files: {}\n", .{total_files});
            try writer.print("  Directories: {}\n", .{total_dirs});
            try writer.print("  Scan time: 0ms\n", .{});
            try writer.print("  Errors: {}\n", .{error_count});
        },
        .json => {
            try writer.writeAll("  ],\n");
            try writer.print("  \"total_size\": {},\n", .{total_size});
            try writer.print("  \"total_files\": {},\n", .{total_files});
            try writer.print("  \"total_dirs\": {},\n", .{total_dirs});
            try writer.print("  \"scan_time_ms\": 0,\n", .{});
            try writer.print("  \"error_count\": {}\n", .{error_count});
            try writer.writeAll("}\n");
        },
    }
}

pub fn scan(io: std.Io, opts: Options) !ScanResult {
    const allocator = std.heap.page_allocator;

    var entries_list: std.ArrayList(Entry) = .empty;
    var total_size: u64 = 0;
    var total_files: u64 = 0;
    var total_dirs: u64 = 0;
    var error_count: u64 = 0;

    var dir = try std.Io.Dir.cwd().openDir(io, opts.path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    try walkDir(allocator, io, &entries_list, opts, if (opts.summarize) null else opts.path, dir, &iter, 0, &total_size, &total_files, &total_dirs, &error_count);

    return ScanResult{
        .entries = try entries_list.toOwnedSlice(allocator),
        .total_size = total_size,
        .total_files = total_files,
        .total_dirs = total_dirs,
        .scan_time_ms = 0,
        .error_count = error_count,
    };
}

fn fileSizeOnDisk(path: []const u8, allocator: mem.Allocator, io: std.Io) u64 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return 0;
    if (stat.kind != .file) return stat.size;

    return switch (builtin.os.tag) {
        .linux, .macos => if (builtin.link_libc) allocatedFileSize(path, allocator) orelse stat.size else stat.size,
        else => stat.size,
    };
}

fn allocatedFileSize(path: []const u8, allocator: mem.Allocator) ?u64 {
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);

    var stat: std.c.Stat = undefined;
    if (c_stat.fstatat(std.c.AT.FDCWD, path_z.ptr, &stat, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
        return null;
    }
    if (stat.blocks < 0) return null;
    return @as(u64, @intCast(stat.blocks)) * 512;
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
    entry_count: *usize,
    first_json_entry: *bool,
    total_size: *u64,
    total_files: *u64,
    total_dirs: *u64,
    error_count: *u64,
) !void {
    if (opts.max_depth) |max_depth| {
        if (depth >= max_depth) return;
    }

    while (true) {
        const maybe_entry = iter.next(io) catch {
            error_count.* += 1;
            return;
        };
        const entry = maybe_entry orelse break;
        if (!opts.show_hidden and entry.name[0] == '.') continue;
        if (opts.max_entries) |max_entries| {
            if (entry_count.* >= max_entries) return;
        }

        var size: u64 = 0;
        var kind = entry.kind;
        if (kind != .directory) {
            const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch {
                error_count.* += 1;
                continue;
            };
            kind = stat.kind;
            if (kind == .file) {
                const full_path = try fs.path.join(allocator, &.{ current_path, entry.name });
                defer allocator.free(full_path);
                size = fileSizeOnDisk(full_path, allocator, io);
            } else {
                size = stat.size;
            }
        }

        const is_dir = kind == .directory;
        const is_file = kind == .file;

        if (is_file) {
            total_size.* += size;
            total_files.* += 1;
        } else if (is_dir) {
            total_dirs.* += 1;
        }

        const full_path = try fs.path.join(allocator, &.{ current_path, entry.name });
        defer allocator.free(full_path);

        switch (opts.format) {
            .human => {
                const prefix = if (is_dir) "d" else if (is_file) "f" else "-";
                try writer.print("{s} {:>10} {s}\n", .{ prefix, size, full_path });
            },
            .json => {
                if (!first_json_entry.*) {
                    try writer.writeAll(",\n");
                }
                first_json_entry.* = false;
                try writer.writeAll("    {\n");
                try writer.print("      \"name\": \"{s}\",\n", .{entry.name});
                try writer.print("      \"path\": \"{s}\",\n", .{full_path});
                try writer.print("      \"size\": {},\n", .{size});
                try writer.print("      \"is_dir\": {},\n", .{is_dir});
                try writer.print("      \"depth\": {}\n", .{depth});
                try writer.writeAll("    }");
            },
        }
        entry_count.* += 1;

        if (is_dir and (opts.max_depth == null or depth < opts.max_depth.?)) {
            var subdir = dir.openDir(io, entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch {
                error_count.* += 1;
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
                entry_count,
                first_json_entry,
                total_size,
                total_files,
                total_dirs,
                error_count,
            );
        }
    }
}

fn walkDir(
    allocator: mem.Allocator,
    io: std.Io,
    entries: *std.ArrayList(Entry),
    opts: Options,
    current_path: ?[]const u8,
    dir: std.Io.Dir,
    iter: *std.Io.Dir.Iterator,
    depth: usize,
    total_size: *u64,
    total_files: *u64,
    total_dirs: *u64,
    error_count: *u64,
) !void {
    if (opts.max_depth) |max_depth| {
        if (depth >= max_depth) return;
    }

    if (!opts.summarize) {
        if (opts.max_entries) |max_entries| {
            if (entries.items.len >= max_entries) return;
        }
    }

    while (true) {
        const maybe_entry = iter.next(io) catch {
            error_count.* += 1;
            return;
        };
        const entry = maybe_entry orelse break;
        if (!opts.show_hidden and entry.name[0] == '.') continue;

        var size: u64 = 0;
        var kind = entry.kind;

        if (kind != .directory) {
            const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch {
                error_count.* += 1;
                continue;
            };
            kind = stat.kind;
            if (kind == .file) {
                const parent_path = current_path orelse unreachable;
                const full_path = try fs.path.join(allocator, &.{ parent_path, entry.name });
                defer allocator.free(full_path);
                size = fileSizeOnDisk(full_path, allocator, io);
            } else {
                size = stat.size;
            }
        }

        const is_dir = kind == .directory;
        const is_file = kind == .file;
        const is_symlink = kind == .sym_link;

        if (is_file) {
            total_size.* += size;
            total_files.* += 1;
        } else if (is_dir) {
            total_dirs.* += 1;
        }

        if (!opts.summarize) {
            const parent_path = current_path orelse unreachable;
            const full_path = try fs.path.join(allocator, &.{ parent_path, entry.name });
            defer allocator.free(full_path);

            try entries.append(allocator, Entry{
                .name = try allocator.dupe(u8, entry.name),
                .path = try allocator.dupe(u8, full_path),
                .size = size,
                .is_dir = is_dir,
                .is_file = is_file,
                .is_symlink = is_symlink,
                .depth = depth,
            });
        }

        if (is_dir and (opts.max_depth == null or depth < opts.max_depth.?)) {
            var subdir = dir.openDir(io, entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch {
                error_count.* += 1;
                continue;
            };
            defer subdir.close(io);

            var subiter = subdir.iterate();
            if (current_path) |parent_path| {
                const child_path = try fs.path.join(allocator, &.{ parent_path, entry.name });
                defer allocator.free(child_path);
                try walkDir(allocator, io, entries, opts, child_path, subdir, &subiter, depth + 1, total_size, total_files, total_dirs, error_count);
            } else {
                try walkDir(allocator, io, entries, opts, null, subdir, &subiter, depth + 1, total_size, total_files, total_dirs, error_count);
            }
        }
    }
}

pub fn formatResult(result: ScanResult, opts: Options, writer: anytype) !void {
    switch (opts.format) {
        .human => {
            if (!opts.summarize) {
                try writer.writeAll("Entries:\n");
                for (result.entries) |entry| {
                    const prefix = if (entry.is_dir) "d" else if (entry.is_file) "f" else "-";
                    try writer.print("{s} {:>10} {s}\n", .{ prefix, entry.size, entry.path });
                }
                try writer.writeAll("\n");
            }
            try writer.writeAll("Summary:\n");
            try writer.print("  Total size: {}\n", .{result.total_size});
            try writer.print("  Files: {}\n", .{result.total_files});
            try writer.print("  Directories: {}\n", .{result.total_dirs});
            try writer.print("  Scan time: {}ms\n", .{result.scan_time_ms});
            try writer.print("  Errors: {}\n", .{result.error_count});
        },
        .json => {
            try writer.writeAll("{\n");
            try writer.writeAll("  \"entries\": [\n");
            if (!opts.summarize) {
                for (result.entries, 0..) |entry, idx| {
                    try writer.writeAll("    {\n");
                    try writer.print("      \"name\": \"{s}\",\n", .{entry.name});
                    try writer.print("      \"path\": \"{s}\",\n", .{entry.path});
                    try writer.print("      \"size\": {},\n", .{entry.size});
                    try writer.print("      \"is_dir\": {},\n", .{entry.is_dir});
                    try writer.print("      \"depth\": {}\n", .{entry.depth});
                    try writer.writeAll(if (idx + 1 == result.entries.len) "    }\n" else "    },\n");
                }
            }
            try writer.writeAll("  ],\n");
            try writer.print("  \"total_size\": {},\n", .{result.total_size});
            try writer.print("  \"total_files\": {},\n", .{result.total_files});
            try writer.print("  \"total_dirs\": {},\n", .{result.total_dirs});
            try writer.print("  \"scan_time_ms\": {},\n", .{result.scan_time_ms});
            try writer.print("  \"error_count\": {}\n", .{result.error_count});
            try writer.writeAll("}\n");
        },
    }
}
