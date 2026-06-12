const std = @import("std");
const plan = @import("../plan/schema.zig");
const plan_validator = @import("../plan/validator.zig");

// 将迁移计划校验结果输出为人类可读摘要。
pub fn writePlanValidationSummary(writer: anytype, value: plan_validator.ValidationReport) !void {
    try writer.print(
        \\HostLift plan validation
        \\Valid: {}
        \\Errors: {d}
        \\Warnings: {d}
        \\Actions: {d}
        \\Requires confirmation: {d}
        \\Critical actions: {d}
        \\
    , .{
        value.valid,
        value.errors,
        value.warnings,
        value.actions,
        value.requires_confirmation,
        value.critical_actions,
    });
}

// 输出迁移计划摘要，按模块统计 action 并展示前若干条。
pub fn writePlanSummary(writer: anytype, value: plan.MigrationPlan) !void {
    const counts = countActions(value.actions);
    try writer.print(
        \\HostLift migration plan summary
        \\Compatibility: {s}
        \\Reason: {s}
        \\Actions: {d}
        \\  Packages: {d}
        \\  Services: {d}
        \\  Cron: {d}
        \\  Users: {d}
        \\  SSH: {d}
        \\  Configs: {d}
        \\  Home configs: {d}
        \\  App data: {d}
        \\  Projects: {d}
        \\  Container review: {d}
        \\  Firewall: {d}
        \\  Sudoers review: {d}
        \\  ACL review: {d}
        \\  Security policy review: {d}
        \\  Storage review: {d}
        \\  Manual/security review: {d}
        \\
    , .{
        if (value.compatibility.compatible) "compatible" else "incompatible",
        value.compatibility.reason,
        value.actions.len,
        counts.packages,
        counts.services,
        counts.cron,
        counts.users,
        counts.ssh,
        counts.configs,
        counts.home_configs,
        counts.appdata,
        counts.projects,
        counts.docker,
        counts.firewall,
        counts.sudoers,
        counts.acl,
        counts.security_policy,
        counts.storage,
        counts.review,
    });

    if (value.actions.len == 0) return;
    try writer.writeAll("\nPlanned actions:\n");
    for (value.actions[0..@min(value.actions.len, 40)]) |action| {
        try writer.print(
            "  - {s} [{s}/{s}] confirm={}: {s}\n",
            .{ action.id, @tagName(action.module), @tagName(action.risk), action.requires_confirmation, action.description },
        );
    }
    if (value.actions.len > 40) try writer.print("  ... {d} more\n", .{value.actions.len - 40});
}

// 按模块分类的 action 计数器。
const ActionCounts = struct {
    packages: usize = 0,
    services: usize = 0,
    cron: usize = 0,
    users: usize = 0,
    ssh: usize = 0,
    configs: usize = 0,
    home_configs: usize = 0,
    appdata: usize = 0,
    projects: usize = 0,
    docker: usize = 0,
    firewall: usize = 0,
    sudoers: usize = 0,
    acl: usize = 0,
    security_policy: usize = 0,
    storage: usize = 0,
    review: usize = 0,
};

// 按模块和风险统计计划 action。
fn countActions(actions: []const plan.Action) ActionCounts {
    var counts: ActionCounts = .{};
    for (actions) |action| {
        if (action.requires_confirmation or action.risk == .high or action.risk == .critical) counts.review += 1;
        switch (action.module) {
            .packages => counts.packages += 1,
            .services => counts.services += 1,
            .cron => counts.cron += 1,
            .users => counts.users += 1,
            .ssh => counts.ssh += 1,
            .configs => counts.configs += 1,
            .home_configs => counts.home_configs += 1,
            .appdata => counts.appdata += 1,
            .projects => counts.projects += 1,
            .docker => counts.docker += 1,
            .firewall => counts.firewall += 1,
            .sudoers => counts.sudoers += 1,
            .acl => counts.acl += 1,
            .security_policy => counts.security_policy += 1,
            .storage => counts.storage += 1,
            else => {},
        }
    }
    return counts;
}

test "plan summary includes action count" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    var actions = [_]plan.Action{.{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .description = "Install explicit package on target: nginx",
        .risk = .low,
        .requires_confirmation = false,
    }};

    const migration_plan = plan.MigrationPlan{
        .schema_version = "hostlift.plan.v1",
        .source_inventory_hash = [_]u8{0} ** 32,
        .target_inventory_hash = [_]u8{1} ** 32,
        .compatibility = .{
            .compatible = true,
            .same_distro = true,
            .same_version = true,
            .same_package_manager = true,
            .same_arch = true,
            .reason = "compatible",
        },
        .actions = actions[0..],
        .created_at = 0,
    };

    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    try writePlanSummary(&writer.writer, migration_plan);
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Actions: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "packages/install/nginx") != null);
}
