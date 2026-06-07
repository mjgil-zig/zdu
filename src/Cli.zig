const builtin = @import("builtin");
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const zdu = @import("zdu");
const Cache = @import("Cache.zig");
const Scan = @import("Scan.zig");
const mem = std.mem;
const Model = @import("Model.zig").Model;

fn parseBoolArg(value: []const u8) ?bool {
    if (mem.eql(u8, value, "true") or mem.eql(u8, value, "1") or mem.eql(u8, value, "yes")) return true;
    if (mem.eql(u8, value, "false") or mem.eql(u8, value, "0") or mem.eql(u8, value, "no")) return false;
    return null;
}

fn benchmarkWorkerLoad(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !u64 {
    const start = std.Io.Timestamp.now(io, .awake);
    _ = try Scan.scanRootTotal(io, allocator, cwd, cache_ttl_seconds, .worker);
    const end = std.Io.Timestamp.now(io, .awake);
    return @as(u64, @intCast(@divFloor(start.durationTo(end).nanoseconds, std.time.ns_per_ms)));
}

fn benchmarkStackLoad(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !u64 {
    const start = std.Io.Timestamp.now(io, .awake);
    _ = try Scan.scanRootTotal(io, allocator, cwd, cache_ttl_seconds, .stack);

    const end = std.Io.Timestamp.now(io, .awake);
    return @as(u64, @intCast(@divFloor(start.durationTo(end).nanoseconds, std.time.ns_per_ms)));
}

fn runBenchmarks(io: std.Io, allocator: mem.Allocator, cwd: []const u8, cache_ttl_seconds: u64) !void {
    const worker_ms = try benchmarkWorkerLoad(io, allocator, cwd, cache_ttl_seconds);
    const stack_ms = try benchmarkStackLoad(io, allocator, cwd, cache_ttl_seconds);
    std.debug.print("worker_thread_ms={d}\nstack_machine_ms={d}\n", .{ worker_ms, stack_ms });
}

fn runNoTui(io: std.Io, allocator: mem.Allocator, config: Config) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const use_cache_path = config.cache_ttl_seconds > 0 or config.refresh_cache or config.parallel;
    const streaming_ok = !use_cache_path and !config.summarize;

    if (streaming_ok) {
        try zdu.scanAndFormat(io, allocator, .{
            .path = config.cwd,
            .format = config.format,
            .summarize = config.summarize,
            .show_hidden = config.show_hidden,
            .max_depth = config.max_depth,
            .max_entries = null,
            .parallel = config.parallel,
            .num_threads = if (config.num_threads == 0) 1 else config.num_threads,
        }, stdout);
        try stdout.flush();
        return;
    }

    const stats: Model.DirStats = if (use_cache_path)
        try Scan.scanRootStats(io, allocator, config.cwd, .{
            .cache_ttl_seconds = config.cache_ttl_seconds,
            .refresh_cache = config.refresh_cache,
            .parallel = config.parallel,
            .num_threads = config.num_threads,
        })
    else blk: {
        const result = try zdu.scan(io, allocator, .{
            .path = config.cwd,
            .format = config.format,
            .summarize = config.summarize,
            .show_hidden = config.show_hidden,
            .max_depth = config.max_depth,
            .max_entries = null,
            .parallel = config.parallel,
            .num_threads = if (config.num_threads == 0) 1 else config.num_threads,
        });
        break :blk Model.DirStats{
            .size = result.total_size,
            .file_count = result.total_files,
            .dir_count = result.total_dirs,
        };
    };

    switch (config.format) {
        .human => {
            var size_buf: [32]u8 = undefined;
            const human = formatSizeHuman(&size_buf, stats.size);
            try stdout.print("{s}\n", .{human});
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"total_size\": {},\n", .{stats.size});
            try stdout.print("  \"total_files\": {},\n", .{stats.file_count});
            try stdout.print("  \"total_dirs\": {}\n", .{stats.dir_count});
            try stdout.writeAll("}\n");
        },
    }
    try stdout.flush();
}

const version = "0.1.0";

const Config = struct {
    cwd: []const u8 = ".",
    cache_ttl_seconds: u64 = 0,
    refresh_cache: bool = false,
    parallel: bool = false,
    num_threads: usize = 0,
    bench: bool = false,
    no_tui: bool = false,
    help: bool = false,
    version: bool = false,
    format: zdu.Format = .human,
    max_depth: ?usize = null,
    show_hidden: bool = false,
    summarize: bool = true,
};

fn formatSizeHuman(buf: *[32]u8, size: u64) []const u8 {
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

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: zdu [options] [path]
        \\
        \\Options:
        \\  -h, --help              Show this help message and exit
        \\  -v, --version           Show version and exit
        \\  --no-tui                Print total size and exit (no interactive UI)
        \\  --format <human|json>   Output format for --no-tui (default: human)
        \\  --max-depth <n>         Limit recursion depth
        \\  --show-hidden           Include dotfiles in output
        \\  --summarize             Show totals only (default for --no-tui)
        \\  --cache-ttl [seconds]   Trust cached stats within TTL (default 60s if no value)
        \\  --refresh-cache         Recompute and rewrite cache entries
        \\  --parallel              Enable parallel directory scanning
        \\  --jobs, -j <n>          Number of parallel workers (implies --parallel)
        \\  --bench                 Run benchmark and exit
        \\
        \\Examples:
        \\  zdu
        \\  zdu /home/user/git
        \\  zdu --no-tui /home/user/git
        \\  zdu --no-tui --format json /home/user/git
        \\  zdu --cache-ttl 300 /home/user/git
        \\  zdu --no-tui --refresh-cache --cache-ttl 1800 /path/to/scan
        \\  zdu --parallel --jobs 8 --refresh-cache --cache-ttl 1800 /path/to/scan
        \\
    );
}

pub fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            config.help = true;
        } else if (mem.eql(u8, arg, "-v") or mem.eql(u8, arg, "--version")) {
            config.version = true;
        } else if (mem.eql(u8, arg, "--cache-ttl")) {
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
        } else if (mem.eql(u8, arg, "--refresh-cache")) {
            config.refresh_cache = true;
        } else if (mem.eql(u8, arg, "--parallel")) {
            config.parallel = true;
        } else if (mem.eql(u8, arg, "--jobs") or mem.eql(u8, arg, "-j")) {
            config.parallel = true;
            if (idx + 1 < args.len) {
                const next_arg = args[idx + 1];
                if (std.fmt.parseInt(usize, next_arg, 10)) |val| {
                    config.num_threads = @max(@as(usize, 1), val);
                    idx += 1;
                } else |_| {
                    config.num_threads = 1;
                }
            } else {
                config.num_threads = 1;
            }
        } else if (mem.eql(u8, arg, "--bench")) {
            config.bench = true;
        } else if (mem.eql(u8, arg, "--no-tui")) {
            config.no_tui = true;
        } else if (mem.eql(u8, arg, "--format")) {
            if (idx + 1 < args.len) {
                const next_arg = args[idx + 1];
                if (mem.eql(u8, next_arg, "json")) {
                    config.format = .json;
                    idx += 1;
                } else if (mem.eql(u8, next_arg, "human")) {
                    config.format = .human;
                    idx += 1;
                }
            }
        } else if (mem.eql(u8, arg, "--max-depth")) {
            if (idx + 1 < args.len) {
                const next_arg = args[idx + 1];
                if (std.fmt.parseInt(usize, next_arg, 10)) |val| {
                    config.max_depth = val;
                    idx += 1;
                } else |_| {}
            }
        } else if (mem.eql(u8, arg, "--show-hidden")) {
            config.show_hidden = true;
        } else if (mem.eql(u8, arg, "--summarize")) {
            config.summarize = true;
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

    if (config.help) {
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;
        try printHelp(stdout);
        try stdout.flush();
        return;
    }

    if (config.version) {
        var stdout_buffer: [64]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print("zdu {s}\n", .{version});
        try stdout.flush();
        return;
    }

    if (config.bench) {
        try runBenchmarks(init.io, allocator, config.cwd, config.cache_ttl_seconds);
        return;
    }
    if (config.no_tui) {
        try runNoTui(init.io, allocator, config);
        return;
    }

    const model = try Model.initLoadingWithOptions(init.io, allocator, config.cwd, .{
        .cache_ttl_seconds = config.cache_ttl_seconds,
        .refresh_cache = config.refresh_cache,
        .parallel = config.parallel,
        .num_threads = config.num_threads,
    });
    defer model.deinit();

    var app: vxfw.App = try .init(init.io, allocator, init.environ_map, &.{});
    defer app.deinit();

    try app.run(model.widget(), .{});
}
