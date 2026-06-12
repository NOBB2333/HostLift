const std = @import("std");
const audit_log = @import("log.zig");
const file_sink = @import("file_sink.zig");
const plan_schema = @import("../plan/schema.zig");
const rollback_manifest = @import("../rollback/manifest.zig");

// 构造一个把主审计 sink 同步镜像到本地文件的组合 sink 类型。
pub fn MirroredSink(comptime Primary: type) type {
    return struct {
        primary: Primary,
        mirror: file_sink.FileSink,

        const Self = @This();

        // 关闭主审计 sink 和本地镜像文件。
        pub fn close(self: *Self) void {
            self.primary.close();
            self.mirror.close();
        }

        // 刷新主审计 sink 和本地镜像文件。
        pub fn flush(self: *Self) !void {
            try self.primary.flush();
            try self.mirror.flush();
        }

        // 返回主审计链尾 hash；镜像链应与主链保持一致。
        pub fn tailHash(self: Self) ?[64]u8 {
            return self.primary.tailHash();
        }

        // 写入 apply action 审计事件，并同步写入本地镜像。
        pub fn writeAction(
            self: *Self,
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
            try self.primary.writeAction(allocator, timestamp, result, operator, host, action, plan_created_at, plan_hash, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message);
            try self.mirror.writeAction(allocator, timestamp, result, operator, host, action, plan_created_at, plan_hash, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message);
        }

        // 写入 rollback 审计事件，并同步写入本地镜像。
        pub fn writeRollback(
            self: *Self,
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
            try self.primary.writeRollback(allocator, timestamp, result, operator, host, entry, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message);
            try self.mirror.writeRollback(allocator, timestamp, result, operator, host, entry, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message);
        }
    };
}
