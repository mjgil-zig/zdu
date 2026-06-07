const builtin = @import("builtin");
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const zdu = @import("zdu");
const Cache = @import("Cache.zig");
const Scan = @import("Scan.zig");
const mem = std.mem;
const Model = @import("Model.zig").Model;

    pub fn handleEvent(model: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                if (model.loading != null) {
                    try ctx.tick(Model.loading_tick_ms, model.widget());
                    ctx.redraw = true;
                }
                return;
            },
            .tick => {
                if (model.loading != null) {
                    model.spinner_frame = (model.spinner_frame + 1) % Model.loading_frames.len;
                    model.advanceLoading() catch {};
                    if (model.loading != null) {
                        try ctx.tick(Model.loading_tick_ms, model.widget());
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
                    if (key.text) |text| {
                        if (mem.eql(u8, text, "Y")) {
                            model.confirmDelete() catch {};
                            if (model.loading != null) try ctx.tick(Model.loading_tick_ms, model.widget());
                            ctx.redraw = true;
                            return;
                        }
                        if (mem.eql(u8, text, "n")) {
                            model.cancelDelete();
                            ctx.redraw = true;
                            return;
                        }
                    }
                    if (key.codepoint == vaxis.Key.enter) {
                        model.confirmDelete() catch {};
                        if (model.loading != null) try ctx.tick(Model.loading_tick_ms, model.widget());
                        ctx.redraw = true;
                        return;
                    }
                    if (key.codepoint == vaxis.Key.escape) {
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
                        if (!Model.isSelectableEntry(entry)) {
                            return;
                        } else if (entry.role == .parent) {
                            model.navigateUp() catch {};
                        } else if (entry.is_dir) {
                            model.navigateInto() catch {};
                            if (model.loading != null) try ctx.tick(Model.loading_tick_ms, model.widget());
                        } else {
                            model.deleteSelected() catch {};
                        }
                        ctx.redraw = true;
                    }
                    return;
                }
                if (key.codepoint == vaxis.Key.left) {
                    if (model.parent != null) {
                        model.navigateUp() catch {};
                        ctx.redraw = true;
                    }
                    return;
                }
                if (key.codepoint == vaxis.Key.backspace or key.codepoint == vaxis.Key.escape) {
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
                        if (model.entries[model.selected].is_dir and Model.isSelectableEntry(model.entries[model.selected])) {
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
                                if (model.loading != null) try ctx.tick(Model.loading_tick_ms, model.widget());
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

    pub fn entryIndexForMouseRow(model: *Model, mouse_row: i16) ?usize {
        if (mouse_row < 2) return null;

        const sticky_rows = model.stickyRootRows(1);
        if (sticky_rows > 0 and mouse_row == 2) return null;

        const row_offset: i16 = if (sticky_rows > 0) 3 else 2;
        if (mouse_row < row_offset) return null;

        const row = @as(usize, @intCast(mouse_row - row_offset));
        if (row >= model.last_visible_rows) return null;
        const entry_idx = model.firstScrollableEntryIndex() + row;
        if (entry_idx >= model.entries.len) return null;
        if (!Model.isSelectableEntry(model.entries[entry_idx])) return null;
        return entry_idx;
    }

    pub fn moveSelection(model: *Model, direction: Model.MoveDirection) void {
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
            if (Model.isSelectableEntry(model.entries[idx])) {
                model.selected = idx;
                return;
            }
        }
    }
