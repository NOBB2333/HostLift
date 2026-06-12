const std = @import("std");
const home_user = @import("home_user.zig");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const users_scanner = @import("users.zig");

// 扫描用户级 systemd unit 文件名、路径、类型和启用状态。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) ![]schema.UserSystemdUnit {
    const users = try users_scanner.parsePasswd(io, allocator);
    defer users_scanner.freeUsers(allocator, users);

    var units: std.ArrayList(schema.UserSystemdUnit) = .empty;
    errdefer {
        for (units.items) |unit| {
            allocator.free(unit.user);
            allocator.free(unit.name);
            allocator.free(unit.path);
        }
        units.deinit(allocator);
    }

    for (users) |user| {
        if (!home_user.shouldScanHome(user)) continue;
        const user_dir = try std.fs.path.join(allocator, &.{ user.home, ".config/systemd/user" });
        defer allocator.free(user_dir);
        try appendUserSystemdUnits(io, allocator, &units, user, user_dir);
        if (units.items.len >= 512) break;
    }

    return units.toOwnedSlice(allocator);
}

// 遍历用户 systemd unit 目录，收集 .service/.timer/.socket 文件。
fn appendUserSystemdUnits(
    io: std.Io,
    allocator: std.mem.Allocator,
    units: *std.ArrayList(schema.UserSystemdUnit),
    user: schema.UserAccount,
    user_dir: []const u8,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, user_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (units.items.len >= 512) return;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const kind = userUnitKind(entry.name);
        if (kind == .unknown) continue;
        const unit_path = try std.fs.path.join(allocator, &.{ user_dir, entry.name });
        defer allocator.free(unit_path);
        try units.append(allocator, .{
            .user = try allocator.dupe(u8, user.name),
            .name = try allocator.dupe(u8, entry.name),
            .path = try allocator.dupe(u8, unit_path),
            .kind = kind,
            .enabled = userUnitEnabled(io, allocator, user_dir, entry.name),
        });
    }
}

// 根据文件后缀判断用户 unit 类型。
fn userUnitKind(name: []const u8) schema.UserSystemdUnitKind {
    if (std.mem.endsWith(u8, name, ".service")) return .service;
    if (std.mem.endsWith(u8, name, ".timer")) return .timer;
    if (std.mem.endsWith(u8, name, ".socket")) return .socket;
    return .unknown;
}

// 检查用户 unit 是否在 default.target.wants 中启用。
fn userUnitEnabled(io: std.Io, allocator: std.mem.Allocator, user_dir: []const u8, name: []const u8) bool {
    const enabled_path = std.fs.path.join(allocator, &.{ user_dir, "default.target.wants", name }) catch return false;
    defer allocator.free(enabled_path);
    return probe.pathExists(io, enabled_path);
}

test "user systemd unit kind parser covers common unit types" {
    try std.testing.expectEqual(schema.UserSystemdUnitKind.service, userUnitKind("syncthing.service"));
    try std.testing.expectEqual(schema.UserSystemdUnitKind.timer, userUnitKind("backup.timer"));
    try std.testing.expectEqual(schema.UserSystemdUnitKind.socket, userUnitKind("podman.socket"));
    try std.testing.expectEqual(schema.UserSystemdUnitKind.unknown, userUnitKind("notes.txt"));
}
