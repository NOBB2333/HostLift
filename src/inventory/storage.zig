const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

const max_mount_entries = 512;

// 扫描 fstab 和当前挂载点事实，不执行 mount/umount。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.StorageInventory {
    const fstab_entries = try parseFstabFile(io, allocator, "/etc/fstab");
    errdefer freeFstabEntries(allocator, fstab_entries);
    const mounts = try parseMountInfoFile(io, allocator, "/proc/self/mountinfo");
    errdefer freeMountEntries(allocator, mounts);
    try enrichMountCapacity(io, allocator, mounts);
    const memory = try readMemoryCapacity(io, allocator);

    return .{
        .fstab_entries = fstab_entries,
        .mounts = mounts,
        .memory_total_bytes = memory.memory_total_bytes,
        .memory_available_bytes = memory.memory_available_bytes,
        .swap_total_bytes = memory.swap_total_bytes,
        .swap_free_bytes = memory.swap_free_bytes,
        .truncated = false,
    };
}

// 释放 StorageInventory 中分配的字符串和切片。
pub fn freeInventory(allocator: std.mem.Allocator, storage: schema.StorageInventory) void {
    freeFstabEntries(allocator, storage.fstab_entries);
    freeMountEntries(allocator, storage.mounts);
}

// 解析 fstab 文件；文件不存在或不可读时返回空列表。
pub fn parseFstabFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]schema.FstabEntry {
    const contents = probe.readWholeFile(io, allocator, path) catch return allocator.alloc(schema.FstabEntry, 0);
    defer allocator.free(contents);
    return parseFstab(allocator, contents);
}

// 解析 mountinfo 文件；文件不存在或不可读时返回空列表。
pub fn parseMountInfoFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]schema.MountEntry {
    const contents = probe.readWholeFile(io, allocator, path) catch return allocator.alloc(schema.MountEntry, 0);
    defer allocator.free(contents);
    return parseMountInfo(allocator, contents);
}

// 解析 fstab 文本为结构化条目。
pub fn parseFstab(allocator: std.mem.Allocator, contents: []const u8) ![]schema.FstabEntry {
    var entries: std.ArrayList(schema.FstabEntry) = .empty;
    errdefer freeFstabEntries(allocator, entries.items);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const device = fields.next() orelse continue;
        const mount_point = fields.next() orelse continue;
        const fs_type = fields.next() orelse continue;
        const options = fields.next() orelse "defaults";
        const dump_raw = fields.next() orelse "0";
        const pass_raw = fields.next() orelse "0";

        try entries.append(allocator, .{
            .device = try allocator.dupe(u8, device),
            .mount_point = try allocator.dupe(u8, mount_point),
            .fs_type = try allocator.dupe(u8, fs_type),
            .options = try allocator.dupe(u8, options),
            .dump = parseSmallInt(dump_raw),
            .pass = parseSmallInt(pass_raw),
        });
    }

    return entries.toOwnedSlice(allocator);
}

// 解析 Linux mountinfo 文本为结构化挂载条目。
pub fn parseMountInfo(allocator: std.mem.Allocator, contents: []const u8) ![]schema.MountEntry {
    var entries: std.ArrayList(schema.MountEntry) = .empty;
    errdefer freeMountEntries(allocator, entries.items);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        if (entries.items.len >= max_mount_entries) break;
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (try parseMountInfoLine(allocator, line)) |entry| {
            try entries.append(allocator, entry);
        }
    }

    return entries.toOwnedSlice(allocator);
}

// 解析单行 mountinfo；字段不完整时返回 null。
fn parseMountInfoLine(allocator: std.mem.Allocator, line: []const u8) !?schema.MountEntry {
    const sep = std.mem.indexOf(u8, line, " - ") orelse return null;
    const left = line[0..sep];
    const right = line[sep + 3 ..];

    var left_fields = std.mem.tokenizeScalar(u8, left, ' ');
    _ = left_fields.next() orelse return null;
    _ = left_fields.next() orelse return null;
    _ = left_fields.next() orelse return null;
    _ = left_fields.next() orelse return null;
    const mount_point = left_fields.next() orelse return null;
    const options = left_fields.next() orelse "";

    var right_fields = std.mem.tokenizeScalar(u8, right, ' ');
    const fs_type = right_fields.next() orelse return null;
    const source = right_fields.next() orelse "";

    const decoded_mount_point = try unescapeMountField(allocator, mount_point);
    errdefer allocator.free(decoded_mount_point);
    const decoded_source = try unescapeMountField(allocator, source);
    errdefer allocator.free(decoded_source);

    return .{
        .mount_point = decoded_mount_point,
        .fs_type = try allocator.dupe(u8, fs_type),
        .source = decoded_source,
        .options = try allocator.dupe(u8, options),
    };
}

fn enrichMountCapacity(io: std.Io, allocator: std.mem.Allocator, mounts: []schema.MountEntry) !void {
    for (mounts) |*mount| {
        const capacity = readMountCapacity(io, allocator, mount.mount_point) orelse continue;
        mount.total_bytes = capacity.total_bytes;
        mount.available_bytes = capacity.available_bytes;
        mount.total_inodes = capacity.total_inodes;
        mount.available_inodes = capacity.available_inodes;
    }
}

const MountCapacity = struct {
    total_bytes: u64 = 0,
    available_bytes: u64 = 0,
    total_inodes: u64 = 0,
    available_inodes: u64 = 0,
};

fn readMountCapacity(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8) ?MountCapacity {
    const output = probe.runCommand(io, allocator, &.{ "df", "-PB1", "--output=size,avail,itotal,iavail", mount_point }, 64 * 1024) catch return null;
    defer allocator.free(output);
    return parseDfCapacity(output);
}

fn parseDfCapacity(output: []const u8) ?MountCapacity {
    var lines = std.mem.splitScalar(u8, output, '\n');
    _ = lines.next() orelse return null;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        return .{
            .total_bytes = parseDfU64(fields.next() orelse return null) orelse return null,
            .available_bytes = parseDfU64(fields.next() orelse return null) orelse return null,
            .total_inodes = parseDfU64(fields.next() orelse "0") orelse 0,
            .available_inodes = parseDfU64(fields.next() orelse "0") orelse 0,
        };
    }
    return null;
}

fn parseDfU64(value: []const u8) ?u64 {
    if (std.mem.eql(u8, value, "-")) return 0;
    return std.fmt.parseUnsigned(u64, value, 10) catch null;
}

const MemoryCapacity = struct {
    memory_total_bytes: u64 = 0,
    memory_available_bytes: u64 = 0,
    swap_total_bytes: u64 = 0,
    swap_free_bytes: u64 = 0,
};

fn readMemoryCapacity(io: std.Io, allocator: std.mem.Allocator) !MemoryCapacity {
    const contents = probe.readWholeFile(io, allocator, "/proc/meminfo") catch return .{};
    defer allocator.free(contents);
    return parseMeminfo(contents);
}

fn parseMeminfo(contents: []const u8) MemoryCapacity {
    var capacity: MemoryCapacity = .{};
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (parseMeminfoLine(line, "MemTotal:")) |value| {
            capacity.memory_total_bytes = value;
        } else if (parseMeminfoLine(line, "MemAvailable:")) |value| {
            capacity.memory_available_bytes = value;
        } else if (parseMeminfoLine(line, "SwapTotal:")) |value| {
            capacity.swap_total_bytes = value;
        } else if (parseMeminfoLine(line, "SwapFree:")) |value| {
            capacity.swap_free_bytes = value;
        }
    }
    return capacity;
}

fn parseMeminfoLine(line: []const u8, key: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, key)) return null;
    var fields = std.mem.tokenizeAny(u8, trimmed[key.len..], " \t");
    const kib = std.fmt.parseUnsigned(u64, fields.next() orelse return null, 10) catch return null;
    return kib * 1024;
}

// 释放 fstab 条目数组。
fn freeFstabEntries(allocator: std.mem.Allocator, entries: []schema.FstabEntry) void {
    for (entries) |entry| {
        allocator.free(entry.device);
        allocator.free(entry.mount_point);
        allocator.free(entry.fs_type);
        allocator.free(entry.options);
    }
    allocator.free(entries);
}

// 释放 mountinfo 条目数组。
fn freeMountEntries(allocator: std.mem.Allocator, entries: []schema.MountEntry) void {
    for (entries) |entry| {
        allocator.free(entry.mount_point);
        allocator.free(entry.fs_type);
        allocator.free(entry.source);
        allocator.free(entry.options);
    }
    allocator.free(entries);
}

// 解析 fstab dump/pass 这类小整数，异常值按 0 处理。
fn parseSmallInt(value: []const u8) u8 {
    return std.fmt.parseInt(u8, value, 10) catch 0;
}

// 还原 mountinfo 字段中的八进制转义，例如 \040 表示空格。
fn unescapeMountField(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(allocator);

    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '\\' and index + 3 < value.len and
            isOctal(value[index + 1]) and isOctal(value[index + 2]) and isOctal(value[index + 3]))
        {
            const byte: u8 = (value[index + 1] - '0') * 64 +
                (value[index + 2] - '0') * 8 +
                (value[index + 3] - '0');
            try decoded.append(allocator, byte);
            index += 4;
            continue;
        }
        try decoded.append(allocator, value[index]);
        index += 1;
    }

    return decoded.toOwnedSlice(allocator);
}

// 判断字节是否为八进制数字（0-7）。
fn isOctal(byte: u8) bool {
    return byte >= '0' and byte <= '7';
}

test "parse fstab skips comments and extracts mount metadata" {
    const entries = try parseFstab(std.testing.allocator,
        \\# comment
        \\UUID=abc / ext4 defaults 0 1
        \\server:/export /mnt/nfs nfs4 rw,noatime 0 0
    );
    defer freeFstabEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("UUID=abc", entries[0].device);
    try std.testing.expectEqualStrings("/", entries[0].mount_point);
    try std.testing.expectEqualStrings("ext4", entries[0].fs_type);
    try std.testing.expectEqual(@as(u8, 1), entries[0].pass);
    try std.testing.expectEqualStrings("server:/export", entries[1].device);
    try std.testing.expectEqualStrings("nfs4", entries[1].fs_type);
}

test "parse mountinfo extracts current mount facts" {
    const entries = try parseMountInfo(std.testing.allocator,
        \\36 25 0:32 / / rw,relatime - ext4 /dev/vda1 rw
        \\42 36 0:45 / /mnt/data rw,nosuid - xfs /dev/vdb1 rw,attr2
    );
    defer freeMountEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("/", entries[0].mount_point);
    try std.testing.expectEqualStrings("ext4", entries[0].fs_type);
    try std.testing.expectEqualStrings("/dev/vda1", entries[0].source);
    try std.testing.expectEqualStrings("/mnt/data", entries[1].mount_point);
    try std.testing.expectEqualStrings("xfs", entries[1].fs_type);
}

test "parse mountinfo decodes octal escaped paths" {
    const entries = try parseMountInfo(std.testing.allocator,
        \\42 36 0:45 / /mnt/data\040one rw,nosuid - ext4 /dev/disk\040one rw
    );
    defer freeMountEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("/mnt/data one", entries[0].mount_point);
    try std.testing.expectEqualStrings("/dev/disk one", entries[0].source);
}

test "parse df capacity extracts bytes and inodes" {
    const capacity = parseDfCapacity(
        \\  1B-blocks       Avail     Inodes     IAvail
        \\10737418240  5368709120    1000000     900000
    ).?;

    try std.testing.expectEqual(@as(u64, 10_737_418_240), capacity.total_bytes);
    try std.testing.expectEqual(@as(u64, 5_368_709_120), capacity.available_bytes);
    try std.testing.expectEqual(@as(u64, 1_000_000), capacity.total_inodes);
    try std.testing.expectEqual(@as(u64, 900_000), capacity.available_inodes);
}

test "parse meminfo extracts memory and swap bytes" {
    const capacity = parseMeminfo(
        \\MemTotal:       16384 kB
        \\MemAvailable:    8192 kB
        \\SwapTotal:       4096 kB
        \\SwapFree:        2048 kB
    );

    try std.testing.expectEqual(@as(u64, 16_777_216), capacity.memory_total_bytes);
    try std.testing.expectEqual(@as(u64, 8_388_608), capacity.memory_available_bytes);
    try std.testing.expectEqual(@as(u64, 4_194_304), capacity.swap_total_bytes);
    try std.testing.expectEqual(@as(u64, 2_097_152), capacity.swap_free_bytes);
}
