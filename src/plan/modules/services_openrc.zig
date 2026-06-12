const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual = @import("manual_common.zig");

// 规划 OpenRC service 脚本复制和 runlevel 收敛动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source_services: []const inventory.OpenRcService,
    target_services: []const inventory.OpenRcService,
) !void {
    for (source_services) |service| {
        if (hasEquivalentOpenRc(target_services, service)) continue;
        const target_has_service = hasOpenRc(target_services, service.name);
        if (!target_has_service) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/install-openrc",
                .name = service.name,
                .subject = service.path,
                .module = .services,
                .action_type = .write_file,
                .risk = .high,
                .requires_confirmation = true,
                .description = "Install OpenRC service script file from source",
            });
        }
        const target_runlevels = openRcRunlevels(target_services, service.name);
        var runlevel_action = false;
        if (service.enabled and service.runlevels.len > 0) {
            const missing_runlevels = try runlevelDifference(allocator, service.runlevels, target_runlevels);
            defer allocator.free(missing_runlevels);
            if (missing_runlevels.len > 0) {
                runlevel_action = true;
                const service_ref = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ service.name, missing_runlevels });
                defer allocator.free(service_ref);
                try common.appendAction(allocator, actions, .{
                    .id_prefix = "services/enable-openrc",
                    .name = service.name,
                    .subject = service_ref,
                    .module = .services,
                    .action_type = .enable_openrc_service,
                    .risk = .high,
                    .requires_confirmation = true,
                    .description = "Enable OpenRC service runlevels on target after validation",
                });
            }
        }
        const extra_runlevels = try runlevelDifference(allocator, target_runlevels, service.runlevels);
        defer allocator.free(extra_runlevels);
        if (extra_runlevels.len > 0) {
            runlevel_action = true;
            const service_ref = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ service.name, extra_runlevels });
            defer allocator.free(service_ref);
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/disable-openrc",
                .name = service.name,
                .subject = service_ref,
                .module = .services,
                .action_type = .disable_openrc_service,
                .risk = .high,
                .requires_confirmation = true,
                .description = "Disable extra OpenRC service runlevels on target after validation",
            });
        }
        if (runlevel_action) continue;
        if (target_has_service and runlevelsSubset(target_runlevels, service.runlevels)) continue;
        if (!service.enabled and !target_has_service) continue;
        try manual.appendManualStep(allocator, actions, .{
            .id_prefix = "services/review-openrc",
            .name = service.name,
            .subject = service.path,
            .module = .services,
            .risk = .high,
            .description = "Review OpenRC service before migration",
        });
    }
}

// 判断目标是否存在与源服务完全等价的 OpenRC 服务。
fn hasEquivalentOpenRc(services: []const inventory.OpenRcService, source: inventory.OpenRcService) bool {
    for (services) |service| {
        if (!std.mem.eql(u8, service.name, source.name)) continue;
        if (service.enabled != source.enabled) continue;
        if (!std.mem.eql(u8, service.runlevels, source.runlevels)) continue;
        return true;
    }
    return false;
}

// 判断目标是否已存在同名 OpenRC 服务。
fn hasOpenRc(services: []const inventory.OpenRcService, name: []const u8) bool {
    for (services) |service| {
        if (std.mem.eql(u8, service.name, name)) return true;
    }
    return false;
}

// 查询目标 OpenRC 服务的运行级别，未找到返回空串。
fn openRcRunlevels(services: []const inventory.OpenRcService, name: []const u8) []const u8 {
    for (services) |service| {
        if (std.mem.eql(u8, service.name, name)) return service.runlevels;
    }
    return "";
}

// 判断候选运行级别是否全部包含在允许级别中（即为子集）。
fn runlevelsSubset(candidate: []const u8, allowed: []const u8) bool {
    if (candidate.len == 0) return true;
    var iterator = std.mem.splitScalar(u8, candidate, ',');
    while (iterator.next()) |runlevel| {
        if (runlevel.len == 0) continue;
        if (!containsRunlevel(allowed, runlevel)) return false;
    }
    return true;
}

// 计算左侧运行级别中存在而右侧不存在的级别差集。
fn runlevelDifference(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, left, ',');
    while (iterator.next()) |runlevel| {
        if (runlevel.len == 0) continue;
        if (containsRunlevel(right, runlevel)) continue;
        if (result.items.len > 0) try result.append(allocator, ',');
        try result.appendSlice(allocator, runlevel);
    }
    return result.toOwnedSlice(allocator);
}

// 判断逗号分隔的运行级别列表是否包含指定级别。
fn containsRunlevel(values: []const u8, needle: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, values, ',');
    while (iterator.next()) |runlevel| {
        if (std.mem.eql(u8, runlevel, needle)) return true;
    }
    return false;
}
