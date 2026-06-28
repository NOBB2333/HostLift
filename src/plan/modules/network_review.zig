const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const manual_common = @import("manual_common.zig");

// 规划网络监听和迁移后端口健康检查动作，不自动改 IP、路由或防火墙。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.NetworkInventory,
    target: inventory.NetworkInventory,
) !void {
    for (source.listeners) |listener| {
        if (hasEquivalentListener(target.listeners, listener)) continue;
        const name = try listenerName(allocator, listener);
        defer allocator.free(name);
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "network/check-listener",
            .name = name,
            .subject = listener.address,
            .module = .network,
            .risk = .high,
            .description = "Check migrated service listener with TCP/HTTP probe, firewall rule and bind address after migration; compare source/target ports and summarize failures manually",
        });
    }
    if (source.truncated) {
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "network/review-truncated",
            .name = "listener-limit",
            .subject = "network",
            .module = .network,
            .risk = .high,
            .description = "Review truncated listener scan results before migration health checks",
        });
    }
}

// 判断目标是否已有等价监听端口。
fn hasEquivalentListener(listeners: []const inventory.ListeningSocket, source: inventory.ListeningSocket) bool {
    for (listeners) |listener| {
        if (!std.mem.eql(u8, listener.protocol, source.protocol)) continue;
        if (listener.port != source.port) continue;
        if (!sameBindAddress(listener.address, source.address)) continue;
        if (!optionalStringEqual(listener.process, source.process)) continue;
        return true;
    }
    return false;
}

// 生成稳定的 listener action 名称。
fn listenerName(allocator: std.mem.Allocator, listener: inventory.ListeningSocket) ![]const u8 {
    if (listener.process) |process| {
        return std.fmt.allocPrint(allocator, "{s}-{d}-{s}", .{ listener.protocol, listener.port, process });
    }
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ listener.protocol, listener.port });
}

// 比较 bind 地址；通配地址视为同类。
fn sameBindAddress(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    return isAnyAddress(left) and isAnyAddress(right);
}

// 判断地址是否为 IPv4/IPv6 通配监听。
fn isAnyAddress(value: []const u8) bool {
    return std.mem.eql(u8, value, "*") or
        std.mem.eql(u8, value, "0.0.0.0") or
        std.mem.eql(u8, value, "::");
}

// 比较两个可选字符串是否相等。
fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

test "network review creates health check for missing listener" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer {
        for (actions.items) |action| {
            std.testing.allocator.free(action.id);
            std.testing.allocator.free(action.subject);
            std.testing.allocator.free(action.description);
        }
        actions.deinit(std.testing.allocator);
    }

    var source_listeners = [_]inventory.ListeningSocket{.{
        .protocol = "tcp",
        .address = "0.0.0.0",
        .port = 443,
        .process = "nginx",
    }};

    try appendActions(std.testing.allocator, &actions, .{
        .listeners = source_listeners[0..],
        .truncated = false,
    }, .{
        .listeners = &.{},
        .truncated = false,
    });

    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    try std.testing.expectEqualStrings("network/check-listener/tcp-443-nginx", actions.items[0].id);
}
