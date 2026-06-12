const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual = @import("manual_common.zig");

// 规划用户级 systemd unit 文件复制和 enable 动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source_units: []const inventory.UserSystemdUnit,
    target_units: []const inventory.UserSystemdUnit,
) !void {
    for (source_units) |unit| {
        if (hasEquivalentUserSystemdUnit(target_units, unit)) continue;
        const target_has_unit = hasUserSystemdUnit(target_units, unit);
        const review_name = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ unit.user, unit.name });
        defer allocator.free(review_name);
        if (!target_has_unit) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/install-user-unit",
                .name = review_name,
                .subject = unit.path,
                .module = .services,
                .action_type = .copy_home_config,
                .owner = unit.user,
                .risk = .high,
                .requires_confirmation = true,
                .description = "Install user systemd unit file from source",
            });
        }
        if (unit.enabled and (!target_has_unit or hasUserSystemdUnitWithSameKind(target_units, unit))) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/enable-user-unit",
                .name = review_name,
                .subject = review_name,
                .module = .services,
                .action_type = .enable_user_systemd_unit,
                .owner = unit.user,
                .risk = .high,
                .requires_confirmation = true,
                .description = "Enable user systemd unit on target after validation",
            });
            continue;
        }
        if (!unit.enabled and !target_has_unit) continue;
        try manual.appendManualStep(allocator, actions, .{
            .id_prefix = "services/review-user-unit",
            .name = review_name,
            .subject = unit.path,
            .module = .services,
            .risk = .high,
            .description = "Review user systemd unit before migration",
        });
    }
}

// 判断目标列表中是否存在同名同用户的用户级 systemd unit。
fn hasUserSystemdUnit(units: []const inventory.UserSystemdUnit, source: inventory.UserSystemdUnit) bool {
    for (units) |unit| {
        if (!std.mem.eql(u8, unit.user, source.user)) continue;
        if (!std.mem.eql(u8, unit.name, source.name)) continue;
        return true;
    }
    return false;
}

// 判断目标是否存在同名同用户且 unit kind 一致的用户级 unit。
fn hasUserSystemdUnitWithSameKind(units: []const inventory.UserSystemdUnit, source: inventory.UserSystemdUnit) bool {
    for (units) |unit| {
        if (!std.mem.eql(u8, unit.user, source.user)) continue;
        if (!std.mem.eql(u8, unit.name, source.name)) continue;
        if (unit.kind != source.kind) continue;
        return true;
    }
    return false;
}

// 判断目标是否存在与源完全等价的用户级 systemd unit。
fn hasEquivalentUserSystemdUnit(units: []const inventory.UserSystemdUnit, source: inventory.UserSystemdUnit) bool {
    for (units) |unit| {
        if (!std.mem.eql(u8, unit.user, source.user)) continue;
        if (!std.mem.eql(u8, unit.name, source.name)) continue;
        if (unit.kind != source.kind) continue;
        if (unit.enabled != source.enabled) continue;
        return true;
    }
    return false;
}
