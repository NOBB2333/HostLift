const std = @import("std");
const audit_sink = @import("../audit/sink.zig");
const common_options = @import("../cli/common_options.zig");
const remote_options = @import("../remote/options.zig");

// rollback 子命令的解析结果，包含 manifest 路径、审批和执行参数。
pub const Parsed = struct {
    manifest_path: ?[]const u8 = null,
    host: ?[]const u8 = null,
    dry_run: bool = false,
    approve: bool = false,
    execution_options: remote_options.ExecutionOptions = .{},
    operator: ?[]const u8 = null,
    approval_ticket: ?[]const u8 = null,
    approval_receipt_path: ?[]const u8 = null,
    approval_receipt_key_env: ?[]const u8 = null,
    audit_log_output_path: ?[]const u8 = null,
    audit_sink_target: ?audit_sink.Target = null,
    audit_mirror_log_path: ?[]const u8 = null,
    policy_path: ?[]const u8 = null,
    host_authz_path: ?[]const u8 = null,
};

// 解析 rollback 命令参数，只负责 argv 到结构化 options 的转换。
pub fn parse(args: []const []const u8) !Parsed {
    var parsed: Parsed = .{};

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) return error.MissingRollbackManifest;
            parsed.manifest_path = args[index];
        } else if (std.mem.eql(u8, arg, "--host")) {
            const result = try common_options.requireValue(args, index, error.MissingRemoteHost);
            index = result.next_index;
            parsed.host = result.value;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--approve")) {
            parsed.approve = true;
        } else if (std.mem.eql(u8, arg, "--operator")) {
            const result = try common_options.parseOperator(args, index);
            index = result.next_index;
            parsed.operator = result.value;
        } else if (std.mem.eql(u8, arg, "--approval-ticket")) {
            const result = try common_options.parseApprovalTicket(args, index);
            index = result.next_index;
            parsed.approval_ticket = result.value;
        } else if (std.mem.eql(u8, arg, "--approval-receipt")) {
            const result = try common_options.parseApprovalReceipt(args, index);
            index = result.next_index;
            parsed.approval_receipt_path = result.value;
        } else if (std.mem.eql(u8, arg, "--approval-receipt-key-env")) {
            const result = try common_options.parseApprovalReceiptKeyEnv(args, index);
            index = result.next_index;
            parsed.approval_receipt_key_env = result.value;
        } else if (std.mem.eql(u8, arg, "--audit-log")) {
            const result = try common_options.parseAuditLog(args, index);
            index = result.next_index;
            parsed.audit_log_output_path = result.value;
        } else if (std.mem.eql(u8, arg, "--audit-sink")) {
            const result = try common_options.parseAuditSink(args, index);
            index = result.next_index;
            parsed.audit_sink_target = result.target;
        } else if (std.mem.eql(u8, arg, "--audit-mirror-log")) {
            const result = try common_options.parseAuditMirrorLog(args, index);
            index = result.next_index;
            parsed.audit_mirror_log_path = result.value;
        } else if (std.mem.eql(u8, arg, "--policy")) {
            const result = try common_options.requireValue(args, index, error.MissingPolicyPath);
            index = result.next_index;
            parsed.policy_path = result.value;
        } else if (std.mem.eql(u8, arg, "--host-authz")) {
            const result = try common_options.parseHostAuthorization(args, index);
            index = result.next_index;
            parsed.host_authz_path = result.value;
        } else if (std.mem.eql(u8, arg, "--remote-timeout")) {
            index = (try common_options.parseExecutionOption(&parsed.execution_options, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--remote-retries")) {
            index = (try common_options.parseExecutionOption(&parsed.execution_options, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--identity-file")) {
            index = (try common_options.parseExecutionOption(&parsed.execution_options, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--credential-provider")) {
            index = (try common_options.parseExecutionOption(&parsed.execution_options, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--operation-id")) {
            index = (try common_options.parseExecutionOption(&parsed.execution_options, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--cancel-file")) {
            index = (try common_options.parseExecutionOption(&parsed.execution_options, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--operation-state")) {
            index = (try common_options.parseExecutionOption(&parsed.execution_options, args, index, arg)).?;
        } else {
            return error.UnknownRollbackArgument;
        }
    }

    if (!parsed.dry_run and !parsed.approve) return error.RollbackRequiresDryRunOrApprove;
    if (parsed.dry_run and parsed.approve) return error.RollbackModeConflict;
    try common_options.validateAuditOptions(.{
        .log_output_path = parsed.audit_log_output_path,
        .sink_target = parsed.audit_sink_target,
        .mirror_log_path = parsed.audit_mirror_log_path,
    });
    return parsed;
}

test "rollback options parser rejects conflicting execution modes" {
    try std.testing.expectError(error.RollbackModeConflict, parse(&.{ "--manifest", "rollback.jsonl", "--dry-run", "--approve" }));
}

test "rollback options parser rejects conflicting audit sinks" {
    try std.testing.expectError(error.AuditSinkConflict, parse(&.{ "--manifest", "rollback.jsonl", "--approve", "--host", "root@192.0.2.10", "--audit-log", "/tmp/audit.jsonl", "--audit-sink", "file:/tmp/other.jsonl" }));
}

test "rollback options parser accepts credential provider option" {
    const parsed = try parse(&.{ "--manifest", "rollback.jsonl", "--dry-run", "--credential-provider", "ssh-agent" });
    try std.testing.expectEqualStrings("ssh-agent", parsed.execution_options.credential_provider.?);
}

test "rollback options parser accepts approval receipt key env" {
    const parsed = try parse(&.{ "--manifest", "rollback.jsonl", "--dry-run", "--approval-receipt", "/tmp/receipt.json", "--approval-receipt-key-env", "HOSTLIFT_APPROVAL_KEY" });
    try std.testing.expectEqualStrings("/tmp/receipt.json", parsed.approval_receipt_path.?);
    try std.testing.expectEqualStrings("HOSTLIFT_APPROVAL_KEY", parsed.approval_receipt_key_env.?);
}

test "rollback options parser accepts audit mirror with remote sink" {
    const parsed = try parse(&.{ "--manifest", "rollback.jsonl", "--dry-run", "--audit-sink", "syslog:local0", "--audit-mirror-log", "/tmp/rollback-audit-mirror.jsonl" });
    try std.testing.expectEqualStrings("/tmp/rollback-audit-mirror.jsonl", parsed.audit_mirror_log_path.?);
}

test "rollback options parser rejects audit mirror without remote sink" {
    try std.testing.expectError(error.AuditMirrorRequiresSink, parse(&.{ "--manifest", "rollback.jsonl", "--dry-run", "--audit-mirror-log", "/tmp/audit-mirror.jsonl" }));
}

test "rollback options parser rejects audit mirror with file sink" {
    try std.testing.expectError(error.AuditMirrorWithFileSink, parse(&.{ "--manifest", "rollback.jsonl", "--dry-run", "--audit-sink", "file:/tmp/audit.jsonl", "--audit-mirror-log", "/tmp/audit-mirror.jsonl" }));
}

test "rollback options parser accepts host authorization file" {
    const parsed = try parse(&.{ "--manifest", "rollback.jsonl", "--dry-run", "--host-authz", "/tmp/host-authz.json" });
    try std.testing.expectEqualStrings("/tmp/host-authz.json", parsed.host_authz_path.?);
}

test "rollback options parser accepts operation state file" {
    const parsed = try parse(&.{ "--manifest", "rollback.jsonl", "--dry-run", "--operation-state", "/tmp/hostlift-operation-state.jsonl" });
    try std.testing.expectEqualStrings("/tmp/hostlift-operation-state.jsonl", parsed.execution_options.operation_state_file.?);
}
