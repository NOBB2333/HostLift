const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 扫描系统和用户 cron 来源文件，只记录摘要信息。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.CronInventory {
    var entries: std.ArrayList(schema.CronEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.source);
            if (entry.owner) |owner| allocator.free(owner);
        }
        entries.deinit(allocator);
    }

    try appendCronFile(io, allocator, &entries, "/etc/crontab", null, .cron);
    try appendCronFile(io, allocator, &entries, "/etc/anacrontab", null, .anacron);
    try appendCronDir(io, allocator, &entries, "/etc/cron.d", null, .cron);
    try appendCronDir(io, allocator, &entries, "/etc/cron.hourly", null, .periodic_dir);
    try appendCronDir(io, allocator, &entries, "/etc/cron.daily", null, .periodic_dir);
    try appendCronDir(io, allocator, &entries, "/etc/cron.weekly", null, .periodic_dir);
    try appendCronDir(io, allocator, &entries, "/etc/cron.monthly", null, .periodic_dir);
    try appendCronSpoolDir(io, allocator, &entries, "/var/spool/cron/crontabs", .cron);
    try appendCronSpoolDir(io, allocator, &entries, "/var/spool/cron", .cron);
    try appendCronSpoolDir(io, allocator, &entries, "/var/spool/at", .at_spool);
    try appendCronSpoolDir(io, allocator, &entries, "/var/spool/cron/atjobs", .at_spool);

    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

// 扫描 cron 配置目录。
fn appendCronDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(schema.CronEntry),
    path: []const u8,
    owner: ?[]const u8,
    kind: schema.CronSourceKind,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        try appendCronFile(io, allocator, entries, child_path, owner, kind);
    }
}

// 扫描用户 cron spool 目录。
fn appendCronSpoolDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(schema.CronEntry),
    path: []const u8,
    kind: schema.CronSourceKind,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        try appendCronFile(io, allocator, entries, child_path, entry.name, kind);
    }
}

// 统计并追加单个 cron 文件摘要。
fn appendCronFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(schema.CronEntry),
    path: []const u8,
    owner: ?[]const u8,
    kind: schema.CronSourceKind,
) !void {
    const contents = probe.readWholeFile(io, allocator, path) catch return;
    defer allocator.free(contents);

    const line_count = probe.countMeaningfulLines(contents);
    if (line_count == 0) return;

    try entries.append(allocator, .{
        .source = try allocator.dupe(u8, path),
        .owner = if (owner) |value| try allocator.dupe(u8, value) else null,
        .line_count = line_count,
        .kind = kind,
    });
}
