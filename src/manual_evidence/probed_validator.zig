const std = @import("std");
const evidence_schema = @import("schema.zig");
const evidence_validator = @import("validator.zig");
const plan_schema = @import("../plan/schema.zig");
const probe_schema = @import("probe_schema.zig");
const security = @import("../security/validation.zig");

// 联合校验 manual evidence 与 HostLift 只读 probe report；它不修改 apply/run-state/workload。
pub fn validate(
    migration_plan: plan_schema.MigrationPlan,
    plan_sha256: []const u8,
    evidence: evidence_schema.Evidence,
    probe_report: probe_schema.Report,
    probe_report_sha256: []const u8,
    expected_host: []const u8,
) probe_schema.ProbedValidationReport {
    const evidence_report = evidence_validator.validate(migration_plan, plan_sha256, evidence);
    var binding_errors: u32 = 0;
    var contract_errors: u32 = 0;
    var result_errors: u32 = 0;
    var required_checked: usize = 0;

    if (!std.mem.eql(u8, probe_report.schema_version, probe_schema.schema_version)) binding_errors += 1;
    if (!isLowerSha256(probe_report_sha256) or
        !isLowerSha256(probe_report.plan_sha256) or
        !std.mem.eql(u8, probe_report.plan_sha256, plan_sha256))
    {
        binding_errors += 1;
    }
    security.validateHost(expected_host) catch {
        binding_errors += 1;
    };
    security.validateHost(probe_report.host) catch {
        binding_errors += 1;
    };
    if (!std.mem.eql(u8, probe_report.host, expected_host)) binding_errors += 1;
    if (!std.mem.eql(u8, probe_report.action_id, evidence.action_id) or
        probe_report.task_kind != evidence.task_kind or
        !std.mem.eql(u8, probe_report.provider, evidence.provider))
    {
        binding_errors += 1;
    }
    if (probe_report.probed_at <= 0) binding_errors += 1;

    const action = findAction(migration_plan.actions, probe_report.action_id) orelse {
        binding_errors += 1;
        return finish(evidence_report, probe_report_sha256, binding_errors, contract_errors, result_errors, required_checked);
    };
    if (action.action_type != .manual_step) binding_errors += 1;
    const task = action.manual_task orelse {
        binding_errors += 1;
        return finish(evidence_report, probe_report_sha256, binding_errors, contract_errors, result_errors, required_checked);
    };
    if (task.kind != probe_report.task_kind or !std.mem.eql(u8, task.provider, probe_report.provider)) binding_errors += 1;

    var computed_all_required_passed = true;
    for (task.verify_probes) |expected| {
        const count = countResult(probe_report.results, expected.kind, expected.target);
        if (count != 1) contract_errors += if (count == 0) 1 else @intCast(count - 1);
        if (findResult(probe_report.results, expected.kind, expected.target)) |result| {
            if (result.required != expected.required) contract_errors += 1;
            if (result.observed_at <= 0 or result.observed_at > probe_report.probed_at) contract_errors += 1;
            if (!executorMatches(result)) contract_errors += 1;
            if (result.observation_sha256) |hash| if (!isLowerSha256(hash)) {
                contract_errors += 1;
            };
            if ((result.status == .@"error") != (result.error_name != null)) contract_errors += 1;
            if (expected.required) {
                required_checked += 1;
                if (result.status != .passed) {
                    result_errors += 1;
                    computed_all_required_passed = false;
                }
            }

            const evidence_probe = findEvidenceProbe(evidence.probes, expected.kind, expected.target) orelse {
                binding_errors += 1;
                continue;
            };
            if (evidence_probe.evidence_sha256 == null or
                !std.mem.eql(u8, evidence_probe.evidence_sha256.?, probe_report_sha256))
            {
                binding_errors += 1;
            }
            if (evidence_probe.observed_at != result.observed_at) binding_errors += 1;
            if (result.status == .passed and evidence_probe.status != .passed) result_errors += 1;
        } else if (expected.required) {
            computed_all_required_passed = false;
        }
    }
    for (probe_report.results) |result| {
        if (result.target.len == 0 or countExpected(task.verify_probes, result.kind, result.target) == 0) contract_errors += 1;
    }
    if (probe_report.all_required_passed != computed_all_required_passed) contract_errors += 1;
    if (!probe_report.all_required_passed) result_errors += 1;

    return finish(evidence_report, probe_report_sha256, binding_errors, contract_errors, result_errors, required_checked);
}

fn finish(
    evidence_report: evidence_schema.ValidationReport,
    report_sha256: []const u8,
    binding_errors: u32,
    contract_errors: u32,
    result_errors: u32,
    required_checked: usize,
) probe_schema.ProbedValidationReport {
    return .{
        .valid = evidence_report.valid and binding_errors == 0 and contract_errors == 0 and result_errors == 0,
        .probe_report_sha256 = report_sha256,
        .evidence_valid = evidence_report.valid,
        .evidence_errors = evidence_report.errors,
        .probe_binding_errors = binding_errors,
        .probe_contract_errors = contract_errors,
        .probe_result_errors = result_errors,
        .required_probes_checked = required_checked,
    };
}

fn executorMatches(result: probe_schema.Result) bool {
    return switch (result.kind) {
        .systemd => result.executor == .systemctl_is_active,
        .tcp => result.executor == .tcp_connect,
        .http => result.executor == .http_request,
        .container => blk: {
            const target = security.parseContainerProbeTarget(result.target) catch break :blk false;
            break :blk if (std.mem.eql(u8, target.runtime, "docker"))
                result.executor == .docker_inspect_state
            else
                result.executor == .podman_inspect_state;
        },
        .command, .log, .manual_evidence => result.executor == .none and result.status == .unsupported,
    };
}

fn findAction(actions: []const plan_schema.Action, action_id: []const u8) ?plan_schema.Action {
    for (actions) |action| if (std.mem.eql(u8, action.id, action_id)) return action;
    return null;
}

fn findResult(results: []const probe_schema.Result, kind: plan_schema.ManualProbeKind, target: []const u8) ?probe_schema.Result {
    for (results) |result| if (result.kind == kind and std.mem.eql(u8, result.target, target)) return result;
    return null;
}

fn countResult(results: []const probe_schema.Result, kind: plan_schema.ManualProbeKind, target: []const u8) usize {
    var count: usize = 0;
    for (results) |result| if (result.kind == kind and std.mem.eql(u8, result.target, target)) {
        count += 1;
    };
    return count;
}

fn countExpected(probes: []const plan_schema.ManualProbe, kind: plan_schema.ManualProbeKind, target: []const u8) usize {
    var count: usize = 0;
    for (probes) |probe| if (probe.kind == kind and std.mem.eql(u8, probe.target, target)) {
        count += 1;
    };
    return count;
}

fn findEvidenceProbe(probes: []const evidence_schema.ProbeEvidence, kind: plan_schema.ManualProbeKind, target: []const u8) ?evidence_schema.ProbeEvidence {
    for (probes) |probe| if (probe.kind == kind and std.mem.eql(u8, probe.target, target)) return probe;
    return null;
}

fn isLowerSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |char| if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return false;
    return true;
}

test "probed validator requires exact report hash host and executor binding" {
    var inputs = [_]plan_schema.ManualInput{.{ .name = "subject", .value = "worker.service" }};
    var conditions = [_]plan_schema.ManualCondition{.{ .kind = .approval, .target = "worker.service" }};
    var outputs = [_]plan_schema.ManualOutput{.{ .name = "health_result" }};
    var expected_probes = [_]plan_schema.ManualProbe{.{ .kind = .systemd, .target = "worker.service" }};
    var actions = [_]plan_schema.Action{.{
        .id = "services/check-status/worker.service",
        .module = .services,
        .action_type = .manual_step,
        .description = "check",
        .risk = .high,
        .requires_confirmation = true,
        .manual_task = .{
            .schema_version = plan_schema.manual_task_schema_version,
            .kind = .health_check,
            .provider = "systemd_status",
            .inputs = &inputs,
            .preconditions = &conditions,
            .expected_outputs = &outputs,
            .verify_probes = &expected_probes,
            .rollback_policy = .none,
            .evidence_schema = evidence_schema.schema_version,
        },
    }};
    const migration_plan: plan_schema.MigrationPlan = .{
        .schema_version = plan_schema.schema_version_v2,
        .source_inventory_hash = [_]u8{0} ** 32,
        .target_inventory_hash = [_]u8{1} ** 32,
        .compatibility = .{ .compatible = true, .same_distro = true, .same_version = true, .same_package_manager = true, .same_arch = true, .reason = "compatible" },
        .actions = &actions,
        .created_at = 1,
    };
    var condition_evidence = [_]evidence_schema.ConditionEvidence{.{ .kind = .approval, .target = "worker.service", .status = .satisfied, .observed_at = 10 }};
    var output_evidence = [_]evidence_schema.OutputEvidence{.{ .name = "health_result", .status = .produced }};
    var probe_evidence = [_]evidence_schema.ProbeEvidence{.{ .kind = .systemd, .target = "worker.service", .status = .passed, .observed_at = 11, .evidence_sha256 = "ab" ** 32 }};
    const evidence: evidence_schema.Evidence = .{
        .schema_version = evidence_schema.schema_version,
        .plan_sha256 = "01" ** 32,
        .action_id = actions[0].id,
        .task_kind = .health_check,
        .provider = "systemd_status",
        .status = .succeeded,
        .operator = "ai-agent",
        .recorded_at = 12,
        .preconditions = &condition_evidence,
        .outputs = &output_evidence,
        .probes = &probe_evidence,
    };
    var results = [_]probe_schema.Result{.{
        .kind = .systemd,
        .target = "worker.service",
        .required = true,
        .status = .passed,
        .executor = .systemctl_is_active,
        .observed_at = 11,
    }};
    var report: probe_schema.Report = .{
        .plan_sha256 = "01" ** 32,
        .action_id = actions[0].id,
        .task_kind = .health_check,
        .provider = "systemd_status",
        .host = "root@192.0.2.10",
        .probed_at = 11,
        .all_required_passed = true,
        .results = &results,
    };

    try std.testing.expect(validate(migration_plan, "01" ** 32, evidence, report, "ab" ** 32, report.host).valid);
    try std.testing.expect(!validate(migration_plan, "01" ** 32, evidence, report, "cd" ** 32, report.host).valid);
    report.host = "root@192.0.2.11";
    try std.testing.expect(!validate(migration_plan, "01" ** 32, evidence, report, "ab" ** 32, "root@192.0.2.10").valid);
    report.host = "root@192.0.2.10";
    results[0].executor = .http_request;
    try std.testing.expect(!validate(migration_plan, "01" ** 32, evidence, report, "ab" ** 32, report.host).valid);
}
