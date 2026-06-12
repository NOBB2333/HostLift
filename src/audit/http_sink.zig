const std = @import("std");
const audit_line = @import("line.zig");
const audit_log = @import("log.zig");
const plan_schema = @import("../plan/schema.zig");
const rollback_manifest = @import("../rollback/manifest.zig");

// HTTPS 远程审计 sink，通过 curl POST 发送事件。
pub const HttpSink = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    chain: audit_log.Chain = .{},

    // 打开 HTTPS 审计 sink；事件会通过 curl POST 到远程端点。
    pub fn open(io: std.Io, allocator: std.mem.Allocator, endpoint: []const u8) HttpSink {
        return .{
            .io = io,
            .allocator = allocator,
            .endpoint = endpoint,
        };
    }

    // 关闭 HTTP sink；当前没有持久连接需要释放。
    pub fn close(self: *HttpSink) void {
        _ = self;
    }

    // 刷新 HTTP sink；curl 是逐事件子进程，无缓冲需要刷新。
    pub fn flush(self: *HttpSink) !void {
        _ = self;
    }

    // 返回当前链尾 hash。
    pub fn tailHash(self: HttpSink) ?[64]u8 {
        return audit_log.chainTailHash(self.chain);
    }

    // 写入 apply action 审计事件到 HTTPS endpoint。
    pub fn writeAction(
        self: *HttpSink,
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
        try sendLine(self.io, self.allocator, self.endpoint, line.items);
    }

    // 写入 rollback entry 审计事件到 HTTPS endpoint。
    pub fn writeRollback(
        self: *HttpSink,
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
        try sendLine(self.io, self.allocator, self.endpoint, line.items);
    }
};

// 通过 curl 子进程发送一行审计事件到远程端点。
fn sendLine(io: std.Io, allocator: std.mem.Allocator, endpoint: []const u8, body: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendCurlArgv(allocator, &argv, endpoint, std.mem.trimEnd(u8, body, "\n"));
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.HttpAuditSinkFailed,
        else => return error.HttpAuditSinkFailed,
    }
}

// 构造 HTTPS 审计 sink 的 curl argv；endpoint 已在 sink target 边界校验。
pub fn appendCurlArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    endpoint: []const u8,
    body: []const u8,
) !void {
    try argv.appendSlice(allocator, &.{
        "curl",
        "--fail-with-body",
        "--silent",
        "--show-error",
        "--max-time",
        "10",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "--data-binary",
        body,
        endpoint,
    });
}

// 从 action_id 中提取模块名称，用于回滚事件。
fn moduleNameForActionId(action_id: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, action_id, '/') orelse return "unknown";
    return action_id[0..slash];
}

test "http sink builds structured curl argv" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendCurlArgv(std.testing.allocator, &argv, "https://audit.example.test/v1/events", "{\"event_hash\":\"abc\"}");

    try std.testing.expectEqualStrings("curl", argv.items[0]);
    try std.testing.expectEqualStrings("--fail-with-body", argv.items[1]);
    try std.testing.expectEqualStrings("--silent", argv.items[2]);
    try std.testing.expectEqualStrings("--show-error", argv.items[3]);
    try std.testing.expectEqualStrings("--max-time", argv.items[4]);
    try std.testing.expectEqualStrings("10", argv.items[5]);
    try std.testing.expectEqualStrings("-X", argv.items[6]);
    try std.testing.expectEqualStrings("POST", argv.items[7]);
    try std.testing.expectEqualStrings("-H", argv.items[8]);
    try std.testing.expectEqualStrings("Content-Type: application/json", argv.items[9]);
    try std.testing.expectEqualStrings("--data-binary", argv.items[10]);
    try std.testing.expectEqualStrings("{\"event_hash\":\"abc\"}", argv.items[11]);
    try std.testing.expectEqualStrings("https://audit.example.test/v1/events", argv.items[12]);
}
