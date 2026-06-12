const std = @import("std");
const audit_operator = @import("../audit/operator.zig");
const audit_sink = @import("../audit/sink.zig");
const remote_options = @import("../remote/options.zig");
const security_validation = @import("../security/validation.zig");

// 命令行参数解析返回的值及下一索引位置。
pub const ValueResult = struct {
    value: []const u8,
    next_index: usize,
};

// 审计日志输出选项，包含路径、sink 和镜像配置。
pub const AuditOptions = struct {
    log_output_path: ?[]const u8 = null,
    sink_target: ?audit_sink.Target = null,
    mirror_log_path: ?[]const u8 = null,
};

// 审批凭证选项，包含 operator、ticket 和 receipt 路径。
pub const ApprovalOptions = struct {
    operator: ?[]const u8 = null,
    ticket: ?[]const u8 = null,
    receipt_path: ?[]const u8 = null,
    receipt_key_env: ?[]const u8 = null,
};

// 读取当前参数后面的必填值，并统一返回下一位置。
pub fn requireValue(args: []const []const u8, index: usize, missing_error: anyerror) !ValueResult {
    const next_index = index + 1;
    if (next_index >= args.len) return missing_error;
    return .{ .value = args[next_index], .next_index = next_index };
}

// 解析 operator 参数并校验格式。
pub fn parseOperator(args: []const []const u8, index: usize) !ValueResult {
    const result = try requireValue(args, index, error.MissingOperator);
    try audit_operator.validate(result.value);
    return result;
}

// 解析审批票据参数并校验格式。
pub fn parseApprovalTicket(args: []const []const u8, index: usize) !ValueResult {
    const result = try requireValue(args, index, error.MissingApprovalTicket);
    try security_validation.validateApprovalTicket(result.value);
    return result;
}

// 解析审批凭证路径并校验路径格式。
pub fn parseApprovalReceipt(args: []const []const u8, index: usize) !ValueResult {
    const result = try requireValue(args, index, error.MissingApprovalReceipt);
    try security_validation.validatePath(result.value);
    return result;
}

// 解析审批凭证签名密钥环境变量名。
pub fn parseApprovalReceiptKeyEnv(args: []const []const u8, index: usize) !ValueResult {
    return requireValue(args, index, error.MissingApprovalReceiptKeyEnv);
}

// 解析审计日志路径并校验路径格式。
pub fn parseAuditLog(args: []const []const u8, index: usize) !ValueResult {
    const result = try requireValue(args, index, error.MissingAuditLogPath);
    try security_validation.validatePath(result.value);
    return result;
}

// 解析审计 sink 目标。
pub fn parseAuditSink(args: []const []const u8, index: usize) !struct { target: audit_sink.Target, next_index: usize } {
    const result = try requireValue(args, index, error.MissingAuditSink);
    return .{ .target = try audit_sink.parseTarget(result.value), .next_index = result.next_index };
}

// 解析审计镜像日志路径并校验路径格式。
pub fn parseAuditMirrorLog(args: []const []const u8, index: usize) !ValueResult {
    const result = try requireValue(args, index, error.MissingAuditMirrorLogPath);
    try security_validation.validatePath(result.value);
    return result;
}

// 解析本地主机授权文件路径并校验路径格式。
pub fn parseHostAuthorization(args: []const []const u8, index: usize) !ValueResult {
    const result = try requireValue(args, index, error.MissingHostAuthorizationPath);
    try security_validation.validatePath(result.value);
    return result;
}

// 校验审计输出选项之间的互斥和依赖关系。
pub fn validateAuditOptions(options: AuditOptions) !void {
    if (options.log_output_path != null and options.sink_target != null) return error.AuditSinkConflict;
    if (options.mirror_log_path != null and options.sink_target == null) return error.AuditMirrorRequiresSink;
    if (options.mirror_log_path != null and options.log_output_path != null) return error.AuditMirrorWithFileSink;
    if (options.mirror_log_path != null and options.sink_target.? == .file) return error.AuditMirrorWithFileSink;
}

// 解析通用远程执行参数。
pub fn parseExecutionOption(options: *remote_options.ExecutionOptions, args: []const []const u8, index: usize, arg: []const u8) !?usize {
    if (std.mem.eql(u8, arg, "--remote-timeout")) {
        const result = try requireValue(args, index, error.MissingTimeout);
        options.timeout_seconds = try std.fmt.parseUnsigned(u32, result.value, 10);
        return result.next_index;
    }
    if (std.mem.eql(u8, arg, "--remote-retries")) {
        const result = try requireValue(args, index, error.MissingRetries);
        options.retries = try std.fmt.parseUnsigned(u8, result.value, 10);
        return result.next_index;
    }
    if (std.mem.eql(u8, arg, "--identity-file")) {
        const result = try requireValue(args, index, error.MissingIdentityFile);
        options.ssh_identity_file = result.value;
        return result.next_index;
    }
    if (std.mem.eql(u8, arg, "--credential-provider")) {
        const result = try requireValue(args, index, error.MissingCredentialProvider);
        options.credential_provider = result.value;
        return result.next_index;
    }
    if (std.mem.eql(u8, arg, "--operation-id")) {
        const result = try requireValue(args, index, error.MissingRemoteOperationId);
        options.operation_id = result.value;
        return result.next_index;
    }
    if (std.mem.eql(u8, arg, "--cancel-file")) {
        const result = try requireValue(args, index, error.MissingRemoteCancelFile);
        options.cancel_file = result.value;
        return result.next_index;
    }
    if (std.mem.eql(u8, arg, "--operation-state")) {
        const result = try requireValue(args, index, error.MissingOperationStatePath);
        options.operation_state_file = result.value;
        return result.next_index;
    }
    return null;
}

test "common options parses and validates audit mirror constraints" {
    try validateAuditOptions(.{ .sink_target = try audit_sink.parseTarget("syslog:local0"), .mirror_log_path = "/tmp/audit.jsonl" });
    try std.testing.expectError(error.AuditMirrorRequiresSink, validateAuditOptions(.{ .mirror_log_path = "/tmp/audit.jsonl" }));
    try std.testing.expectError(error.AuditMirrorWithFileSink, validateAuditOptions(.{
        .sink_target = try audit_sink.parseTarget("file:/tmp/audit.jsonl"),
        .mirror_log_path = "/tmp/mirror.jsonl",
    }));
}

test "common options parses remote execution metadata" {
    var options: remote_options.ExecutionOptions = .{};
    const next = (try parseExecutionOption(&options, &.{ "--operation-state", "/tmp/hostlift-state.jsonl" }, 0, "--operation-state")).?;

    try std.testing.expectEqual(@as(usize, 1), next);
    try std.testing.expectEqualStrings("/tmp/hostlift-state.jsonl", options.operation_state_file.?);
}
