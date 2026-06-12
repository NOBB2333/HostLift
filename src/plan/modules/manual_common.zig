const std = @import("std");
const plan = @import("../schema.zig");
const common = @import("common.zig");

// 人工步骤输入参数结构体，用于构造需人工介入的高风险动作。
pub const ManualStepInput = struct {
    id_prefix: []const u8,
    name: []const u8,
    subject: []const u8,
    module: plan.ModuleName,
    risk: plan.RiskLevel,
    description: []const u8,
};

// 追加一条需要人工处理的高风险动作。
pub fn appendManualStep(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    input: ManualStepInput,
) !void {
    try common.appendAction(allocator, actions, .{
        .id_prefix = input.id_prefix,
        .name = input.name,
        .subject = input.subject,
        .module = input.module,
        .action_type = .manual_step,
        .risk = input.risk,
        .requires_confirmation = true,
        .description = input.description,
    });
}
