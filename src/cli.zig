const std = @import("std");
const audit_command = @import("cli/audit.zig");
const apply_command = @import("cli/apply.zig");
const evidence_command = @import("cli/evidence.zig");
const help_command = @import("cli/help.zig");
const scan_command = @import("cli/scan.zig");
const manifest_command = @import("cli/manifest.zig");
const plan_command = @import("cli/plan.zig");
const validate_command = @import("cli/validate.zig");
const remote_command = @import("cli/remote.zig");
const rollback_command = @import("rollback/command.zig");
const transfer_command = @import("transfer/command.zig");

const version = "0.1.0";

// CLI 运行包装：把预期错误转成稳定的用户错误输出，并用非零码退出。
pub fn runReportingErrors(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) void {
    runWithArgs(io, allocator, args, stdout, stderr) catch |err| {
        reportError(stderr, err) catch {};
        stderr.flush() catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };
}

// 输出统一的 CLI 错误格式。
pub fn reportError(stderr: anytype, err: anyerror) !void {
    try stderr.print("error: {s}\n", .{@errorName(err)});
}

// CLI 总入口：解析一级子命令，并分发到对应处理函数。
pub fn runWithArgs(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len <= 1) {
        try help_command.print(stdout);
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        try help_command.print(stdout);
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        try stdout.print("hostlift {s}\n", .{version});
    } else if (std.mem.eql(u8, command, "scan")) {
        try scan_command.run(io, allocator, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "manifest")) {
        try manifest_command.run(io, allocator, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "plan")) {
        try plan_command.run(io, allocator, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "validate")) {
        try validate_command.run(io, allocator, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "apply")) {
        try apply_command.run(io, allocator, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "evidence")) {
        try evidence_command.run(io, allocator, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "audit")) {
        try audit_command.run(io, allocator, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "rollback")) {
        try rollback_command.run(io, allocator, args[2..], stdout, stderr);
    } else if (std.mem.eql(u8, command, "remote")) {
        try remote_command.run(io, allocator, args[2..], stdout, stderr);
    } else if (std.mem.eql(u8, command, "transfer")) {
        try transfer_command.run(io, allocator, args[2..], stdout, stderr);
    } else {
        try stderr.print("unknown command: {s}\n\n", .{command});
        try help_command.print(stderr);
        std.process.exit(2);
    }
}

test "version command writes version" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    try buffer.print(std.testing.allocator, "hostlift {s}\n", .{version});
    try std.testing.expectEqualStrings("hostlift 0.1.0\n", buffer.items);
}

test "reportError writes stable user-facing error" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);

    try reportError(&writer.writer, error.UnsupportedAuditSink);
    buffer = writer.toArrayList();
    try std.testing.expectEqualStrings("error: UnsupportedAuditSink\n", buffer.items);
}
