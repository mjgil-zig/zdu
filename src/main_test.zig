const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;const zdu = @import("zdu");
const Cache = @import("Cache.zig");
const Scan = @import("Scan.zig");
const Model = @import("Model.zig").Model;
const Cli = @import("Cli.zig");

const parseArgs = Cli.parseArgs;
const main = Cli.main;


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
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(dir_path);

    Cache.writeCachedDirSize(dir_path, 1234, 60, std.testing.allocator);
    const cached = Scan.readCachedDirSize(dir_path, std.testing.allocator);

    if (cached == null) return error.SkipZigTest;
    try std.testing.expectEqual(@as(?u64, 1234), cached);

    Cache.clearCachedDirSize(dir_path, std.testing.allocator);
}

test "Windows ADS relative paths get explicit current-directory prefix" {
    try std.testing.expect(Cache.windowsPathNeedsDotPrefix("relative"));
    try std.testing.expect(Cache.windowsPathNeedsDotPrefix("relative\\path"));
    try std.testing.expect(!Cache.windowsPathNeedsDotPrefix("."));
    try std.testing.expect(!Cache.windowsPathNeedsDotPrefix(".."));
    try std.testing.expect(!Cache.windowsPathNeedsDotPrefix("C:\\absolute"));
    try std.testing.expect(!Cache.windowsPathNeedsDotPrefix("/absolute"));
    try std.testing.expect(!Cache.windowsPathNeedsDotPrefix("\\\\server\\share"));
}

test "Windows ADS path helper appends named data stream suffix" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const base_ascii = "C:\\tmp\\zdu-dir";
    var base: [base_ascii.len]u16 = undefined;
    for (base_ascii, 0..) |ch, idx| base[idx] = ch;

    var buf: [256]u16 = undefined;
    const ads_path = Cache.windowsMakeAdsPathW(buf[0..], base[0..], Cache.dir_stats_xattr_name) orelse return error.SkipZigTest;

    try zduTestExpectUtf16AsciiEqual(
        "C:\\tmp\\zdu-dir:user.zdu.dir_stats.v3:$DATA",
        ads_path[0.."C:\\tmp\\zdu-dir:user.zdu.dir_stats.v3:$DATA".len],
    );
}

test "Windows ADS cache round trip works by path and directory handle" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root");

    const root_path = try zduTestTmpPath(allocator, &tmp, "root");
    defer allocator.free(root_path);

    Cache.clearCachedDirStats(root_path, allocator);

    const written: Model.DirStats = .{ .size = 4321, .file_count = 7, .dir_count = 3 };
    Cache.writeCachedDirStats(root_path, written, 60, allocator);

    const by_path = Cache.readCachedDirStats(root_path, allocator) orelse return error.SkipZigTest;
    try std.testing.expectEqual(written.size, by_path.size);
    try std.testing.expectEqual(written.file_count, by_path.file_count);
    try std.testing.expectEqual(written.dir_count, by_path.dir_count);

    var dir = std.Io.Dir.cwd().openDir(std.testing.io, root_path, .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(std.testing.io);

    const by_handle = Cache.readCachedDirStatsFd(dir) orelse return error.SkipZigTest;
    try std.testing.expectEqual(written.size, by_handle.size);
    try std.testing.expectEqual(written.file_count, by_handle.file_count);
    try std.testing.expectEqual(written.dir_count, by_handle.dir_count);

    Cache.clearCachedDirStats(root_path, allocator);
    try std.testing.expect(Cache.readCachedDirStats(root_path, allocator) == null);
}

test "Windows ADS cache falls back to legacy v2 size stream" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root");

    const root_path = try zduTestTmpPath(allocator, &tmp, "root");
    defer allocator.free(root_path);

    const now = Cache.currentTimestampSeconds() orelse return error.SkipZigTest;

    var legacy_record: [16]u8 = undefined;
    zduTestEncodeCacheRecord(&legacy_record, 9876, now + 60);

    Cache.clearCachedDirStats(root_path, allocator);
    if (!Cache.windowsWriteAds(root_path, Cache.dir_size_xattr_name, legacy_record[0..], allocator)) return error.SkipZigTest;

    const cached = Cache.readCachedDirStats(root_path, allocator) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 9876), cached.size);
    try std.testing.expectEqual(@as(u64, 0), cached.file_count);
    try std.testing.expectEqual(@as(u64, 0), cached.dir_count);
}

test "Windows ADS cache rejects wrong-length stats stream" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root");

    const root_path = try zduTestTmpPath(allocator, &tmp, "root");
    defer allocator.free(root_path);

    Cache.clearCachedDirStats(root_path, allocator);

    var malformed_record: [31]u8 = undefined;
    @memset(malformed_record[0..], 0xaa);
    if (!Cache.windowsWriteAds(root_path, Cache.dir_stats_xattr_name, malformed_record[0..], allocator)) return error.SkipZigTest;

    try std.testing.expect(Cache.readCachedDirStats(root_path, allocator) == null);
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
        .linux, .macos, .windows => {},
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

    const remaining_size = Scan.fileSizeOnDisk(root_file_path, std.testing.allocator, std.testing.io);
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
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(root_path);

    Cache.clearCachedDirStats(root_path, std.testing.allocator);

    var model: Model = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .cwd = root_path,
    };

    model.propagateDeletedStats(.{ .size = 1, .file_count = 1 }, root_path);
    try std.testing.expect(Cache.readCachedDirStats(root_path, std.testing.allocator) == null);
}

test "delete propagation skips stale undersized cache" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(root_path);

    Cache.writeCachedDirStats(root_path, .{ .size = 1, .file_count = 1, .dir_count = 1 }, 60, std.testing.allocator);

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
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sub");

    const root_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(root_path);
    const child_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sub" });
    defer std.testing.allocator.free(child_path);
    const deleted_path = try std.fs.path.join(std.testing.allocator, &.{ child_path, "victim.txt" });
    defer std.testing.allocator.free(deleted_path);

    Cache.writeCachedDirStats(root_path, .{ .size = 100, .file_count = 3, .dir_count = 2 }, 60, std.testing.allocator);
    Cache.writeCachedDirStats(child_path, .{ .size = 70, .file_count = 2, .dir_count = 1 }, 60, std.testing.allocator);

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



test "parseArgs: --help" {
    const args = &[_][]const u8{ "zdu", "--help" };
    const config = try parseArgs(args);
    try std.testing.expect(config.help);
}

test "parseArgs: -h" {
    const args = &[_][]const u8{ "zdu", "-h" };
    const config = try parseArgs(args);
    try std.testing.expect(config.help);
}

test "parseArgs: --version" {
    const args = &[_][]const u8{ "zdu", "--version" };
    const config = try parseArgs(args);
    try std.testing.expect(config.version);
}

test "parseArgs: -v" {
    const args = &[_][]const u8{ "zdu", "-v" };
    const config = try parseArgs(args);
    try std.testing.expect(config.version);
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

test "parseArgs: --format json" {
    const args = &[_][]const u8{ "zdu", "--no-tui", "--format", "json", "/home/user" };
    const config = try parseArgs(args);
    try std.testing.expect(config.no_tui);
    try std.testing.expectEqual(zdu.Format.json, config.format);
    try std.testing.expectEqualStrings("/home/user", config.cwd);
}

test "parseArgs: --format human" {
    const args = &[_][]const u8{ "zdu", "--no-tui", "--format", "human", "/home/user" };
    const config = try parseArgs(args);
    try std.testing.expect(config.no_tui);
    try std.testing.expectEqual(zdu.Format.human, config.format);
}

test "parseArgs: --max-depth" {
    const args = &[_][]const u8{ "zdu", "--no-tui", "--max-depth", "2", "/home/user" };
    const config = try parseArgs(args);
    try std.testing.expect(config.no_tui);
    try std.testing.expectEqual(@as(?usize, 2), config.max_depth);
}

test "parseArgs: --show-hidden" {
    const args = &[_][]const u8{ "zdu", "--no-tui", "--show-hidden", "/home/user" };
    const config = try parseArgs(args);
    try std.testing.expect(config.no_tui);
    try std.testing.expect(config.show_hidden);
}

test "parseArgs: --summarize" {
    const args = &[_][]const u8{ "zdu", "--no-tui", "--summarize", "/home/user" };
    const config = try parseArgs(args);
    try std.testing.expect(config.no_tui);
    try std.testing.expect(config.summarize);
}

test "parallel scan tasks are sorted by cached file count" {
    var tasks = [_]Scan.ParallelScanTask{
        .{ .path = @constCast("small"), .estimate_files = 1 },
        .{ .path = @constCast("large"), .estimate_files = 10 },
        .{ .path = @constCast("middle"), .estimate_files = 5 },
    };

    Scan.sortParallelTasks(tasks[0..]);

    try std.testing.expectEqualStrings("large", tasks[0].path);
    try std.testing.expectEqualStrings("middle", tasks[1].path);
    try std.testing.expectEqualStrings("small", tasks[2].path);
}

fn zduTestExpectUtf16AsciiEqual(expected: []const u8, actual: []const u16) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |ch, idx| {
        try std.testing.expectEqual(@as(u16, ch), actual[idx]);
    }
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
    return Scan.readCachedDirSize(path, allocator) orelse error.TestUnexpectedResult;
}

fn zduTestRequireCachedStats(path: []const u8, allocator: mem.Allocator) !Model.DirStats {
    return Cache.readCachedDirStats(path, allocator) orelse error.TestUnexpectedResult;
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
    Cache.clearCachedDirStats(path, allocator);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.setxattr(
                path_z.ptr,
                Cache.dir_size_xattr_name,
                bytes.ptr,
                bytes.len,
                0,
            );
            if (std.os.linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
        },
        .macos => {
            const rc = Cache.darwin_xattr.setxattr(
                path_z.ptr,
                Cache.dir_size_xattr_name,
                bytes.ptr,
                bytes.len,
                0,
                0,
            );
            if (std.c.errno(rc) != .SUCCESS) return error.SkipZigTest;
        },
        .windows => {
            if (!Cache.windowsWriteAds(path, Cache.dir_size_xattr_name, bytes, allocator)) return error.SkipZigTest;
        },
        else => return error.SkipZigTest,
    }
}

fn zduTestSetRawDirStatsXattr(
    path: []const u8,
    bytes: []const u8,
    allocator: mem.Allocator,
) !void {
    Cache.clearCachedDirStats(path, allocator);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.setxattr(
                path_z.ptr,
                Cache.dir_stats_xattr_name,
                bytes.ptr,
                bytes.len,
                0,
            );
            if (std.os.linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
        },
        .macos => {
            const rc = Cache.darwin_xattr.setxattr(
                path_z.ptr,
                Cache.dir_stats_xattr_name,
                bytes.ptr,
                bytes.len,
                0,
                0,
            );
            if (std.c.errno(rc) != .SUCCESS) return error.SkipZigTest;
        },
        .windows => {
            if (!Cache.windowsWriteAds(path, Cache.dir_stats_xattr_name, bytes, allocator)) return error.SkipZigTest;
        },
        else => return error.SkipZigTest,
    }
}


test "loading writes each nested directory cache with that directory's own size" {
    switch (builtin.os.tag) {
        .linux, .macos, .windows => {},
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

    Cache.clearCachedDirSize(a_path, allocator);
    Cache.clearCachedDirSize(b_path, allocator);
    Cache.clearCachedDirSize(c_path, allocator);

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
        .linux, .macos, .windows => {},
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

    Cache.clearCachedDirSize(root_path, allocator);
    Cache.clearCachedDirSize(a_path, allocator);

    const stats = try Scan.scanRootStats(std.testing.io, allocator, root_path, .{
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
        .linux, .macos, .windows => {},
        else => return error.SkipZigTest,
    }

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root/d");

    const dir_path = try zduTestTmpPath(allocator, &tmp, "root/d");
    defer allocator.free(dir_path);

    Cache.clearCachedDirSize(dir_path, allocator);

    const written_stats: Model.DirStats = .{ .size = 1234, .file_count = 9, .dir_count = 2 };
    Cache.writeCachedDirStats(dir_path, written_stats, 60, allocator);

    const fresh = Cache.readCachedDirStats(dir_path, allocator) orelse return error.SkipZigTest;
    try std.testing.expectEqual(written_stats.size, fresh.size);
    try std.testing.expectEqual(written_stats.file_count, fresh.file_count);
    try std.testing.expectEqual(written_stats.dir_count, fresh.dir_count);

    var dir = std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(std.testing.io);

    const fresh_fd = Cache.readCachedDirStatsFd(dir) orelse return error.SkipZigTest;
    try std.testing.expectEqual(written_stats.size, fresh_fd.size);
    try std.testing.expectEqual(written_stats.file_count, fresh_fd.file_count);
    try std.testing.expectEqual(written_stats.dir_count, fresh_fd.dir_count);

    const now = Cache.currentTimestampSeconds() orelse return error.SkipZigTest;

    var expired_record: [32]u8 = undefined;
    zduTestEncodeStatsCacheRecord(
        &expired_record,
        .{ .size = 5678, .file_count = 3, .dir_count = 1 },
        if (now == 0) 0 else now - 1,
    );

    try zduTestSetRawDirStatsXattr(dir_path, expired_record[0..], allocator);
    try std.testing.expect(Cache.readCachedDirStats(dir_path, allocator) == null);

    var malformed_record: [31]u8 = undefined;
    @memset(malformed_record[0..], 0xaa);

    try zduTestSetRawDirStatsXattr(dir_path, malformed_record[0..], allocator);
    try std.testing.expect(Cache.readCachedDirStats(dir_path, allocator) == null);

    var legacy_record: [16]u8 = undefined;
    zduTestEncodeCacheRecord(
        &legacy_record,
        7777,
        now + 60,
    );

    try zduTestSetRawDirSizeXattr(dir_path, legacy_record[0..], allocator);
    const legacy = Cache.readCachedDirStats(dir_path, allocator) orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u64, 7777), legacy.size);
    try std.testing.expectEqual(@as(u64, 0), legacy.file_count);
    try std.testing.expectEqual(@as(u64, 0), legacy.dir_count);
}

test "expired dir size cache is recomputed and refreshed" {
    switch (builtin.os.tag) {
        .linux, .macos, .windows => {},
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

    const now = Cache.currentTimestampSeconds() orelse return error.SkipZigTest;

    var expired_record: [16]u8 = undefined;
    zduTestEncodeCacheRecord(
        &expired_record,
        999_999_999,
        if (now == 0) 0 else now - 1,
    );

    try zduTestSetRawDirSizeXattr(dir_path, expired_record[0..], allocator);

    const stats = Scan.computeDirStats(
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
        .linux, .macos, .windows => {},
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
    Cache.writeCachedDirStats(dir_path, stale, 1800, allocator);

    const refreshed = Scan.computeDirStatsRefreshing(dir_path, allocator, std.testing.io, 1800);
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
        .linux, .macos, .windows => {},
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

    const serial = try Scan.scanRootStats(std.testing.io, allocator, root_path, .{
        .cache_ttl_seconds = 1800,
        .refresh_cache = true,
        .parallel = false,
        .num_threads = 1,
    });

    const parallel = try Scan.scanRootStats(std.testing.io, allocator, root_path, .{
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

test "dynamic parallel scan splits nested children and waits before parent cache write" {
    switch (builtin.os.tag) {
        .linux, .macos, .windows => {},
        else => return error.SkipZigTest,
    }

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root/huge/a");
    try tmp.dir.createDirPath(std.testing.io, "root/huge/b");
    try zduTestWriteFile(&tmp, "root/huge/a/one.txt", "1");
    try zduTestWriteFile(&tmp, "root/huge/b/two.txt", "22");
    try zduTestWriteFile(&tmp, "root/huge/local.txt", "333");

    const huge_path = try zduTestTmpPath(allocator, &tmp, "root/huge");
    defer allocator.free(huge_path);
    const a_path = try zduTestTmpPath(allocator, &tmp, "root/huge/a");
    defer allocator.free(a_path);
    const b_path = try zduTestTmpPath(allocator, &tmp, "root/huge/b");
    defer allocator.free(b_path);

    Cache.writeCachedDirStats(a_path, .{ .size = 999_999, .file_count = Model.dynamic_split_min_files, .dir_count = 1 }, 1800, allocator);
    Cache.writeCachedDirStats(b_path, .{ .size = 888_888, .file_count = Model.dynamic_split_min_files, .dir_count = 1 }, 1800, allocator);

    const inputs = [_]Scan.DynamicScanInput{
        .{ .path = huge_path, .estimate_files = Model.dynamic_split_min_files * 2 },
    };

    const results = try Scan.computeDynamicScanInputs(std.testing.io, allocator, inputs[0..], .{
        .cache_ttl_seconds = 1800,
        .refresh_cache = true,
        .parallel = true,
        .num_threads = 2,
    }, 2);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u64, 3), results[0].file_count);
    try std.testing.expectEqual(@as(u64, 3), results[0].dir_count);

    const huge_cached = try zduTestRequireCachedStats(huge_path, allocator);
    try std.testing.expectEqual(results[0].size, huge_cached.size);
    try std.testing.expectEqual(@as(u64, 3), huge_cached.file_count);
    try std.testing.expectEqual(@as(u64, 3), huge_cached.dir_count);

    const a_cached = try zduTestRequireCachedStats(a_path, allocator);
    const b_cached = try zduTestRequireCachedStats(b_path, allocator);
    try std.testing.expectEqual(@as(u64, 1), a_cached.file_count);
    try std.testing.expectEqual(@as(u64, 1), b_cached.file_count);
    try std.testing.expect(a_cached.size != 999_999);
    try std.testing.expect(b_cached.size != 888_888);
}

test "parallel worker count can exceed initial task count for dynamic splitting" {
    try std.testing.expectEqual(@as(usize, 4), Scan.resolvedWorkerCount(true, 4, 1));
    try std.testing.expectEqual(@as(usize, 3), Model.entryScanWorkerCount(true, 3, 1));
    try std.testing.expectEqual(@as(usize, 1), Scan.resolvedWorkerCount(true, 4, 0));
    try std.testing.expectEqual(@as(usize, 1), Model.entryScanWorkerCount(false, 3, 8));
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

    Cache.writeCachedDirStats(d_path, .{ .size = 999_999, .file_count = 99, .dir_count = 99 }, 1800, allocator);

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

test "integration: --help prints usage" {
    const allocator = std.testing.allocator;
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "./zig-out/bin/zdu", "--help" },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--no-tui") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--version") != null);
}

test "integration: --version prints version" {
    const allocator = std.testing.allocator;
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "./zig-out/bin/zdu", "--version" },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "zdu") != null);
}

test "integration: --no-tui --summarize prints summary" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "a/b");
    var f1 = try tmp.dir.createFile(std.testing.io, "a/file1.txt", .{});
    defer f1.close(std.testing.io);
    try f1.writeStreamingAll(std.testing.io, "hello");
    var f2 = try tmp.dir.createFile(std.testing.io, "a/b/file2.txt", .{});
    defer f2.close(std.testing.io);
    try f2.writeStreamingAll(std.testing.io, "world");

    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
    });
    defer allocator.free(path);

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "./zig-out/bin/zdu", "--no-tui", "--format", "json", "--summarize", path },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "total_size") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "total_files") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "total_dirs") != null);
}

test "Escape cancels delete confirmation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try zduTestWriteFile(&tmp, "victim.txt", "delete me");

    const root_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(root_path);

    const model = try Model.init(std.testing.io, std.testing.allocator, root_path);
    defer model.deinit();

    model.selected = findEntryIndex(model, "victim.txt") orelse return error.SkipZigTest;
    try model.deleteSelected();
    try std.testing.expect(model.confirm_delete != null);

    var ctx = testEventContext(std.testing.allocator, std.testing.io);
    defer ctx.cmds.deinit(std.testing.allocator);

    try model.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });

    try std.testing.expect(model.confirm_delete == null);
    try std.testing.expect(ctx.redraw);

    // File should still exist
    const victim_check_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "victim.txt" });
    defer std.testing.allocator.free(victim_check_path);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, victim_check_path, .{});
}

test "right-click on directory opens delete confirmation" {
    var entries = [_]Model.Entry{
        .{ .name = @constCast(""), .path = @constCast("/tmp"), .size = 10, .is_dir = true, .role = .summary },
        .{ .name = @constCast("subdir"), .path = @constCast("/tmp/subdir"), .size = 5, .is_dir = true, .file_count = 0, .dir_count = 1 },
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
        .button = .right,
        .row = 3,
        .col = 0,
        .mods = .{},
    } });

    try std.testing.expect(model.confirm_delete != null);
    try std.testing.expect(model.confirm_delete.?.is_dir);
    try std.testing.expect(ctx.redraw);

    // Clean up allocated confirm_delete path
    model.cancelDelete();
}
