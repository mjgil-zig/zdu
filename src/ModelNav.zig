const builtin = @import("builtin");
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const zdu = @import("zdu");
const Cache = @import("Cache.zig");
const Scan = @import("Scan.zig");
const mem = std.mem;
const Model = @import("Model.zig").Model;

pub fn navigateInto(model: *Model) !void {
    if (model.selected >= model.entries.len) return;
    const entry = model.entries[model.selected];
    if (!entry.is_dir or !Model.isSelectableEntry(entry)) return;

    const next_cwd = try model.allocEntryPath(entry);
    errdefer model.allocator.free(next_cwd);

    const io = model.io;
    const allocator = model.allocator;
    const cache_ttl_seconds = model.cache_ttl_seconds;
    const refresh_cache = model.refresh_cache;
    const parallel = model.parallel;
    const num_threads = model.num_threads;

    const parent = try allocator.create(Model);
    errdefer allocator.destroy(parent);
    parent.* = model.*;

    model.* = .{
        .io = io,
        .allocator = allocator,
        .cwd = next_cwd,
        .parent = parent,
        .cache_ttl_seconds = cache_ttl_seconds,
        .refresh_cache = refresh_cache,
        .parallel = parallel,
        .num_threads = num_threads,
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
        .stats = Model.statsFromEntry(entry),
        .entry_index = model.selected,
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
        model.propagateDeletedStats(confirm.stats, confirm.path);
        model.removeEntryAt(confirm.entry_index) catch return;
    }
}

pub fn cancelDelete(model: *Model) void {
    if (model.confirm_delete) |confirm| {
        model.allocator.free(confirm.path);
        model.confirm_delete = null;
    }
}
