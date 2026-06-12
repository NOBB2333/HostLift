const std = @import("std");
const audit_log = @import("log.zig");
const writer_sink = @import("writer_sink.zig");
const plan_schema = @import("../plan/schema.zig");
const rollback_manifest = @import("../rollback/manifest.zig");

// 本地 JSONL 文件审计 sink。
pub const FileSink = struct {
    io: std.Io,
    file: std.Io.File,
    writer: std.Io.File.Writer,
    chain: audit_log.Chain = .{},

    // 打开本地 JSONL 审计 sink；现阶段集中 sink 会在此接口外扩展。
    pub fn open(io: std.Io, path: []const u8, buffer: []u8) !FileSink {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        return .{
            .io = io,
            .file = file,
            .writer = file.writer(io, buffer),
        };
    }

    // 关闭底层审计文件。
    pub fn close(self: *FileSink) void {
        self.file.close(self.io);
    }

    // 刷新已写入的审计事件。
    pub fn flush(self: *FileSink) !void {
        try self.writer.flush();
    }

    // 返回当前链尾 hash。
    pub fn tailHash(self: FileSink) ?[64]u8 {
        return audit_log.chainTailHash(self.chain);
    }

    // 写入 apply action 审计事件。
    pub fn writeAction(
        self: *FileSink,
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
            &self.writer.interface,
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

    // 写入 rollback entry 审计事件。
    pub fn writeRollback(
        self: *FileSink,
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
            &self.writer.interface,
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

pub const WriterSink = writer_sink.WriterSink;
