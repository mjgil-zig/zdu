const builtin = @import("builtin");
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const zdu = @import("zdu");
const Cache = @import("Cache.zig");
const Scan = @import("Scan.zig");
const mem = std.mem;

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

    pub const loading_frames = [_][]const u8{ "|", "/", "-", "\\" };
    pub const loading_tick_ms: u32 = 16;
    pub const dir_size_xattr_name = Cache.dir_size_xattr_name;
    pub const dir_stats_xattr_name = Cache.dir_stats_xattr_name;

    pub const CachedDirSize = Cache.CachedDirSize;
    pub const CachedDirStats = Cache.CachedDirStats;
    pub const DirStats = Cache.DirStats;
    pub const MoveDirection = enum { up, down };
    pub const DynamicScanInput = Scan.DynamicScanInput;

    pub const Options = struct {
        cache_ttl_seconds: u64 = 0,
        refresh_cache: bool = false,
        parallel: bool = false,
        num_threads: usize = 0,
    };

    pub const EntryRole = enum {
        summary,
        parent,
        item,
    };

    pub const Entry = struct {
        name: []u8,
        path: ?[]u8 = null,
        size: u64,
        file_count: u64 = 0,
        dir_count: u64 = 0,
        is_dir: bool,
        role: EntryRole = .item,
    };

    pub const ConfirmDelete = struct {
        path: []u8,
        is_dir: bool,
        stats: DirStats,
        entry_index: usize,
    };

    pub const ScanFrame = struct {
        dir: std.Io.Dir,
        iter: std.Io.Dir.Iterator,
        entry_index: usize,
        total: DirStats = .{ .dir_count = 1 },
    };

    pub const EntryScanTask = struct {
        path: []u8,
        entry_index: usize,
        estimate_files: u64,
    };

    pub const EntryScanContext = struct {
        io: std.Io,
        allocator: mem.Allocator,
        cache_ttl_seconds: u64,
        refresh_cache: bool,
        tasks: []const EntryScanTask,
        results: []DirStats,
        next_index: usize = 0,
        mutex: std.Io.Mutex = .init,
    };

    pub const dynamic_split_min_files: u64 = 4096;
    pub const dynamic_wait_sleep_ns: u64 = 100_000;
    pub const dynamic_worker_stack_size: usize = 3 * 1024 * 1024;

    pub const Loading = struct {
        processed: usize = 0,
        entry_index: usize = 0,
        processed_bytes: u64 = 0,
        processed_dirs: u64 = 0,
        root_dir: std.Io.Dir,
        scan_stack: std.ArrayList(ScanFrame) = .empty,
        started_at: std.Io.Timestamp,
    };

    pub fn createModel(io: std.Io, allocator: mem.Allocator, cwd: []const u8, options: Options) !*Model {
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

    pub fn allocEntryOwned(
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

    pub fn statsFromEntry(entry: Entry) DirStats {
        if (entry.is_dir) {
            return .{
                .size = entry.size,
                .file_count = entry.file_count,
                .dir_count = if (entry.dir_count == 0) 1 else entry.dir_count,
            };
        }
        return .{ .size = entry.size, .file_count = 1, .dir_count = 0 };
    }

    pub fn pushLoadingFrame(loading: *Loading, allocator: mem.Allocator, io: std.Io, dir: std.Io.Dir, entry_index: usize) !void {
        return @import("ModelLoad.zig").pushLoadingFrame(loading, allocator, io, dir, entry_index);
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

    pub fn freeEntryItems(allocator: mem.Allocator, entries: []Entry) void {
        for (entries) |entry| {
            allocator.free(entry.name);
            if (entry.path) |path| allocator.free(path);
        }
    }

    pub fn freeState(model: *Model) void {
        model.freeLoading();
        model.allocator.free(model.cwd);
        freeEntryItems(model.allocator, model.entries);
        model.allocator.free(model.entries);
        if (model.confirm_delete) |confirm| {
            model.allocator.free(confirm.path);
        }
    }

    pub fn freeLoading(model: *Model) void {
        if (model.loading) |*loading| {
            loading.root_dir.close(model.io);
            for (loading.scan_stack.items) |*frame| {
                frame.dir.close(model.io);
            }
            loading.scan_stack.deinit(model.allocator);
            model.loading = null;
        }
    }

    pub fn freeEntries(model: *Model) void {
        freeEntryItems(model.allocator, model.entries);
        model.allocator.free(model.entries);
        model.entries = &.{};
        model.resetEntryView();
    }

    pub fn entriesStorageBytes(entries: []Entry) u64 {
        var bytes: u64 = @as(u64, @intCast(entries.len * @sizeOf(Entry)));
        for (entries) |entry| {
            bytes += entry.name.len;
            if (entry.path) |path| bytes += path.len;
        }
        return bytes;
    }

    pub fn allocItemPath(allocator: mem.Allocator, cwd: []const u8, name: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ cwd, name });
    }

    pub fn allocEntryPath(model: *Model, entry: Entry) ![]u8 {
        if (entry.path) |path| return model.allocator.dupe(u8, path);
        return allocItemPath(model.allocator, model.cwd, entry.name);
    }

    pub fn resetEntryView(model: *Model) void {
        model.selected = initialSelectedIndex(model.entries);
        model.scroll_offset = 0;
        model.last_visible_rows = 0;
    }

    pub fn sortEntries(entries: []Entry) void {
        mem.sortUnstable(Entry, entries, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                if (entryRoleRank(a.role) != entryRoleRank(b.role)) return entryRoleRank(a.role) < entryRoleRank(b.role);
                if (a.size != b.size) return a.size > b.size;
                return mem.lessThan(u8, a.name, b.name);
            }
        }.less);
    }

    pub fn totalItemStats(entries: []const Entry) DirStats {
        var total: DirStats = .{};
        for (entries) |entry| {
            if (entry.role == .item) Scan.addStats(&total, statsFromEntry(entry));
        }
        return total;
    }

    pub fn currentDirStatsFromEntries(entries: []const Entry) DirStats {
        var stats = totalItemStats(entries);
        stats.dir_count += 1;
        return stats;
    }

    pub fn totalItemSize(entries: []const Entry) u64 {
        return totalItemStats(entries).size;
    }

    pub const InitialEntryMode = enum {
        eager,
        loading,
    };

    pub fn appendParentEntry(model: *Model, entries_list: *std.ArrayList(Entry)) !void {
        if (model.parent) |parent| {
            const parent_stats = parent.knownDirStats() orelse
                Cache.readCachedDirStats(parent.cwd, model.allocator) orelse Cache.DirStats{};
            try entries_list.append(model.allocator, try allocEntryOwned(
                model.allocator,
                "..",
                parent.cwd,
                parent_stats,
                true,
                .parent,
            ));
        }
    }

    pub fn appendInitialEntries(model: *Model, dir: std.Io.Dir, entries_list: *std.ArrayList(Entry), mode: InitialEntryMode) !void {
        return @import("ModelLoad.zig").appendInitialEntries(model, dir, entries_list, mode);
    }

    pub fn primeDirXattrs(model: *Model) !void {
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
                Scan.computeDirStatsRefreshing(full_path, model.allocator, model.io, model.cache_ttl_seconds)
            else
                Scan.computeDirStats(full_path, model.allocator, model.io, model.cache_ttl_seconds);
        }
    }

    pub fn sortEntryScanTasks(tasks: []EntryScanTask) void {
        return @import("ModelLoad.zig").sortEntryScanTasks(tasks);
    }

    pub fn entryScanWorkerCount(parallel: bool, requested: usize, task_count: usize) usize {
        return @import("ModelLoad.zig").entryScanWorkerCount(parallel, requested, task_count);
    }

    pub fn nextEntryScanTask(ctx: *EntryScanContext) ?usize {
        return @import("ModelLoad.zig").nextEntryScanTask(ctx);
    }

    pub fn entryScanWorker(ctx: *EntryScanContext) void {
        return @import("ModelLoad.zig").entryScanWorker(ctx);
    }

    pub fn scanEntryTasks(model: *Model, tasks: []const EntryScanTask, entries: []Entry) !void {
        return @import("ModelLoad.zig").scanEntryTasks(model, tasks, entries);
    }

    pub fn loadDirParallel(model: *Model) !void {
        return @import("ModelLoad.zig").loadDirParallel(model);
    }

    pub fn loadDir(model: *Model) !void {
        return @import("ModelLoad.zig").loadDir(model);
    }

    pub fn beginLoading(model: *Model) !void {
        return @import("ModelLoad.zig").beginLoading(model);
    }

    pub fn advanceLoading(model: *Model) !void {
        return @import("ModelLoad.zig").advanceLoading(model);
    }

    pub fn advanceLoadingStep(model: *Model) !bool {
        return @import("ModelLoad.zig").advanceLoadingStep(model);
    }

    pub fn finalizeLoadingEntry(model: *Model, entry_index: usize, stats: DirStats, cache_written: bool) !void {
        return @import("ModelLoad.zig").finalizeLoadingEntry(model, entry_index, stats, cache_written);
    }

    pub fn prependRootSummaryToEntries(model: *Model) !void {
        return @import("ModelLoad.zig").prependRootSummaryToEntries(model);
    }

    pub fn entryRoleRank(role: EntryRole) u8 {
        return switch (role) {
            .summary => 0,
            .parent => 1,
            .item => 2,
        };
    }

    pub fn isSelectableEntry(entry: Entry) bool {
        return entry.role != .summary;
    }

    pub fn initialSelectedIndex(entries: []Entry) usize {
        if (entries.len <= 1) return 0;
        return switch (entries[0].role) {
            .summary, .parent => 1,
            .item => 0,
        };
    }

    pub fn prependRootSummary(allocator: mem.Allocator, entries: *std.ArrayList(Entry), cwd: []const u8) !void {
        const total_stats = currentDirStatsFromEntries(entries.items);

        try entries.insert(allocator, 0, try allocEntryOwned(allocator, "", cwd, total_stats, true, .summary));
    }

    pub fn hasStickyRootSummary(model: *const Model) bool {
        return model.entries.len > 0 and model.entries[0].role == .summary;
    }

    pub fn stickyRootRows(model: *const Model, visible_rows: usize) usize {
        return if (visible_rows > 0 and model.hasStickyRootSummary()) 1 else 0;
    }

    pub fn minScrollableEntryIndex(model: *const Model) usize {
        return if (model.hasStickyRootSummary()) 1 else 0;
    }

    pub fn firstScrollableEntryIndex(model: *const Model) usize {
        return @max(model.scroll_offset, model.minScrollableEntryIndex());
    }

    pub fn ensureSelectionVisible(model: *Model, visible_rows: usize) void {
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

    pub fn computeDirSize(path: []const u8, allocator: mem.Allocator, io: std.Io, cache_ttl_seconds: u64) u64 {
        return Scan.computeDirStats(path, allocator, io, cache_ttl_seconds).size;
    }

    pub fn knownDirStats(model: *Model) ?DirStats {
        if (model.entries.len > 0 and model.entries[0].role == .summary) {
            return statsFromEntry(model.entries[0]);
        }
        return Cache.readCachedDirStats(model.cwd, model.allocator);
    }

    pub fn updateEntryStats(entry: *Entry, stats: DirStats) void {
        entry.size = stats.size;
        entry.file_count = stats.file_count;
        entry.dir_count = stats.dir_count;
    }

    pub fn updateParentEntryStats(model: *Model, stats: DirStats) void {
        for (model.entries) |*entry| {
            if (entry.role == .parent) {
                updateEntryStats(entry, stats);
                return;
            }
        }
    }

    pub fn updateSummaryEntryStats(model: *Model, stats: DirStats) void {
        if (model.entries.len > 0 and model.entries[0].role == .summary) {
            updateEntryStats(&model.entries[0], stats);
        }
    }

    pub fn entryPathMatches(model: *Model, entry: Entry, target_path: []const u8) bool {
        if (entry.path) |path| return mem.eql(u8, path, target_path);
        const path = allocItemPath(model.allocator, model.cwd, entry.name) catch return false;
        defer model.allocator.free(path);
        return mem.eql(u8, path, target_path);
    }

    pub fn subtractEntryStatsByPath(model: *Model, target_path: []const u8, deleted_stats: DirStats) void {
        for (model.entries) |*entry| {
            if (entry.role != .item) continue;
            if (!entryPathMatches(model, entry.*, target_path)) continue;
            if (Scan.subtractStats(statsFromEntry(entry.*), deleted_stats)) |updated_stats| {
                updateEntryStats(entry, updated_stats);
            }
            return;
        }
    }

    pub fn propagateDeletedStats(model: *Model, deleted_stats: DirStats, deleted_path: []const u8) void {
        var current: ?*Model = model;
        var changed_path: []const u8 = deleted_path;
        var child: ?*Model = null;

        while (current) |cursor| {
            const maybe_current_stats = knownDirStats(cursor);
            if (child != null) subtractEntryStatsByPath(cursor, changed_path, deleted_stats);

            if (maybe_current_stats) |current_stats| {
                if (Scan.subtractStats(current_stats, deleted_stats)) |updated_stats| {
                    updateSummaryEntryStats(cursor, updated_stats);
                    Cache.writeCachedDirStats(cursor.cwd, updated_stats, cursor.cache_ttl_seconds, cursor.allocator);
                    if (child) |child_model| child_model.updateParentEntryStats(updated_stats);
                }
            }

            changed_path = cursor.cwd;
            child = cursor;
            current = cursor.parent;
        }
    }

    pub fn freeEntryItem(allocator: mem.Allocator, entry: Entry) void {
        allocator.free(entry.name);
        if (entry.path) |path| allocator.free(path);
    }

    pub fn removeEntryAt(model: *Model, entry_index: usize) !void {
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

    pub fn entryIndexForMouseRow(model: *Model, mouse_row: i16) ?usize {
        return @import("ModelEvent.zig").entryIndexForMouseRow(model, mouse_row);
    }

    pub fn moveSelection(model: *Model, direction: MoveDirection) void {
        return @import("ModelEvent.zig").moveSelection(model, direction);
    }

    pub fn navigateInto(model: *Model) !void {
        return @import("ModelNav.zig").navigateInto(model);
    }

    pub fn navigateUp(model: *Model) !void {
        return @import("ModelNav.zig").navigateUp(model);
    }

    pub fn deleteSelected(model: *Model) !void {
        return @import("ModelNav.zig").deleteSelected(model);
    }

    pub fn confirmDelete(model: *Model) !void {
        return @import("ModelNav.zig").confirmDelete(model);
    }

    pub fn cancelDelete(model: *Model) void {
        return @import("ModelNav.zig").cancelDelete(model);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const model: *Model = @ptrCast(@alignCast(ptr));
        return model.handleEvent(ctx, event);
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) mem.Allocator.Error!vxfw.Surface {
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
        return @import("ModelEvent.zig").handleEvent(model, ctx, event);
    }

    pub fn writeText(surface: *vxfw.Surface, allocator: mem.Allocator, text: []const u8, row: u16, start_col: u16, style: vaxis.Style) mem.Allocator.Error!void {
        for (text, 0..) |ch, i| {
            const col: u16 = start_col + @as(u16, @intCast(i));
            const grapheme = try allocator.dupe(u8, &.{ch});
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = grapheme, .width = 1 },
                .style = style,
            });
        }
    }

    pub fn formatSize(buf: *[32]u8, size: u64) []const u8 {
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

    pub fn formatDuration(buf: *[32]u8, duration_ms: u64) []const u8 {
        if (duration_ms < std.time.ms_per_s) return std.fmt.bufPrint(buf, "{d}ms", .{duration_ms}) catch unreachable;

        const total_seconds = duration_ms / std.time.ms_per_s;
        if (total_seconds < 60) {
            return std.fmt.bufPrint(buf, "{d}s", .{total_seconds}) catch unreachable;
        }

        const minutes = total_seconds / 60;
        const seconds = total_seconds % 60;
        return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ minutes, seconds }) catch unreachable;
    }

    pub fn drawLoading(model: *Model, surface: *vxfw.Surface, allocator: mem.Allocator, width: u16, height: u16) mem.Allocator.Error!void {
        return @import("ModelDraw.zig").drawLoading(model, surface, allocator, width, height);
    }

    pub fn drawEntryLine(model: *Model, surface: *vxfw.Surface, allocator: mem.Allocator, entry_idx: usize, row: u16) mem.Allocator.Error!void {
        return @import("ModelDraw.zig").drawEntryLine(model, surface, allocator, entry_idx, row);
    }

    pub fn draw(model: *Model, ctx: vxfw.DrawContext) mem.Allocator.Error!vxfw.Surface {
        return @import("ModelDraw.zig").draw(model, ctx);
    }
};
