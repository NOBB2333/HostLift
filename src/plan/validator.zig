const std = @import("std");
const schema = @import("schema.zig");
const plan_filter = @import("filter.zig");
const action_compatibility = @import("action_compatibility.zig");
const postgresql_artifacts = @import("../postgresql/artifacts.zig");
const reinstall_schema = @import("../reinstall/schema.zig");
const reinstall_artifacts = @import("../reinstall/artifacts.zig");

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
    manual_contract_errors: u32,
    postgresql_contract_errors: u32,
    reinstall_contract_errors: u32,
    dependency_errors: u32,
    phase_errors: u32,
    duplicate_action_ids: u32,
    compatibility_errors: u32,
};

// 校验迁移计划的 schema、兼容性和高风险 action 确认要求。
pub fn validate(value: schema.MigrationPlan) ValidationReport {
    var errors: u32 = 0;
    var warnings: u32 = 0;
    var requires_confirmation: usize = 0;
    var critical_actions: usize = 0;
    var manual_contract_errors: u32 = 0;
    var postgresql_contract_errors: u32 = 0;
    var reinstall_contract_errors: u32 = 0;
    var dependency_errors: u32 = 0;
    var phase_errors: u32 = 0;
    var duplicate_action_ids: u32 = 0;
    var compatibility_errors: u32 = 0;
    var postgresql_action_count: u8 = 0;
    var postgresql_action_mask: u8 = 0;

    const is_v1 = std.mem.eql(u8, value.schema_version, schema.schema_version_v1);
    const is_v2 = std.mem.eql(u8, value.schema_version, schema.schema_version_v2);
    if (!is_v1 and !is_v2) errors += 1;
    const fully_compatible = action_compatibility.isFullyCompatible(value.compatibility);
    if (value.compatibility.compatible != fully_compatible) {
        errors += 1;
        compatibility_errors += 1;
    }
    if (is_v1 and !fully_compatible) {
        errors += 1;
        compatibility_errors += 1;
    }
    if (value.actions.len == 0 and value.compatibility.compatible) warnings += 1;

    for (value.actions, 0..) |action, action_index| {
        if (action.id.len == 0) errors += 1;
        if (action.description.len == 0) errors += 1;
        if (is_v2 and !action_compatibility.isAllowed(action, value.compatibility)) {
            errors += 1;
            compatibility_errors += 1;
        }
        if (is_v2 and action.phase == null) {
            errors += 1;
            phase_errors += 1;
        }
        for (value.actions[0..action_index]) |previous| {
            if (std.mem.eql(u8, previous.id, action.id)) {
                errors += 1;
                duplicate_action_ids += 1;
            }
        }
        if (action.requires_confirmation) requires_confirmation += 1;
        if (isPostgresqlAction(action.action_type)) {
            postgresql_action_count +|= 1;
            postgresql_action_mask |= postgresqlActionBit(action.action_type);
            if (!is_v2 or !validPostgresqlAction(action, value.source_inventory_hash)) {
                errors += 1;
                postgresql_contract_errors += 1;
            }
        }
        if (isReinstallAction(action.action_type)) {
            if (!is_v2 or !validReinstallAction(value.actions, action, value.source_inventory_hash)) {
                errors += 1;
                reinstall_contract_errors += 1;
            }
        } else if (action.reinstall != null) {
            errors += 1;
            reinstall_contract_errors += 1;
        }
        if (action.action_type == .manual_step) {
            if (!action.requires_confirmation) errors += 1;
            if (action.risk == .low or action.risk == .medium) errors += 1;
            if (is_v2 and !validManualTask(action.manual_task)) {
                errors += 1;
                manual_contract_errors += 1;
            }
        } else if (is_v2 and action.manual_task != null) {
            errors += 1;
            manual_contract_errors += 1;
        }
        if (action.risk == .critical) {
            critical_actions += 1;
            if (!action.requires_confirmation) errors += 1;
        }
        if ((action.risk == .medium or action.risk == .high) and !action.requires_confirmation) warnings += 1;

        for (schema.dependencies(action)) |dependency_id| {
            const dependency_index = findActionIndex(value.actions, dependency_id) orelse {
                errors += 1;
                dependency_errors += 1;
                continue;
            };
            if (dependency_index >= action_index) {
                errors += 1;
                dependency_errors += 1;
            }
            if (action.phase != null and value.actions[dependency_index].phase != null and
                @intFromEnum(value.actions[dependency_index].phase.?) > @intFromEnum(action.phase.?))
            {
                errors += 1;
                phase_errors += 1;
            }
            if (isPostgresqlAction(action.action_type) and
                !std.mem.eql(u8, action.subject, value.actions[dependency_index].subject))
            {
                errors += 1;
                postgresql_contract_errors += 1;
            }
        }
    }
    const reinstall_global_errors = reinstallGlobalContractErrors(value.actions);
    errors +|= reinstall_global_errors;
    reinstall_contract_errors +|= reinstall_global_errors;
    if (postgresql_action_count > 0 and (postgresql_action_count != 5 or postgresql_action_mask != 0b1_1111)) {
        errors += 1;
        postgresql_contract_errors += 1;
    }
    if (hasDependencyCycle(value.actions)) {
        errors += 1;
        dependency_errors += 1;
    }

    return .{
        .schema_version = validation_report_schema_version,
        .valid = errors == 0,
        .errors = errors,
        .warnings = warnings,
        .actions = value.actions.len,
        .requires_confirmation = requires_confirmation,
        .critical_actions = critical_actions,
        .manual_contract_errors = manual_contract_errors,
        .postgresql_contract_errors = postgresql_contract_errors,
        .reinstall_contract_errors = reinstall_contract_errors,
        .dependency_errors = dependency_errors,
        .phase_errors = phase_errors,
        .duplicate_action_ids = duplicate_action_ids,
        .compatibility_errors = compatibility_errors,
    };
}

fn isReinstallAction(action_type: schema.ActionType) bool {
    return switch (action_type) {
        .reinstall_download, .reinstall_execute, .reinstall_verify => true,
        else => false,
    };
}

fn validReinstallAction(actions: []const schema.Action, action: schema.Action, source_inventory_hash: [32]u8) bool {
    const spec = action.reinstall orelse return false;
    if (action.module != .resources or !action.requires_confirmation or action.manual_task != null) return false;
    const recipe = reinstall_schema.Recipe{
        .id = spec.recipe_id,
        .manual_action_id = spec.source_manual_action_id,
        .kind = @enumFromInt(@intFromEnum(spec.kind)),
        .source_url = spec.source_url,
        .sha256 = spec.sha256,
        .artifact_size_bytes = spec.artifact_size_bytes,
        .target_distro_id = spec.target_distro_id,
        .target_distro_version = spec.target_distro_version,
        .target_arch = spec.target_arch,
        .install_argv = spec.install_argv,
        .verify_argv = spec.verify_argv,
        .verify_stdout_sha256 = spec.verify_stdout_sha256,
        .managed_paths = spec.managed_paths,
    };
    if (!std.mem.eql(u8, spec.schema_version, reinstall_schema.schema_version)) return false;
    reinstall_schema.validateRecipe(recipe) catch return false;
    reinstall_artifacts.validateRoot(action.subject, source_inventory_hash, spec.recipe_id) catch return false;
    if (findActionIndex(actions, spec.source_manual_action_id) != null) return false;

    const expected = switch (action.action_type) {
        .reinstall_download => .{ "resources/reinstall-download", schema.ActionPhase.transfer, schema.RiskLevel.high, @as(?[]const u8, null) },
        .reinstall_execute => .{ "resources/reinstall-execute", schema.ActionPhase.restore, schema.RiskLevel.critical, @as(?[]const u8, "resources/reinstall-download") },
        .reinstall_verify => .{ "resources/reinstall-verify", schema.ActionPhase.verify, schema.RiskLevel.high, @as(?[]const u8, "resources/reinstall-execute") },
        else => return false,
    };
    if (!matchesRecipeActionId(action.id, expected[0], spec.recipe_id) or action.phase == null or action.phase.? != expected[1] or action.risk != expected[2]) return false;
    const dependencies = schema.dependencies(action);
    if (expected[3]) |prefix| {
        if (dependencies.len != 1 or !matchesRecipeActionId(dependencies[0], prefix, spec.recipe_id)) return false;
    } else if (dependencies.len != 0) return false;

    const download = findReinstallAction(actions, .reinstall_download, spec.recipe_id) orelse return false;
    const execute = findReinstallAction(actions, .reinstall_execute, spec.recipe_id) orelse return false;
    const verify = findReinstallAction(actions, .reinstall_verify, spec.recipe_id) orelse return false;
    return reinstallSpecEqual(download.reinstall orelse return false, spec) and
        reinstallSpecEqual(execute.reinstall orelse return false, spec) and
        reinstallSpecEqual(verify.reinstall orelse return false, spec) and
        std.mem.eql(u8, download.subject, action.subject) and
        std.mem.eql(u8, execute.subject, action.subject) and
        std.mem.eql(u8, verify.subject, action.subject);
}

fn matchesRecipeActionId(value: []const u8, prefix: []const u8, recipe_id: []const u8) bool {
    return value.len == prefix.len + 1 + recipe_id.len and
        std.mem.startsWith(u8, value, prefix) and
        value[prefix.len] == '/' and
        std.mem.eql(u8, value[prefix.len + 1 ..], recipe_id);
}

fn findReinstallAction(actions: []const schema.Action, action_type: schema.ActionType, recipe_id: []const u8) ?schema.Action {
    for (actions) |candidate| {
        if (candidate.action_type != action_type or candidate.reinstall == null) continue;
        if (std.mem.eql(u8, candidate.reinstall.?.recipe_id, recipe_id)) return candidate;
    }
    return null;
}

fn reinstallGlobalContractErrors(actions: []const schema.Action) u32 {
    var errors: u32 = 0;
    for (actions, 0..) |action, action_index| {
        if (action.action_type != .reinstall_download or action.reinstall == null) continue;
        const spec = action.reinstall.?;
        if (countReinstallActions(actions, .reinstall_download, spec.recipe_id) != 1 or
            countReinstallActions(actions, .reinstall_execute, spec.recipe_id) != 1 or
            countReinstallActions(actions, .reinstall_verify, spec.recipe_id) != 1)
        {
            errors +|= 1;
        }
        for (actions[0..action_index]) |previous| {
            if (previous.action_type != .reinstall_download or previous.reinstall == null) continue;
            const previous_spec = previous.reinstall.?;
            if (std.mem.eql(u8, previous_spec.recipe_id, spec.recipe_id) or
                std.mem.eql(u8, previous_spec.source_manual_action_id, spec.source_manual_action_id) or
                managedPathsOverlap(previous_spec.managed_paths, spec.managed_paths))
            {
                errors +|= 1;
            }
        }
    }
    return errors;
}

fn countReinstallActions(actions: []const schema.Action, action_type: schema.ActionType, recipe_id: []const u8) usize {
    var count: usize = 0;
    for (actions) |action| {
        if (action.action_type == action_type and action.reinstall != null and std.mem.eql(u8, action.reinstall.?.recipe_id, recipe_id)) count += 1;
    }
    return count;
}

fn managedPathsOverlap(left: []const []const u8, right: []const []const u8) bool {
    for (left) |left_path| {
        for (right) |right_path| if (pathsOverlap(left_path, right_path)) return true;
    }
    return false;
}

fn pathsOverlap(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    if (left.len < right.len and std.mem.startsWith(u8, right, left) and right[left.len] == '/') return true;
    return right.len < left.len and std.mem.startsWith(u8, left, right) and left[right.len] == '/';
}

fn reinstallSpecEqual(left: schema.ReinstallSpec, right: schema.ReinstallSpec) bool {
    return std.mem.eql(u8, left.schema_version, right.schema_version) and
        std.mem.eql(u8, left.recipe_id, right.recipe_id) and
        std.mem.eql(u8, left.source_manual_action_id, right.source_manual_action_id) and
        left.kind == right.kind and
        std.mem.eql(u8, left.source_url, right.source_url) and
        std.mem.eql(u8, left.sha256, right.sha256) and
        left.artifact_size_bytes == right.artifact_size_bytes and
        std.mem.eql(u8, left.target_distro_id, right.target_distro_id) and
        std.mem.eql(u8, left.target_distro_version, right.target_distro_version) and
        std.mem.eql(u8, left.target_arch, right.target_arch) and
        stringSlicesEqual(left.install_argv, right.install_argv) and
        stringSlicesEqual(left.verify_argv, right.verify_argv) and
        std.mem.eql(u8, left.verify_stdout_sha256, right.verify_stdout_sha256) and
        stringSlicesEqual(left.managed_paths, right.managed_paths);
}

fn stringSlicesEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value| if (!std.mem.eql(u8, left_value, right_value)) return false;
    return true;
}

fn isPostgresqlAction(action_type: schema.ActionType) bool {
    return postgresqlActionBit(action_type) != 0;
}

fn postgresqlActionBit(action_type: schema.ActionType) u8 {
    return switch (action_type) {
        .postgresql_dump => 1 << 0,
        .postgresql_target_baseline => 1 << 1,
        .postgresql_transfer => 1 << 2,
        .postgresql_restore => 1 << 3,
        .postgresql_verify => 1 << 4,
        else => 0,
    };
}

fn validPostgresqlAction(action: schema.Action, source_inventory_hash: [32]u8) bool {
    if (action.module != .appdata or !action.requires_confirmation or action.manual_task != null) return false;
    postgresql_artifacts.validateRootForInventoryHash(action.subject, source_inventory_hash) catch return false;
    const expected = switch (action.action_type) {
        .postgresql_dump => .{ "appdata/postgresql-dump/cluster", schema.ActionPhase.quiesce, schema.RiskLevel.critical, null },
        .postgresql_target_baseline => .{ "appdata/postgresql-target-baseline/cluster", schema.ActionPhase.quiesce, schema.RiskLevel.critical, "appdata/postgresql-dump/cluster" },
        .postgresql_transfer => .{ "appdata/postgresql-transfer/cluster", schema.ActionPhase.transfer, schema.RiskLevel.critical, "appdata/postgresql-target-baseline/cluster" },
        .postgresql_restore => .{ "appdata/postgresql-restore/cluster", schema.ActionPhase.restore, schema.RiskLevel.critical, "appdata/postgresql-transfer/cluster" },
        .postgresql_verify => .{ "appdata/postgresql-verify/cluster", schema.ActionPhase.verify, schema.RiskLevel.high, "appdata/postgresql-restore/cluster" },
        else => return false,
    };
    if (!std.mem.eql(u8, action.id, expected[0]) or action.phase == null or action.phase.? != expected[1] or action.risk != expected[2]) return false;
    const dependencies = schema.dependencies(action);
    if (expected[3]) |dependency| return dependencies.len == 1 and std.mem.eql(u8, dependencies[0], dependency);
    return dependencies.len == 0;
}

// 校验过滤后的 action 集合仍包含每条显式依赖；apply 和 plan 输出共用。
pub fn validateSelection(actions: []const schema.Action, filter: plan_filter.ActionFilter) !void {
    for (actions) |action| {
        if (!filter.matches(action)) continue;
        for (schema.dependencies(action)) |dependency_id| {
            const dependency_index = findActionIndex(actions, dependency_id) orelse return error.ActionDependencyMissing;
            if (!filter.matches(actions[dependency_index])) return error.SelectedActionDependencyMissing;
        }
    }
}

fn validManualTask(task_value: ?schema.ManualTask) bool {
    const task = task_value orelse return false;
    if (!std.mem.eql(u8, task.schema_version, schema.manual_task_schema_version)) return false;
    if (task.provider.len == 0 or task.inputs.len == 0 or task.preconditions.len == 0 or task.expected_outputs.len == 0 or task.verify_probes.len == 0) return false;
    if (!std.mem.eql(u8, task.evidence_schema, schema.manual_evidence_schema_version)) return false;
    for (task.inputs, 0..) |input, input_index| {
        if (input.name.len == 0) return false;
        if (input.value == null and input.secret_ref == null) return false;
        if (input.value != null and input.secret_ref != null) return false;
        for (task.inputs[0..input_index]) |previous| {
            if (std.mem.eql(u8, previous.name, input.name)) return false;
        }
    }
    if (task.secret_refs) |secret_refs| for (secret_refs, 0..) |secret_ref, secret_index| {
        if (secret_ref.len == 0) return false;
        for (secret_refs[0..secret_index]) |previous| {
            if (std.mem.eql(u8, previous, secret_ref)) return false;
        }
    };
    for (task.preconditions, 0..) |condition, condition_index| {
        if (condition.target.len == 0) return false;
        for (task.preconditions[0..condition_index]) |previous| {
            if (previous.kind == condition.kind and std.mem.eql(u8, previous.target, condition.target)) return false;
        }
    }
    for (task.expected_outputs, 0..) |output, output_index| {
        if (output.name.len == 0) return false;
        for (task.expected_outputs[0..output_index]) |previous| {
            if (std.mem.eql(u8, previous.name, output.name)) return false;
        }
    }
    for (task.verify_probes, 0..) |probe, probe_index| {
        if (probe.target.len == 0) return false;
        for (task.verify_probes[0..probe_index]) |previous| {
            if (previous.kind == probe.kind and std.mem.eql(u8, previous.target, probe.target)) return false;
        }
    }
    return true;
}

fn findActionIndex(actions: []const schema.Action, action_id: []const u8) ?usize {
    for (actions, 0..) |action, index| {
        if (std.mem.eql(u8, action.id, action_id)) return index;
    }
    return null;
}

fn hasDependencyCycle(actions: []const schema.Action) bool {
    for (actions) |action| {
        if (reaches(actions, action.id, action.id, 0)) return true;
    }
    return false;
}

fn reaches(actions: []const schema.Action, current_id: []const u8, target_id: []const u8, depth: usize) bool {
    if (depth > actions.len) return true;
    const current_index = findActionIndex(actions, current_id) orelse return false;
    for (schema.dependencies(actions[current_index])) |dependency_id| {
        if (std.mem.eql(u8, dependency_id, target_id)) return true;
        if (reaches(actions, dependency_id, target_id, depth + 1)) return true;
    }
    return false;
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

test "validator v2 accepts portable action on a partially compatible target" {
    var actions = [_]schema.Action{.{
        .id = "projects/copy//srv/app",
        .module = .projects,
        .action_type = .copy_project_path,
        .description = "Copy project",
        .risk = .medium,
        .requires_confirmation = true,
        .phase = .transfer,
    }};
    var migration_plan = fixture(false, &actions);
    migration_plan.schema_version = schema.schema_version_v2;

    const report = validate(migration_plan);

    try std.testing.expect(report.valid);
    try std.testing.expectEqual(@as(u32, 0), report.compatibility_errors);
}

test "validator v2 rejects distro-bound action on a mismatched target" {
    var actions = [_]schema.Action{.{
        .id = "configs/write//etc/app.conf",
        .module = .configs,
        .action_type = .write_file,
        .description = "Write system config",
        .risk = .high,
        .requires_confirmation = true,
        .phase = .transfer,
    }};
    var migration_plan = fixture(false, &actions);
    migration_plan.schema_version = schema.schema_version_v2;

    const report = validate(migration_plan);

    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(u32, 1), report.compatibility_errors);
}

test "validator rejects a forged full compatibility boolean" {
    var migration_plan = fixture(true, &.{});
    migration_plan.schema_version = schema.schema_version_v2;
    migration_plan.compatibility.same_arch = false;

    const report = validate(migration_plan);

    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(u32, 1), report.compatibility_errors);
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

test "validator rejects duplicate provider input names and empty secret refs" {
    var inputs = [_]schema.ManualInput{
        .{ .name = "subject", .value = "app" },
        .{ .name = "subject", .value = "duplicate" },
    };
    var secret_refs = [_][]const u8{""};
    var preconditions = [_]schema.ManualCondition{.{ .kind = .approval, .target = "app" }};
    var outputs = [_]schema.ManualOutput{.{ .name = "installed_artifact" }};
    var probes = [_]schema.ManualProbe{.{ .kind = .manual_evidence, .target = "app" }};
    var actions = [_]schema.Action{.{
        .id = "resources/reinstall/app",
        .module = .resources,
        .action_type = .manual_step,
        .description = "reinstall",
        .risk = .high,
        .requires_confirmation = true,
        .phase = .prepare,
        .manual_task = .{
            .schema_version = schema.manual_task_schema_version,
            .kind = .reinstall,
            .provider = "resource_reinstall",
            .inputs = &inputs,
            .secret_refs = &secret_refs,
            .preconditions = &preconditions,
            .expected_outputs = &outputs,
            .verify_probes = &probes,
            .rollback_policy = .manual,
            .evidence_schema = "hostlift.manual_evidence.v1",
        },
    }};
    var migration_plan = fixture(true, &actions);
    migration_plan.schema_version = schema.schema_version_v2;

    const report = validate(migration_plan);
    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(u32, 1), report.manual_contract_errors);
}

test "validator rejects ambiguous manual evidence contract keys" {
    var inputs = [_]schema.ManualInput{.{ .name = "subject", .value = "app" }};
    var preconditions = [_]schema.ManualCondition{
        .{ .kind = .approval, .target = "app" },
        .{ .kind = .approval, .target = "app" },
    };
    var outputs = [_]schema.ManualOutput{
        .{ .name = "installed_artifact" },
        .{ .name = "installed_artifact" },
    };
    var probes = [_]schema.ManualProbe{
        .{ .kind = .manual_evidence, .target = "app" },
        .{ .kind = .manual_evidence, .target = "app" },
    };
    var actions = [_]schema.Action{.{
        .id = "resources/reinstall/app",
        .module = .resources,
        .action_type = .manual_step,
        .description = "reinstall",
        .risk = .high,
        .requires_confirmation = true,
        .phase = .prepare,
        .manual_task = .{
            .schema_version = schema.manual_task_schema_version,
            .kind = .reinstall,
            .provider = "resource_reinstall",
            .inputs = &inputs,
            .preconditions = &preconditions,
            .expected_outputs = &outputs,
            .verify_probes = &probes,
            .rollback_policy = .manual,
            .evidence_schema = schema.manual_evidence_schema_version,
        },
    }};
    var migration_plan = fixture(true, &actions);
    migration_plan.schema_version = schema.schema_version_v2;

    const report = validate(migration_plan);
    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(u32, 1), report.manual_contract_errors);
}

test "validator rejects missing forward and cyclic dependencies" {
    var missing_actions = [_]schema.Action{.{
        .id = "projects/compose-up//srv/app",
        .module = .projects,
        .action_type = .start_compose_project,
        .description = "start",
        .risk = .high,
        .requires_confirmation = true,
        .depends_on = &.{"projects/copy//srv/app"},
    }};
    try std.testing.expect(!validate(fixture(true, &missing_actions)).valid);

    var cyclic_actions = [_]schema.Action{
        .{ .id = "a", .module = .projects, .action_type = .run_command, .description = "a", .risk = .low, .requires_confirmation = false, .depends_on = &.{"b"} },
        .{ .id = "b", .module = .projects, .action_type = .run_command, .description = "b", .risk = .low, .requires_confirmation = false, .depends_on = &.{"a"} },
    };
    try std.testing.expect(!validate(fixture(true, &cyclic_actions)).valid);
}

test "selection validation requires dependency closure" {
    var actions = [_]schema.Action{
        .{ .id = "projects/copy//srv/app", .module = .projects, .action_type = .copy_project_path, .description = "copy", .risk = .high, .requires_confirmation = true },
        .{ .id = "projects/compose-up//srv/app", .module = .projects, .action_type = .start_compose_project, .description = "start", .risk = .high, .requires_confirmation = true, .depends_on = &.{"projects/copy//srv/app"} },
    };
    var filter: plan_filter.ActionFilter = .empty;
    defer filter.deinit(std.testing.allocator);
    try filter.appendActionPattern(std.testing.allocator, .include, "projects/compose-up/");
    try std.testing.expectError(error.SelectedActionDependencyMissing, validateSelection(&actions, filter));
    try validateSelection(&actions, .empty);
}

test "validator rejects incomplete or unsafe PostgreSQL provider contracts" {
    const root = "/var/lib/hostlift/artifacts/postgresql/abababababababababababababababababababababababababababababababab";
    var actions = [_]schema.Action{.{
        .id = "appdata/postgresql-restore/cluster",
        .module = .appdata,
        .action_type = .postgresql_restore,
        .subject = root,
        .description = "unsafe partial restore",
        .risk = .critical,
        .requires_confirmation = true,
        .phase = .restore,
    }};
    var migration_plan = fixture(true, &actions);
    migration_plan.schema_version = schema.schema_version_v2;

    const report = validate(migration_plan);
    try std.testing.expect(!report.valid);
    try std.testing.expect(report.postgresql_contract_errors >= 1);

    actions[0].subject = "/tmp/untrusted.sql";
    const unsafe_path_report = validate(migration_plan);
    try std.testing.expect(!unsafe_path_report.valid);
    try std.testing.expect(unsafe_path_report.postgresql_contract_errors >= 1);
}

test "validator rejects overlapping managed paths across forged reinstall chains" {
    var paths_a = [_][]const u8{"/usr/local/bin/tool"};
    var paths_b = [_][]const u8{"/opt/tool-b"};
    const spec_a = reinstallSpecFixture("tool-a", "resources/reinstall//usr/local/bin/tool", &paths_a);
    const spec_b = reinstallSpecFixture("tool-b", "resources/reinstall//opt/tool-b", &paths_b);
    var actions = [_]schema.Action{
        reinstallActionFixture(.reinstall_download, "tool-a", "/var/lib/hostlift/artifacts/reinstall/0000000000000000000000000000000000000000000000000000000000000000/tool-a", spec_a),
        reinstallActionFixture(.reinstall_execute, "tool-a", "/var/lib/hostlift/artifacts/reinstall/0000000000000000000000000000000000000000000000000000000000000000/tool-a", spec_a),
        reinstallActionFixture(.reinstall_verify, "tool-a", "/var/lib/hostlift/artifacts/reinstall/0000000000000000000000000000000000000000000000000000000000000000/tool-a", spec_a),
        reinstallActionFixture(.reinstall_download, "tool-b", "/var/lib/hostlift/artifacts/reinstall/0000000000000000000000000000000000000000000000000000000000000000/tool-b", spec_b),
        reinstallActionFixture(.reinstall_execute, "tool-b", "/var/lib/hostlift/artifacts/reinstall/0000000000000000000000000000000000000000000000000000000000000000/tool-b", spec_b),
        reinstallActionFixture(.reinstall_verify, "tool-b", "/var/lib/hostlift/artifacts/reinstall/0000000000000000000000000000000000000000000000000000000000000000/tool-b", spec_b),
    };
    var migration_plan = fixture(true, &actions);
    migration_plan.schema_version = schema.schema_version_v2;

    try std.testing.expect(validate(migration_plan).valid);
    try std.testing.expectEqual(@as(u32, 0), reinstallGlobalContractErrors(&actions));

    paths_b[0] = "/usr/local/bin/tool";
    const overlap_report = validate(migration_plan);
    try std.testing.expect(!overlap_report.valid);
    try std.testing.expect(overlap_report.reinstall_contract_errors >= 1);
    try std.testing.expectEqual(@as(u32, 1), reinstallGlobalContractErrors(&actions));
}

fn reinstallSpecFixture(recipe_id: []const u8, manual_action_id: []const u8, managed_paths: []const []const u8) schema.ReinstallSpec {
    return .{
        .schema_version = reinstall_schema.schema_version,
        .recipe_id = recipe_id,
        .source_manual_action_id = manual_action_id,
        .kind = .verified_script,
        .source_url = "https://downloads.example.test/install.sh",
        .sha256 = "01" ** 32,
        .artifact_size_bytes = 1024,
        .target_distro_id = "ubuntu",
        .target_distro_version = "24.04",
        .target_arch = "x86_64",
        .install_argv = &.{ "sh", reinstall_schema.artifact_placeholder },
        .verify_argv = &.{ "test", "-e", "/usr/local/bin/tool" },
        .verify_stdout_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        .managed_paths = managed_paths,
    };
}

fn reinstallActionFixture(action_type: schema.ActionType, recipe_id: []const u8, subject: []const u8, spec: schema.ReinstallSpec) schema.Action {
    const id = if (std.mem.eql(u8, recipe_id, "tool-a")) switch (action_type) {
        .reinstall_download => "resources/reinstall-download/tool-a",
        .reinstall_execute => "resources/reinstall-execute/tool-a",
        .reinstall_verify => "resources/reinstall-verify/tool-a",
        else => unreachable,
    } else switch (action_type) {
        .reinstall_download => "resources/reinstall-download/tool-b",
        .reinstall_execute => "resources/reinstall-execute/tool-b",
        .reinstall_verify => "resources/reinstall-verify/tool-b",
        else => unreachable,
    };
    const dependencies: ?[]const []const u8 = switch (action_type) {
        .reinstall_download => null,
        .reinstall_execute => if (std.mem.eql(u8, recipe_id, "tool-a")) &.{"resources/reinstall-download/tool-a"} else &.{"resources/reinstall-download/tool-b"},
        .reinstall_verify => if (std.mem.eql(u8, recipe_id, "tool-a")) &.{"resources/reinstall-execute/tool-a"} else &.{"resources/reinstall-execute/tool-b"},
        else => unreachable,
    };
    const risk: schema.RiskLevel = if (action_type == .reinstall_execute) .critical else .high;
    const phase: schema.ActionPhase = switch (action_type) {
        .reinstall_download => .transfer,
        .reinstall_execute => .restore,
        .reinstall_verify => .verify,
        else => unreachable,
    };
    return .{
        .id = id,
        .module = .resources,
        .action_type = action_type,
        .subject = subject,
        .description = "verified reinstall",
        .risk = risk,
        .requires_confirmation = true,
        .phase = phase,
        .depends_on = dependencies,
        .reinstall = spec,
    };
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
