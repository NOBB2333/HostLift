const std = @import("std");
const replay_sink = @import("replay_sink.zig");
const sink_target = @import("sink_target.zig");
const verify = @import("verify.zig");

// 审计日志重放报告，记录验证和重放的事件数。
pub const Report = struct {
    valid: bool,
    events: usize,
    replayed: usize,
    tail_hash: ?[]const u8 = null,

    // 释放 replay 报告中持有的 tail hash。
    pub fn deinit(self: Report, allocator: std.mem.Allocator) void {
        if (self.tail_hash) |value| allocator.free(value);
    }
};

// 校验本地审计 JSONL 后，把原始审计行重放到指定 sink。
pub fn replayJsonl(
    io: std.Io,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    target: sink_target.Target,
    file_buffer: []u8,
) !Report {
    const verify_report = try verify.verifyJsonl(allocator, bytes);
    defer verify_report.deinit(allocator);
    if (!verify_report.valid) return error.InvalidAuditLog;

    var report = Report{
        .valid = true,
        .events = verify_report.events,
        .replayed = 0,
        .tail_hash = if (verify_report.tail_hash) |value| try allocator.dupe(u8, value) else null,
    };
    errdefer report.deinit(allocator);

    var sink = try replay_sink.RawSink.open(io, allocator, target, file_buffer);
    defer sink.close();

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        try sink.writeLine(line);
        report.replayed += 1;
    }
    try sink.flush();
    return report;
}

test "replay refuses invalid audit chain before opening sink" {
    var buffer: [4096]u8 = undefined;
    const invalid =
        \\{"schema_version":"hostlift.audit.v1","event_hash":"bad"}
        \\
    ;
    try std.testing.expectError(error.InvalidAuditLog, replayJsonl(std.testing.io, std.testing.allocator, invalid, .{ .file = "/tmp/hostlift-replay-invalid.jsonl" }, &buffer));
}

test "replay writes verified raw audit lines to file sink" {
    const audit_log = @import("log.zig");
    const fs_util = @import("../util/fs.zig");

    var source_buffer: std.ArrayList(u8) = .empty;
    defer source_buffer.deinit(std.testing.allocator);
    var source_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &source_buffer);
    var chain: audit_log.Chain = .{};
    try audit_log.writeChainedEvent(std.testing.allocator, &source_writer.writer, &chain, .{
        .timestamp = 123,
        .phase = .apply,
        .result = .succeeded,
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .action_id = "packages/install/nginx",
        .action_type = "install_package",
        .module = "packages",
        .message = "ok",
    });
    source_buffer = source_writer.toArrayList();

    const path = "zig-cache-hostlift-audit-replay-test.jsonl";
    var file_buffer: [4096]u8 = undefined;
    const report = try replayJsonl(std.testing.io, std.testing.allocator, source_buffer.items, .{ .file = path }, &file_buffer);
    defer report.deinit(std.testing.allocator);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try std.testing.expect(report.valid);
    try std.testing.expectEqual(@as(usize, 1), report.events);
    try std.testing.expectEqual(@as(usize, 1), report.replayed);
    try std.testing.expect(report.tail_hash != null);

    const replayed = try fs_util.readFileAlloc(std.testing.io, std.testing.allocator, path, 1024 * 1024);
    defer std.testing.allocator.free(replayed);
    try std.testing.expectEqualStrings(source_buffer.items, replayed);
}
