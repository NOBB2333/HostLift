const std = @import("std");
const operation_state = @import("operation_state.zig");
const remote_options = @import("options.zig");
const session = @import("session.zig");

// 带重试执行远程子进程，并把 stdout/stderr 透传给调用方。
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

// 带取消标记检查执行远程子进程；每次尝试前都会检查本地 cancel file。
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
    try runWithSession(io, allocator, argv, timeout_seconds, retries, try session.control(null, cancel_file), stdout, stderr);
}

// 按远程 session control 执行子进程；每次尝试前都会检查取消标记。
pub fn runWithSession(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_seconds: u32,
    retries: u8,
    control: session.Control,
    stdout: anytype,
    stderr: anytype,
) !void {
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        session.checkCancelled(io, control) catch |err| {
            try appendState(io, control, .command, attempt + 1, retries, .cancelled, err);
            return err;
        };
        try appendState(io, control, .command, attempt + 1, retries, .started, null);
        runOnce(io, allocator, argv, timeout_seconds, stdout, stderr) catch |err| {
            try appendState(io, control, .command, attempt + 1, retries, .failed, err);
            if (attempt >= retries) return err;
            try writeRetry(stderr, "remote command", session.attemptContext(control, attempt + 1, retries), err);
            continue;
        };
        try appendState(io, control, .command, attempt + 1, retries, .succeeded, null);
        return;
    }
}

// 运行短命令并返回退出码，stdout/stderr 只用于状态判断。
pub fn runForExitCode(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_seconds: u32,
) !u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = remote_options.ioTimeout(timeout_seconds),
    }) catch |err| switch (err) {
        error.Timeout => return error.RemoteCommandTimedOut,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code,
        else => error.RemoteCommandFailed,
    };
}

// 运行短命令并返回 stdout；调用方负责释放返回的 buffer。
pub fn runForOutput(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_seconds: u32,
    stdout_limit: usize,
) ![]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = remote_options.ioTimeout(timeout_seconds),
    }) catch |err| switch (err) {
        error.Timeout => return error.RemoteCommandTimedOut,
        else => return err,
    };
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.RemoteCommandFailed,
        else => return error.RemoteCommandFailed,
    }
    return result.stdout;
}

// 执行单次远程子进程，透传 stdout/stderr 给调用方。
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
        error.Timeout => return error.RemoteCommandTimedOut,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try stdout.writeAll(result.stdout);
    try stderr.writeAll(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.RemoteCommandFailed,
        else => return error.RemoteCommandFailed,
    }
}

// 向 stderr 输出重试上下文信息。
fn writeRetry(stderr: anytype, label: []const u8, attempt: session.Attempt, err: anyerror) !void {
    if (attempt.operation_id) |operation_id| {
        try stderr.print("{s} retry {d}/{d} [{s}]: {s}\n", .{ label, attempt.attempt, attempt.retries, operation_id, @errorName(err) });
        return;
    }
    try stderr.print("{s} retry {d}/{d}: {s}\n", .{ label, attempt.attempt, attempt.retries, @errorName(err) });
}

// 追加操作状态事件到状态文件。
fn appendState(
    io: std.Io,
    control: session.Control,
    kind: operation_state.OperationKind,
    attempt: u8,
    retries: u8,
    status: operation_state.Status,
    err: ?anyerror,
) !void {
    try operation_state.appendEvent(io, control.operation_state_file, .{
        .operation_id = control.operation_id,
        .kind = kind,
        .attempt = attempt,
        .retries = retries,
        .status = status,
        .error_name = if (err) |value| @errorName(value) else null,
    });
}

test "remote runner retry message includes operation id when present" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    const control = try session.control("OPS-123/remote", null);

    try writeRetry(&writer.writer, "remote command", session.attemptContext(control, 1, 3), error.RemoteCommandFailed);
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "[OPS-123/remote]") != null);
}
