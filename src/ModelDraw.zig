const builtin = @import("builtin");
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const zdu = @import("zdu");
const Cache = @import("Cache.zig");
const Scan = @import("Scan.zig");
const mem = std.mem;
const Model = @import("Model.zig").Model;

pub fn draw(model: *Model, ctx: vxfw.DrawContext) mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 80;
    const height = ctx.max.height orelse 24;

    var surface = try vxfw.Surface.init(ctx.arena, model.widget(), .{ .width = width, .height = height });

    const title = try std.fmt.allocPrint(ctx.arena, "zdu - {s}", .{model.cwd});
    try Model.writeText(&surface, ctx.arena, title, 0, 0, .{ .reverse = true });

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

    const help = "up/down: navigate | Enter/Right: open/del | Delete: del dir | Backspace/Left/Esc: go up | q: quit";
    try Model.writeText(&surface, ctx.arena, help, height -| 1, 0, .{ .fg = .{ .index = 8 } });

    if (model.confirm_delete) |confirm| {
        const prefix_text = try std.fmt.allocPrint(ctx.arena, "Delete {s}? [", .{confirm.path});
        const suffix_text = "/n]";
        const dialog_len = prefix_text.len + 1 + suffix_text.len;
        const dialog_row = height / 2 -| 1;
        const dialog_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(dialog_len)))) / 2));
        const dialog_style: vaxis.Style = .{ .bg = .{ .index = 1 }, .fg = .{ .index = 15 } };
        const confirm_style: vaxis.Style = .{ .bg = .{ .index = 15 }, .fg = .{ .index = 1 }, .bold = true };
        try Model.writeText(&surface, ctx.arena, prefix_text, dialog_row, dialog_col, dialog_style);
        try Model.writeText(&surface, ctx.arena, "Y", dialog_row, dialog_col + @as(u16, @intCast(prefix_text.len)), confirm_style);
        try Model.writeText(&surface, ctx.arena, suffix_text, dialog_row, dialog_col + @as(u16, @intCast(prefix_text.len + 1)), dialog_style);
    }

    return surface;
}

pub fn drawLoading(model: *Model, surface: *vxfw.Surface, allocator: mem.Allocator, width: u16, height: u16) mem.Allocator.Error!void {
    var loading = &model.loading.?;
    const total = model.entries.len;
    const done = loading.processed;
    const processed_bytes = loading.processed_bytes;
    const processed_dirs = loading.processed_dirs;
    const elapsed_ns = @max(@as(i128, 0), loading.started_at.durationTo(std.Io.Timestamp.now(model.io, .awake)).nanoseconds);
    var elapsed_buf: [32]u8 = undefined;
    const elapsed_text = Model.formatDuration(&elapsed_buf, @as(u64, @intCast(elapsed_ns / std.time.ns_per_ms)));
    var processed_buf: [32]u8 = undefined;
    const processed_text = Model.formatSize(&processed_buf, processed_bytes);
    const dir_label = if (processed_dirs == 1) "directory" else "directories";

    const title = "Model.Loading directory";
    const spinner = Model.loading_frames[model.spinner_frame];
    const status = try std.fmt.allocPrint(allocator, "{s} {d}/{d} entries", .{ spinner, done, total });
    const detail = try std.fmt.allocPrint(allocator, "Processed: {s}", .{processed_text});
    const meta = try std.fmt.allocPrint(allocator, "{d} {s}   Elapsed: {s}", .{ processed_dirs, dir_label, elapsed_text });

    const start_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(title.len)))) / 2));
    const status_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(status.len)))) / 2));
    const detail_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(detail.len)))) / 2));
    const meta_col = @as(u16, @intCast((width -| @min(width, @as(u16, @intCast(meta.len)))) / 2));
    const center_row = height / 2;

    try Model.writeText(surface, allocator, title, center_row -| 2, start_col, .{ .fg = .{ .index = 15 }, .bold = true });
    try Model.writeText(surface, allocator, status, center_row -| 1, status_col, .{ .fg = .{ .index = 12 } });
    try Model.writeText(surface, allocator, detail, center_row, detail_col, .{ .fg = .{ .index = 10 } });
    try Model.writeText(surface, allocator, meta, center_row + 1, meta_col, .{ .fg = .{ .index = 7 } });
}

pub fn drawEntryLine(model: *Model, surface: *vxfw.Surface, allocator: mem.Allocator, entry_idx: usize, row: u16) mem.Allocator.Error!void {
    const entry = model.entries[entry_idx];
    const prefix = switch (entry.role) {
        .summary => "[ROOT]",
        else => if (entry.is_dir) "[DIR] " else "[FILE]",
    };
    var size_buf: [32]u8 = undefined;
    const size_str = Model.formatSize(&size_buf, entry.size);
    const line = if (entry.is_dir) blk: {
        const file_label = if (entry.file_count == 1) "file" else "files";
        if (entry.name.len == 0) {
            break :blk try std.fmt.allocPrint(allocator, "{s} {s:>10} {d:>8} {s}", .{ prefix, size_str, entry.file_count, file_label });
        }
        break :blk try std.fmt.allocPrint(allocator, "{s} {s:>10} {d:>8} {s} {s}", .{ prefix, size_str, entry.file_count, file_label, entry.name });
    } else try std.fmt.allocPrint(allocator, "{s} {s:>10} {s}", .{ prefix, size_str, entry.name });

    const is_selected = entry_idx == model.selected and Model.isSelectableEntry(entry);
    const style: vaxis.Style = if (is_selected) .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 } } else .{};
    try Model.writeText(surface, allocator, line, row, 0, style);
}
