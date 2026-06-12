const std = @import("std");
const audit_log = @import("log.zig");
const plan_schema = @import("../plan/schema.zig");
const rollback_manifest = @import("../rollback/manifest.zig");

// 通用 writer 审计 sink，写入到任意 std.Io.Writer。
pub const WriterSink = struct {
    writer: *std.Io.Writer,
    chain: audit_log.Chain = .{},

    // 关闭 writer sink；外部 writer 生命周期由调用方管理。
    pub fn close(self: *WriterSink) void {
        _ = self;
    }

    // 刷新 writer sink；外部 writer 由调用方决定是否需要刷新。
    pub fn flush(self: *WriterSink) !void {
        _ = self;
    }

    // 返回当前链尾 hash。
    pub fn tailHash(self: WriterSink) ?[64]u8 {
        return audit_log.chainTailHash(self.chain);
    }

    // 写入 apply action 审计事件到任意 writer。
    pub fn writeAction(
        self: *WriterSink,
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
        try audit_log.writeChainedActionEvent(
            allocator,
            self.writer,
            &self.chain,
            timestamp,
            result,
            operator,
            host,
            action,
            plan_created_at,
            plan_hash,
            policy_hash,
            approval_ticket,
            credential_source,
            rollback_manifest_path,
            message,
        );
    }

    // 写入 rollback entry 审计事件到任意 writer。
    pub fn writeRollback(
        self: *WriterSink,
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
        try audit_log.writeChainedRollbackEvent(
            allocator,
            self.writer,
            &self.chain,
            timestamp,
            result,
            operator,
            host,
            entry,
            policy_hash,
            approval_ticket,
            credential_source,
            rollback_manifest_path,
            message,
        );
    }
};
