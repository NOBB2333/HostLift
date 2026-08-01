const std = @import("std");
const evidence_completeness = @import("../manual_evidence/completeness.zig");
const evidence_ledger = @import("../manual_evidence/ledger.zig");
const evidence_probe_command = @import("evidence_probe.zig");
const evidence_schema = @import("../manual_evidence/schema.zig");
const evidence_validator = @import("../manual_evidence/validator.zig");
const manifest_hash = @import("../manifest/hash.zig");
const plan_schema = @import("../plan/schema.zig");
const plan_validator = @import("../plan/validator.zig");
const fs_util = @import("../util/fs.zig");

// 处理 manual evidence 子命令；仅 probe 子命令执行固定只读远程探针，所有子命令都不执行 action。
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    if (args.len == 0) return error.MissingEvidenceCommand;
    if (std.mem.eql(u8, args[0], "validate")) {
        try runValidate(io, allocator, args[1..], writer);
    } else if (std.mem.eql(u8, args[0], "completeness")) {
        try runCompleteness(io, allocator, args[1..], writer);
    } else if (std.mem.eql(u8, args[0], "record")) {
        try runRecord(io, allocator, args[1..], writer);
    } else if (std.mem.eql(u8, args[0], "verify-ledger")) {
        try runVerifyLedger(io, allocator, args[1..], writer);
    } else if (std.mem.eql(u8, args[0], "probe")) {
        try evidence_probe_command.runProbe(io, allocator, args[1..], writer);
    } else if (std.mem.eql(u8, args[0], "validate-probed")) {
        try evidence_probe_command.runValidateProbed(io, allocator, args[1..], writer);
    } else {
        return error.UnknownEvidenceCommand;
    }
}

fn runValidate(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var plan_path: ?[]const u8 = null;
    var evidence_path: ?[]const u8 = null;
    var summary = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--plan")) {
            index += 1;
            if (index >= args.len) return error.MissingPlanPath;
            plan_path = args[index];
        } else if (std.mem.eql(u8, arg, "--evidence")) {
            index += 1;
            if (index >= args.len) return error.MissingEvidencePath;
            evidence_path = args[index];
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else {
            return error.UnknownEvidenceValidateArgument;
        }
    }

    const required_plan_path = plan_path orelse return error.MissingPlanPath;
    const required_evidence_path = evidence_path orelse return error.MissingEvidencePath;
    const plan_bytes = try fs_util.readFileAlloc(io, allocator, required_plan_path, 16 * 1024 * 1024);
    defer allocator.free(plan_bytes);
    const evidence_bytes = try fs_util.readFileAlloc(io, allocator, required_evidence_path, 1024 * 1024);
    defer allocator.free(evidence_bytes);

    const parsed_plan = try std.json.parseFromSlice(plan_schema.MigrationPlan, allocator, plan_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_plan.deinit();
    if (!plan_validator.validate(parsed_plan.value).valid) return error.InvalidMigrationPlan;

    const parsed_evidence = try std.json.parseFromSlice(evidence_schema.Evidence, allocator, evidence_bytes, .{ .ignore_unknown_fields = false });
    defer parsed_evidence.deinit();
    const plan_sha256 = try manifest_hash.sha256BytesHexAlloc(allocator, plan_bytes);
    defer allocator.free(plan_sha256);
    const report = evidence_validator.validate(parsed_plan.value, plan_sha256, parsed_evidence.value);

    if (summary) {
        try writer.print(
            "HostLift manual evidence validation\nValid: {}\nErrors: {d}\nBinding errors: {d}\nContract errors: {d}\nResult errors: {d}\nPreconditions: {d}\nOutputs: {d}\nProbes: {d}\n",
            .{
                report.valid,
                report.errors,
                report.binding_errors,
                report.contract_errors,
                report.result_errors,
                report.preconditions_checked,
                report.outputs_checked,
                report.probes_checked,
            },
        );
    } else {
        try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, writer);
        try writer.writeByte('\n');
    }

    if (!report.valid) return error.InvalidManualEvidence;
}

fn runCompleteness(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var plan_path: ?[]const u8 = null;
    var evidence_paths: std.ArrayList([]const u8) = .empty;
    defer evidence_paths.deinit(allocator);
    var summary = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--plan")) {
            index += 1;
            if (index >= args.len) return error.MissingPlanPath;
            plan_path = args[index];
        } else if (std.mem.eql(u8, arg, "--evidence")) {
            index += 1;
            if (index >= args.len) return error.MissingEvidencePath;
            try evidence_paths.append(allocator, args[index]);
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else {
            return error.UnknownEvidenceCompletenessArgument;
        }
    }

    const plan_bytes = try fs_util.readFileAlloc(io, allocator, plan_path orelse return error.MissingPlanPath, 16 * 1024 * 1024);
    defer allocator.free(plan_bytes);
    const parsed_plan = try std.json.parseFromSlice(plan_schema.MigrationPlan, allocator, plan_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_plan.deinit();
    if (!plan_validator.validate(parsed_plan.value).valid) return error.InvalidMigrationPlan;
    if (!std.mem.eql(u8, parsed_plan.value.schema_version, plan_schema.schema_version_v2)) return error.ManualEvidenceRequiresPlanV2;
    const plan_sha256 = try manifest_hash.sha256BytesHexAlloc(allocator, plan_bytes);
    defer allocator.free(plan_sha256);

    var observed: std.ArrayList(evidence_completeness.ObservedEvidence) = .empty;
    defer {
        for (observed.items) |item| allocator.free(item.action_id);
        observed.deinit(allocator);
    }
    for (evidence_paths.items) |path| {
        const evidence_bytes = try fs_util.readFileAlloc(io, allocator, path, 1024 * 1024);
        defer allocator.free(evidence_bytes);
        const parsed_evidence = try std.json.parseFromSlice(evidence_schema.Evidence, allocator, evidence_bytes, .{ .ignore_unknown_fields = false });
        defer parsed_evidence.deinit();
        const validation = evidence_validator.validate(parsed_plan.value, plan_sha256, parsed_evidence.value);
        const action_id = try allocator.dupe(u8, parsed_evidence.value.action_id);
        errdefer allocator.free(action_id);
        try observed.append(allocator, .{
            .source_ref = path,
            .action_id = action_id,
            .validation = validation,
        });
    }

    var report = try evidence_completeness.build(allocator, parsed_plan.value, observed.items);
    defer report.deinit(allocator);
    if (summary) {
        try writer.print(
            "HostLift manual evidence completeness\nContract complete: {}\nTrust level: {s}\nManual actions: {d}\nValid actions: {d}\nMissing actions: {d}\nDuplicate actions: {d}\nInvalid actions: {d}\nEvidence files: {d}\nInvalid evidence files: {d}\nUnexpected evidence files: {d}\n",
            .{
                report.contract_complete,
                @tagName(report.trust_level),
                report.manual_actions,
                report.valid_actions,
                report.missing_actions,
                report.duplicate_actions,
                report.invalid_actions,
                report.evidence_files,
                report.invalid_evidence_files,
                report.unexpected_evidence_files,
            },
        );
    } else {
        try std.json.Stringify.value(report, .{ .whitespace = .indent_2, .emit_null_optional_fields = true }, writer);
        try writer.writeByte('\n');
    }

    if (!report.contract_complete) return error.IncompleteManualEvidence;
}

fn runRecord(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var plan_path: ?[]const u8 = null;
    var evidence_path: ?[]const u8 = null;
    var ledger_path: ?[]const u8 = null;
    var summary = false;
    try parseLedgerArgs(args, &plan_path, &evidence_path, &ledger_path, &summary, true);
    const required_plan_path = plan_path orelse return error.MissingPlanPath;
    const required_evidence_path = evidence_path orelse return error.MissingEvidencePath;
    const required_ledger_path = ledger_path orelse return error.MissingEvidenceLedgerPath;

    const plan_bytes = try fs_util.readFileAlloc(io, allocator, required_plan_path, 16 * 1024 * 1024);
    defer allocator.free(plan_bytes);
    const parsed_plan = try std.json.parseFromSlice(plan_schema.MigrationPlan, allocator, plan_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_plan.deinit();
    if (!plan_validator.validate(parsed_plan.value).valid) return error.InvalidMigrationPlan;
    if (!std.mem.eql(u8, parsed_plan.value.schema_version, plan_schema.schema_version_v2)) return error.ManualEvidenceRequiresPlanV2;
    const plan_sha256 = try manifest_hash.sha256BytesHexAlloc(allocator, plan_bytes);
    defer allocator.free(plan_sha256);

    const evidence_bytes = try fs_util.readFileAlloc(io, allocator, required_evidence_path, 1024 * 1024);
    defer allocator.free(evidence_bytes);
    var ledger_writer_buffer: [4096]u8 = undefined;
    try evidence_ledger.appendEvidenceBytes(
        io,
        allocator,
        required_ledger_path,
        parsed_plan.value,
        plan_sha256,
        evidence_bytes,
        std.Io.Timestamp.now(io, .real).toSeconds(),
        &ledger_writer_buffer,
    );

    var report = try evidence_ledger.verifyFile(io, allocator, required_ledger_path, parsed_plan.value, plan_sha256);
    defer report.deinit(allocator);
    try writeLedgerReport(writer, report, summary);
    if (!report.valid) return error.InvalidManualEvidenceLedger;
}

fn runVerifyLedger(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var plan_path: ?[]const u8 = null;
    var evidence_path: ?[]const u8 = null;
    var ledger_path: ?[]const u8 = null;
    var summary = false;
    try parseLedgerArgs(args, &plan_path, &evidence_path, &ledger_path, &summary, false);
    const required_plan_path = plan_path orelse return error.MissingPlanPath;
    const required_ledger_path = ledger_path orelse return error.MissingEvidenceLedgerPath;

    const plan_bytes = try fs_util.readFileAlloc(io, allocator, required_plan_path, 16 * 1024 * 1024);
    defer allocator.free(plan_bytes);
    const parsed_plan = try std.json.parseFromSlice(plan_schema.MigrationPlan, allocator, plan_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_plan.deinit();
    if (!plan_validator.validate(parsed_plan.value).valid) return error.InvalidMigrationPlan;
    if (!std.mem.eql(u8, parsed_plan.value.schema_version, plan_schema.schema_version_v2)) return error.ManualEvidenceRequiresPlanV2;
    const plan_sha256 = try manifest_hash.sha256BytesHexAlloc(allocator, plan_bytes);
    defer allocator.free(plan_sha256);
    var report = try evidence_ledger.verifyFile(io, allocator, required_ledger_path, parsed_plan.value, plan_sha256);
    defer report.deinit(allocator);
    try writeLedgerReport(writer, report, summary);
    if (!report.valid) return error.InvalidManualEvidenceLedger;
}

fn parseLedgerArgs(
    args: []const []const u8,
    plan_path: *?[]const u8,
    evidence_path: *?[]const u8,
    ledger_path: *?[]const u8,
    summary: *bool,
    allow_evidence: bool,
) !void {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--plan")) {
            index += 1;
            if (index >= args.len) return error.MissingPlanPath;
            plan_path.* = args[index];
        } else if (std.mem.eql(u8, arg, "--evidence") and allow_evidence) {
            index += 1;
            if (index >= args.len) return error.MissingEvidencePath;
            evidence_path.* = args[index];
        } else if (std.mem.eql(u8, arg, "--ledger")) {
            index += 1;
            if (index >= args.len) return error.MissingEvidenceLedgerPath;
            ledger_path.* = args[index];
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary.* = true;
        } else {
            return error.UnknownEvidenceLedgerArgument;
        }
    }
}

fn writeLedgerReport(writer: anytype, report: evidence_ledger.VerifyReport, summary: bool) !void {
    if (summary) {
        try writer.print(
            "HostLift manual evidence ledger verification\nValid: {}\nChain valid: {}\nPlan match: {}\nTrust level: {s}\nRecords: {d}\nEvidence records: {d}\nManual actions: {d}\nMissing actions: {d}\nLedger contract complete: {}\nTail hash: {?s}\n",
            .{
                report.valid,
                report.chain_valid,
                report.plan_match,
                @tagName(report.trust_level),
                report.records,
                report.evidence_records,
                report.manual_actions,
                report.missing_actions,
                report.ledger_contract_complete,
                report.tail_hash,
            },
        );
    } else {
        try std.json.Stringify.value(report, .{ .whitespace = .indent_2, .emit_null_optional_fields = true }, writer);
        try writer.writeByte('\n');
    }
}

test "evidence command requires validate and both paths" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);

    try std.testing.expectError(error.MissingEvidenceCommand, run(std.testing.io, std.testing.allocator, &.{}, &writer.writer));
    try std.testing.expectError(error.UnknownEvidenceCommand, run(std.testing.io, std.testing.allocator, &.{"unknown"}, &writer.writer));
    try std.testing.expectError(error.MissingPlanPath, run(std.testing.io, std.testing.allocator, &.{ "validate", "--evidence", "evidence.json" }, &writer.writer));
    try std.testing.expectError(error.MissingEvidencePath, run(std.testing.io, std.testing.allocator, &.{ "validate", "--plan", "plan.json" }, &writer.writer));
    try std.testing.expectError(error.MissingPlanPath, run(std.testing.io, std.testing.allocator, &.{ "completeness", "--summary" }, &writer.writer));
    try std.testing.expectError(error.MissingPlanPath, run(std.testing.io, std.testing.allocator, &.{ "record", "--summary" }, &writer.writer));
    try std.testing.expectError(error.MissingEvidenceLedgerPath, run(std.testing.io, std.testing.allocator, &.{ "verify-ledger", "--plan", "plan.json" }, &writer.writer));
    try std.testing.expectError(error.MissingOutputPath, run(std.testing.io, std.testing.allocator, &.{ "probe", "--plan", "plan.json" }, &writer.writer));
    try std.testing.expectError(error.MissingRemoteHost, run(std.testing.io, std.testing.allocator, &.{ "validate-probed", "--plan", "plan.json" }, &writer.writer));
}

test "evidence validate reads strict json and binds the original plan bytes" {
    const plan_json =
        \\{
        \\  "schema_version": "hostlift.plan.v2",
        \\  "source_inventory_hash": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
        \\  "target_inventory_hash": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        \\  "compatibility": {"compatible":true,"same_distro":true,"same_version":true,"same_package_manager":true,"same_arch":true,"reason":"compatible"},
        \\  "actions": [{
        \\    "id": "resources/reinstall//opt/tool",
        \\    "module": "resources",
        \\    "action_type": "manual_step",
        \\    "description": "Reinstall tool",
        \\    "risk": "high",
        \\    "requires_confirmation": true,
        \\    "phase": "prepare",
        \\    "manual_task": {
        \\      "schema_version": "hostlift.manual_task.v2",
        \\      "kind": "reinstall",
        \\      "provider": "resource_reinstall",
        \\      "inputs": [{"name":"subject","value":"/opt/tool"}],
        \\      "preconditions": [{"kind":"source_reviewed","target":"/opt/tool"}],
        \\      "expected_outputs": [{"name":"installed_artifact"}],
        \\      "verify_probes": [{"kind":"manual_evidence","target":"/opt/tool"}],
        \\      "rollback_policy": "manual",
        \\      "evidence_schema": "hostlift.manual_evidence.v1"
        \\    }
        \\  }],
        \\  "created_at": 1
        \\}
    ;
    const plan_sha256 = try manifest_hash.sha256BytesHexAlloc(std.testing.allocator, plan_json);
    defer std.testing.allocator.free(plan_sha256);
    const evidence_json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "schema_version": "hostlift.manual_evidence.v1",
        \\  "plan_sha256": "{s}",
        \\  "action_id": "resources/reinstall//opt/tool",
        \\  "task_kind": "reinstall",
        \\  "provider": "resource_reinstall",
        \\  "status": "succeeded",
        \\  "operator": "ai-agent",
        \\  "recorded_at": 12,
        \\  "preconditions": [{{"kind":"source_reviewed","target":"/opt/tool","status":"satisfied","observed_at":10}}],
        \\  "outputs": [{{"name":"installed_artifact","status":"produced","artifact_sha256":"{s}"}}],
        \\  "probes": [{{"kind":"manual_evidence","target":"/opt/tool","status":"passed","observed_at":11}}]
        \\}}
    , .{ plan_sha256, "ab" ** 32 });
    defer std.testing.allocator.free(evidence_json);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/plan.json", .{tmp.sub_path});
    defer std.testing.allocator.free(plan_path);
    const evidence_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evidence.json", .{tmp.sub_path});
    defer std.testing.allocator.free(evidence_path);
    try writeTestFile(plan_path, plan_json);
    try writeTestFile(evidence_path, evidence_json);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    try run(std.testing.io, std.testing.allocator, &.{ "validate", "--plan", plan_path, "--evidence", evidence_path, "--summary" }, &writer.writer);
    buffer = writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Valid: true") != null);

    var completeness_buffer: std.ArrayList(u8) = .empty;
    defer completeness_buffer.deinit(std.testing.allocator);
    var completeness_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &completeness_buffer);
    try run(std.testing.io, std.testing.allocator, &.{ "completeness", "--plan", plan_path, "--evidence", evidence_path, "--summary" }, &completeness_writer.writer);
    completeness_buffer = completeness_writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, completeness_buffer.items, "Contract complete: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, completeness_buffer.items, "Trust level: contract_only") != null);

    var missing_buffer: std.ArrayList(u8) = .empty;
    defer missing_buffer.deinit(std.testing.allocator);
    var missing_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &missing_buffer);
    try std.testing.expectError(
        error.IncompleteManualEvidence,
        run(std.testing.io, std.testing.allocator, &.{ "completeness", "--plan", plan_path }, &missing_writer.writer),
    );
    missing_buffer = missing_writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, missing_buffer.items, evidence_schema.completeness_report_schema_version) != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_buffer.items, "\"missing_actions\": 1") != null);

    const ledger_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evidence.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(ledger_path);
    var record_buffer: std.ArrayList(u8) = .empty;
    defer record_buffer.deinit(std.testing.allocator);
    var record_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &record_buffer);
    try run(std.testing.io, std.testing.allocator, &.{ "record", "--plan", plan_path, "--evidence", evidence_path, "--ledger", ledger_path, "--summary" }, &record_writer.writer);
    record_buffer = record_writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, record_buffer.items, "Trust level: hash_chain_only") != null);
    try std.testing.expect(std.mem.indexOf(u8, record_buffer.items, "Ledger contract complete: true") != null);

    var ledger_verify_buffer: std.ArrayList(u8) = .empty;
    defer ledger_verify_buffer.deinit(std.testing.allocator);
    var ledger_verify_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &ledger_verify_buffer);
    try run(std.testing.io, std.testing.allocator, &.{ "verify-ledger", "--plan", plan_path, "--ledger", ledger_path }, &ledger_verify_writer.writer);
    ledger_verify_buffer = ledger_verify_writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, ledger_verify_buffer.items, evidence_ledger.verify_schema_version) != null);

    var duplicate_buffer: std.ArrayList(u8) = .empty;
    defer duplicate_buffer.deinit(std.testing.allocator);
    var duplicate_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &duplicate_buffer);
    try std.testing.expectError(
        error.ManualEvidenceActionAlreadyRecorded,
        run(std.testing.io, std.testing.allocator, &.{ "record", "--plan", plan_path, "--evidence", evidence_path, "--ledger", ledger_path }, &duplicate_writer.writer),
    );
    duplicate_buffer = duplicate_writer.toArrayList();
}

fn writeTestFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var file_buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &file_buffer);
    try writer.interface.writeAll(bytes);
    try writer.flush();
}
