const std = @import("std");
const audit_replay = @import("../audit/replay.zig");
const audit_sink_target = @import("../audit/sink_target.zig");
const audit_verify = @import("../audit/verify.zig");
const fs_util = @import("../util/fs.zig");

// 处理 audit 子命令，支持校验和重放本地 JSONL 审计链。
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    if (args.len == 0) return error.MissingAuditCommand;
    const command = args[0];
    if (std.mem.eql(u8, command, "verify")) {
        try runVerify(io, allocator, args[1..], writer);
    } else if (std.mem.eql(u8, command, "replay")) {
        try runReplay(io, allocator, args[1..], writer);
    } else {
        return error.UnknownAuditCommand;
    }
}

// 执行 audit verify 子命令，校验 JSONL 审计链完整性。
fn runVerify(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var log_path: ?[]const u8 = null;
    var summary = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--log")) {
            index += 1;
            if (index >= args.len) return error.MissingAuditLogPath;
            log_path = args[index];
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else {
            return error.UnknownAuditVerifyArgument;
        }
    }

    const file_path = log_path orelse return error.MissingAuditLogPath;
    const bytes = try fs_util.readFileAlloc(io, allocator, file_path, 16 * 1024 * 1024);
    defer allocator.free(bytes);

    const report = try audit_verify.verifyJsonl(allocator, bytes);
    defer report.deinit(allocator);
    if (summary) {
        try writer.print(
            "HostLift audit verification\nValid: {}\nEvents: {d}\nErrors: {d}\nTail hash: {?s}\n",
            .{ report.valid, report.events, report.errors, report.tail_hash },
        );
    } else {
        try std.json.Stringify.value(report, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = true,
        }, writer);
        try writer.writeByte('\n');
    }

    if (!report.valid) return error.InvalidAuditLog;
}

// 执行 audit replay 子命令，重放审计日志到指定 sink。
fn runReplay(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var log_path: ?[]const u8 = null;
    var sink_value: ?[]const u8 = null;
    var summary = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--log")) {
            index += 1;
            if (index >= args.len) return error.MissingAuditLogPath;
            log_path = args[index];
        } else if (std.mem.eql(u8, arg, "--audit-sink")) {
            index += 1;
            if (index >= args.len) return error.MissingAuditSink;
            sink_value = args[index];
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else {
            return error.UnknownAuditReplayArgument;
        }
    }

    const file_path = log_path orelse return error.MissingAuditLogPath;
    const target = try audit_sink_target.parse(sink_value orelse return error.MissingAuditSink);
    if (target == .file and std.mem.eql(u8, target.file, file_path)) return error.AuditReplayWouldOverwriteSource;

    const bytes = try fs_util.readFileAlloc(io, allocator, file_path, 16 * 1024 * 1024);
    defer allocator.free(bytes);

    var file_buffer: [4096]u8 = undefined;
    const report = try audit_replay.replayJsonl(io, allocator, bytes, target, &file_buffer);
    defer report.deinit(allocator);
    if (summary) {
        try writer.print(
            "HostLift audit replay\nValid: {}\nEvents: {d}\nReplayed: {d}\nTail hash: {?s}\n",
            .{ report.valid, report.events, report.replayed, report.tail_hash },
        );
    } else {
        try std.json.Stringify.value(report, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = true,
        }, writer);
        try writer.writeByte('\n');
    }
}
