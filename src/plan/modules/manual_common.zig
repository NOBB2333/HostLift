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
    task_provider: ?[]const u8 = null,
    task_inputs: []const common.ManualInputSpec = &.{},
    task_secret_refs: []const []const u8 = &.{},
    task_verify_probes: ?[]const common.ManualProbeSpec = null,
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
        .manual_task_spec = .{
            .provider = input.task_provider,
            .inputs = input.task_inputs,
            .secret_refs = input.task_secret_refs,
            .verify_probes = input.task_verify_probes,
        },
    });
}
