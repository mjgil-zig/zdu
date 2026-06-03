const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;

const c_time = if (builtin.os.tag == .macos) struct {
    extern "c" fn time(timer: ?*i64) i64;
} else struct {};

const darwin_xattr = if (builtin.os.tag == .macos) struct {
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
} else struct {};

const windows_ads = if (builtin.os.tag == .windows) struct {
    const HANDLE = std.os.windows.HANDLE;
    const DWORD = u32;

    const GENERIC_READ: DWORD = 0x80000000;
    const GENERIC_WRITE: DWORD = 0x40000000;
    const FILE_SHARE_READ: DWORD = 0x00000001;
    const FILE_SHARE_WRITE: DWORD = 0x00000002;
    const FILE_SHARE_DELETE: DWORD = 0x00000004;
    const CREATE_ALWAYS: DWORD = 2;
    const OPEN_EXISTING: DWORD = 3;
    const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
    const FILE_NAME_NORMALIZED: DWORD = 0x00000000;
    const VOLUME_NAME_DOS: DWORD = 0x00000000;

    const share_all = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;

    extern "kernel32" fn CloseHandle(hObject: HANDLE) c_int;
    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) HANDLE;
    extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) c_int;
    extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) c_int;
    extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *std.os.windows.FILETIME) void;
    extern "kernel32" fn GetFinalPathNameByHandleW(
        hFile: HANDLE,
        lpszFilePath: [*]u16,
        cchFilePath: DWORD,
        dwFlags: DWORD,
    ) DWORD;
    extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: *DWORD,
        lpOverlapped: ?*anyopaque,
    ) c_int;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: *DWORD,
        lpOverlapped: ?*anyopaque,
    ) c_int;

    fn isInvalidHandle(handle: HANDLE) bool {
        return @intFromPtr(handle) == std.math.maxInt(usize);
    }
} else struct {};

pub const DirStats = struct {
    size: u64 = 0,
    file_count: u64 = 0,
    dir_count: u64 = 0,
};

const CachedDirSize = struct {
    size: u64,
    expires_at: u64,
};

const CachedDirStats = struct {
    size: u64,
    file_count: u64,
    dir_count: u64,
    expires_at: u64,
};

pub const dir_size_xattr_name: [:0]const u8 = "user.zdu.dir_size.v2";
pub const dir_stats_xattr_name: [:0]const u8 = "user.zdu.dir_stats.v3";

pub fn readCachedDirSize(path: []const u8, allocator: mem.Allocator) ?u64 {
    if (readCachedDirStats(path, allocator)) |stats| return stats.size;
    return null;
}

pub fn readCachedDirSizeFd(dir: std.Io.Dir) ?u64 {
    if (readCachedDirStatsFd(dir)) |stats| return stats.size;
    return null;
}

pub const windows_max_path_wchars = 32768;
pub const windows_ads_path_extra_wchars = 128;

pub fn windowsPathNeedsDotPrefix(path: []const u8) bool {
    if (path.len == 0) return false;
    if (mem.eql(u8, path, ".") or mem.eql(u8, path, "..")) return false;
    if (path[0] == '\\' or path[0] == '/') return false;
    if (path.len >= 2 and path[1] == ':') return false;
    return true;
}

pub fn windowsAllocAdsPath(allocator: mem.Allocator, path: []const u8, stream_name: [:0]const u8) ?[:0]u16 {
    if (comptime builtin.os.tag != .windows) return null;

    const prefix = if (windowsPathNeedsDotPrefix(path)) ".\\" else "";
    const ads_path_utf8 = std.fmt.allocPrint(allocator, "{s}{s}:{s}:$DATA", .{ prefix, path, stream_name }) catch return null;
    defer allocator.free(ads_path_utf8);

    return std.unicode.utf8ToUtf16LeAllocZ(allocator, ads_path_utf8) catch return null;
}

pub fn windowsMakeAdsPathW(buf: []u16, base_path: []const u16, stream_name: [:0]const u8) ?[:0]u16 {
    if (comptime builtin.os.tag != .windows) return null;

    const stream_type = ":$DATA";
    const needed = base_path.len + 1 + stream_name.len + stream_type.len + 1;
    if (needed > buf.len) return null;

    var idx: usize = 0;
    @memcpy(buf[idx..][0..base_path.len], base_path);
    idx += base_path.len;

    buf[idx] = ':';
    idx += 1;

    for (stream_name) |ch| {
        buf[idx] = ch;
        idx += 1;
    }

    for (stream_type) |ch| {
        buf[idx] = ch;
        idx += 1;
    }

    buf[idx] = 0;
    return buf[0..idx :0];
}

pub fn windowsStripVerbatimPrefix(path: []const u16) []const u16 {
    const prefix = "\\\\?\\";
    if (path.len > prefix.len and
        path[0] == '\\' and path[1] == '\\' and
        path[2] == '?' and path[3] == '\\')
    {
        const rest = path[prefix.len..];
        // \\?\UNC\server\share -> \\server\share
        if (rest.len > 4 and
            (rest[0] == 'U' or rest[0] == 'u') and
            (rest[1] == 'N' or rest[1] == 'n') and
            (rest[2] == 'C' or rest[2] == 'c') and
            rest[3] == '\\')
        {
            return path[prefix.len - 2 ..];
        }
        return rest;
    }
    return path;
}

pub fn windowsAdsPathFromDirHandle(dir: std.Io.Dir, stream_name: [:0]const u8, buf: []u16) ?[:0]u16 {
    if (comptime builtin.os.tag != .windows) return null;

    var path_buf: [windows_max_path_wchars]u16 = undefined;
    const len_raw = windows_ads.GetFinalPathNameByHandleW(
        dir.handle,
        path_buf[0..].ptr,
        @intCast(path_buf.len),
        windows_ads.FILE_NAME_NORMALIZED | windows_ads.VOLUME_NAME_DOS,
    );
    if (len_raw == 0) return null;

    const len: usize = @intCast(len_raw);
    if (len >= path_buf.len) return null;

    const normalized = windowsStripVerbatimPrefix(path_buf[0..len]);
    return windowsMakeAdsPathW(buf, normalized, stream_name);
}

pub fn windowsReadAdsPathW(path_w: [*:0]const u16, buf: []u8) bool {
    if (comptime builtin.os.tag != .windows) return false;

    const handle = windows_ads.CreateFileW(
        path_w,
        windows_ads.GENERIC_READ,
        windows_ads.share_all,
        null,
        windows_ads.OPEN_EXISTING,
        windows_ads.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (windows_ads.isInvalidHandle(handle)) return false;
    defer _ = windows_ads.CloseHandle(handle);

    var file_size: i64 = 0;
    if (windows_ads.GetFileSizeEx(handle, &file_size) == 0) return false;
    if (file_size < 0 or @as(u64, @intCast(file_size)) != buf.len) return false;

    var bytes_read: windows_ads.DWORD = 0;
    if (windows_ads.ReadFile(handle, buf.ptr, @intCast(buf.len), &bytes_read, null) == 0) return false;
    return bytes_read == buf.len;
}

pub fn windowsWriteAdsPathW(path_w: [*:0]const u16, buf: []const u8) bool {
    if (comptime builtin.os.tag != .windows) return false;

    const handle = windows_ads.CreateFileW(
        path_w,
        windows_ads.GENERIC_WRITE,
        windows_ads.share_all,
        null,
        windows_ads.CREATE_ALWAYS,
        windows_ads.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (windows_ads.isInvalidHandle(handle)) return false;
    defer _ = windows_ads.CloseHandle(handle);

    var bytes_written: windows_ads.DWORD = 0;
    if (windows_ads.WriteFile(handle, buf.ptr, @intCast(buf.len), &bytes_written, null) == 0) return false;
    return bytes_written == buf.len;
}

pub fn windowsDeleteAdsPathW(path_w: [*:0]const u16) void {
    if (comptime builtin.os.tag != .windows) return;
    _ = windows_ads.DeleteFileW(path_w);
}

pub fn windowsReadAds(path: []const u8, stream_name: [:0]const u8, buf: []u8, allocator: mem.Allocator) bool {
    if (comptime builtin.os.tag != .windows) return false;

    const ads_path = windowsAllocAdsPath(allocator, path, stream_name) orelse return false;
    defer allocator.free(ads_path);
    return windowsReadAdsPathW(ads_path.ptr, buf);
}

pub fn windowsReadAdsFd(dir: std.Io.Dir, stream_name: [:0]const u8, buf: []u8) bool {
    if (comptime builtin.os.tag != .windows) return false;

    var ads_buf: [windows_max_path_wchars + windows_ads_path_extra_wchars]u16 = undefined;
    const ads_path = windowsAdsPathFromDirHandle(dir, stream_name, ads_buf[0..]) orelse return false;
    return windowsReadAdsPathW(ads_path.ptr, buf);
}

pub fn windowsWriteAds(path: []const u8, stream_name: [:0]const u8, buf: []const u8, allocator: mem.Allocator) bool {
    if (comptime builtin.os.tag != .windows) return false;

    const ads_path = windowsAllocAdsPath(allocator, path, stream_name) orelse return false;
    defer allocator.free(ads_path);
    return windowsWriteAdsPathW(ads_path.ptr, buf);
}

pub fn windowsWriteAdsFd(dir: std.Io.Dir, stream_name: [:0]const u8, buf: []const u8) bool {
    if (comptime builtin.os.tag != .windows) return false;

    var ads_buf: [windows_max_path_wchars + windows_ads_path_extra_wchars]u16 = undefined;
    const ads_path = windowsAdsPathFromDirHandle(dir, stream_name, ads_buf[0..]) orelse return false;
    return windowsWriteAdsPathW(ads_path.ptr, buf);
}

pub fn windowsDeleteAds(path: []const u8, stream_name: [:0]const u8, allocator: mem.Allocator) void {
    if (comptime builtin.os.tag != .windows) return;

    const ads_path = windowsAllocAdsPath(allocator, path, stream_name) orelse return;
    defer allocator.free(ads_path);
    windowsDeleteAdsPathW(ads_path.ptr);
}

pub fn decodeCachedDirStatsBuf(buf: *const [32]u8, now: u64) ?DirStats {
    const record = decodeCachedDirStats(buf);
    if (record.expires_at < now) return null;
    return .{
        .size = record.size,
        .file_count = record.file_count,
        .dir_count = record.dir_count,
    };
}

pub fn decodeCachedDirSizeBuf(buf: *const [16]u8, now: u64) ?DirStats {
    const record = decodeCachedDirSize(buf);
    if (record.expires_at < now) return null;
    return .{ .size = record.size };
}

pub fn readCachedDirStatsV2Windows(path: []const u8, allocator: mem.Allocator, now: u64) ?DirStats {
    var buf: [16]u8 = undefined;
    if (!windowsReadAds(path, dir_size_xattr_name, buf[0..], allocator)) return null;
    return decodeCachedDirSizeBuf(&buf, now);
}

pub fn readCachedDirStats(path: []const u8, allocator: mem.Allocator) ?DirStats {
    const now = currentTimestampSeconds() orelse return null;
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);
    var buf: [32]u8 = undefined;

    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            const rc = linux.getxattr(path_z.ptr, dir_stats_xattr_name, buf[0..].ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc != buf.len) return null;
                    const record = decodeCachedDirStats(&buf);
                    if (record.expires_at < now) return null;
                    return .{
                        .size = record.size,
                        .file_count = record.file_count,
                        .dir_count = record.dir_count,
                    };
                },
                else => return readCachedDirStatsV2Z(path_z.ptr, now),
            }
        },
        .macos => {
            const rc = darwin_xattr.getxattr(path_z.ptr, dir_stats_xattr_name, buf[0..].ptr, buf.len, 0, 0);
            switch (std.c.errno(rc)) {
                .SUCCESS => {
                    if (rc != buf.len) return null;
                    const record = decodeCachedDirStats(&buf);
                    if (record.expires_at < now) return null;
                    return .{
                        .size = record.size,
                        .file_count = record.file_count,
                        .dir_count = record.dir_count,
                    };
                },
                else => return readCachedDirStatsV2Z(path_z.ptr, now),
            }
        },
        .windows => {
            if (windowsReadAds(path, dir_stats_xattr_name, buf[0..], allocator)) {
                return decodeCachedDirStatsBuf(&buf, now);
            }
            return readCachedDirStatsV2Windows(path, allocator, now);
        },
        else => return null,
    }
}

pub fn readCachedDirStatsFd(dir: std.Io.Dir) ?DirStats {
    const now = currentTimestampSeconds() orelse return null;
    var buf: [32]u8 = undefined;

    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            const rc = linux.fgetxattr(dir.handle, dir_stats_xattr_name, buf[0..].ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc != buf.len) return null;
                    const record = decodeCachedDirStats(&buf);
                    if (record.expires_at < now) return null;
                    return .{
                        .size = record.size,
                        .file_count = record.file_count,
                        .dir_count = record.dir_count,
                    };
                },
                else => return readCachedDirStatsV2Fd(dir, now),
            }
        },
        .macos => {
            const rc = darwin_xattr.fgetxattr(dir.handle, dir_stats_xattr_name, buf[0..].ptr, buf.len, 0, 0);
            switch (std.c.errno(rc)) {
                .SUCCESS => {
                    if (rc != buf.len) return null;
                    const record = decodeCachedDirStats(&buf);
                    if (record.expires_at < now) return null;
                    return .{
                        .size = record.size,
                        .file_count = record.file_count,
                        .dir_count = record.dir_count,
                    };
                },
                else => return readCachedDirStatsV2Fd(dir, now),
            }
        },
        .windows => {
            if (windowsReadAdsFd(dir, dir_stats_xattr_name, buf[0..])) {
                return decodeCachedDirStatsBuf(&buf, now);
            }
            return readCachedDirStatsV2Fd(dir, now);
        },
        else => return null,
    }
}

pub fn readCachedDirStatsV2Z(path_z: [*:0]const u8, now: u64) ?DirStats {
    var buf: [16]u8 = undefined;

    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            const rc = linux.getxattr(path_z, dir_size_xattr_name, buf[0..].ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc != buf.len) return null;
                    const record = decodeCachedDirSize(&buf);
                    if (record.expires_at < now) return null;
                    return .{ .size = record.size };
                },
                .NODATA, .NOENT, .OPNOTSUPP, .RANGE => return null,
                else => return null,
            }
        },
        .macos => {
            const rc = darwin_xattr.getxattr(path_z, dir_size_xattr_name, buf[0..].ptr, buf.len, 0, 0);
            switch (std.c.errno(rc)) {
                .SUCCESS => {
                    if (rc != buf.len) return null;
                    const record = decodeCachedDirSize(&buf);
                    if (record.expires_at < now) return null;
                    return .{ .size = record.size };
                },
                .NOATTR, .NOENT, .OPNOTSUPP, .RANGE => return null,
                else => return null,
            }
        },
        else => return null,
    }
}

pub fn readCachedDirStatsV2Fd(dir: std.Io.Dir, now: u64) ?DirStats {
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
                    return .{ .size = record.size };
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
                    return .{ .size = record.size };
                },
                .NOATTR, .NOENT, .OPNOTSUPP, .RANGE => return null,
                else => return null,
            }
        },
        .windows => {
            if (!windowsReadAdsFd(dir, dir_size_xattr_name, buf[0..])) return null;
            return decodeCachedDirSizeBuf(&buf, now);
        },
        else => return null,
    }
}

pub fn writeCachedDirSize(path: []const u8, size: u64, cache_ttl_seconds: u64, allocator: mem.Allocator) void {
    writeCachedDirStats(path, .{ .size = size }, cache_ttl_seconds, allocator);
}

pub fn writeCachedDirSizeFd(dir: std.Io.Dir, size: u64, cache_ttl_seconds: u64) void {
    writeCachedDirStatsFd(dir, .{ .size = size }, cache_ttl_seconds);
}

pub fn writeCachedDirStats(path: []const u8, stats: DirStats, cache_ttl_seconds: u64, allocator: mem.Allocator) void {
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);
    const stats_buf = encodeCachedDirStatsForWrite(stats, cache_ttl_seconds) orelse return;
    const size_buf = encodeCachedDirSizeForWrite(stats.size, cache_ttl_seconds) orelse return;

    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            _ = linux.setxattr(path_z.ptr, dir_stats_xattr_name, stats_buf[0..].ptr, stats_buf.len, 0);
            _ = linux.setxattr(path_z.ptr, dir_size_xattr_name, size_buf[0..].ptr, size_buf.len, 0);
        },
        .macos => {
            _ = darwin_xattr.setxattr(path_z.ptr, dir_stats_xattr_name, stats_buf[0..].ptr, stats_buf.len, 0, 0);
            _ = darwin_xattr.setxattr(path_z.ptr, dir_size_xattr_name, size_buf[0..].ptr, size_buf.len, 0, 0);
        },
        .windows => {
            _ = windowsWriteAds(path, dir_stats_xattr_name, stats_buf[0..], allocator);
            _ = windowsWriteAds(path, dir_size_xattr_name, size_buf[0..], allocator);
        },
        else => {},
    }
}

pub fn writeCachedDirStatsFd(dir: std.Io.Dir, stats: DirStats, cache_ttl_seconds: u64) void {
    const stats_buf = encodeCachedDirStatsForWrite(stats, cache_ttl_seconds) orelse return;
    const size_buf = encodeCachedDirSizeForWrite(stats.size, cache_ttl_seconds) orelse return;

    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            _ = linux.fsetxattr(dir.handle, dir_stats_xattr_name, stats_buf[0..].ptr, stats_buf.len, 0);
            _ = linux.fsetxattr(dir.handle, dir_size_xattr_name, size_buf[0..].ptr, size_buf.len, 0);
        },
        .macos => {
            _ = darwin_xattr.fsetxattr(dir.handle, dir_stats_xattr_name, stats_buf[0..].ptr, stats_buf.len, 0, 0);
            _ = darwin_xattr.fsetxattr(dir.handle, dir_size_xattr_name, size_buf[0..].ptr, size_buf.len, 0, 0);
        },
        .windows => {
            _ = windowsWriteAdsFd(dir, dir_stats_xattr_name, stats_buf[0..]);
            _ = windowsWriteAdsFd(dir, dir_size_xattr_name, size_buf[0..]);
        },
        else => {},
    }
}

pub fn currentTimestampSeconds() ?u64 {
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
            const now = c_time.time(null);
            if (now < 0) return null;
            return @as(u64, @intCast(now));
        },
        .windows => {
            var ft: std.os.windows.FILETIME = undefined;
            windows_ads.GetSystemTimeAsFileTime(&ft);
            const hns = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
            if (hns < 116444736000000000) return null;
            return (hns - 116444736000000000) / 10000000;
        },
        else => return null,
    }
}

pub fn cacheExpiresAt(cache_ttl_seconds: u64) ?u64 {
    return if (cache_ttl_seconds == 0)
        std.math.maxInt(u64)
    else blk: {
        const now = currentTimestampSeconds() orelse return null;
        break :blk now + cache_ttl_seconds;
    };
}

pub fn encodeCachedDirSizeForWrite(size: u64, cache_ttl_seconds: u64) ?[16]u8 {
    var buf: [16]u8 = undefined;
    encodeCachedDirSize(&buf, .{
        .size = size,
        .expires_at = cacheExpiresAt(cache_ttl_seconds) orelse return null,
    });
    return buf;
}

pub fn encodeCachedDirStatsForWrite(stats: DirStats, cache_ttl_seconds: u64) ?[32]u8 {
    var buf: [32]u8 = undefined;
    encodeCachedDirStats(&buf, .{
        .size = stats.size,
        .file_count = stats.file_count,
        .dir_count = stats.dir_count,
        .expires_at = cacheExpiresAt(cache_ttl_seconds) orelse return null,
    });
    return buf;
}

pub fn encodeCachedDirSize(buf: *[16]u8, record: CachedDirSize) void {
    std.mem.writeInt(u64, buf[0..8], record.size, .little);
    std.mem.writeInt(u64, buf[8..16], record.expires_at, .little);
}

pub fn decodeCachedDirSize(buf: *const [16]u8) CachedDirSize {
    return .{
        .size = std.mem.readInt(u64, buf[0..8], .little),
        .expires_at = std.mem.readInt(u64, buf[8..16], .little),
    };
}

pub fn encodeCachedDirStats(buf: *[32]u8, record: CachedDirStats) void {
    std.mem.writeInt(u64, buf[0..8], record.size, .little);
    std.mem.writeInt(u64, buf[8..16], record.file_count, .little);
    std.mem.writeInt(u64, buf[16..24], record.dir_count, .little);
    std.mem.writeInt(u64, buf[24..32], record.expires_at, .little);
}

pub fn decodeCachedDirStats(buf: *const [32]u8) CachedDirStats {
    return .{
        .size = std.mem.readInt(u64, buf[0..8], .little),
        .file_count = std.mem.readInt(u64, buf[8..16], .little),
        .dir_count = std.mem.readInt(u64, buf[16..24], .little),
        .expires_at = std.mem.readInt(u64, buf[24..32], .little),
    };
}

pub fn clearCachedDirSize(path: []const u8, allocator: mem.Allocator) void {
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            _ = linux.removexattr(path_z.ptr, dir_stats_xattr_name);
            _ = linux.removexattr(path_z.ptr, dir_size_xattr_name);
        },
        .macos => {
            _ = darwin_xattr.removexattr(path_z.ptr, dir_stats_xattr_name, 0);
            _ = darwin_xattr.removexattr(path_z.ptr, dir_size_xattr_name, 0);
        },
        .windows => {
            windowsDeleteAds(path, dir_stats_xattr_name, allocator);
            windowsDeleteAds(path, dir_size_xattr_name, allocator);
        },
        else => {},
    }
}

pub fn clearCachedDirStats(path: []const u8, allocator: mem.Allocator) void {
    clearCachedDirSize(path, allocator);
}

