const std = @import("std");
const evidence_schema = @import("schema.zig");
const plan_schema = @import("../plan/schema.zig");

// 校验 evidence 与原始 plan/manual task 的强绑定及逐项结果；它不执行探针，也不授权 apply。
pub fn validate(plan: plan_schema.MigrationPlan, plan_sha256: []const u8, evidence: evidence_schema.Evidence) evidence_schema.ValidationReport {
    var binding_errors: u32 = 0;
    var contract_errors: u32 = 0;
    var result_errors: u32 = 0;

    if (!std.mem.eql(u8, evidence.schema_version, evidence_schema.schema_version)) binding_errors += 1;
    if (!isLowerSha256(plan_sha256) or !isLowerSha256(evidence.plan_sha256) or
        !std.mem.eql(u8, plan_sha256, evidence.plan_sha256))
    {
        binding_errors += 1;
    }
    if (evidence.action_id.len == 0 or evidence.provider.len == 0 or evidence.operator.len == 0 or evidence.recorded_at <= 0) {
        binding_errors += 1;
    }
    if (evidence.status != .succeeded) result_errors += 1;

    const action = findAction(plan.actions, evidence.action_id) orelse {
        binding_errors += 1;
        return report(evidence, binding_errors, contract_errors, result_errors);
    };
    if (action.action_type != .manual_step) binding_errors += 1;
    const task = action.manual_task orelse {
        binding_errors += 1;
        return report(evidence, binding_errors, contract_errors, result_errors);
    };
    if (!std.mem.eql(u8, task.evidence_schema, evidence_schema.schema_version)) binding_errors += 1;
    if (!std.mem.eql(u8, task.provider, evidence.provider)) binding_errors += 1;
    if (task.kind != evidence.task_kind) binding_errors += 1;

    validateConditions(task.preconditions, evidence.preconditions, evidence.recorded_at, &contract_errors, &result_errors);
    validateOutputs(task.expected_outputs, evidence.outputs, &contract_errors, &result_errors);
    validateProbes(task.verify_probes, evidence.probes, evidence.recorded_at, &contract_errors, &result_errors);

    return report(evidence, binding_errors, contract_errors, result_errors);
}

fn report(evidence: evidence_schema.Evidence, binding_errors: u32, contract_errors: u32, result_errors: u32) evidence_schema.ValidationReport {
    const errors = binding_errors + contract_errors + result_errors;
    return .{
        .valid = errors == 0,
        .errors = errors,
        .binding_errors = binding_errors,
        .contract_errors = contract_errors,
        .result_errors = result_errors,
        .preconditions_checked = evidence.preconditions.len,
        .outputs_checked = evidence.outputs.len,
        .probes_checked = evidence.probes.len,
    };
}

fn validateConditions(
    expected: []const plan_schema.ManualCondition,
    actual: []const evidence_schema.ConditionEvidence,
    recorded_at: i64,
    contract_errors: *u32,
    result_errors: *u32,
) void {
    for (expected) |condition| {
        const count = countCondition(actual, condition.kind, condition.target);
        if (count != 1) contract_errors.* += if (count == 0) 1 else @intCast(count - 1);
        if (findCondition(actual, condition.kind, condition.target)) |item| {
            if (item.observed_at <= 0 or item.observed_at > recorded_at) contract_errors.* += 1;
            if (condition.required and item.status != .satisfied) result_errors.* += 1;
        }
    }
    for (actual) |item| {
        if (item.target.len == 0 or countExpectedCondition(expected, item.kind, item.target) == 0) contract_errors.* += 1;
    }
}

fn validateOutputs(
    expected: []const plan_schema.ManualOutput,
    actual: []const evidence_schema.OutputEvidence,
    contract_errors: *u32,
    result_errors: *u32,
) void {
    for (expected) |output| {
        const count = countOutput(actual, output.name);
        if (count != 1) contract_errors.* += if (count == 0) 1 else @intCast(count - 1);
        if (findOutput(actual, output.name)) |item| {
            if (item.artifact_sha256) |hash| {
                if (!isLowerSha256(hash)) contract_errors.* += 1;
            }
            if (item.status != .produced and item.artifact_sha256 != null) contract_errors.* += 1;
            if (output.required and item.status != .produced) result_errors.* += 1;
        }
    }
    for (actual) |item| {
        if (item.name.len == 0 or countExpectedOutput(expected, item.name) == 0) contract_errors.* += 1;
    }
}

fn validateProbes(
    expected: []const plan_schema.ManualProbe,
    actual: []const evidence_schema.ProbeEvidence,
    recorded_at: i64,
    contract_errors: *u32,
    result_errors: *u32,
) void {
    for (expected) |probe| {
        const count = countProbe(actual, probe.kind, probe.target);
        if (count != 1) contract_errors.* += if (count == 0) 1 else @intCast(count - 1);
        if (findProbe(actual, probe.kind, probe.target)) |item| {
            if (item.observed_at <= 0 or item.observed_at > recorded_at) contract_errors.* += 1;
            if (item.evidence_sha256) |hash| {
                if (!isLowerSha256(hash)) contract_errors.* += 1;
            }
            if (probe.required and item.status != .passed) result_errors.* += 1;
        }
    }
    for (actual) |item| {
        if (item.target.len == 0 or countExpectedProbe(expected, item.kind, item.target) == 0) contract_errors.* += 1;
    }
}

fn findAction(actions: []const plan_schema.Action, action_id: []const u8) ?plan_schema.Action {
    for (actions) |action| if (std.mem.eql(u8, action.id, action_id)) return action;
    return null;
}

fn findCondition(items: []const evidence_schema.ConditionEvidence, kind: plan_schema.ManualConditionKind, target: []const u8) ?evidence_schema.ConditionEvidence {
    for (items) |item| if (item.kind == kind and std.mem.eql(u8, item.target, target)) return item;
    return null;
}

fn countCondition(items: []const evidence_schema.ConditionEvidence, kind: plan_schema.ManualConditionKind, target: []const u8) usize {
    var count: usize = 0;
    for (items) |item| if (item.kind == kind and std.mem.eql(u8, item.target, target)) {
        count += 1;
    };
    return count;
}

fn countExpectedCondition(items: []const plan_schema.ManualCondition, kind: plan_schema.ManualConditionKind, target: []const u8) usize {
    var count: usize = 0;
    for (items) |item| if (item.kind == kind and std.mem.eql(u8, item.target, target)) {
        count += 1;
    };
    return count;
}

fn findOutput(items: []const evidence_schema.OutputEvidence, name: []const u8) ?evidence_schema.OutputEvidence {
    for (items) |item| if (std.mem.eql(u8, item.name, name)) return item;
    return null;
}

fn countOutput(items: []const evidence_schema.OutputEvidence, name: []const u8) usize {
    var count: usize = 0;
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) count += 1;
    }
    return count;
}

fn countExpectedOutput(items: []const plan_schema.ManualOutput, name: []const u8) usize {
    var count: usize = 0;
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) count += 1;
    }
    return count;
}

fn findProbe(items: []const evidence_schema.ProbeEvidence, kind: plan_schema.ManualProbeKind, target: []const u8) ?evidence_schema.ProbeEvidence {
    for (items) |item| if (item.kind == kind and std.mem.eql(u8, item.target, target)) return item;
    return null;
}

fn countProbe(items: []const evidence_schema.ProbeEvidence, kind: plan_schema.ManualProbeKind, target: []const u8) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.kind == kind and std.mem.eql(u8, item.target, target)) count += 1;
    }
    return count;
}

fn countExpectedProbe(items: []const plan_schema.ManualProbe, kind: plan_schema.ManualProbeKind, target: []const u8) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.kind == kind and std.mem.eql(u8, item.target, target)) count += 1;
    }
    return count;
}

fn isLowerSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |char| if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return false;
    return true;
}

test "manual evidence validates exact plan action and provider contract" {
    var actions = [_]plan_schema.Action{fixtureAction()};
    const plan = fixture(&actions);
    var conditions = [_]evidence_schema.ConditionEvidence{.{ .kind = .source_reviewed, .target = "/opt/tool", .status = .satisfied, .observed_at = 10 }};
    var outputs = [_]evidence_schema.OutputEvidence{.{ .name = "installed_artifact", .status = .produced, .artifact_sha256 = "ab" ** 32 }};
    var probes = [_]evidence_schema.ProbeEvidence{.{ .kind = .manual_evidence, .target = "/opt/tool", .status = .passed, .observed_at = 11, .evidence_sha256 = "cd" ** 32 }};
    const evidence = evidenceFixture(&conditions, &outputs, &probes);

    const result = validate(plan, "01" ** 32, evidence);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 0), result.errors);
}

test "manual evidence rejects cross-plan binding and incomplete failed results" {
    var actions = [_]plan_schema.Action{fixtureAction()};
    const plan = fixture(&actions);
    var conditions = [_]evidence_schema.ConditionEvidence{.{ .kind = .source_reviewed, .target = "/opt/tool", .status = .not_satisfied, .observed_at = 10 }};
    var outputs = [_]evidence_schema.OutputEvidence{.{ .name = "unexpected", .status = .produced }};
    var probes = [_]evidence_schema.ProbeEvidence{};
    var evidence = evidenceFixture(&conditions, &outputs, &probes);
    evidence.provider = "other_provider";
    evidence.status = .failed;

    const result = validate(plan, "02" ** 32, evidence);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.binding_errors >= 2);
    try std.testing.expect(result.contract_errors >= 3);
    try std.testing.expect(result.result_errors >= 2);
}

test "manual evidence rejects duplicate contract entries and non-manual actions" {
    var actions = [_]plan_schema.Action{fixtureAction()};
    const plan = fixture(&actions);
    var duplicate_outputs = [_]evidence_schema.OutputEvidence{
        .{ .name = "installed_artifact", .status = .produced },
        .{ .name = "installed_artifact", .status = .produced },
    };
    var conditions = [_]evidence_schema.ConditionEvidence{.{ .kind = .source_reviewed, .target = "/opt/tool", .status = .satisfied, .observed_at = 10 }};
    var probes = [_]evidence_schema.ProbeEvidence{.{ .kind = .manual_evidence, .target = "/opt/tool", .status = .passed, .observed_at = 11 }};
    const evidence = evidenceFixture(&conditions, &duplicate_outputs, &probes);
    try std.testing.expect(validate(plan, "01" ** 32, evidence).contract_errors > 0);

    actions[0].action_type = .run_command;
    try std.testing.expect(validate(plan, "01" ** 32, evidence).binding_errors > 0);
}

test "manual evidence rejects future observations and contradictory output hashes" {
    var actions = [_]plan_schema.Action{fixtureAction()};
    const plan = fixture(&actions);
    var conditions = [_]evidence_schema.ConditionEvidence{.{ .kind = .source_reviewed, .target = "/opt/tool", .status = .satisfied, .observed_at = 13 }};
    var outputs = [_]evidence_schema.OutputEvidence{.{ .name = "installed_artifact", .status = .missing, .artifact_sha256 = "ab" ** 32 }};
    var probes = [_]evidence_schema.ProbeEvidence{.{ .kind = .manual_evidence, .target = "/opt/tool", .status = .passed, .observed_at = 13 }};
    const evidence = evidenceFixture(&conditions, &outputs, &probes);

    const result = validate(plan, "01" ** 32, evidence);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.contract_errors >= 3);
    try std.testing.expect(result.result_errors >= 1);
}

var fixture_inputs = [_]plan_schema.ManualInput{.{ .name = "subject", .value = "/opt/tool" }};
var fixture_preconditions = [_]plan_schema.ManualCondition{.{ .kind = .source_reviewed, .target = "/opt/tool" }};
var fixture_outputs = [_]plan_schema.ManualOutput{.{ .name = "installed_artifact" }};
var fixture_probes = [_]plan_schema.ManualProbe{.{ .kind = .manual_evidence, .target = "/opt/tool" }};

fn fixtureAction() plan_schema.Action {
    return .{
        .id = "resources/reinstall//opt/tool",
        .module = .resources,
        .action_type = .manual_step,
        .subject = "/opt/tool",
        .description = "Reinstall tool",
        .risk = .high,
        .requires_confirmation = true,
        .phase = .prepare,
        .manual_task = .{
            .schema_version = plan_schema.manual_task_schema_version,
            .kind = .reinstall,
            .provider = "resource_reinstall",
            .inputs = &fixture_inputs,
            .preconditions = &fixture_preconditions,
            .expected_outputs = &fixture_outputs,
            .verify_probes = &fixture_probes,
            .rollback_policy = .manual,
            .evidence_schema = evidence_schema.schema_version,
        },
    };
}

fn fixture(actions: []plan_schema.Action) plan_schema.MigrationPlan {
    return .{
        .schema_version = plan_schema.schema_version_v2,
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
        .actions = actions,
        .created_at = 1,
    };
}

fn evidenceFixture(
    conditions: []const evidence_schema.ConditionEvidence,
    outputs: []const evidence_schema.OutputEvidence,
    probes: []const evidence_schema.ProbeEvidence,
) evidence_schema.Evidence {
    return .{
        .schema_version = evidence_schema.schema_version,
        .plan_sha256 = "01" ** 32,
        .action_id = "resources/reinstall//opt/tool",
        .task_kind = .reinstall,
        .provider = "resource_reinstall",
        .status = .succeeded,
        .operator = "ai-agent",
        .recorded_at = 12,
        .preconditions = conditions,
        .outputs = outputs,
        .probes = probes,
    };
}
