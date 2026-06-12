const combined_sink = @import("combined_sink.zig");
const file_sink = @import("file_sink.zig");
const http_sink = @import("http_sink.zig");
const sink_plan = @import("sink_plan.zig");
const sink_target = @import("sink_target.zig");
const syslog_sink = @import("syslog_sink.zig");
const writer_sink = @import("writer_sink.zig");

pub const TargetKind = sink_target.TargetKind;
pub const Target = sink_target.Target;
pub const SinkPlanKind = sink_plan.PlanKind;
pub const SinkPlan = sink_plan.Plan;
pub const SinkSelection = sink_plan.Selection;
pub const FileSink = file_sink.FileSink;
pub const HttpSink = http_sink.HttpSink;
pub const WriterSink = writer_sink.WriterSink;
pub const SyslogSink = syslog_sink.SyslogSink;
pub const OpenedSink = combined_sink.Opened;
pub const OpenResult = combined_sink.OpenResult;

// 解析审计 sink 目标；当前只有 file 目标可执行，集中 sink 先只做安全校验。
pub fn parseTarget(value: []const u8) !Target {
    return sink_target.parse(value);
}

// 校验 HTTPS 审计端点；当前不联网，只固定后续 HTTP sink 的输入边界。
pub fn validateHttpsEndpoint(value: []const u8) !void {
    return sink_target.validateHttpsEndpoint(value);
}

// 校验 syslog facility 名称；后续 syslog adapter 会复用同一边界。
pub fn validateSyslogFacility(value: []const u8) !void {
    return sink_target.validateSyslogFacility(value);
}

// 把审计 sink target 转成执行计划；集中 sink 当前保留契约但不执行。
pub fn planTarget(target: Target) SinkPlan {
    return sink_plan.planTarget(target);
}

// 选择 approved 执行时使用的本地审计文件路径。
pub fn selectFilePath(allocator: @import("std").mem.Allocator, explicit_log_path: ?[]const u8, target: ?Target, fallback_timestamp: i64) !SinkSelection {
    return sink_plan.selectFilePath(allocator, explicit_log_path, target, fallback_timestamp);
}

// 打开 approved 执行使用的审计 sink。
pub fn openSink(io: @import("std").Io, allocator: @import("std").mem.Allocator, explicit_log_path: ?[]const u8, target: ?Target, fallback_timestamp: i64, file_buffer: []u8) !OpenResult {
    return combined_sink.open(io, allocator, explicit_log_path, target, fallback_timestamp, file_buffer);
}

// 打开 approved 执行使用的审计 sink，并可选双写本地镜像日志。
pub fn openSinkWithMirror(io: @import("std").Io, allocator: @import("std").mem.Allocator, explicit_log_path: ?[]const u8, target: ?Target, mirror_log_path: ?[]const u8, fallback_timestamp: i64, file_buffer: []u8, mirror_buffer: ?[]u8) !OpenResult {
    return combined_sink.openWithMirror(io, allocator, explicit_log_path, target, mirror_log_path, fallback_timestamp, file_buffer, mirror_buffer);
}
