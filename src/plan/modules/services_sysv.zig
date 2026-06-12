const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual = @import("manual_common.zig");

// 规划 SysV init 脚本复制和 runlevel 收敛动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source_scripts: []const inventory.SysvInitScript,
    target_scripts: []const inventory.SysvInitScript,
) !void {
    for (source_scripts) |script| {
        if (hasEquivalentSysvInit(target_scripts, script)) continue;
        const target_has_script = hasSysvInit(target_scripts, script.name);
        if (!target_has_script) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/install-sysv-init",
                .name = script.name,
                .subject = script.path,
                .module = .services,
                .action_type = .write_file,
                .risk = .high,
                .requires_confirmation = true,
                .description = "Install SysV init script file from source",
            });
        }
        const target_runlevels = sysvRunlevels(target_scripts, script.name);
        var runlevel_action = false;
        if (script.enabled and script.runlevels.len > 0) {
            const missing_runlevels = try runlevelDifference(allocator, script.runlevels, target_runlevels);
            defer allocator.free(missing_runlevels);
            if (missing_runlevels.len > 0) {
                runlevel_action = true;
                const script_ref = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ script.name, missing_runlevels });
                defer allocator.free(script_ref);
                try common.appendAction(allocator, actions, .{
                    .id_prefix = "services/enable-sysv-init",
                    .name = script.name,
                    .subject = script_ref,
                    .module = .services,
                    .action_type = .enable_sysv_init,
                    .risk = .high,
                    .requires_confirmation = true,
                    .description = "Enable SysV init runlevels on target after validation",
                });
            }
        }
        const extra_runlevels = try runlevelDifference(allocator, target_runlevels, script.runlevels);
        defer allocator.free(extra_runlevels);
        if (extra_runlevels.len > 0) {
            runlevel_action = true;
            const script_ref = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ script.name, extra_runlevels });
            defer allocator.free(script_ref);
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/disable-sysv-init",
                .name = script.name,
                .subject = script_ref,
                .module = .services,
                .action_type = .disable_sysv_init,
                .risk = .high,
                .requires_confirmation = true,
                .description = "Disable extra SysV init runlevels on target after validation",
            });
        }
        if (runlevel_action) continue;
        if (!script.enabled and !target_has_script) continue;
        try manual.appendManualStep(allocator, actions, .{
            .id_prefix = "services/review-sysv-init",
            .name = script.name,
            .subject = script.path,
            .module = .services,
            .risk = .high,
            .description = "Review SysV init script before migration",
        });
    }
}

// 判断目标是否存在与源脚本完全等价的 SysV init 脚本。
fn hasEquivalentSysvInit(scripts: []const inventory.SysvInitScript, source: inventory.SysvInitScript) bool {
    for (scripts) |script| {
        if (!std.mem.eql(u8, script.name, source.name)) continue;
        if (script.enabled != source.enabled) continue;
        if (!std.mem.eql(u8, script.runlevels, source.runlevels)) continue;
        return true;
    }
    return false;
}

// 判断目标是否已存在同名 SysV init 脚本。
fn hasSysvInit(scripts: []const inventory.SysvInitScript, name: []const u8) bool {
    for (scripts) |script| {
        if (std.mem.eql(u8, script.name, name)) return true;
    }
    return false;
}

// 查询目标 SysV 脚本的运行级别，未找到返回空串。
fn sysvRunlevels(scripts: []const inventory.SysvInitScript, name: []const u8) []const u8 {
    for (scripts) |script| {
        if (std.mem.eql(u8, script.name, name)) return script.runlevels;
    }
    return "";
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
