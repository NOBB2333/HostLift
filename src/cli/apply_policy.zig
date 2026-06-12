const std = @import("std");
const action_policy = @import("../policy/action.zig");
const plan_schema = @import("../plan/schema.zig");
const policy_source = @import("../policy/source.zig");

// 输出 apply/dry-run 统一的 policy 评估摘要。
pub fn writeReport(writer: anytype, report: action_policy.Report) !void {
    try writer.print(
        "Policy: valid={} checked={} allowed={} denied={} approval_ticket_required={} approval_ticket_present={} approval_ticket_allowed={} approval_scope_allowed={} plan_hash_allowed={} target_host_allowed={} operator_allowed={}\n",
        .{
            report.valid,
            report.checked_actions,
            report.allowed_actions,
            report.denied_actions,
            report.requires_approval_ticket,
            report.approval_ticket_present,
            report.approval_ticket_allowed,
            report.approval_scope_allowed,
            report.plan_hash_allowed,
            report.target_host_allowed,
            report.operator_allowed,
        },
    );
}

// 对 dry-run 迁移计划执行 policy 检查。
pub fn evaluateDryRun(
    io: std.Io,
    allocator: std.mem.Allocator,
    plan: plan_schema.MigrationPlan,
    plan_hash: []const u8,
    policy_path: ?[]const u8,
    writer: anytype,
) !void {
    const path = policy_path orelse return;
    var policy = try policy_source.readWithHash(io, allocator, path);
    defer policy.deinit(allocator);
    const report = action_policy.evaluatePlanWithContext(plan, policy.value(), .{ .plan_hash = plan_hash });
    try writeReport(writer, report);
    if (!report.valid) return error.PolicyDeniedMigrationPlan;
}

// 对 approved apply 执行 policy 检查并返回可写入审计的 policy hash。
pub fn evaluateApproved(
    io: std.Io,
    allocator: std.mem.Allocator,
    plan: plan_schema.MigrationPlan,
    plan_hash: []const u8,
    policy_path: ?[]const u8,
    target_host: []const u8,
    approval_ticket: ?[]const u8,
    operator: []const u8,
    writer: anytype,
) !?[]const u8 {
    const path = policy_path orelse return null;
    var policy = try policy_source.readWithHash(io, allocator, path);
    defer policy.deinit(allocator);
    const policy_hash = try allocator.dupe(u8, policy.hash);
    errdefer allocator.free(policy_hash);
    const report = action_policy.evaluatePlanForApply(plan, policy.value(), plan_hash, target_host, approval_ticket, operator);
    try writeReport(writer, report);
    if (!report.valid) return error.PolicyDeniedMigrationPlan;
    return policy_hash;
}
