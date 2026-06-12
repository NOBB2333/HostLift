const std = @import("std");
const validation = @import("../security/validation.zig");

// 远程操作类型。
pub const OperationKind = enum {
    command,
    transfer,
};

// 远程操作状态。
pub const Status = enum {
    started,
    succeeded,
    failed,
    cancelled,
};

// 远程操作状态事件，不记录敏感信息。
pub const Event = struct {
    operation_id: ?[]const u8,
    kind: OperationKind,
    attempt: u8,
    retries: u8,
    status: Status,
    error_name: ?[]const u8 = null,
};

// 校验本地 operation state JSONL 路径；必须使用绝对路径，避免 cwd 变化写错位置。
pub fn validatePath(path: []const u8) !void {
    validation.validatePath(path) catch return error.InvalidOperationStatePath;
    if (!std.mem.startsWith(u8, path, "/")) return error.InvalidOperationStatePath;
    if (path.len <= 1) return error.InvalidOperationStatePath;
}

// 追加一条远程操作状态 JSONL；不记录 argv、host、identity file 或 secret。
pub fn appendEvent(io: std.Io, path: ?[]const u8, event: Event) !void {
    const output_path = path orelse return;
    try validatePath(output_path);
    var file = try std.Io.Dir.createFileAbsolute(io, output_path, .{ .truncate = false });
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const stat = try file.stat(io);
    try writer.seekTo(stat.size);
    try writeEvent(&writer.interface, event);
    try writer.interface.flush();
}

// 将操作状态事件序列化为 JSON 写入 writer。
fn writeEvent(writer: anytype, event: Event) !void {
    try writer.writeAll("{\"schema_version\":\"hostlift.remote.operation_state.v1\"");
    try writer.writeAll(",\"operation_id\":");
    if (event.operation_id) |operation_id| {
        try std.json.Stringify.value(operation_id, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"kind\":\"{s}\"", .{@tagName(event.kind)});
    try writer.print(",\"attempt\":{d}", .{event.attempt});
    try writer.print(",\"retries\":{d}", .{event.retries});
    try writer.print(",\"status\":\"{s}\"", .{@tagName(event.status)});
    try writer.writeAll(",\"error\":");
    if (event.error_name) |error_name| {
        try std.json.Stringify.value(error_name, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}\n");
}

test "operation state path must be absolute and safe" {
    try validatePath("/tmp/hostlift-operation-state.jsonl");
    try std.testing.expectError(error.InvalidOperationStatePath, validatePath("relative.jsonl"));
    try std.testing.expectError(error.InvalidOperationStatePath, validatePath("/tmp/state;rm"));
}

test "operation state event omits command and credential details" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);

    try writeEvent(&writer.writer, .{
        .operation_id = "OPS-123/apply",
        .kind = .command,
        .attempt = 1,
        .retries = 2,
        .status = .failed,
        .error_name = "RemoteCommandFailed",
    });
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"operation_id\":\"OPS-123/apply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "ssh") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "identity") == null);
}
