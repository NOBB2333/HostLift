const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const init_common = @import("services_init_common.zig");

// 扫描 OpenRC service 和 runlevel 启用摘要。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) ![]schema.OpenRcService {
    if (!probe.pathExists(io, "/etc/runlevels")) return allocator.alloc(schema.OpenRcService, 0);
    var dir = std.Io.Dir.openDirAbsolute(io, "/etc/init.d", .{ .iterate = true }) catch return allocator.alloc(schema.OpenRcService, 0);
    defer dir.close(io);

    var services: std.ArrayList(schema.OpenRcService) = .empty;
    errdefer {
        for (services.items) |service| {
            allocator.free(service.name);
            allocator.free(service.path);
            allocator.free(service.runlevels);
        }
        services.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (services.items.len >= 512) break;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (init_common.ignoreInitScriptName(entry.name)) continue;
        const path = try std.fs.path.join(allocator, &.{ "/etc/init.d", entry.name });
        defer allocator.free(path);
        const runlevels = try scanRunlevels(io, allocator, entry.name);
        errdefer allocator.free(runlevels);
        try services.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .path = try allocator.dupe(u8, path),
            .enabled = runlevels.len > 0,
            .runlevels = runlevels,
        });
    }

    return services.toOwnedSlice(allocator);
}

// 扫描服务在 /etc/runlevels 下的启用 runlevel 列表。
fn scanRunlevels(io: std.Io, allocator: std.mem.Allocator, service_name: []const u8) ![]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, "/etc/runlevels", .{ .iterate = true }) catch return allocator.alloc(u8, 0);
    defer dir.close(io);

    var level_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (level_names.items) |level| allocator.free(level);
        level_names.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!runlevelEnablesService(io, allocator, entry.name, service_name)) continue;
        try level_names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, level_names.items, {}, lessThanBytes);
    var runlevels: std.ArrayList(u8) = .empty;
    errdefer runlevels.deinit(allocator);
    for (level_names.items) |level| {
        if (runlevels.items.len > 0) try runlevels.append(allocator, ',');
        try runlevels.appendSlice(allocator, level);
    }
    return runlevels.toOwnedSlice(allocator);
}

// 检查指定 runlevel 目录下是否存在指向该服务的符号链接。
fn runlevelEnablesService(io: std.Io, allocator: std.mem.Allocator, runlevel: []const u8, service_name: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ "/etc/runlevels", runlevel, service_name }) catch return false;
    defer allocator.free(path);
    return probe.pathExists(io, path);
}

// 字节序比较，用于 runlevel 名称排序。
fn lessThanBytes(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
