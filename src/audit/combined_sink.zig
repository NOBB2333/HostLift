const std = @import("std");
const audit_log = @import("log.zig");
const file_sink = @import("file_sink.zig");
const http_sink = @import("http_sink.zig");
const mirror_sink = @import("mirror_sink.zig");
const sink_target = @import("sink_target.zig");
const syslog_sink = @import("syslog_sink.zig");
const plan_schema = @import("../plan/schema.zig");
const rollback_manifest = @import("../rollback/manifest.zig");

pub const Opened = union(enum) {
    file: file_sink.FileSink,
    http: http_sink.HttpSink,
    syslog: syslog_sink.SyslogSink,
    mirrored_http: mirror_sink.MirroredSink(http_sink.HttpSink),
    mirrored_syslog: mirror_sink.MirroredSink(syslog_sink.SyslogSink),

    // 关闭底层审计 sink。
    pub fn close(self: *Opened) void {
        switch (self.*) {
            .file => |*sink| sink.close(),
            .http => |*sink| sink.close(),
            .syslog => |*sink| sink.close(),
            .mirrored_http => |*sink| sink.close(),
            .mirrored_syslog => |*sink| sink.close(),
        }
    }

    // 刷新审计 sink。
    pub fn flush(self: *Opened) !void {
        switch (self.*) {
            .file => |*sink| try sink.flush(),
            .http => |*sink| try sink.flush(),
            .syslog => |*sink| try sink.flush(),
            .mirrored_http => |*sink| try sink.flush(),
            .mirrored_syslog => |*sink| try sink.flush(),
        }
    }

    // 返回当前链尾 hash。
    pub fn tailHash(self: Opened) ?[64]u8 {
        return switch (self) {
            .file => |sink| sink.tailHash(),
            .http => |sink| sink.tailHash(),
            .syslog => |sink| sink.tailHash(),
            .mirrored_http => |sink| sink.tailHash(),
            .mirrored_syslog => |sink| sink.tailHash(),
        };
    }

    // 写入 apply action 审计事件。
    pub fn writeAction(
        self: *Opened,
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
        switch (self.*) {
            .file => |*sink| try sink.writeAction(allocator, timestamp, result, operator, host, action, plan_created_at, plan_hash, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message),
            .http => |*sink| try sink.writeAction(allocator, timestamp, result, operator, host, action, plan_created_at, plan_hash, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message),
            .syslog => |*sink| try sink.writeAction(allocator, timestamp, result, operator, host, action, plan_created_at, plan_hash, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message),
            .mirrored_http => |*sink| try sink.writeAction(allocator, timestamp, result, operator, host, action, plan_created_at, plan_hash, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message),
            .mirrored_syslog => |*sink| try sink.writeAction(allocator, timestamp, result, operator, host, action, plan_created_at, plan_hash, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message),
        }
    }

    // 写入 rollback entry 审计事件。
    pub fn writeRollback(
        self: *Opened,
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
        switch (self.*) {
            .file => |*sink| try sink.writeRollback(allocator, timestamp, result, operator, host, entry, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message),
            .http => |*sink| try sink.writeRollback(allocator, timestamp, result, operator, host, entry, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message),
            .syslog => |*sink| try sink.writeRollback(allocator, timestamp, result, operator, host, entry, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message),
            .mirrored_http => |*sink| try sink.writeRollback(allocator, timestamp, result, operator, host, entry, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message),
            .mirrored_syslog => |*sink| try sink.writeRollback(allocator, timestamp, result, operator, host, entry, policy_hash, approval_ticket, credential_source, rollback_manifest_path, message),
        }
    }
};

// 审计 sink 打开结果，持有 sink 实例和目标描述。
pub const OpenResult = struct {
    sink: Opened,
    label: []const u8,
    label_allocated: bool = false,

    // 释放打开 sink 时分配的目标描述。
    pub fn deinit(self: *OpenResult, allocator: std.mem.Allocator) void {
        self.sink.close();
        if (self.label_allocated) allocator.free(self.label);
    }
};

// 打开审计 sink；file 写 JSONL，syslog 走 logger，HTTPS 走 curl POST。
pub fn open(
    io: std.Io,
    allocator: std.mem.Allocator,
    explicit_log_path: ?[]const u8,
    target: ?sink_target.Target,
    fallback_timestamp: i64,
    file_buffer: []u8,
) !OpenResult {
    return openWithMirror(io, allocator, explicit_log_path, target, null, fallback_timestamp, file_buffer, null);
}

// 打开审计 sink，并在使用 syslog/HTTPS sink 时可选双写本地镜像日志。
pub fn openWithMirror(
    io: std.Io,
    allocator: std.mem.Allocator,
    explicit_log_path: ?[]const u8,
    target: ?sink_target.Target,
    mirror_log_path: ?[]const u8,
    fallback_timestamp: i64,
    file_buffer: []u8,
    mirror_buffer: ?[]u8,
) !OpenResult {
    if (explicit_log_path != null and target != null) return error.AuditSinkConflict;
    if (mirror_log_path != null and target == null) return error.AuditMirrorRequiresSink;
    if (mirror_log_path != null and explicit_log_path != null) return error.AuditMirrorWithFileSink;
    if (explicit_log_path) |path| {
        return .{
            .sink = .{ .file = try file_sink.FileSink.open(io, path, file_buffer) },
            .label = path,
        };
    }
    if (target) |value| {
        return switch (value) {
            .file => |path| blk: {
                if (mirror_log_path != null) return error.AuditMirrorWithFileSink;
                break :blk .{
                    .sink = .{ .file = try file_sink.FileSink.open(io, path, file_buffer) },
                    .label = path,
                };
            },
            .syslog => |facility| blk: {
                const label = try std.fmt.allocPrint(allocator, "syslog:{s}", .{facility});
                errdefer allocator.free(label);
                const opened: Opened = if (mirror_log_path) |mirror_path| .{
                    .mirrored_syslog = .{
                        .primary = syslog_sink.SyslogSink.open(io, allocator, facility),
                        .mirror = try file_sink.FileSink.open(io, mirror_path, mirror_buffer orelse return error.MissingAuditMirrorBuffer),
                    },
                } else .{ .syslog = syslog_sink.SyslogSink.open(io, allocator, facility) };
                break :blk .{
                    .sink = opened,
                    .label = label,
                    .label_allocated = true,
                };
            },
            .http => |endpoint| .{
                .sink = if (mirror_log_path) |mirror_path| .{
                    .mirrored_http = .{
                        .primary = http_sink.HttpSink.open(io, allocator, endpoint),
                        .mirror = try file_sink.FileSink.open(io, mirror_path, mirror_buffer orelse return error.MissingAuditMirrorBuffer),
                    },
                } else .{ .http = http_sink.HttpSink.open(io, allocator, endpoint) },
                .label = endpoint,
            },
        };
    }
    const path = try audit_log.pathForBatch(allocator, fallback_timestamp);
    errdefer allocator.free(path);
    return .{
        .sink = .{ .file = try file_sink.FileSink.open(io, path, file_buffer) },
        .label = path,
        .label_allocated = true,
    };
}
