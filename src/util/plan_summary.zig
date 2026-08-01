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
        \\Manual contract errors: {d}
        \\PostgreSQL contract errors: {d}
        \\Reinstall contract errors: {d}
        \\Dependency errors: {d}
        \\Phase errors: {d}
        \\Duplicate action IDs: {d}
        \\Compatibility errors: {d}
        \\
    , .{
        value.valid,
        value.errors,
        value.warnings,
        value.actions,
        value.requires_confirmation,
        value.critical_actions,
        value.manual_contract_errors,
        value.postgresql_contract_errors,
        value.reinstall_contract_errors,
        value.dependency_errors,
        value.phase_errors,
        value.duplicate_action_ids,
        value.compatibility_errors,
    });
}

// 输出面向个人迁移选择的 action 清单，便于后续按 action id include/exclude。
pub fn writePlanSelection(writer: anytype, value: plan.MigrationPlan) !void {
    const risk_counts = countRisks(value.actions);
    try writer.print(
        \\HostLift migration selection checklist
        \\Full host compatibility: {s}
        \\Actions: {d}
        \\Risk summary: low={d} medium={d} high={d} critical={d}
        \\
        \\Use the batch sections as a personal migration guide, then pass --include-module,
        \\--exclude-module, --include-action or --exclude-action to plan/apply.
        \\
    , .{
        if (value.compatibility.compatible) "compatible" else "incompatible",
        value.actions.len,
        risk_counts.low,
        risk_counts.medium,
        risk_counts.high,
        risk_counts.critical,
    });

    try writeSelectionBatch(writer, value.actions, .base);
    try writeSelectionBatch(writer, value.actions, .config);
    try writeSelectionBatch(writer, value.actions, .data);
    try writeSelectionBatch(writer, value.actions, .runtime);
    try writeSelectionBatch(writer, value.actions, .manual);
    try writeSelectionBatch(writer, value.actions, .other);
}

// 输出迁移后的轻量健康检查报告；只汇总 plan 中的检查项，不执行远程探测。
pub fn writePlanHealthReport(writer: anytype, value: plan.MigrationPlan) !void {
    const counts = countHealthChecks(value.actions);
    const total = counts.services + counts.network + counts.containers + counts.compose + counts.firewall;
    try writer.print(
        \\HostLift post-migration health report
        \\Full host compatibility: {s}
        \\Health checks: {d}
        \\  Services: {d}
        \\  Network listeners: {d}
        \\  Containers: {d}
        \\  Compose projects: {d}
        \\  Firewall connectivity: {d}
        \\
        \\This is a personal checklist generated from the migration plan. It does not
        \\run probes or block apply; run these checks after the relevant batch finishes.
        \\
    , .{
        if (value.compatibility.compatible) "compatible" else "incompatible",
        total,
        counts.services,
        counts.network,
        counts.containers,
        counts.compose,
        counts.firewall,
    });

    if (total == 0) {
        try writer.writeAll("\nNo dedicated post-migration health actions found in this plan.\n");
        return;
    }

    try writeHealthGroup(writer, value.actions, .services);
    try writeHealthGroup(writer, value.actions, .network);
    try writeHealthGroup(writer, value.actions, .containers);
    try writeHealthGroup(writer, value.actions, .compose);
    try writeHealthGroup(writer, value.actions, .firewall);
}

// 输出迁移计划摘要，按模块统计 action 并展示前若干条。
pub fn writePlanSummary(writer: anytype, value: plan.MigrationPlan) !void {
    const counts = countActions(value.actions);
    try writer.print(
        \\HostLift migration plan summary
        \\Full host compatibility: {s}
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
        \\  Resources: {d}
        \\  Container review: {d}
        \\  Network health review: {d}
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
        counts.resources,
        counts.docker,
        counts.network,
        counts.firewall,
        counts.sudoers,
        counts.acl,
        counts.security_policy,
        counts.storage,
        counts.review,
    });

    if (value.actions.len == 0) return;
    try writeBatchRecommendations(writer, counts);
    try writer.writeAll("\nPlanned actions:\n");
    for (value.actions[0..@min(value.actions.len, 40)]) |action| {
        try writer.print(
            "  - {s} [{s}/{s}] confirm={}: {s}\n",
            .{ action.id, @tagName(action.module), @tagName(action.risk), action.requires_confirmation, action.description },
        );
    }
    if (value.actions.len > 40) try writer.print("  ... {d} more\n", .{value.actions.len - 40});
}

fn writeBatchRecommendations(writer: anytype, counts: ActionCounts) !void {
    try writer.print(
        \\
        \\Recommended personal migration batches
        \\  1. Base packages/users: {d}
        \\  2. Configs/SSH/home: {d}
        \\  3. Data/projects/resources: {d}
        \\  4. Services/cron/firewall/containers: {d}
        \\  5. Manual high-risk review: {d}
        \\
    , .{
        counts.packages + counts.users,
        counts.configs + counts.ssh + counts.home_configs,
        counts.appdata + counts.projects + counts.resources,
        counts.services + counts.cron + counts.firewall + counts.docker + counts.network,
        counts.review + counts.sudoers + counts.acl + counts.security_policy + counts.storage,
    });
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
    network: usize = 0,
    firewall: usize = 0,
    sudoers: usize = 0,
    acl: usize = 0,
    security_policy: usize = 0,
    storage: usize = 0,
    resources: usize = 0,
    review: usize = 0,
};

// 风险等级统计，用于让选择清单先显示高风险密度。
const RiskCounts = struct {
    low: usize = 0,
    medium: usize = 0,
    high: usize = 0,
    critical: usize = 0,
};

// 个人迁移推荐批次；只影响人类可读输出，不改变 action 执行语义。
const SelectionBatch = enum {
    base,
    config,
    data,
    runtime,
    manual,
    other,
};

// 健康检查分组；由已有 action id/type 推断，不新增远程副作用。
const HealthGroup = enum {
    services,
    network,
    containers,
    compose,
    firewall,
};

// 迁移后健康检查统计。
const HealthCounts = struct {
    services: usize = 0,
    network: usize = 0,
    containers: usize = 0,
    compose: usize = 0,
    firewall: usize = 0,
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
            .network => counts.network += 1,
            .firewall => counts.firewall += 1,
            .sudoers => counts.sudoers += 1,
            .acl => counts.acl += 1,
            .security_policy => counts.security_policy += 1,
            .storage => counts.storage += 1,
            .resources => counts.resources += 1,
            else => {},
        }
    }
    return counts;
}

// 按风险等级统计计划 action。
fn countRisks(actions: []const plan.Action) RiskCounts {
    var counts: RiskCounts = .{};
    for (actions) |action| {
        switch (action.risk) {
            .low => counts.low += 1,
            .medium => counts.medium += 1,
            .high => counts.high += 1,
            .critical => counts.critical += 1,
        }
    }
    return counts;
}

// 输出一个个人迁移批次中的 action 清单。
fn writeSelectionBatch(writer: anytype, actions: []const plan.Action, batch: SelectionBatch) !void {
    const total = countSelectionBatch(actions, batch);
    if (total == 0) return;
    try writer.print(
        \\
        \\{s} ({d})
        \\Filter hint: {s}
        \\[ ] ACTION_ID | MODULE | RISK | TYPE | PHASE | DEPENDS_ON | SUBJECT
        \\
    , .{ selectionBatchTitle(batch), total, selectionBatchHint(batch) });
    for (actions) |action| {
        if (selectionBatchForAction(action) != batch) continue;
        try writeChecklistAction(writer, action);
    }
}

// 统计指定个人迁移批次中的 action 数量。
fn countSelectionBatch(actions: []const plan.Action, batch: SelectionBatch) usize {
    var total: usize = 0;
    for (actions) |action| {
        if (selectionBatchForAction(action) == batch) total += 1;
    }
    return total;
}

// 将 action 映射到个人迁移批次。
fn selectionBatchForAction(action: plan.Action) SelectionBatch {
    return switch (action.module) {
        .packages, .users => .base,
        .configs, .ssh, .home_configs, .system_baseline, .dev_env, .kernel => .config,
        .appdata, .projects, .resources => .data,
        .services, .cron, .firewall, .docker, .network, .processes => .runtime,
        .sudoers, .acl, .security, .security_policy, .storage => .manual,
    };
}

// 返回个人迁移批次标题。
fn selectionBatchTitle(batch: SelectionBatch) []const u8 {
    return switch (batch) {
        .base => "Batch 1 - Base packages/users",
        .config => "Batch 2 - Configs/SSH/home/system baseline",
        .data => "Batch 3 - Data/projects/resources",
        .runtime => "Batch 4 - Services/cron/firewall/containers/network",
        .manual => "Batch 5 - Manual high-risk review",
        .other => "Other actions",
    };
}

// 返回个人迁移批次的过滤提示。
fn selectionBatchHint(batch: SelectionBatch) []const u8 {
    return switch (batch) {
        .base => "--include-module packages,users",
        .config => "--include-module configs,ssh,home_configs,system_baseline,dev_env,kernel",
        .data => "--include-module appdata,projects,resources",
        .runtime => "--include-module services,cron,firewall,docker,network,processes",
        .manual => "--include-module sudoers,acl,security,security_policy,storage",
        .other => "review action ids and include/exclude explicitly",
    };
}

// 输出一条可勾选 action。
fn writeChecklistAction(writer: anytype, action: plan.Action) !void {
    const dependencies = plan.dependencies(action);
    try writer.print(
        "[ ] {s} | {s} | {s} | {s} | {s} | {s} | {s}\n",
        .{
            action.id,
            @tagName(action.module),
            @tagName(action.risk),
            @tagName(action.action_type),
            if (action.phase) |phase| @tagName(phase) else "legacy",
            if (dependencies.len > 0) dependencies[0] else "-",
            action.subject,
        },
    );
}

// 统计 plan 中的迁移后健康检查项。
fn countHealthChecks(actions: []const plan.Action) HealthCounts {
    var counts: HealthCounts = .{};
    for (actions) |action| {
        const group = healthGroupForAction(action) orelse continue;
        switch (group) {
            .services => counts.services += 1,
            .network => counts.network += 1,
            .containers => counts.containers += 1,
            .compose => counts.compose += 1,
            .firewall => counts.firewall += 1,
        }
    }
    return counts;
}

// 输出一个健康检查分组。
fn writeHealthGroup(writer: anytype, actions: []const plan.Action, group: HealthGroup) !void {
    const total = countHealthGroup(actions, group);
    if (total == 0) return;
    try writer.print(
        \\
        \\{s} ({d})
        \\[ ] ACTION_ID | RISK | SUBJECT | CHECK
        \\
    , .{ healthGroupTitle(group), total });
    for (actions) |action| {
        const action_group = healthGroupForAction(action) orelse continue;
        if (action_group != group) continue;
        try writer.print(
            "[ ] {s} | {s} | {s} | {s}\n",
            .{ action.id, @tagName(action.risk), action.subject, action.description },
        );
    }
}

// 统计指定健康检查分组中的 action 数量。
fn countHealthGroup(actions: []const plan.Action, group: HealthGroup) usize {
    var total: usize = 0;
    for (actions) |action| {
        const action_group = healthGroupForAction(action) orelse continue;
        if (action_group == group) total += 1;
    }
    return total;
}

// 从 action id/type 推断健康检查分组。
fn healthGroupForAction(action: plan.Action) ?HealthGroup {
    if (std.mem.startsWith(u8, action.id, "services/check-status/")) return .services;
    if (std.mem.startsWith(u8, action.id, "network/check-listener/")) return .network;
    if (std.mem.startsWith(u8, action.id, "docker/check-container/")) return .containers;
    if (std.mem.startsWith(u8, action.id, "firewall/check-connectivity/")) return .firewall;
    if (action.action_type == .verify_compose_project or std.mem.startsWith(u8, action.id, "projects/compose-verify/")) return .compose;
    return null;
}

// 返回健康检查分组标题。
fn healthGroupTitle(group: HealthGroup) []const u8 {
    return switch (group) {
        .services => "Services",
        .network => "Network listeners",
        .containers => "Containers",
        .compose => "Compose projects",
        .firewall => "Firewall connectivity",
    };
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
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Resources: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Recommended personal migration batches") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "packages/install/nginx") != null);
}

test "plan selection prints action id and subject" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    var actions = [_]plan.Action{.{
        .id = "resources/copy//home/alice/.config",
        .module = .resources,
        .action_type = .copy_data_path,
        .subject = "/home/alice/.config",
        .description = "Copy login state",
        .risk = .high,
        .requires_confirmation = true,
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
    try writePlanSelection(&writer.writer, migration_plan);
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "resources/copy//home/alice/.config") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "/home/alice/.config") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Risk summary: low=0 medium=0 high=1 critical=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Batch 3 - Data/projects/resources") != null);
}

test "plan health report prints grouped post migration checks" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    var actions = [_]plan.Action{
        .{
            .id = "services/check-status/nginx.service",
            .module = .services,
            .action_type = .manual_step,
            .subject = "nginx.service",
            .description = "Check systemctl status and journal tail",
            .risk = .high,
            .requires_confirmation = true,
        },
        .{
            .id = "network/check-listener/tcp-443-nginx",
            .module = .network,
            .action_type = .manual_step,
            .subject = "0.0.0.0",
            .description = "Check migrated listener",
            .risk = .high,
            .requires_confirmation = true,
        },
        .{
            .id = "packages/install/nginx",
            .module = .packages,
            .action_type = .install_package,
            .description = "Install package",
            .risk = .low,
            .requires_confirmation = false,
        },
    };

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
    try writePlanHealthReport(&writer.writer, migration_plan);
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Health checks: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Services (1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Network listeners (1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "packages/install/nginx") == null);
}
