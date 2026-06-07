const std = @import("std");
const Cli = @import("Cli.zig");

pub fn main(init: std.process.Init) !void {
    return Cli.main(init);
}

test {
    _ = @import("main_test.zig");
}
