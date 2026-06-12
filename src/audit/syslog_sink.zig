const std = @import("std");
const audit_line = @import("line.zig");
const audit_log = @import("log.zig");
const plan_schema = @import("../plan/schema.zig");
const rollback_manifest = @import("../rollback/manifest.zig");

// syslog 审计 sink，通过 logger 子进程写入本机 syslog。
pub const SyslogSink = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    facility: []const u8,
    chain: audit_log.Chain = .{},

    // 打开 syslog 审计 sink；事件会通过 logger argv 写入本机 syslog。
    pub fn open(io: std.Io, allocator: std.mem.Allocator, facility: []const u8) SyslogSink {
        return .{
            .io = io,
            .allocator = allocator,
            .facility = facility,
        };
    }

    // 关闭 syslog sink；当前没有持久句柄需要释放。
    pub fn close(self: *SyslogSink) void {
        _ = self;
    }

    // 刷新 syslog sink；logger 是逐事件子进程，无缓冲需要刷新。
    pub fn flush(self: *SyslogSink) !void {
        _ = self;
    }

    // 返回当前链尾 hash。
    pub fn tailHash(self: SyslogSink) ?[64]u8 {
        return audit_log.chainTailHash(self.chain);
    }

    // 写入 apply action 审计事件到 syslog。
    pub fn writeAction(
        self: *SyslogSink,
        allocator: std.mem.Allocator,
        timestamp: i64,
        result: audit_log.Result,
        operator: []const u8,
        host: []const u8,
        action: plan_schema.Action,
        plan_created_at: i64,
        plan_hash: []const u8,
        policy_hash: ?[]const u8,
        approval_ticket: ?[]const u8,
        credential_source: audit_log.CredentialSource,
        rollback_manifest_path: []const u8,
        message: []const u8,
    ) !void {
        var line = try audit_line.encodeChained(allocator, &self.chain, .{
            .timestamp = timestamp,
            .phase = .apply,
            .result = result,
            .operator = operator,
            .host = host,
            .action_id = action.id,
            .action_type = @tagName(action.action_type),
            .module = @tagName(action.module),
            .plan_created_at = plan_created_at,
            .plan_hash = plan_hash,
            .policy_hash = policy_hash,
            .approval_ticket = approval_ticket,
            .credential_source = credential_source,
            .rollback_manifest = rollback_manifest_path,
            .message = message,
        });
        defer line.deinit(allocator);
        try sendLine(self.io, self.allocator, self.facility, line.items);
    }

    // 写入 rollback entry 审计事件到 syslog。
    pub fn writeRollback(
        self: *SyslogSink,
        allocator: std.mem.Allocator,
        timestamp: i64,
        result: audit_log.Result,
        operator: []const u8,
        host: []const u8,
        entry: rollback_manifest.Entry,
        policy_hash: ?[]const u8,
        approval_ticket: ?[]const u8,
        credential_source: audit_log.CredentialSource,
        rollback_manifest_path: []const u8,
        message: []const u8,
    ) !void {
        var line = try audit_line.encodeChained(allocator, &self.chain, .{
            .timestamp = timestamp,
            .phase = .rollback,
            .result = result,
            .operator = operator,
            .host = host,
            .action_id = entry.action_id,
            .action_type = entry.action_type,
            .module = moduleNameForActionId(entry.action_id),
            .policy_hash = policy_hash,
            .approval_ticket = approval_ticket,
            .credential_source = credential_source,
            .rollback_manifest = rollback_manifest_path,
            .message = message,
        });
        defer line.deinit(allocator);
        try sendLine(self.io, self.allocator, self.facility, line.items);
    }
};

// 通过 logger 子进程发送一条审计消息到 syslog。
fn sendLine(io: std.Io, allocator: std.mem.Allocator, facility: []const u8, message: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        if (argv.items.len >= 3) allocator.free(argv.items[2]);
        argv.deinit(allocator);
    }
    try appendLoggerArgv(allocator, &argv, facility, std.mem.trimEnd(u8, message, "\n"));
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SyslogAuditSinkFailed,
        else => return error.SyslogAuditSinkFailed,
    }
}

// 构造 logger argv；facility 已在 sink target 边界校验。
pub fn appendLoggerArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    facility: []const u8,
    message: []const u8,
) !void {
    const priority = try std.fmt.allocPrint(allocator, "{s}.info", .{facility});
    errdefer allocator.free(priority);
    try argv.appendSlice(allocator, &.{ "logger", "-p", priority, "-t", "hostlift", "--", message });
}

// 从 action_id 中提取模块名称，用于回滚事件。
fn moduleNameForActionId(action_id: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, action_id, '/') orelse return "unknown";
    return action_id[0..slash];
}

test "syslog sink builds structured logger argv" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        if (argv.items.len >= 3) std.testing.allocator.free(argv.items[2]);
        argv.deinit(std.testing.allocator);
    }
    try appendLoggerArgv(std.testing.allocator, &argv, "local0", "{\"event_hash\":\"abc\"}");

    try std.testing.expectEqualStrings("logger", argv.items[0]);
    try std.testing.expectEqualStrings("-p", argv.items[1]);
    try std.testing.expectEqualStrings("local0.info", argv.items[2]);
    try std.testing.expectEqualStrings("-t", argv.items[3]);
    try std.testing.expectEqualStrings("hostlift", argv.items[4]);
    try std.testing.expectEqualStrings("--", argv.items[5]);
    try std.testing.expectEqualStrings("{\"event_hash\":\"abc\"}", argv.items[6]);
}
