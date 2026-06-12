const std = @import("std");
const schema = @import("schema.zig");

pub const validation_report_schema_version = "hostlift.plan.validation.v1";

// 校验结果报告结构体，汇总错误数、警告数和关键动作数。
pub const ValidationReport = struct {
    schema_version: []const u8,
    valid: bool,
    errors: u32,
    warnings: u32,
    actions: usize,
    requires_confirmation: usize,
    critical_actions: usize,
};

// 校验迁移计划的 schema、兼容性和高风险 action 确认要求。
pub fn validate(value: schema.MigrationPlan) ValidationReport {
    var errors: u32 = 0;
    var warnings: u32 = 0;
    var requires_confirmation: usize = 0;
    var critical_actions: usize = 0;

    if (!std.mem.eql(u8, value.schema_version, "hostlift.plan.v1")) errors += 1;
    if (!value.compatibility.compatible) errors += 1;
    if (value.actions.len == 0 and value.compatibility.compatible) warnings += 1;

    for (value.actions) |action| {
        if (action.id.len == 0) errors += 1;
        if (action.description.len == 0) errors += 1;
        if (action.requires_confirmation) requires_confirmation += 1;
        if (action.action_type == .manual_step) {
            if (!action.requires_confirmation) errors += 1;
            if (action.risk == .low or action.risk == .medium) errors += 1;
        }
        if (action.risk == .critical) {
            critical_actions += 1;
            if (!action.requires_confirmation) errors += 1;
        }
        if ((action.risk == .medium or action.risk == .high) and !action.requires_confirmation) warnings += 1;
    }

    return .{
        .schema_version = validation_report_schema_version,
        .valid = errors == 0,
        .errors = errors,
        .warnings = warnings,
        .actions = value.actions.len,
        .requires_confirmation = requires_confirmation,
        .critical_actions = critical_actions,
    };
}

test "validator accepts compatible plan with safe action" {
    var actions = [_]schema.Action{.{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .description = "Install explicit package on target: nginx",
        .risk = .low,
        .requires_confirmation = false,
    }};
    const migration_plan = fixture(true, actions[0..]);

    const report = validate(migration_plan);

    try std.testing.expect(report.valid);
    try std.testing.expectEqual(@as(u32, 0), report.errors);
    try std.testing.expectEqual(@as(usize, 1), report.actions);
}

test "validator rejects incompatible plans and critical actions without confirmation" {
    var actions = [_]schema.Action{.{
        .id = "danger",
        .module = .security,
        .action_type = .run_command,
        .description = "Dangerous command",
        .risk = .critical,
        .requires_confirmation = false,
    }};
    const migration_plan = fixture(false, actions[0..]);

    const report = validate(migration_plan);

    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(u32, 2), report.errors);
    try std.testing.expectEqual(@as(usize, 1), report.critical_actions);
}

test "validator rejects manual steps without high risk and confirmation" {
    var actions = [_]schema.Action{
        .{
            .id = "sudoers/review//etc/sudoers.d/deploy",
            .module = .sudoers,
            .action_type = .manual_step,
            .description = "Review sudoers metadata before migration",
            .risk = .medium,
            .requires_confirmation = true,
        },
        .{
            .id = "storage/review-fstab//data",
            .module = .storage,
            .action_type = .manual_step,
            .description = "Review fstab entry before migration",
            .risk = .high,
            .requires_confirmation = false,
        },
    };
    const migration_plan = fixture(true, actions[0..]);

    const report = validate(migration_plan);

    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(u32, 2), report.errors);
    try std.testing.expectEqual(@as(usize, 1), report.requires_confirmation);
}

test "validator accepts confirmed high-risk manual step" {
    var actions = [_]schema.Action{.{
        .id = "acl/review//srv/app",
        .module = .acl,
        .action_type = .manual_step,
        .description = "Review extended ACL before migration",
        .risk = .high,
        .requires_confirmation = true,
    }};
    const migration_plan = fixture(true, actions[0..]);

    const report = validate(migration_plan);

    try std.testing.expect(report.valid);
    try std.testing.expectEqual(@as(u32, 0), report.errors);
    try std.testing.expectEqual(@as(usize, 1), report.requires_confirmation);
}

// 测试辅助：构造最小迁移计划。
fn fixture(compatible: bool, actions: []schema.Action) schema.MigrationPlan {
    return .{
        .schema_version = "hostlift.plan.v1",
        .source_inventory_hash = [_]u8{0} ** 32,
        .target_inventory_hash = [_]u8{1} ** 32,
        .compatibility = .{
            .compatible = compatible,
            .same_distro = compatible,
            .same_version = compatible,
            .same_package_manager = compatible,
            .same_arch = true,
            .reason = if (compatible) "compatible" else "incompatible",
        },
        .actions = actions,
        .created_at = 0,
    };
}
