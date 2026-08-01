const std = @import("std");
const evidence_schema = @import("../manual_evidence/schema.zig");
const manifest_hash = @import("../manifest/hash.zig");
const plan_schema = @import("../plan/schema.zig");
const plan_validator = @import("../plan/validator.zig");
const probe_schema = @import("../manual_evidence/probe_schema.zig");
const probed_validator = @import("../manual_evidence/probed_validator.zig");
const remote_manual_probe = @import("../remote/manual_probe.zig");
const remote_options = @import("../remote/options.zig");
const security = @import("../security/validation.zig");
const fs_util = @import("../util/fs.zig");

// 解析并执行单个 manual action 的固定只读远程探针，报告文件拒绝覆盖。
pub fn runProbe(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var plan_path: ?[]const u8 = null;
    var action_id: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var summary = false;
    var execution: remote_options.ExecutionOptions = .{};

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--plan")) {
            plan_path = try nextValue(args, &index, error.MissingPlanPath);
        } else if (std.mem.eql(u8, arg, "--action")) {
            action_id = try nextValue(args, &index, error.MissingManualProbeAction);
        } else if (std.mem.eql(u8, arg, "--host")) {
            host = try nextValue(args, &index, error.MissingRemoteHost);
        } else if (std.mem.eql(u8, arg, "--output")) {
            output_path = try nextValue(args, &index, error.MissingOutputPath);
        } else if (std.mem.eql(u8, arg, "--remote-timeout")) {
            execution.timeout_seconds = try std.fmt.parseUnsigned(u32, try nextValue(args, &index, error.MissingTimeout), 10);
        } else if (std.mem.eql(u8, arg, "--identity-file")) {
            execution.ssh_identity_file = try nextValue(args, &index, error.MissingIdentityFile);
        } else if (std.mem.eql(u8, arg, "--credential-provider")) {
            execution.credential_provider = try nextValue(args, &index, error.MissingCredentialProvider);
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else {
            return error.UnknownEvidenceProbeArgument;
        }
    }

    const required_output = output_path orelse return error.MissingOutputPath;
    security.validatePath(required_output) catch return error.InvalidManualProbeOutputPath;
    if (fs_util.pathExists(io, required_output)) return error.OutputFileExists;
    const required_host = host orelse return error.MissingRemoteHost;
    try security.validateHost(required_host);
    _ = try remote_options.normalize(execution);

    const plan_bytes = try fs_util.readFileAlloc(io, allocator, plan_path orelse return error.MissingPlanPath, 16 * 1024 * 1024);
    defer allocator.free(plan_bytes);
    const parsed_plan = try std.json.parseFromSlice(plan_schema.MigrationPlan, allocator, plan_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_plan.deinit();
    if (!plan_validator.validate(parsed_plan.value).valid) return error.InvalidMigrationPlan;
    if (!std.mem.eql(u8, parsed_plan.value.schema_version, plan_schema.schema_version_v2)) return error.ManualEvidenceRequiresPlanV2;
    const plan_sha256 = try manifest_hash.sha256BytesHexAlloc(allocator, plan_bytes);
    defer allocator.free(plan_sha256);

    var report = try remote_manual_probe.execute(
        io,
        allocator,
        parsed_plan.value,
        plan_sha256,
        action_id orelse return error.MissingManualProbeAction,
        required_host,
        execution,
    );
    defer report.deinit(allocator);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var allocating_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &bytes);
    try std.json.Stringify.value(report.value, .{ .whitespace = .indent_2, .emit_null_optional_fields = true }, &allocating_writer.writer);
    try allocating_writer.writer.writeByte('\n');
    bytes = allocating_writer.toArrayList();
    try writeExclusive(io, required_output, bytes.items);

    if (summary) {
        try writer.print(
            "HostLift manual remote probe\nPassed: {}\nTrust level: {s}\nAction: {s}\nProvider: {s}\nHost: {s}\nResults: {d}\nReport: {s}\n",
            .{
                report.value.all_required_passed,
                @tagName(report.value.trust_level),
                report.value.action_id,
                report.value.provider,
                report.value.host,
                report.value.results.len,
                required_output,
            },
        );
    } else {
        try writer.writeAll(bytes.items);
    }
    if (!report.value.all_required_passed) return error.ManualProbeRequiredProbeFailed;
}

// 联合校验 evidence、probe report 原始摘要和显式目标 host，不执行任何远程操作。
pub fn runValidateProbed(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var plan_path: ?[]const u8 = null;
    var evidence_path: ?[]const u8 = null;
    var probe_report_path: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var summary = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--plan")) {
            plan_path = try nextValue(args, &index, error.MissingPlanPath);
        } else if (std.mem.eql(u8, arg, "--evidence")) {
            evidence_path = try nextValue(args, &index, error.MissingEvidencePath);
        } else if (std.mem.eql(u8, arg, "--probe-report")) {
            probe_report_path = try nextValue(args, &index, error.MissingManualProbeReportPath);
        } else if (std.mem.eql(u8, arg, "--host")) {
            host = try nextValue(args, &index, error.MissingRemoteHost);
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else {
            return error.UnknownEvidenceValidateProbedArgument;
        }
    }

    const expected_host = host orelse return error.MissingRemoteHost;
    try security.validateHost(expected_host);
    const plan_bytes = try fs_util.readFileAlloc(io, allocator, plan_path orelse return error.MissingPlanPath, 16 * 1024 * 1024);
    defer allocator.free(plan_bytes);
    const evidence_bytes = try fs_util.readFileAlloc(io, allocator, evidence_path orelse return error.MissingEvidencePath, 1024 * 1024);
    defer allocator.free(evidence_bytes);
    const probe_bytes = try fs_util.readFileAlloc(io, allocator, probe_report_path orelse return error.MissingManualProbeReportPath, 4 * 1024 * 1024);
    defer allocator.free(probe_bytes);

    const parsed_plan = try std.json.parseFromSlice(plan_schema.MigrationPlan, allocator, plan_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_plan.deinit();
    if (!plan_validator.validate(parsed_plan.value).valid) return error.InvalidMigrationPlan;
    if (!std.mem.eql(u8, parsed_plan.value.schema_version, plan_schema.schema_version_v2)) return error.ManualEvidenceRequiresPlanV2;
    const parsed_evidence = try std.json.parseFromSlice(evidence_schema.Evidence, allocator, evidence_bytes, .{ .ignore_unknown_fields = false });
    defer parsed_evidence.deinit();
    const parsed_probe = try std.json.parseFromSlice(probe_schema.Report, allocator, probe_bytes, .{ .ignore_unknown_fields = false });
    defer parsed_probe.deinit();
    const plan_sha256 = try manifest_hash.sha256BytesHexAlloc(allocator, plan_bytes);
    defer allocator.free(plan_sha256);
    const probe_sha256 = try manifest_hash.sha256BytesHexAlloc(allocator, probe_bytes);
    defer allocator.free(probe_sha256);

    const report = probed_validator.validate(
        parsed_plan.value,
        plan_sha256,
        parsed_evidence.value,
        parsed_probe.value,
        probe_sha256,
        expected_host,
    );
    if (summary) {
        try writer.print(
            "HostLift probed manual evidence validation\nValid: {}\nTrust level: {s}\nEvidence valid: {}\nEvidence errors: {d}\nProbe binding errors: {d}\nProbe contract errors: {d}\nProbe result errors: {d}\nRequired probes: {d}\nProbe report SHA-256: {s}\n",
            .{
                report.valid,
                @tagName(report.trust_level),
                report.evidence_valid,
                report.evidence_errors,
                report.probe_binding_errors,
                report.probe_contract_errors,
                report.probe_result_errors,
                report.required_probes_checked,
                report.probe_report_sha256,
            },
        );
    } else {
        try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, writer);
        try writer.writeByte('\n');
    }
    if (!report.valid) return error.InvalidProbedManualEvidence;
}

fn nextValue(args: []const []const u8, index: *usize, missing_error: anyerror) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return missing_error;
    return args[index.*];
}

fn writeExclusive(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.OutputFileExists,
        else => return err,
    };
    var keep_file = false;
    defer file.close(io);
    errdefer if (!keep_file) std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try file_writer.interface.writeAll(bytes);
    try file_writer.flush();
    keep_file = true;
}
