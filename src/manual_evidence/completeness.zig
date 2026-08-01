const std = @import("std");
const evidence_schema = @import("schema.zig");
const plan_schema = @import("../plan/schema.zig");

// CLI 已对每份 evidence 做单文件校验；聚合层只接收校验摘要和来源标识。
pub const ObservedEvidence = struct {
    source_ref: []const u8,
    action_id: []const u8,
    validation: evidence_schema.ValidationReport,
};

// 按 plan 中全部 manual action 生成合同覆盖报告；结果不授权 apply，也不代表可信执行完成。
pub fn build(
    allocator: std.mem.Allocator,
    plan: plan_schema.MigrationPlan,
    observed: []const ObservedEvidence,
) !evidence_schema.CompletenessReport {
    var manual_count: usize = 0;
    for (plan.actions) |action| if (action.action_type == .manual_step) {
        manual_count += 1;
    };

    const actions = try allocator.alloc(evidence_schema.ActionCoverage, manual_count);
    var initialized_actions: usize = 0;
    errdefer {
        for (actions[0..initialized_actions]) |action| {
            allocator.free(action.action_id);
            if (action.provider) |provider| allocator.free(provider);
        }
        allocator.free(actions);
    }

    var valid_actions: usize = 0;
    var missing_actions: usize = 0;
    var duplicate_actions: usize = 0;
    var invalid_actions: usize = 0;
    for (plan.actions) |action| {
        if (action.action_type != .manual_step) continue;
        const evidence_count = countObserved(observed, action.id);
        const status: evidence_schema.CoverageStatus = if (evidence_count == 0)
            .missing
        else if (evidence_count > 1)
            .duplicate
        else if (action.manual_task == null or !findObserved(observed, action.id).?.validation.valid)
            .invalid
        else
            .valid;
        switch (status) {
            .valid => valid_actions += 1,
            .missing => missing_actions += 1,
            .duplicate => duplicate_actions += 1,
            .invalid => invalid_actions += 1,
        }
        const action_id = try allocator.dupe(u8, action.id);
        errdefer allocator.free(action_id);
        const provider = if (action.manual_task) |task| try allocator.dupe(u8, task.provider) else null;
        errdefer if (provider) |value| allocator.free(value);
        actions[initialized_actions] = .{
            .action_id = action_id,
            .provider = provider,
            .task_kind = if (action.manual_task) |task| task.kind else null,
            .status = status,
            .evidence_count = evidence_count,
        };
        initialized_actions += 1;
    }

    const evidence = try allocator.alloc(evidence_schema.EvidenceCheck, observed.len);
    var initialized_evidence: usize = 0;
    errdefer {
        for (evidence[0..initialized_evidence]) |item| {
            allocator.free(item.source_ref);
            allocator.free(item.action_id);
        }
        allocator.free(evidence);
    }
    var valid_evidence_files: usize = 0;
    var invalid_evidence_files: usize = 0;
    var unexpected_evidence_files: usize = 0;
    for (observed) |item| {
        const source_ref = try allocator.dupe(u8, item.source_ref);
        errdefer allocator.free(source_ref);
        const action_id = try allocator.dupe(u8, item.action_id);
        errdefer allocator.free(action_id);
        const expected = isManualAction(plan.actions, item.action_id);
        if (item.validation.valid) {
            valid_evidence_files += 1;
        } else {
            invalid_evidence_files += 1;
        }
        if (!expected) unexpected_evidence_files += 1;
        evidence[initialized_evidence] = .{
            .source_ref = source_ref,
            .action_id = action_id,
            .valid = item.validation.valid,
            .expected_manual_action = expected,
            .binding_errors = item.validation.binding_errors,
            .contract_errors = item.validation.contract_errors,
            .result_errors = item.validation.result_errors,
        };
        initialized_evidence += 1;
    }

    return .{
        .contract_complete = valid_actions == manual_count and unexpected_evidence_files == 0 and invalid_evidence_files == 0,
        .manual_actions = manual_count,
        .valid_actions = valid_actions,
        .missing_actions = missing_actions,
        .duplicate_actions = duplicate_actions,
        .invalid_actions = invalid_actions,
        .evidence_files = observed.len,
        .valid_evidence_files = valid_evidence_files,
        .invalid_evidence_files = invalid_evidence_files,
        .unexpected_evidence_files = unexpected_evidence_files,
        .actions = actions,
        .evidence = evidence,
    };
}

fn findObserved(observed: []const ObservedEvidence, action_id: []const u8) ?ObservedEvidence {
    for (observed) |item| if (std.mem.eql(u8, item.action_id, action_id)) return item;
    return null;
}

fn countObserved(observed: []const ObservedEvidence, action_id: []const u8) usize {
    var count: usize = 0;
    for (observed) |item| {
        if (std.mem.eql(u8, item.action_id, action_id)) count += 1;
    }
    return count;
}

fn isManualAction(actions: []const plan_schema.Action, action_id: []const u8) bool {
    for (actions) |action| {
        if (std.mem.eql(u8, action.id, action_id)) return action.action_type == .manual_step;
    }
    return false;
}

test "completeness reports missing manual actions" {
    var actions = fixtureActions();
    const plan = fixturePlan(&actions);
    const observed = [_]ObservedEvidence{.{ .source_ref = "a.json", .action_id = "manual/a", .validation = validation(true) }};
    var report = try build(std.testing.allocator, plan, &observed);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(!report.contract_complete);
    try std.testing.expectEqual(@as(usize, 2), report.manual_actions);
    try std.testing.expectEqual(@as(usize, 1), report.valid_actions);
    try std.testing.expectEqual(@as(usize, 1), report.missing_actions);
    try std.testing.expectEqual(evidence_schema.CoverageStatus.missing, report.actions[1].status);
}

test "completeness rejects duplicate invalid and unexpected evidence" {
    var actions = fixtureActions();
    const plan = fixturePlan(&actions);
    const observed = [_]ObservedEvidence{
        .{ .source_ref = "a-1.json", .action_id = "manual/a", .validation = validation(true) },
        .{ .source_ref = "a-2.json", .action_id = "manual/a", .validation = validation(false) },
        .{ .source_ref = "package.json", .action_id = "packages/install/nginx", .validation = validation(false) },
    };
    var report = try build(std.testing.allocator, plan, &observed);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(!report.contract_complete);
    try std.testing.expectEqual(@as(usize, 1), report.duplicate_actions);
    try std.testing.expectEqual(@as(usize, 2), report.invalid_evidence_files);
    try std.testing.expectEqual(@as(usize, 1), report.unexpected_evidence_files);
    try std.testing.expectEqual(evidence_schema.CoverageStatus.duplicate, report.actions[0].status);
}

test "completeness accepts exactly one valid evidence per manual action" {
    var actions = fixtureActions();
    const plan = fixturePlan(&actions);
    const observed = [_]ObservedEvidence{
        .{ .source_ref = "a.json", .action_id = "manual/a", .validation = validation(true) },
        .{ .source_ref = "b.json", .action_id = "manual/b", .validation = validation(true) },
    };
    var report = try build(std.testing.allocator, plan, &observed);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.contract_complete);
    try std.testing.expectEqual(evidence_schema.TrustLevel.contract_only, report.trust_level);
    try std.testing.expectEqual(@as(usize, 2), report.valid_actions);
}

var fixture_inputs = [_]plan_schema.ManualInput{.{ .name = "subject", .value = "test" }};
var fixture_conditions = [_]plan_schema.ManualCondition{.{ .kind = .approval, .target = "test" }};
var fixture_outputs = [_]plan_schema.ManualOutput{.{ .name = "review_decision" }};
var fixture_probes = [_]plan_schema.ManualProbe{.{ .kind = .manual_evidence, .target = "test" }};

fn fixtureTask(provider: []const u8) plan_schema.ManualTask {
    return .{
        .schema_version = plan_schema.manual_task_schema_version,
        .kind = .review,
        .provider = provider,
        .inputs = &fixture_inputs,
        .preconditions = &fixture_conditions,
        .expected_outputs = &fixture_outputs,
        .verify_probes = &fixture_probes,
        .rollback_policy = .none,
        .evidence_schema = evidence_schema.schema_version,
    };
}

fn fixtureActions() [3]plan_schema.Action {
    return .{
        .{ .id = "manual/a", .module = .resources, .action_type = .manual_step, .description = "a", .risk = .high, .requires_confirmation = true, .manual_task = fixtureTask("provider_a") },
        .{ .id = "manual/b", .module = .appdata, .action_type = .manual_step, .description = "b", .risk = .high, .requires_confirmation = true, .manual_task = fixtureTask("provider_b") },
        .{ .id = "packages/install/nginx", .module = .packages, .action_type = .install_package, .description = "package", .risk = .low, .requires_confirmation = false },
    };
}

fn fixturePlan(actions: []plan_schema.Action) plan_schema.MigrationPlan {
    return .{
        .schema_version = plan_schema.schema_version_v2,
        .source_inventory_hash = [_]u8{0} ** 32,
        .target_inventory_hash = [_]u8{1} ** 32,
        .compatibility = .{ .compatible = true, .same_distro = true, .same_version = true, .same_package_manager = true, .same_arch = true, .reason = "compatible" },
        .actions = actions,
        .created_at = 1,
    };
}

fn validation(valid: bool) evidence_schema.ValidationReport {
    return .{
        .valid = valid,
        .errors = if (valid) 0 else 1,
        .binding_errors = if (valid) 0 else 1,
        .contract_errors = 0,
        .result_errors = 0,
        .preconditions_checked = 1,
        .outputs_checked = 1,
        .probes_checked = 1,
    };
}
