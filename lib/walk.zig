const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const zdu = @import("zdu.zig");
const stat = @import("stat.zig");

pub const SizedKind = struct {
    is_dir: bool,
    is_file: bool,
    size: u64,
};

pub fn entryKindAndSize(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    initial_kind: anytype,
    error_count: *u64,
) !SizedKind {
    if (initial_kind == .directory) {
        return .{ .is_dir = true, .is_file = false, .size = 0 };
    }
    if (initial_kind == .file) {
        const size = stat.fileSizeOnDiskAt(dir, name, io);
        return .{ .is_dir = false, .is_file = true, .size = size };
    }

    if (comptime stat.have_posix_stat) {
        if (stat.cStatAt(dir, name)) |s| {
            const is_dir = stat.posixStatIsDirectory(s);
            const is_file = stat.posixStatIsRegular(s);
            const size = stat.posixStatAllocatedSize(s);
            return .{ .is_dir = is_dir, .is_file = is_file, .size = size };
        }
        // Fall through to statFile fallback; don't increment error_count yet
    }

    const s = dir.statFile(io, name, .{ .follow_symlinks = false }) catch {
        error_count.* += 1;
        return .{ .is_dir = false, .is_file = initial_kind == .file, .size = 0 };
    };
    return .{
        .is_dir = s.kind == .directory,
        .is_file = s.kind == .file,
        .size = s.size,
    };
}

pub fn recordEntry(size: u64, is_dir: bool, is_file: bool, totals: *zdu.ScanTotals) void {
    if (is_file) {
        totals.total_size += size;
        totals.total_files += 1;
    } else if (is_dir) {
        totals.total_dirs += 1;
    }
}

pub fn walkDirStreaming(
    allocator: mem.Allocator,
    io: std.Io,
    writer: anytype,
    opts: zdu.Options,
    current_path: []const u8,
    dir: std.Io.Dir,
    iter: *std.Io.Dir.Iterator,
    depth: usize,
    first_json_entry: *bool,
    totals: *zdu.ScanTotals,
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

        if (is_dir and zdu.isGeneratedDirPath(full_path)) continue;

        recordEntry(kind.size, is_dir, is_file, totals);

        if (!opts.summarize) {
            try zdu.writeEntry(writer, opts.format, entry.name, full_path, kind.size, is_dir, depth, first_json_entry);
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

pub fn walkDirTotals(
    allocator: mem.Allocator,
    io: std.Io,
    opts: zdu.Options,
    current_path: ?[]const u8,
    check_generated_paths: bool,
    dir: std.Io.Dir,
    iter: *std.Io.Dir.Iterator,
    depth: usize,
    totals: *zdu.ScanTotals,
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
                if (zdu.isGeneratedDirPath(full_path.?)) continue;
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
                check_generated_paths and zdu.pathNeedsGeneratedDirChecks(full_path.?),
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
