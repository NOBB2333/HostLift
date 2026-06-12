const std = @import("std");
const audit_sink = @import("../audit/sink.zig");
const apply_executor = @import("../apply/executor.zig");
const common_options = @import("common_options.zig");
const plan_filter = @import("../plan/filter.zig");
const remote_schema = @import("../remote/schema.zig");

// apply 子命令的解析结果，包含 plan 路径、审批和审计参数。
pub const Parsed = struct {
    plan_path: ?[]const u8 = null,
    dry_run: bool = false,
    approve: bool = false,
    host: ?[]const u8 = null,
    source_host: ?[]const u8 = null,
    operator: ?[]const u8 = null,
    approval_ticket: ?[]const u8 = null,
    approval_receipt_path: ?[]const u8 = null,
    approval_receipt_key_env: ?[]const u8 = null,
    audit_log_output_path: ?[]const u8 = null,
    audit_sink_target: ?audit_sink.Target = null,
    audit_mirror_log_path: ?[]const u8 = null,
    policy_path: ?[]const u8 = null,
    host_authz_path: ?[]const u8 = null,
    apply_options: apply_executor.Options = .{},
    filter: plan_filter.ActionFilter = .empty,

    // 释放解析过程中分配的 action/module 过滤器。
    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        self.filter.deinit(allocator);
    }
};

// 解析 apply 命令参数，只做 argv 到结构化 options 的转换。
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Parsed {
    var parsed: Parsed = .{};
    errdefer parsed.deinit(allocator);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--plan")) {
            index += 1;
            if (index >= args.len) return error.MissingPlanPath;
            parsed.plan_path = args[index];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--approve")) {
            parsed.approve = true;
        } else if (std.mem.eql(u8, arg, "--host")) {
            const result = try common_options.requireValue(args, index, error.MissingRemoteHost);
            index = result.next_index;
            parsed.host = result.value;
        } else if (std.mem.eql(u8, arg, "--source-host")) {
            const result = try common_options.requireValue(args, index, error.MissingSourceHost);
            index = result.next_index;
            parsed.source_host = result.value;
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
        } else if (std.mem.eql(u8, arg, "--firewall-reload")) {
            parsed.apply_options.firewall_reload = true;
        } else if (std.mem.eql(u8, arg, "--ssh-port")) {
            index += 1;
            if (index >= args.len) return error.MissingSshPort;
            parsed.apply_options.ssh_port = try std.fmt.parseUnsigned(u16, args[index], 10);
            if (parsed.apply_options.ssh_port == 0) return error.InvalidSshPort;
        } else if (std.mem.eql(u8, arg, "--firewall-recovery-window")) {
            index += 1;
            if (index >= args.len) return error.MissingFirewallRecoveryWindow;
            parsed.apply_options.firewall_recovery_window_seconds = try std.fmt.parseUnsigned(u32, args[index], 10);
            if (parsed.apply_options.firewall_recovery_window_seconds < 10 or parsed.apply_options.firewall_recovery_window_seconds > 3600) return error.InvalidFirewallRecoveryWindow;
        } else if (std.mem.eql(u8, arg, "--remote-timeout")) {
            index = (try common_options.parseExecutionOption(&parsed.apply_options.execution, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--remote-retries")) {
            index = (try common_options.parseExecutionOption(&parsed.apply_options.execution, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--identity-file")) {
            index = (try common_options.parseExecutionOption(&parsed.apply_options.execution, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--credential-provider")) {
            index = (try common_options.parseExecutionOption(&parsed.apply_options.execution, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--operation-id")) {
            index = (try common_options.parseExecutionOption(&parsed.apply_options.execution, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--cancel-file")) {
            index = (try common_options.parseExecutionOption(&parsed.apply_options.execution, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--operation-state")) {
            index = (try common_options.parseExecutionOption(&parsed.apply_options.execution, args, index, arg)).?;
        } else if (std.mem.eql(u8, arg, "--transfer-transport")) {
            index += 1;
            if (index >= args.len) return error.MissingTransport;
            parsed.apply_options.transfer_transport = parseTransferTransport(args[index]) orelse return error.InvalidTransport;
        } else if (std.mem.eql(u8, arg, "--transfer-partial")) {
            parsed.apply_options.transfer_partial = true;
        } else if (std.mem.eql(u8, arg, "--transfer-resume")) {
            parsed.apply_options.transfer_resume = true;
        } else if (std.mem.eql(u8, arg, "--transfer-bwlimit")) {
            index += 1;
            if (index >= args.len) return error.MissingTransferBandwidthLimit;
            parsed.apply_options.transfer_bandwidth_limit_kbps = try std.fmt.parseUnsigned(u32, args[index], 10);
            if (parsed.apply_options.transfer_bandwidth_limit_kbps.? == 0) return error.InvalidTransferBandwidthLimit;
        } else if (std.mem.eql(u8, arg, "--include-module")) {
            index += 1;
            if (index >= args.len) return error.MissingFilterValue;
            try parsed.filter.appendModuleList(allocator, .include, args[index]);
        } else if (std.mem.eql(u8, arg, "--exclude-module")) {
            index += 1;
            if (index >= args.len) return error.MissingFilterValue;
            try parsed.filter.appendModuleList(allocator, .exclude, args[index]);
        } else if (std.mem.eql(u8, arg, "--include-action")) {
            index += 1;
            if (index >= args.len) return error.MissingFilterValue;
            try parsed.filter.appendActionPattern(allocator, .include, args[index]);
        } else if (std.mem.eql(u8, arg, "--exclude-action")) {
            index += 1;
            if (index >= args.len) return error.MissingFilterValue;
            try parsed.filter.appendActionPattern(allocator, .exclude, args[index]);
        } else {
            return error.UnknownApplyArgument;
        }
    }

    if (!parsed.dry_run and !parsed.approve) return error.ApplyRequiresDryRunOrApprove;
    if (parsed.dry_run and parsed.approve) return error.ApplyModeConflict;
    try common_options.validateAuditOptions(.{
        .log_output_path = parsed.audit_log_output_path,
        .sink_target = parsed.audit_sink_target,
        .mirror_log_path = parsed.audit_mirror_log_path,
    });
    return parsed;
}

// 解析 transfer 后端名称。
pub fn parseTransferTransport(value: []const u8) ?remote_schema.TransferTransport {
    if (std.mem.eql(u8, value, "scp")) return .scp;
    if (std.mem.eql(u8, value, "rsync")) return .rsync;
    if (std.mem.eql(u8, value, "chunk")) return .chunk;
    return null;
}

test "apply command parses transfer transport names" {
    try std.testing.expectEqual(remote_schema.TransferTransport.scp, parseTransferTransport("scp").?);
    try std.testing.expectEqual(remote_schema.TransferTransport.rsync, parseTransferTransport("rsync").?);
    try std.testing.expectEqual(remote_schema.TransferTransport.chunk, parseTransferTransport("chunk").?);
    try std.testing.expect(parseTransferTransport("ftp") == null);
}

test "apply options parser rejects conflicting execution modes" {
    try std.testing.expectError(error.ApplyModeConflict, parse(std.testing.allocator, &.{ "--plan", "plan.json", "--dry-run", "--approve" }));
}

test "apply options parser accepts credential provider option" {
    var parsed = try parse(std.testing.allocator, &.{ "--plan", "plan.json", "--dry-run", "--credential-provider", "ssh-agent" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ssh-agent", parsed.apply_options.execution.credential_provider.?);
}

test "apply options parser accepts transfer resume option" {
    var parsed = try parse(std.testing.allocator, &.{ "--plan", "plan.json", "--dry-run", "--transfer-resume" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.apply_options.transfer_resume);
}

test "apply options parser accepts transfer bandwidth limit" {
    var parsed = try parse(std.testing.allocator, &.{ "--plan", "plan.json", "--dry-run", "--transfer-bwlimit", "4096" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 4096), parsed.apply_options.transfer_bandwidth_limit_kbps);
}

test "apply options parser accepts approval receipt key env" {
    var parsed = try parse(std.testing.allocator, &.{ "--plan", "plan.json", "--dry-run", "--approval-receipt", "/tmp/receipt.json", "--approval-receipt-key-env", "HOSTLIFT_APPROVAL_KEY" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/receipt.json", parsed.approval_receipt_path.?);
    try std.testing.expectEqualStrings("HOSTLIFT_APPROVAL_KEY", parsed.approval_receipt_key_env.?);
}

test "apply options parser accepts audit mirror with remote sink" {
    var parsed = try parse(std.testing.allocator, &.{ "--plan", "plan.json", "--dry-run", "--audit-sink", "https://audit.example.test/events", "--audit-mirror-log", "/tmp/audit-mirror.jsonl" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/audit-mirror.jsonl", parsed.audit_mirror_log_path.?);
}

test "apply options parser rejects audit mirror without remote sink" {
    try std.testing.expectError(error.AuditMirrorRequiresSink, parse(std.testing.allocator, &.{ "--plan", "plan.json", "--dry-run", "--audit-mirror-log", "/tmp/audit-mirror.jsonl" }));
}

test "apply options parser rejects audit mirror with file sink" {
    try std.testing.expectError(error.AuditMirrorWithFileSink, parse(std.testing.allocator, &.{ "--plan", "plan.json", "--dry-run", "--audit-sink", "file:/tmp/audit.jsonl", "--audit-mirror-log", "/tmp/audit-mirror.jsonl" }));
}

test "apply options parser accepts host authorization file" {
    var parsed = try parse(std.testing.allocator, &.{ "--plan", "plan.json", "--dry-run", "--host-authz", "/tmp/host-authz.json" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/host-authz.json", parsed.host_authz_path.?);
}

test "apply options parser accepts operation state file" {
    var parsed = try parse(std.testing.allocator, &.{ "--plan", "plan.json", "--dry-run", "--operation-state", "/tmp/hostlift-operation-state.jsonl" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/hostlift-operation-state.jsonl", parsed.apply_options.execution.operation_state_file.?);
}
