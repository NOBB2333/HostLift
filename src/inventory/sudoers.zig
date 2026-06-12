const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

const max_sudoers_d_entries = 128;

// 扫描 sudoers 主文件和片段目录的元数据，不读取或输出授权规则内容。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.SudoersInventory {
    var entries: std.ArrayList(schema.SudoersEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    var truncated = false;
    try appendPath(io, allocator, &entries, "/etc/sudoers");
    try appendSudoersDirectory(io, allocator, &entries, &truncated, "/etc/sudoers.d");

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

// 释放 sudoers 扫描条目中分配的路径。
pub fn freeEntries(allocator: std.mem.Allocator, entries: []schema.SudoersEntry) void {
    for (entries) |entry| allocator.free(entry.path);
    allocator.free(entries);
}

// 追加单个 sudoers 路径事实。
fn appendPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(schema.SudoersEntry),
    path: []const u8,
) !void {
    const present = probe.pathExists(io, path);
    const directory = if (present) probe.pathIsDirectory(io, path) else false;
    try entries.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .present = present,
        .kind = if (!present) .missing else if (directory) .directory else .file,
        .size = if (present and !directory) probe.fileSize(io, path) orelse 0 else 0,
        .mode = if (present) modeForPath(io, allocator, path) else null,
        .meaningful_lines = if (present and !directory) meaningfulLineCount(io, allocator, path) else 0,
    });
}

// 追加 sudoers.d 目录和其中的片段文件事实。
fn appendSudoersDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(schema.SudoersEntry),
    truncated: *bool,
    path: []const u8,
) !void {
    try appendPath(io, allocator, entries, path);

    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entries.items.len >= max_sudoers_d_entries + 2) {
            truncated.* = true;
            return;
        }
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        if (std.mem.endsWith(u8, entry.name, "~")) continue;
        if (std.mem.indexOfScalar(u8, entry.name, '.') != null) continue;

        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        try appendPath(io, allocator, entries, child_path);
    }
}

// 读取路径权限 mode；失败时返回 null，避免扫描因 stat 不可用而失败。
fn modeForPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?u32 {
    const argv = [_][]const u8{ "stat", "-c", "%a", path };
    const output = probe.runFirstLine(io, allocator, &argv) catch return null;
    defer allocator.free(output);
    return std.fmt.parseInt(u32, output, 8) catch null;
}

// 统计 sudoers 文件中的有效行数；不把行内容写入 inventory。
fn meaningfulLineCount(io: std.Io, allocator: std.mem.Allocator, path: []const u8) u32 {
    const contents = probe.readWholeFile(io, allocator, path) catch return 0;
    defer allocator.free(contents);
    return probe.countMeaningfulLines(contents);
}

test "sudoers scanner never serializes rule content" {
    const allocator = std.testing.allocator;
    const path = "/tmp/hostlift-sudoers-test";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};

    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = path, .data = "# comment\nroot ALL=(ALL) ALL\n" });

    var entries: std.ArrayList(schema.SudoersEntry) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    try appendPath(std.testing.io, allocator, &entries, path);

    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expect(entries.items[0].present);
    try std.testing.expectEqual(schema.SudoersPathKind.file, entries.items[0].kind);
    try std.testing.expectEqual(@as(u32, 1), entries.items[0].meaningful_lines);
    try std.testing.expect(std.mem.indexOf(u8, entries.items[0].path, "root ALL") == null);
}
