const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

const readTrimmedFile = probe.readTrimmedFile;
const readWholeFile = probe.readWholeFile;
const runFirstLine = probe.runFirstLine;

// 读取当前主机的基础 host 信息。
pub fn readHostInfo(io: std.Io, allocator: std.mem.Allocator) !schema.HostInfo {
    return .{
        .hostname = try readHostname(io, allocator),
        .machine_id_hash = try readMachineIdHash(io, allocator),
        .kernel_release = try readKernelRelease(io, allocator),
        .arch = schema.CpuArch.fromBuiltin(@import("builtin").target.cpu.arch),
    };
}

// 解析 /etc/os-release 获取当前发行版信息。
pub fn readOsRelease(io: std.Io, allocator: std.mem.Allocator) !schema.DistroInfo {
    const contents = readWholeFile(io, allocator, "/etc/os-release") catch |err| switch (err) {
        error.FileNotFound => return unknownDistro(allocator),
        else => return err,
    };
    defer allocator.free(contents);

    var id = try allocator.dupe(u8, "unknown");
    var version_id = try allocator.dupe(u8, "unknown");
    var pretty_name = try allocator.dupe(u8, "Unknown Linux");
    var id_like: std.ArrayList([]const u8) = .empty;
    errdefer {
        allocator.free(id);
        allocator.free(version_id);
        allocator.free(pretty_name);
        for (id_like.items) |item| allocator.free(item);
        id_like.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, line, '=')) |equals| {
            const key = line[0..equals];
            const raw_value = line[equals + 1 ..];
            const value = stripOsReleaseValue(raw_value);

            if (std.mem.eql(u8, key, "ID")) {
                allocator.free(id);
                id = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "VERSION_ID")) {
                allocator.free(version_id);
                version_id = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "PRETTY_NAME")) {
                allocator.free(pretty_name);
                pretty_name = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "ID_LIKE")) {
                var parts = std.mem.tokenizeScalar(u8, value, ' ');
                while (parts.next()) |part| try id_like.append(allocator, try allocator.dupe(u8, part));
            }
        }
    }

    return .{
        .id = id,
        .id_like = try id_like.toOwnedSlice(allocator),
        .version_id = version_id,
        .pretty_name = pretty_name,
    };
}

// 读取当前主机 hostname。
fn readHostname(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    if (readTrimmedFile(io, allocator, "/proc/sys/kernel/hostname")) |hostname| {
        if (hostname.len > 0) return hostname;
        allocator.free(hostname);
    } else |_| {}

    if (readTrimmedFile(io, allocator, "/etc/hostname")) |hostname| {
        if (hostname.len > 0) return hostname;
        allocator.free(hostname);
    } else |_| {}

    if (runFirstLine(io, allocator, &.{"hostname"})) |hostname| {
        return hostname;
    } else |_| {}

    return allocator.dupe(u8, "unknown");
}

// 读取 Linux kernel release。
fn readKernelRelease(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    if (readTrimmedFile(io, allocator, "/proc/sys/kernel/osrelease")) |release| {
        if (release.len > 0) return release;
        allocator.free(release);
    } else |_| {}

    if (runFirstLine(io, allocator, &.{ "uname", "-r" })) |release| {
        return release;
    } else |_| {}

    return allocator.dupe(u8, "unknown");
}

// 读取 machine-id 并只保留 hash，避免输出原始机器 ID。
fn readMachineIdHash(io: std.Io, allocator: std.mem.Allocator) !?[32]u8 {
    const machine_id = readTrimmedFile(io, allocator, "/etc/machine-id") catch return null;
    defer allocator.free(machine_id);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(machine_id, &hash, .{});
    return hash;
}

// 构造无法识别发行版时的默认信息。
fn unknownDistro(allocator: std.mem.Allocator) !schema.DistroInfo {
    return .{
        .id = try allocator.dupe(u8, "unknown"),
        .id_like = try allocator.alloc([]const u8, 0),
        .version_id = try allocator.dupe(u8, "unknown"),
        .pretty_name = try allocator.dupe(u8, "Unknown Linux"),
    };
}

// 去掉 os-release 字段值外层引号和转义。
fn stripOsReleaseValue(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

test "os-release value stripping removes quotes" {
    try std.testing.expectEqualStrings("Ubuntu 24.04", stripOsReleaseValue("\"Ubuntu 24.04\""));
    try std.testing.expectEqualStrings("debian", stripOsReleaseValue("debian"));
}
