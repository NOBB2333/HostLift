const std = @import("std");
const validation = @import("../security/validation.zig");

// 远程操作控制元数据，包含取消标记和状态文件路径。
pub const Control = struct {
    operation_id: ?[]const u8 = null,
    cancel_file: ?[]const u8 = null,
    operation_state_file: ?[]const u8 = null,
};

// 远程操作单次尝试上下文。
pub const Attempt = struct {
    operation_id: ?[]const u8,
    attempt: u8,
    retries: u8,
};

// 构造远程操作控制元数据，集中校验 operation id 和 cancel file。
pub fn control(operation_id: ?[]const u8, cancel_file: ?[]const u8) !Control {
    return controlWithState(operation_id, cancel_file, null);
}

// 构造带状态文件的远程操作控制元数据。
pub fn controlWithState(operation_id: ?[]const u8, cancel_file: ?[]const u8, operation_state_file: ?[]const u8) !Control {
    if (operation_id) |value| try validateOperationId(value);
    if (cancel_file) |value| try validateCancelFile(value);
    if (operation_state_file) |value| try validateOperationStateFile(value);
    return .{
        .operation_id = operation_id,
        .cancel_file = cancel_file,
        .operation_state_file = operation_state_file,
    };
}

// 校验远程操作标识，供后续 session/cancel/控制面板关联使用。
pub fn validateOperationId(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidRemoteOperationId;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '-', '_', '.', '/', ':' => {},
            else => return error.InvalidRemoteOperationId,
        }
    }
}

// 校验本地取消标记文件路径；必须使用绝对路径避免 cwd 造成误取消。
pub fn validateCancelFile(path: []const u8) !void {
    validation.validatePath(path) catch return error.InvalidRemoteCancelFile;
    if (!std.mem.startsWith(u8, path, "/")) return error.InvalidRemoteCancelFile;
    if (path.len <= 1) return error.InvalidRemoteCancelFile;
}

// 校验本地 operation state 文件路径；必须使用绝对路径。
pub fn validateOperationStateFile(path: []const u8) !void {
    validation.validatePath(path) catch return error.InvalidOperationStatePath;
    if (!std.mem.startsWith(u8, path, "/")) return error.InvalidOperationStatePath;
    if (path.len <= 1) return error.InvalidOperationStatePath;
}

// 如果本地取消标记文件存在，则拒绝继续执行远程操作。
pub fn checkCancelled(io: std.Io, control_value: Control) !void {
    try checkCancelFile(io, control_value.cancel_file);
}

// 返回一次子进程尝试的上下文，供 runner 输出稳定的重试信息。
pub fn attemptContext(control_value: Control, attempt: u8, retries: u8) Attempt {
    return .{
        .operation_id = control_value.operation_id,
        .attempt = attempt,
        .retries = retries,
    };
}

// 如果本地取消标记文件存在，则拒绝继续执行远程操作。
pub fn checkCancelFile(io: std.Io, cancel_file: ?[]const u8) !void {
    const path = cancel_file orelse return;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.RemoteOperationCancelled;
}

test "remote session validates operation metadata" {
    try validateOperationId("OPS-123/remote:1");
    try std.testing.expectError(error.InvalidRemoteOperationId, validateOperationId("bad value"));
    try validateCancelFile("/tmp/hostlift-cancel-OPS-123");
    try std.testing.expectError(error.InvalidRemoteCancelFile, validateCancelFile("relative-cancel"));
    try validateOperationStateFile("/tmp/hostlift-state.jsonl");
    try std.testing.expectError(error.InvalidOperationStatePath, validateOperationStateFile("relative-state"));
}

test "remote session builds control and attempt context" {
    const control_value = try controlWithState("OPS-123/remote:1", "/tmp/hostlift-cancel-OPS-123", "/tmp/hostlift-state.jsonl");
    try std.testing.expectEqualStrings("OPS-123/remote:1", control_value.operation_id.?);
    try std.testing.expectEqualStrings("/tmp/hostlift-cancel-OPS-123", control_value.cancel_file.?);
    try std.testing.expectEqualStrings("/tmp/hostlift-state.jsonl", control_value.operation_state_file.?);

    const attempt = attemptContext(control_value, 1, 3);
    try std.testing.expectEqualStrings("OPS-123/remote:1", attempt.operation_id.?);
    try std.testing.expectEqual(@as(u8, 1), attempt.attempt);
    try std.testing.expectEqual(@as(u8, 3), attempt.retries);
}
