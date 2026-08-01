const std = @import("std");
const manifest_hash = @import("../manifest/hash.zig");
const plan_schema = @import("../plan/schema.zig");
const probe_schema = @import("../manual_evidence/probe_schema.zig");
const remote_options = @import("options.zig");
const planner = @import("planner.zig");
const runner = @import("runner.zig");
const security = @import("../security/validation.zig");
const ssh_argv = @import("ssh_argv.zig");

pub const GeneratedReport = struct {
    value: probe_schema.Report,

    // 释放生成报告拥有的结果数组和规范化观察摘要。
    pub fn deinit(self: *GeneratedReport, allocator: std.mem.Allocator) void {
        for (self.value.results) |result| if (result.observation_sha256) |hash| allocator.free(hash);
        allocator.free(self.value.results);
    }
};

// 对指定 manual action 执行固定只读远程探针；不执行 action，也不保存远程原始输出。
pub fn execute(
    io: std.Io,
    allocator: std.mem.Allocator,
    migration_plan: plan_schema.MigrationPlan,
    plan_sha256: []const u8,
    action_id: []const u8,
    host: []const u8,
    options: remote_options.ExecutionOptions,
) !GeneratedReport {
    try planner.validateHost(host);
    const action = findAction(migration_plan.actions, action_id) orelse return error.ManualProbeActionNotFound;
    if (action.action_type != .manual_step) return error.ManualProbeRequiresManualAction;
    const task = action.manual_task orelse return error.ManualProbeMissingTask;

    const results = try allocator.alloc(probe_schema.Result, task.verify_probes.len);
    var initialized: usize = 0;
    errdefer {
        for (results[0..initialized]) |result| if (result.observation_sha256) |hash| allocator.free(hash);
        allocator.free(results);
    }
    for (task.verify_probes, 0..) |probe, index| {
        results[index] = executeOne(io, allocator, host, probe, options);
        initialized += 1;
    }
    const probed_at = std.Io.Timestamp.now(io, .real).toSeconds();
    var all_required_passed = true;
    for (results) |result| {
        if (result.required and result.status != .passed) all_required_passed = false;
    }
    return .{ .value = .{
        .plan_sha256 = plan_sha256,
        .action_id = action.id,
        .task_kind = task.kind,
        .provider = task.provider,
        .host = host,
        .probed_at = probed_at,
        .all_required_passed = all_required_passed,
        .results = results,
    } };
}

fn executeOne(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    probe: plan_schema.ManualProbe,
    options: remote_options.ExecutionOptions,
) probe_schema.Result {
    const observed_at = std.Io.Timestamp.now(io, .real).toSeconds();
    return executeSupported(io, allocator, host, probe, options, observed_at) catch |err| .{
        .kind = probe.kind,
        .target = probe.target,
        .required = probe.required,
        .status = .@"error",
        .executor = executorFor(probe) catch .none,
        .observed_at = observed_at,
        .error_name = @errorName(err),
    };
}

fn executeSupported(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    probe: plan_schema.ManualProbe,
    options: remote_options.ExecutionOptions,
    observed_at: i64,
) !probe_schema.Result {
    const base: probe_schema.Result = .{
        .kind = probe.kind,
        .target = probe.target,
        .required = probe.required,
        .status = .unsupported,
        .executor = try executorFor(probe),
        .observed_at = observed_at,
    };
    switch (probe.kind) {
        .systemd => {
            try security.validateSystemdProbeTarget(probe.target);
            const argv = [_][]const u8{ "systemctl", "is-active", "--quiet", probe.target };
            return withExitStatus(io, allocator, host, &argv, options, base);
        },
        .container => return inspectContainer(io, allocator, host, probe.target, options, base),
        .tcp => {
            const target = try security.parseTcpProbeTarget(probe.target);
            var port_buffer: [5]u8 = undefined;
            const port = try std.fmt.bufPrint(&port_buffer, "{d}", .{target.port});
            const argv = [_][]const u8{ "nc", "-z", "-w", "5", target.host, port };
            return withExitStatus(io, allocator, host, &argv, options, base);
        },
        .http => {
            try security.validateHttpProbeTarget(probe.target);
            const argv = [_][]const u8{ "curl", "--fail", "--silent", "--show-error", "--max-time", "10", "--output", "/dev/null", probe.target };
            return withExitStatus(io, allocator, host, &argv, options, base);
        },
        .command, .log, .manual_evidence => return base,
    }
}

fn withExitStatus(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    argv: []const []const u8,
    options: remote_options.ExecutionOptions,
    base: probe_schema.Result,
) !probe_schema.Result {
    const code = try executeForExitCode(io, allocator, host, argv, options);
    var result = base;
    result.status = if (code == 0) .passed else if (code < 126) .failed else .@"error";
    if (code >= 126) result.error_name = "RemoteProbeExecutorFailed";
    return result;
}

fn executeForExitCode(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    argv: []const []const u8,
    options: remote_options.ExecutionOptions,
) !u8 {
    const command_plan = try planner.buildCommandPlanWithOptions(host, argv, options);
    const connect_timeout = try std.fmt.allocPrint(allocator, "ConnectTimeout={d}", .{command_plan.timeout_seconds});
    defer allocator.free(connect_timeout);
    var ssh: std.ArrayList([]const u8) = .empty;
    defer ssh.deinit(allocator);
    try ssh_argv.appendSshPrefix(allocator, &ssh, command_plan.ssh_identity_file, connect_timeout, host);
    try ssh.appendSlice(allocator, argv);
    return runner.runForExitCode(io, allocator, ssh.items, command_plan.timeout_seconds);
}

fn inspectContainer(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    target_text: []const u8,
    options: remote_options.ExecutionOptions,
    base: probe_schema.Result,
) !probe_schema.Result {
    const target = try security.parseContainerProbeTarget(target_text);
    const argv = [_][]const u8{ target.runtime, "inspect", target.name };
    const output = try @import("exec.zig").commandOutputWithOptions(io, allocator, host, &argv, options, 4 * 1024 * 1024);
    defer allocator.free(output);
    const State = struct { Running: bool };
    const Container = struct { State: State };
    const parsed = std.json.parseFromSlice([]Container, allocator, output, .{ .ignore_unknown_fields = true }) catch return error.InvalidContainerProbeOutput;
    defer parsed.deinit();
    if (parsed.value.len != 1) return error.InvalidContainerProbeOutput;
    const normalized = if (parsed.value[0].State.Running) "true" else "false";
    var result = base;
    result.status = if (parsed.value[0].State.Running) .passed else .failed;
    result.observation_sha256 = try manifest_hash.sha256BytesHexAlloc(allocator, normalized);
    return result;
}

fn executorFor(probe: plan_schema.ManualProbe) !probe_schema.Executor {
    return switch (probe.kind) {
        .systemd => .systemctl_is_active,
        .container => blk: {
            const target = try security.parseContainerProbeTarget(probe.target);
            break :blk if (std.mem.eql(u8, target.runtime, "docker")) .docker_inspect_state else .podman_inspect_state;
        },
        .tcp => .tcp_connect,
        .http => .http_request,
        .command, .log, .manual_evidence => .none,
    };
}

fn findAction(actions: []const plan_schema.Action, action_id: []const u8) ?plan_schema.Action {
    for (actions) |action| if (std.mem.eql(u8, action.id, action_id)) return action;
    return null;
}

test "unsupported manual probe fails closed without remote execution" {
    var probes = [_]plan_schema.ManualProbe{.{ .kind = .manual_evidence, .target = "review" }};
    var inputs = [_]plan_schema.ManualInput{.{ .name = "subject", .value = "review" }};
    var conditions = [_]plan_schema.ManualCondition{.{ .kind = .approval, .target = "review" }};
    var outputs = [_]plan_schema.ManualOutput{.{ .name = "review_decision" }};
    var actions = [_]plan_schema.Action{.{
        .id = "manual/review",
        .module = .configs,
        .action_type = .manual_step,
        .description = "review",
        .risk = .high,
        .requires_confirmation = true,
        .manual_task = .{
            .schema_version = plan_schema.manual_task_schema_version,
            .kind = .review,
            .provider = "configs",
            .inputs = &inputs,
            .preconditions = &conditions,
            .expected_outputs = &outputs,
            .verify_probes = &probes,
            .rollback_policy = .none,
            .evidence_schema = plan_schema.manual_evidence_schema_version,
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
    var report = try execute(std.testing.io, std.testing.allocator, migration_plan, "01" ** 32, "manual/review", "root@192.0.2.10", .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.value.all_required_passed);
    try std.testing.expectEqual(probe_schema.ResultStatus.unsupported, report.value.results[0].status);
}
