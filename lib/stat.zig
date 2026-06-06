const std = @import("std");
const mem = std.mem;

const builtin = @import("builtin");

pub const have_posix_stat = builtin.link_libc and (builtin.os.tag == .linux or builtin.os.tag == .macos);
pub const PosixStat = if (have_posix_stat) std.c.Stat else struct {
    size: i64 = 0,
    mode: u32 = 0,
    blocks: i64 = 0,
};

pub const c_stat = if (have_posix_stat) struct {
    extern "c" fn fstatat(dirfd: std.c.fd_t, path: [*:0]const u8, buf: *std.c.Stat, flag: u32) c_int;
} else struct {};

pub fn posixStatIsRegular(stat: PosixStat) bool {
    if (comptime !have_posix_stat) return false;
    return std.c.S.ISREG(stat.mode);
}

pub fn posixStatIsDirectory(stat: PosixStat) bool {
    if (comptime !have_posix_stat) return false;
    return std.c.S.ISDIR(stat.mode);
}

pub fn posixStatApparentSize(stat: PosixStat) u64 {
    return if (stat.size < 0) 0 else @intCast(stat.size);
}

pub fn posixStatAllocatedSize(stat: PosixStat) u64 {
    const apparent_size = posixStatApparentSize(stat);
    if (!posixStatIsRegular(stat)) return apparent_size;
    if (stat.blocks <= 0) return apparent_size;
    return @as(u64, @intCast(stat.blocks)) * 512;
}

pub fn cStatAt(dir: std.Io.Dir, sub_path: []const u8) ?PosixStat {
    if (comptime !have_posix_stat) return null;

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (sub_path.len + 1 > path_buf.len) return null;
    @memcpy(path_buf[0..sub_path.len], sub_path);
    path_buf[sub_path.len] = 0;
    var stat: PosixStat = undefined;
    if (c_stat.fstatat(dir.handle, @ptrCast(path_buf[0..sub_path.len :0].ptr), &stat, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
        return null;
    }
    return stat;
}

pub fn fileSizeOnDiskAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
    return switch (builtin.os.tag) {
        .linux => if (builtin.link_libc) fileSizeOnDiskWithLibcAt(dir, sub_path, io) else fileSizeOnDiskFallbackAt(dir, sub_path, io),
        .macos => if (builtin.cpu.arch == .x86_64)
            fileSizeOnDiskFallbackAt(dir, sub_path, io)
        else if (builtin.link_libc)
            fileSizeOnDiskWithLibcAt(dir, sub_path, io)
        else
            fileSizeOnDiskFallbackAt(dir, sub_path, io),
        else => fileSizeOnDiskFallbackAt(dir, sub_path, io),
    };
}

pub fn fileSizeOnDiskWithLibcAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
    if (comptime !have_posix_stat) return fileSizeOnDiskFallbackAt(dir, sub_path, io);

    const stat = cStatAt(dir, sub_path) orelse return fileSizeOnDiskFallbackAt(dir, sub_path, io);
    return posixStatAllocatedSize(stat);
}

pub fn fileSizeOnDiskFallbackAt(dir: std.Io.Dir, sub_path: []const u8, io: std.Io) u64 {
    const stat = dir.statFile(io, sub_path, .{ .follow_symlinks = false }) catch return 0;
    return stat.size;
}
