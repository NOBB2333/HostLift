const std = @import("std");
const operation_state = @import("../remote/operation_state.zig");
const remote_options = @import("../remote/options.zig");
const remote_session = @import("../remote/session.zig");

// 执行传输子进程，并按传输计划的 timeout/retry 控制失败重试。
pub fn runWithRetries(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_seconds: u32,
    retries: u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    try runWithSession(io, allocator, argv, timeout_seconds, retries, .{}, stdout, stderr);
}

// 执行可取消的传输子进程；每次尝试前检查本地 cancel file。
pub fn runWithRetriesCancellable(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_seconds: u32,
    retries: u8,
    cancel_file: ?[]const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    try runWithSession(io, allocator, argv, timeout_seconds, retries, try remote_session.control(null, cancel_file), stdout, stderr);
}

// 按远程 session control 执行传输子进程；每次尝试前检查本地 cancel file。
pub fn runWithSession(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_seconds: u32,
    retries: u8,
    control: remote_session.Control,
    stdout: anytype,
    stderr: anytype,
) !void {
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        remote_session.checkCancelled(io, control) catch |err| {
            try appendState(io, control, attempt + 1, retries, .cancelled, err);
            return err;
        };
        try appendState(io, control, attempt + 1, retries, .started, null);
        runOnce(io, allocator, argv, timeout_seconds, stdout, stderr) catch |err| {
            try appendState(io, control, attempt + 1, retries, .failed, err);
            if (attempt >= retries) return err;
            try writeRetry(stderr, remote_session.attemptContext(control, attempt + 1, retries), err);
            continue;
        };
        try appendState(io, control, attempt + 1, retries, .succeeded, null);
        return;
    }
}

// 启动单次传输子进程，超时或非零退出码时返回错误。
fn runOnce(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_seconds: u32,
    stdout: anytype,
    stderr: anytype,
) !void {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = remote_options.ioTimeout(timeout_seconds),
    }) catch |err| switch (err) {
        error.Timeout => return error.RemoteTransferTimedOut,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try stdout.writeAll(result.stdout);
    try stderr.writeAll(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.RemoteTransferFailed,
        else => return error.RemoteTransferFailed,
    }
}

// 将重试信息写入 stderr，含 operation id 和错误名称。
fn writeRetry(stderr: anytype, attempt: remote_session.Attempt, err: anyerror) !void {
    if (attempt.operation_id) |operation_id| {
        try stderr.print("remote transfer retry {d}/{d} [{s}]: {s}\n", .{ attempt.attempt, attempt.retries, operation_id, @errorName(err) });
        return;
    }
    try stderr.print("remote transfer retry {d}/{d}: {s}\n", .{ attempt.attempt, attempt.retries, @errorName(err) });
}

// 将传输尝试状态追加到 operation state 文件。
fn appendState(
    io: std.Io,
    control: remote_session.Control,
    attempt: u8,
    retries: u8,
    status: operation_state.Status,
    err: ?anyerror,
) !void {
    try operation_state.appendEvent(io, control.operation_state_file, .{
        .operation_id = control.operation_id,
        .kind = .transfer,
        .attempt = attempt,
        .retries = retries,
        .status = status,
        .error_name = if (err) |value| @errorName(value) else null,
    });
}

test "transport runner retry message includes operation id when present" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    const control = try remote_session.control("OPS-123/transfer", null);

    try writeRetry(&writer.writer, remote_session.attemptContext(control, 2, 3), error.RemoteTransferFailed);
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "[OPS-123/transfer]") != null);
}
