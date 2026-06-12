const std = @import("std");
const home_user = @import("home_user.zig");
const schema = @import("schema.zig");
const users_scanner = @import("users.zig");

// 扫描系统级和用户级 XDG autostart desktop 入口。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) ![]schema.XdgAutostartEntry {
    var entries: std.ArrayList(schema.XdgAutostartEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            if (entry.user) |user| allocator.free(user);
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        entries.deinit(allocator);
    }

    try appendXdgAutostartDir(io, allocator, &entries, .system, null, "/etc/xdg/autostart");

    const users = try users_scanner.parsePasswd(io, allocator);
    defer users_scanner.freeUsers(allocator, users);
    for (users) |user| {
        if (!home_user.shouldScanHome(user)) continue;
        const autostart_dir = try std.fs.path.join(allocator, &.{ user.home, ".config/autostart" });
        defer allocator.free(autostart_dir);
        try appendXdgAutostartDir(io, allocator, &entries, .user, user.name, autostart_dir);
        if (entries.items.len >= 512) break;
    }

    return entries.toOwnedSlice(allocator);
}

// 遍历 XDG autostart 目录，收集 .desktop 入口。
fn appendXdgAutostartDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(schema.XdgAutostartEntry),
    scope: schema.XdgAutostartScope,
    user: ?[]const u8,
    dir_path: []const u8,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entries.items.len >= 512) return;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        try entries.append(allocator, .{
            .scope = scope,
            .user = if (user) |value| try allocator.dupe(u8, value) else null,
            .name = try allocator.dupe(u8, entry.name),
            .path = try allocator.dupe(u8, path),
        });
    }
}
