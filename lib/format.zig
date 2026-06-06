const std = @import("std");
const zdu = @import("zdu.zig");

pub fn writeEntry(
    writer: anytype,
    format: zdu.Format,
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

pub fn writeHumanSummary(writer: anytype, result: zdu.ScanResult) !void {
    try writer.writeAll("Summary:\n");
    try writer.print("  Total size: {}\n", .{result.total_size});
    try writer.print("  Files: {}\n", .{result.total_files});
    try writer.print("  Directories: {}\n", .{result.total_dirs});
    try writer.print("  Scan time: {}ms\n", .{result.scan_time_ms});
    try writer.print("  Errors: {}\n", .{result.error_count});
}

pub fn writeJsonSummaryFields(writer: anytype, result: zdu.ScanResult) !void {
    try writer.print("  \"total_size\": {},\n", .{result.total_size});
    try writer.print("  \"total_files\": {},\n", .{result.total_files});
    try writer.print("  \"total_dirs\": {},\n", .{result.total_dirs});
    try writer.print("  \"scan_time_ms\": {},\n", .{result.scan_time_ms});
    try writer.print("  \"error_count\": {}\n", .{result.error_count});
}

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
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

pub fn formatResult(result: zdu.ScanResult, opts: zdu.Options, writer: anytype) !void {
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
