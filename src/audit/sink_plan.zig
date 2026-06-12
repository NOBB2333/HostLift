const std = @import("std");
const audit_log = @import("log.zig");
const sink_target = @import("sink_target.zig");

// 审计 sink 计划类型。
pub const PlanKind = enum {
    file,
    http,
    syslog,
};

// 审计 sink 执行计划。
pub const Plan = struct {
    kind: PlanKind,
    target: []const u8,
    executable: bool,
};

// 审计文件路径选择结果。
pub const Selection = struct {
    path: []const u8,
    allocated: bool,
};

// 把审计 sink target 转成执行计划；集中 sink 当前保留契约但不执行。
pub fn planTarget(target: sink_target.Target) Plan {
    return switch (target) {
        .file => |path| .{ .kind = .file, .target = path, .executable = true },
        .http => |endpoint| .{ .kind = .http, .target = endpoint, .executable = true },
        .syslog => |facility| .{ .kind = .syslog, .target = facility, .executable = true },
    };
}

// 选择 approved 执行时使用的本地审计文件路径，并拒绝未实现的集中 sink。
pub fn selectFilePath(
    allocator: std.mem.Allocator,
    explicit_log_path: ?[]const u8,
    target: ?sink_target.Target,
    fallback_timestamp: i64,
) !Selection {
    if (explicit_log_path != null and target != null) return error.AuditSinkConflict;
    if (explicit_log_path) |path| return .{ .path = path, .allocated = false };
    if (target) |value| {
        const plan = planTarget(value);
        if (!plan.executable) return error.UnsupportedAuditSink;
        if (plan.kind != .file) return error.AuditSinkIsNotFile;
        return .{ .path = plan.target, .allocated = false };
    }
    return .{
        .path = try audit_log.pathForBatch(allocator, fallback_timestamp),
        .allocated = true,
    };
}

test "audit sink plan marks http and syslog as executable" {
    const http_plan = planTarget(try sink_target.parse("https://audit.example.test/v1/events"));
    try std.testing.expectEqual(PlanKind.http, http_plan.kind);
    try std.testing.expect(http_plan.executable);

    const syslog_plan = planTarget(try sink_target.parse("syslog:local0"));
    try std.testing.expectEqual(PlanKind.syslog, syslog_plan.kind);
    try std.testing.expect(syslog_plan.executable);
}

test "audit sink plan selects explicit file and default paths" {
    const explicit = try selectFilePath(std.testing.allocator, "/tmp/audit.jsonl", null, 123);
    try std.testing.expect(!explicit.allocated);
    try std.testing.expectEqualStrings("/tmp/audit.jsonl", explicit.path);

    const file_target = try selectFilePath(std.testing.allocator, null, try sink_target.parse("file:/tmp/hostlift-audit.jsonl"), 123);
    try std.testing.expect(!file_target.allocated);
    try std.testing.expectEqualStrings("/tmp/hostlift-audit.jsonl", file_target.path);

    const fallback = try selectFilePath(std.testing.allocator, null, null, 123);
    defer std.testing.allocator.free(fallback.path);
    try std.testing.expect(fallback.allocated);
    try std.testing.expectEqualStrings("/tmp/hostlift-audit-123.jsonl", fallback.path);
}

test "audit sink plan rejects conflicts and unsupported centralized sinks" {
    try std.testing.expectError(
        error.AuditSinkConflict,
        selectFilePath(std.testing.allocator, "/tmp/audit.jsonl", try sink_target.parse("file:/tmp/other.jsonl"), 123),
    );
}
