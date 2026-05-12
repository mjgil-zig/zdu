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

fn isGeneratedDirPath(path: []const u8) bool {
    return mem.eql(u8, path, "/proc") or mem.startsWith(u8, path, "/proc/");
}

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

    const loading_frames = [_][]const u8{ "|", "/", "-", "\\" };
    const loading_tick_ms: u32 = 16;
    const dir_size_xattr_name: [:0]const u8 = "user.zdu.dir_size.v2";

    const CachedDirSize = struct {
        size: u64,
        expires_at: u64,
    };

    const DirStats = struct {
        size: u64,
        dir_count: u64,
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
        is_dir: bool,
        role: EntryRole = .item,
    };

    const ConfirmDelete = struct {
        path: []u8,
        is_dir: bool,
        size: u64,
    };

    const ScanFrame = struct {
        dir: std.Io.Dir,
        iter: std.Io.Dir.Iterator,
        entry_index: usize,
        total: u64 = 0,
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

    pub fn init(io: std.Io, allocator: mem.Allocator, cwd: []const u8) !*Model {
        return initWithCache(io, allocator, cwd, 0);
    }

    pub fn initWithCache(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !*Model {
        const model = try allocator.create(Model);
        model.* = .{
            .io = io,
            .allocator = allocator,
            .cwd = try allocator.dupe(u8, cwd),
            .cache_ttl_seconds = cache_ttl_seconds,
        };
        try model.primeDirXattrs();
        try model.loadDir();
        return model;
    }

    pub fn initLoading(io: std.Io, allocator: mem.Allocator, cwd: []const u8) !*Model {
        return initLoadingWithCache(io, allocator, cwd, 0);
    }

    pub fn initLoadingWithCache(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !*Model {
        const model = try allocator.create(Model);
        model.* = .{
            .io = io,
            .allocator = allocator,
            .cwd = try allocator.dupe(u8, cwd),
            .cache_ttl_seconds = cache_ttl_seconds,
        };
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
        model.selected = 0;
        model.scroll_offset = 0;
        model.last_visible_rows = 0;
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

    fn primeDirXattrs(model: *Model) !void {
        if (isGeneratedDirPath(model.cwd)) return;

        var dir = std.Io.Dir.cwd().openDir(model.io, model.cwd, .{ .iterate = true }) catch return;
        defer dir.close(model.io);

        var iter = dir.iterate();
        while (iter.next(model.io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            const full_path = try std.fs.path.join(model.allocator, &.{ model.cwd, entry.name });
            defer model.allocator.free(full_path);
            if (isGeneratedDirPath(full_path)) continue;

            _ = computeDirStats(full_path, model.allocator, model.io, model.cache_ttl_seconds);
        }
    }

    pub fn loadDir(model: *Model) !void {
        model.freeLoading();
        model.freeEntries();

        if (isGeneratedDirPath(model.cwd)) return;

        var dir = std.Io.Dir.cwd().openDir(model.io, model.cwd, .{ .iterate = true }) catch return;
        defer dir.close(model.io);

        var entries_list: std.ArrayList(Entry) = .empty;
        defer entries_list.deinit(model.allocator);
        errdefer freeEntryItems(model.allocator, entries_list.items);

        if (model.parent) |parent| {
            try entries_list.append(model.allocator, .{
                .name = try model.allocator.dupe(u8, ".."),
                .path = try model.allocator.dupe(u8, parent.cwd),
                .size = readCachedDirSize(parent.cwd, model.allocator) orelse 0,
                .is_dir = true,
                .role = .parent,
            });
        }

        var iter = dir.iterate();
        while (iter.next(model.io) catch null) |entry| {
            const size: u64 = if (entry.kind == .directory) blk: {
                const full_path = try std.fs.path.join(model.allocator, &.{ model.cwd, entry.name });
                defer model.allocator.free(full_path);
                if (isGeneratedDirPath(full_path)) continue;
                break :blk readCachedDirSize(full_path, model.allocator) orelse 0;
            } else blk: {
                break :blk fileSizeOnDiskAt(dir, entry.name, model.io);
            };

            try entries_list.append(model.allocator, .{
                .name = try model.allocator.dupe(u8, entry.name),
                .size = size,
                .is_dir = entry.kind == .directory,
                .role = .item,
            });
        }

        mem.sortUnstable(Entry, entries_list.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                if (entryRoleRank(a.role) != entryRoleRank(b.role)) return entryRoleRank(a.role) < entryRoleRank(b.role);
                if (a.size != b.size) return a.size > b.size;
                return mem.lessThan(u8, a.name, b.name);
            }
        }.less);

        if (model.parent == null) {
            try prependRootSummary(model.allocator, &entries_list, model.cwd);
        }

        var current_total_size: u64 = 0;
        for (entries_list.items) |entry| {
            if (entry.role == .item) current_total_size += entry.size;
        }
        writeCachedDirSizeFd(dir, current_total_size, model.cache_ttl_seconds);
        model.entries = try entries_list.toOwnedSlice(model.allocator);
        model.selected = initialSelectedIndex(model.entries);
        model.scroll_offset = 0;
        model.last_visible_rows = 0;
    }

    fn beginLoading(model: *Model) !void {
        model.freeLoading();
        model.freeEntries();

        if (isGeneratedDirPath(model.cwd)) return;

        var dir = std.Io.Dir.cwd().openDir(model.io, model.cwd, .{ .iterate = true }) catch return;

        var entries_list: std.ArrayList(Entry) = .empty;
        defer entries_list.deinit(model.allocator);
        errdefer freeEntryItems(model.allocator, entries_list.items);
        errdefer dir.close(model.io);

        if (model.parent) |parent| {
            try entries_list.append(model.allocator, .{
                .name = try model.allocator.dupe(u8, ".."),
                .path = try model.allocator.dupe(u8, parent.cwd),
                .size = readCachedDirSize(parent.cwd, model.allocator) orelse 0,
                .is_dir = true,
                .role = .parent,
            });
        }

        var iter = dir.iterate();
        while (iter.next(model.io) catch null) |entry| {
            if (entry.kind == .directory) {
                const full_path = try std.fs.path.join(model.allocator, &.{ model.cwd, entry.name });
                defer model.allocator.free(full_path);
                if (isGeneratedDirPath(full_path)) continue;
            }

            try entries_list.append(model.allocator, .{
                .name = try model.allocator.dupe(u8, entry.name),
                .size = 0,
                .is_dir = entry.kind == .directory,
                .role = .item,
            });
        }

        model.entries = try entries_list.toOwnedSlice(model.allocator);
        model.loading = .{
            .root_dir = dir,
            .started_at = .now(model.io, .awake),
        };
        model.spinner_frame = 0;
        model.selected = initialSelectedIndex(model.entries);
        model.scroll_offset = 0;
        model.last_visible_rows = 0;
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

        mem.sortUnstable(Entry, model.entries, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                if (entryRoleRank(a.role) != entryRoleRank(b.role)) return entryRoleRank(a.role) < entryRoleRank(b.role);
                if (a.size != b.size) return a.size > b.size;
                return mem.lessThan(u8, a.name, b.name);
            }
        }.less);

        if (model.parent == null) {
            try model.prependRootSummaryToEntries();
        }

        loading.root_dir.close(model.io);
        loading.scan_stack.deinit(model.allocator);
        model.loading = null;
        model.selected = initialSelectedIndex(model.entries);
        model.scroll_offset = 0;
        model.last_visible_rows = 0;
    }

    fn advanceLoadingStep(model: *Model) !bool {
        const loading = if (model.loading) |*loading| loading else return false;

        if (loading.scan_stack.items.len > 0) {
            var frame = &loading.scan_stack.items[loading.scan_stack.items.len - 1];
            if (frame.iter.next(model.io) catch null) |entry| {
                if (entry.kind == .file) {
                    const size = fileSizeOnDiskAt(frame.dir, entry.name, model.io);
                    frame.total += size;
                    loading.processed_bytes += size;
                    return true;
                }

                if (entry.kind == .directory) {
                    var dir = frame.dir.openDir(model.io, entry.name, .{ .iterate = true }) catch return true;
                    if (model.cache_ttl_seconds > 0) {
                        if (readCachedDirSizeFd(dir)) |cached_size| {
                            dir.close(model.io);
                            frame.total += cached_size;
                            loading.processed_bytes += cached_size;
                            loading.processed_dirs += 1;
                            return true;
                        }
                    }
                    loading.processed_dirs += 1;
                    try loading.scan_stack.append(model.allocator, .{
                        .dir = dir,
                        .iter = dir.iterateAssumeFirstIteration(),
                        .entry_index = frame.entry_index,
                        .total = 0,
                    });
                    return true;
                }

                return true;
            }

            const completed = loading.scan_stack.pop().?;
            writeCachedDirSizeFd(completed.dir, completed.total, model.cache_ttl_seconds);
            completed.dir.close(model.io);

            if (loading.scan_stack.items.len > 0) {
                loading.scan_stack.items[loading.scan_stack.items.len - 1].total += completed.total;
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
            const size = fileSizeOnDiskAt(loading.root_dir, entry.name, model.io);
            loading.processed_bytes += size;
            try model.finalizeLoadingEntry(idx, size, false);
            return true;
        }

        var dir = loading.root_dir.openDir(model.io, entry.name, .{ .iterate = true }) catch {
            try model.finalizeLoadingEntry(idx, 0, false);
            return true;
        };
        if (model.cache_ttl_seconds > 0) {
            if (readCachedDirSizeFd(dir)) |cached_size| {
                dir.close(model.io);
                loading.processed_bytes += cached_size;
                loading.processed_dirs += 1;
                try model.finalizeLoadingEntry(idx, cached_size, true);
                return true;
            }
        }
        loading.processed_dirs += 1;
        try loading.scan_stack.append(model.allocator, .{
            .dir = dir,
            .iter = dir.iterateAssumeFirstIteration(),
            .entry_index = idx,
            .total = 0,
        });
        return true;
    }

    fn finalizeLoadingEntry(model: *Model, entry_index: usize, size: u64, cache_written: bool) !void {
        const loading = &model.loading.?;
        if (entry_index < model.entries.len) {
            model.entries[entry_index].size = size;
            if (!cache_written and model.entries[entry_index].is_dir and model.entries[entry_index].role == .item) {
                const full_path = try model.allocEntryPath(model.entries[entry_index]);
                defer model.allocator.free(full_path);
                writeCachedDirSize(full_path, size, model.cache_ttl_seconds, model.allocator);
            }
        }
        loading.processed += 1;
        loading.entry_index += 1;
    }

    fn prependRootSummaryToEntries(model: *Model) !void {
        var total_size: u64 = 0;
        for (model.entries) |entry| {
            if (entry.role == .item) total_size += entry.size;
        }

        const updated = try model.allocator.alloc(Entry, model.entries.len + 1);
        updated[0] = .{
            .name = try model.allocator.dupe(u8, ""),
            .path = try model.allocator.dupe(u8, model.cwd),
            .size = total_size,
            .is_dir = true,
            .role = .summary,
        };
        @memcpy(updated[1..], model.entries);
        model.allocator.free(model.entries);
        model.entries = updated;
        if (model.loading) |loading| {
            writeCachedDirSizeFd(loading.root_dir, total_size, model.cache_ttl_seconds);
        } else {
            writeCachedDirSize(model.cwd, total_size, model.cache_ttl_seconds, model.allocator);
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
        var total_size: u64 = 0;
        for (entries.items) |entry| {
            if (entry.role == .item) total_size += entry.size;
        }

        try entries.insert(allocator, 0, .{
            .name = try allocator.dupe(u8, ""),
            .path = try allocator.dupe(u8, cwd),
            .size = total_size,
            .is_dir = true,
            .role = .summary,
        });
    }

    fn ensureSelectionVisible(model: *Model, visible_rows: usize) void {
        if (visible_rows == 0) {
            model.scroll_offset = 0;
            return;
        }

        if (model.selected < model.scroll_offset) {
            model.scroll_offset = model.selected;
        } else if (model.selected >= model.scroll_offset + visible_rows) {
            model.scroll_offset = model.selected - visible_rows + 1;
        }

        if (model.entries.len <= visible_rows) {
            model.scroll_offset = 0;
        } else {
            model.scroll_offset = @min(model.scroll_offset, model.entries.len - visible_rows);
        }
    }

    fn computeDirSize(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) u64 {
        return computeDirStats(path, allocator, io, cache_ttl_seconds).size;
    }

    const StackFrame = struct {
        dir: std.Io.Dir,
        iter: std.Io.Dir.Iterator,
        total: u64 = 0,
    };

    fn computeDirStats(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) DirStats {
        if (isGeneratedDirPath(path)) return .{ .size = 0, .dir_count = 0 };

        if (cache_ttl_seconds > 0) {
            if (readCachedDirSize(path, allocator)) |cached_size| {
                return .{ .size = cached_size, .dir_count = 1 };
            }
        }

        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return .{ .size = 0, .dir_count = 1 };
        defer dir.close(io);

        return computeDirStatsInDir(dir, io, cache_ttl_seconds);
    }

    fn computeDirStatsInDir(dir: std.Io.Dir, io: std.Io, cache_ttl_seconds: u64) DirStats {
        if (cache_ttl_seconds > 0) {
            if (readCachedDirSizeFd(dir)) |cached_size| {
                return .{ .size = cached_size, .dir_count = 1 };
            }
        }

        var total: u64 = 0;
        var dir_count: u64 = 1;
        var iter = dir.iterateAssumeFirstIteration();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .file) {
                total += fileSizeOnDiskAt(dir, entry.name, io);
            } else if (entry.kind == .directory) {
                var subdir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer subdir.close(io);
                const child = computeDirStatsInDir(subdir, io, cache_ttl_seconds);
                total += child.size;
                dir_count += child.dir_count;
            }
        }
        writeCachedDirSizeFd(dir, total, cache_ttl_seconds);
        return .{ .size = total, .dir_count = dir_count };
    }

    fn computeDirStatsStack(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) !DirStats {
        var stack: std.ArrayList(StackFrame) = .empty;
        defer {
            for (stack.items) |*frame| {
                frame.dir.close(io);
            }
            stack.deinit(allocator);
        }

        var root_dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return .{ .size = 0, .dir_count = 1 };
        if (cache_ttl_seconds > 0) {
            if (readCachedDirSizeFd(root_dir)) |cached_size| {
                root_dir.close(io);
                return .{ .size = cached_size, .dir_count = 1 };
            }
        }
        try stack.append(allocator, .{ .dir = root_dir, .iter = root_dir.iterateAssumeFirstIteration() });

        var dir_count: u64 = 1;

        while (stack.items.len > 0) {
            var frame = &stack.items[stack.items.len - 1];
            if (frame.iter.next(io) catch null) |entry| {
                if (entry.kind == .file) {
                    frame.total += fileSizeOnDiskAt(frame.dir, entry.name, io);
                    continue;
                }
                if (entry.kind == .directory) {
                    var subdir = frame.dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                    if (cache_ttl_seconds > 0) {
                        if (readCachedDirSizeFd(subdir)) |cached_size| {
                            frame.total += cached_size;
                            subdir.close(io);
                            dir_count += 1;
                            continue;
                        }
                    }
                    try stack.append(allocator, .{
                        .dir = subdir,
                        .iter = subdir.iterateAssumeFirstIteration(),
                    });
                    dir_count += 1;
                    continue;
                }
                continue;
            }

            const completed = stack.pop().?;
            writeCachedDirSizeFd(completed.dir, completed.total, cache_ttl_seconds);
            completed.dir.close(io);

            if (stack.items.len > 0) {
                stack.items[stack.items.len - 1].total += completed.total;
            } else {
                return .{ .size = completed.total, .dir_count = dir_count };
            }
        }

        return .{ .size = 0, .dir_count = dir_count };
    }

    fn fileSizeOnDisk(path: []const u8, allocator: mem.Allocator, io: std.Io) u64 {
        _ = allocator;
        return fileSizeOnDiskAt(std.Io.Dir.cwd(), path, io);
    }

    fn fileSizeOnDiskAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
        return switch (builtin.os.tag) {
            .linux, .macos => if (builtin.link_libc) fileSizeOnDiskWithLibcAt(dir, sub_path) else fileSizeOnDiskFallbackAt(dir, sub_path, io),
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

    fn readCachedDirSize(path: []const u8, allocator: mem.Allocator) ?u64 {
        const now = currentTimestampSeconds() orelse return null;
        const path_z = allocator.dupeZ(u8, path) catch return null;
        defer allocator.free(path_z);
        var buf: [16]u8 = undefined;

        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                const rc = linux.getxattr(path_z.ptr, dir_size_xattr_name, buf[0..].ptr, buf.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => {
                        if (rc != buf.len) return null;
                        const record = decodeCachedDirSize(&buf);
                        if (record.expires_at < now) return null;
                        return record.size;
                    },
                    .NODATA, .NOENT, .OPNOTSUPP, .RANGE => return null,
                    else => return null,
                }
            },
            .macos => {
                const rc = darwin_xattr.getxattr(path_z.ptr, dir_size_xattr_name, buf[0..].ptr, buf.len, 0, 0);
                switch (std.c.errno(rc)) {
                    .SUCCESS => {
                        if (rc != buf.len) return null;
                        const record = decodeCachedDirSize(&buf);
                        if (record.expires_at < now) return null;
                        return record.size;
                    },
                    .NOATTR, .NOENT, .OPNOTSUPP, .RANGE => return null,
                    else => return null,
                }
            },
            else => return null,
        }
    }

    fn readCachedDirSizeFd(dir: std.Io.Dir) ?u64 {
        const now = currentTimestampSeconds() orelse return null;
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
                        return record.size;
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
                        return record.size;
                    },
                    .NOATTR, .NOENT, .OPNOTSUPP, .RANGE => return null,
                    else => return null,
                }
            },
            else => return null,
        }
    }

    fn writeCachedDirSize(path: []const u8, size: u64, cache_ttl_seconds: u64, allocator: mem.Allocator) void {
        const path_z = allocator.dupeZ(u8, path) catch return;
        defer allocator.free(path_z);
        var buf: [16]u8 = undefined;
        const expires_at: u64 = if (cache_ttl_seconds == 0)
            std.math.maxInt(u64)
        else blk: {
            const now = currentTimestampSeconds() orelse return;
            break :blk now + cache_ttl_seconds;
        };
        encodeCachedDirSize(&buf, .{
            .size = size,
            .expires_at = expires_at,
        });

        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                _ = linux.setxattr(path_z.ptr, dir_size_xattr_name, buf[0..].ptr, buf.len, 0);
            },
            .macos => {
                _ = darwin_xattr.setxattr(path_z.ptr, dir_size_xattr_name, buf[0..].ptr, buf.len, 0, 0);
            },
            else => {},
        }
    }

    fn writeCachedDirSizeFd(dir: std.Io.Dir, size: u64, cache_ttl_seconds: u64) void {
        var buf: [16]u8 = undefined;
        const expires_at: u64 = if (cache_ttl_seconds == 0)
            std.math.maxInt(u64)
        else blk: {
            const now = currentTimestampSeconds() orelse return;
            break :blk now + cache_ttl_seconds;
        };
        encodeCachedDirSize(&buf, .{
            .size = size,
            .expires_at = expires_at,
        });

        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                _ = linux.fsetxattr(dir.handle, dir_size_xattr_name, buf[0..].ptr, buf.len, 0);
            },
            .macos => {
                _ = darwin_xattr.fsetxattr(dir.handle, dir_size_xattr_name, buf[0..].ptr, buf.len, 0, 0);
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

    fn clearCachedDirSize(path: []const u8, allocator: mem.Allocator) void {
        const path_z = allocator.dupeZ(u8, path) catch return;
        defer allocator.free(path_z);

        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                _ = linux.removexattr(path_z.ptr, dir_size_xattr_name);
            },
            .macos => {
                _ = darwin_xattr.removexattr(path_z.ptr, dir_size_xattr_name, 0);
            },
            else => {},
        }
    }

    fn clearDirSizeCacheChain(model: *Model) void {
        var current: ?*Model = model;
        while (current) |cursor| {
            clearCachedDirSize(cursor.cwd, cursor.allocator);
            current = cursor.parent;
        }
    }

    fn propagateDeletedSize(model: *Model, deleted_size: u64) void {
        var current: ?*Model = model;
        while (current) |cursor| {
            const current_size = blk: {
                if (cursor.entries.len > 0) {
                    if (cursor.entries[0].role == .summary) break :blk cursor.entries[0].size;
                    var total: u64 = 0;
                    for (cursor.entries) |entry| {
                        if (entry.role == .item) total += entry.size;
                    }
                    break :blk total;
                }
                if (readCachedDirSize(cursor.cwd, cursor.allocator)) |cached_size| break :blk cached_size;
                break :blk computeDirSize(
                    cursor.cwd,
                    cursor.allocator,
                    cursor.io,
                    cursor.cache_ttl_seconds,
                );
            };
            const updated_size = current_size -| deleted_size;
            if (cursor.entries.len > 0 and cursor.entries[0].role == .summary) {
                cursor.entries[0].size = updated_size;
            }
            writeCachedDirSize(cursor.cwd, updated_size, cursor.cache_ttl_seconds, cursor.allocator);
            current = cursor.parent;
        }
    }

    fn entryIndexForMouseRow(model: *Model, mouse_row: i16) ?usize {
        if (mouse_row < 2) return null;
        const row = @as(usize, @intCast(mouse_row - 2));
        if (row >= model.last_visible_rows) return null;
        const entry_idx = model.scroll_offset + row;
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

        const parent = try allocator.create(Model);
        errdefer allocator.destroy(parent);
        parent.* = model.*;

        model.* = .{
            .io = io,
            .allocator = allocator,
            .cwd = next_cwd,
            .parent = parent,
            .cache_ttl_seconds = cache_ttl_seconds,
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
            .size = entry.size,
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
            model.propagateDeletedSize(confirm.size);
            model.loadDir() catch return;
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
                    if (key.codepoint == vaxis.Key.enter) {
                        model.confirmDelete() catch {};
                        if (model.loading != null) try ctx.tick(loading_tick_ms, model.widget());
                        ctx.redraw = true;
                        return;
                    } else if (key.text != null and mem.eql(u8, key.text.?, "n")) {
                        model.cancelDelete();
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
                if (key.codepoint == vaxis.Key.backspace or key.codepoint == vaxis.Key.left or key.codepoint == vaxis.Key.escape) {
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
        const entries_bytes = entriesStorageBytes(model.entries);
        const stack_bytes = @as(u64, @intCast(loading.scan_stack.capacity * @sizeOf(ScanFrame)));
        const retained_bytes = entries_bytes + stack_bytes;

        const elapsed_ns = @max(@as(i128, 0), loading.started_at.durationTo(std.Io.Timestamp.now(model.io, .awake)).nanoseconds);
        var elapsed_buf: [32]u8 = undefined;
        const elapsed_text = formatDuration(&elapsed_buf, @as(u64, @intCast(elapsed_ns / std.time.ns_per_ms)));
        var processed_buf: [32]u8 = undefined;
        const processed_text = formatSize(&processed_buf, processed_bytes);
        const dir_label = if (processed_dirs == 1) "directory" else "directories";
        var retained_buf: [32]u8 = undefined;
        const retained_text = formatSize(&retained_buf, retained_bytes);
        var entries_buf: [32]u8 = undefined;
        const entries_text = formatSize(&entries_buf, entries_bytes);
        var stack_buf: [32]u8 = undefined;
        const stack_text = formatSize(&stack_buf, stack_bytes);

        const title = "Loading directory";
        const spinner = loading_frames[model.spinner_frame];
        const status = try std.fmt.allocPrint(allocator, "{s} {d}/{d} entries", .{ spinner, done, total });
        const detail = try std.fmt.allocPrint(allocator, "Processed: {s}", .{processed_text});
        const meta = try std.fmt.allocPrint(allocator, "{d} {s}   Elapsed: {s}", .{ processed_dirs, dir_label, elapsed_text });
        const retained = try std.fmt.allocPrint(allocator, "Retained~ {s}  entries {s}  stack {s}", .{ retained_text, entries_text, stack_text });

        const start_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(title.len)))) / 2));
        const status_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(status.len)))) / 2));
        const detail_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(detail.len)))) / 2));
        const meta_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(meta.len)))) / 2));
        const retained_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(retained.len)))) / 2));
        const center_row = height / 2;

        try writeText(surface, allocator, title, center_row -| 2, start_col, .{ .fg = .{ .index = 15 }, .bold = true });
        try writeText(surface, allocator, status, center_row -| 1, status_col, .{ .fg = .{ .index = 12 } });
        try writeText(surface, allocator, detail, center_row, detail_col, .{ .fg = .{ .index = 10 } });
        try writeText(surface, allocator, meta, center_row + 1, meta_col, .{ .fg = .{ .index = 8 } });
        try writeText(surface, allocator, retained, center_row + 2, retained_col, .{ .fg = .{ .index = 11 } });
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
        const max_entries = @min(model.entries.len -| model.scroll_offset, visible_rows);
        model.last_visible_rows = max_entries;
        for (0..max_entries) |i| {
            const entry_idx = model.scroll_offset + i;
            const entry = model.entries[entry_idx];
            const prefix = switch (entry.role) {
                .summary => "[ROOT]",
                else => if (entry.is_dir) "[DIR] " else "[FILE]",
            };
            var size_buf: [32]u8 = undefined;
            const size_str = formatSize(&size_buf, entry.size);
            const line = if (entry.name.len == 0)
                try std.fmt.allocPrint(ctx.arena, "{s} {s:>10}", .{ prefix, size_str })
            else
                try std.fmt.allocPrint(ctx.arena, "{s} {s:>10} {s}", .{ prefix, size_str, entry.name });

            const row = @as(u16, @intCast(2 + i));
            const is_selected = entry_idx == model.selected and isSelectableEntry(entry);
            const style: vaxis.Style = if (is_selected) .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 } } else .{};

            try writeText(&surface, ctx.arena, line, row, 0, style);
        }

        const help = "up/down: navigate | Enter/Right: open/parent | Delete: del dir | Backspace/Left/Esc: go up";
        try writeText(&surface, ctx.arena, help, height -| 1, 0, .{ .fg = .{ .index = 8 } });

        if (model.confirm_delete) |confirm| {
            const dialog_text = try std.fmt.allocPrint(ctx.arena, "Delete {s}? [Y/n]", .{confirm.path});
            const dialog_row = height / 2 -| 1;
            const dialog_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(dialog_text.len)))) / 2));
            try writeText(&surface, ctx.arena, dialog_text, dialog_row, dialog_col, .{ .bg = .{ .index = 1 }, .fg = .{ .index = 15 } });
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

test "delete propagates removed size up the directory chain" {
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
    try finishLoading(model, std.testing.allocator, std.testing.io);

    const remaining_size = Model.fileSizeOnDisk(root_file_path, std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(?u64, 0), Model.readCachedDirSize(child_path, std.testing.allocator));
    try std.testing.expectEqual(@as(?u64, remaining_size), Model.readCachedDirSize(root_path, std.testing.allocator));
    try std.testing.expectEqualStrings("..", model.entries[0].name);
    try std.testing.expectEqual(remaining_size, model.entries[0].size);
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

fn benchmarkWorkerLoad(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !u64 {
    const start = std.Io.Timestamp.now(io, .awake);
    var dir = std.Io.Dir.cwd().openDir(io, cwd, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var iter = dir.iterate();
    var total_size: u64 = 0;
    while (iter.next(io) catch null) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ cwd, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            const stats = Model.computeDirStats(full_path, allocator, io, cache_ttl_seconds);
            total_size += stats.size;
        } else if (entry.kind == .file) {
            total_size += Model.fileSizeOnDiskAt(dir, entry.name, io);
        }
    }
    Model.writeCachedDirSize(cwd, total_size, cache_ttl_seconds, allocator);

    const end = std.Io.Timestamp.now(io, .awake);
    return @as(u64, @intCast(@divFloor(start.durationTo(end).nanoseconds, std.time.ns_per_ms)));
}

fn benchmarkStackLoad(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !u64 {
    const start = std.Io.Timestamp.now(io, .awake);
    _ = try scanRootTotalStack(io, allocator, cwd, cache_ttl_seconds);

    const end = std.Io.Timestamp.now(io, .awake);
    return @as(u64, @intCast(@divFloor(start.durationTo(end).nanoseconds, std.time.ns_per_ms)));
}

fn scanRootTotalStack(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !u64 {
    if (isGeneratedDirPath(cwd)) return 0;

    var dir = std.Io.Dir.cwd().openDir(io, cwd, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var iter = dir.iterate();
    var total_size: u64 = 0;
    while (iter.next(io) catch null) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ cwd, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            if (isGeneratedDirPath(full_path)) continue;
            const stats = try Model.computeDirStatsStack(full_path, allocator, io, cache_ttl_seconds);
            total_size += stats.size;
        } else if (entry.kind == .file) {
            total_size += Model.fileSizeOnDiskAt(dir, entry.name, io);
        }
    }
    Model.writeCachedDirSize(cwd, total_size, cache_ttl_seconds, allocator);
    return total_size;
}

fn runBenchmarks(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !void {
    const worker_ms = try benchmarkWorkerLoad(io, allocator, cwd, cache_ttl_seconds);
    const stack_ms = try benchmarkStackLoad(io, allocator, cwd, cache_ttl_seconds);
    std.debug.print("worker_thread_ms={d}\nstack_machine_ms={d}\n", .{ worker_ms, stack_ms });
}

fn runNoTui(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !void {
    _ = allocator;
    _ = cache_ttl_seconds;
    const result = try zdu.scan(io, .{
        .path = cwd,
        .format = .human,
        .summarize = true,
        .show_hidden = false,
        .max_depth = null,
        .max_entries = null,
        .parallel = false,
        .num_threads = 1,
        .use_io_uring = false,
    });

    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{d}\n", .{result.total_size});
    try stdout.flush();
}

const Config = struct {
    cwd: []const u8 = ".",
    cache_ttl_seconds: u64 = 0,
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
        try runNoTui(init.io, allocator, config.cwd, config.cache_ttl_seconds);
        return;
    }

    const model = try Model.initLoadingWithCache(init.io, allocator, config.cwd, config.cache_ttl_seconds);
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

fn zduTestEncodeCacheRecord(buf: *[16]u8, size: u64, expires_at: u64) void {
    std.mem.writeInt(u64, buf[0..8], size, .little);
    std.mem.writeInt(u64, buf[8..16], expires_at, .little);
}

fn zduTestSetRawDirSizeXattr(
    path: []const u8,
    bytes: []const u8,
    allocator: mem.Allocator,
) !void {
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

    try std.testing.expect(b_cached > 0);
    try std.testing.expect(c_cached > 0);

    try std.testing.expect(a_cached > b_cached);
    try std.testing.expect(a_cached > c_cached);
    try std.testing.expectEqual(a_cached, b_cached + c_cached);
}

test "dir size xattr cache accepts fresh records and rejects expired or malformed records" {
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

    Model.writeCachedDirSize(dir_path, 1234, 60, allocator);

    const fresh = Model.readCachedDirSize(dir_path, allocator) orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u64, 1234), fresh);

    var dir = std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(std.testing.io);

    try std.testing.expectEqual(@as(?u64, 1234), Model.readCachedDirSizeFd(dir));

    const now = Model.currentTimestampSeconds() orelse return error.SkipZigTest;

    var expired_record: [16]u8 = undefined;
    zduTestEncodeCacheRecord(
        &expired_record,
        5678,
        if (now == 0) 0 else now - 1,
    );

    try zduTestSetRawDirSizeXattr(dir_path, expired_record[0..], allocator);
    try std.testing.expectEqual(@as(?u64, null), Model.readCachedDirSize(dir_path, allocator));

    var malformed_record: [15]u8 = undefined;
    @memset(&malformed_record, 0xaa);

    try zduTestSetRawDirSizeXattr(dir_path, malformed_record[0..], allocator);
    try std.testing.expectEqual(@as(?u64, null), Model.readCachedDirSize(dir_path, allocator));
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

test "model does not process /proc" {
    var model = try Model.init(std.testing.io, std.testing.allocator, "/proc");
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 0), model.entries.len);
    try std.testing.expect(model.loading == null);
}
