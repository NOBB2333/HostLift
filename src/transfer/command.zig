const std = @import("std");
const remote_planner = @import("../remote/planner.zig");
const remote_preflight = @import("../remote/preflight.zig");
const remote_schema = @import("../remote/schema.zig");
const chunk_transport = @import("../transport/chunk.zig");
const rsync_transport = @import("../transport/rsync.zig");
const scp_transport = @import("../transport/scp.zig");
const json_util = @import("../util/json.zig");
const manifest_flow = @import("manifest_flow.zig");
const transfer_options = @import("options.zig");

// 解析 transfer 子命令，生成 dry-run 计划或在批准后执行传输。
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try transfer_options.parse(args);

    const transfer_source_path = parsed.source_path orelse return error.MissingTransferSource;
    try manifest_flow.validateOptions(parsed);

    const transfer_plan = try remote_planner.buildTransferPlanAdvancedWithLimits(
        parsed.host orelse return error.MissingRemoteHost,
        parsed.source_host,
        transfer_source_path,
        parsed.target_path orelse return error.MissingTransferTarget,
        parsed.preserve_metadata,
        parsed.recursive,
        parsed.transport,
        parsed.partial,
        parsed.resumable,
        parsed.execution,
        parsed.bandwidth_limit_kbps,
    );

    var source_manifest = try manifest_flow.buildSource(io, allocator, parsed, transfer_source_path);
    defer if (source_manifest) |*value| value.deinit(allocator);

    try manifest_flow.writeSourceIfRequested(io, stdout, parsed, source_manifest);

    if (!parsed.approve) {
        try json_util.writeTransferPlan(stdout, transfer_plan);
        return;
    }
    try preflightTransfer(io, allocator, transfer_plan, parsed.execution);
    try executePlan(io, allocator, transfer_plan, stdout, stderr);
    try manifest_flow.verifyRemoteIfRequested(io, allocator, stdout, parsed, transfer_plan, source_manifest);
}

// 在批准执行前检查传输计划的远端依赖。
fn preflightTransfer(
    io: std.Io,
    allocator: std.mem.Allocator,
    transfer_plan: remote_schema.TransferPlan,
    execution_options: @import("../remote/options.zig").ExecutionOptions,
) !void {
    try remote_preflight.runCheck(io, allocator, remote_preflight.transferTargetCheck(transfer_plan), execution_options);
    if (remote_preflight.transferSourceCheck(transfer_plan)) |check| try remote_preflight.runCheck(io, allocator, check, execution_options);
}

// 执行 scp 传输；单文件传输会在成功后做 SHA-256 校验。
pub fn executePlan(
    io: std.Io,
    allocator: std.mem.Allocator,
    transfer_plan: remote_schema.TransferPlan,
    stdout: anytype,
    stderr: anytype,
) !void {
    switch (transfer_plan.transport) {
        .scp => try scp_transport.executePlan(io, allocator, transfer_plan, stdout, stderr),
        .rsync => try rsync_transport.executePlan(io, allocator, transfer_plan, stdout, stderr),
        .chunk => try chunk_transport.executePlan(io, allocator, transfer_plan, stdout, stderr),
    }
}
