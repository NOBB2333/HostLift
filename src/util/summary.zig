const inventory = @import("../inventory/schema.zig");
const inventory_summary = @import("inventory_summary.zig");
const plan = @import("../plan/schema.zig");
const plan_summary = @import("plan_summary.zig");
const plan_validator = @import("../plan/validator.zig");

// 输出主机清单的人类可读摘要。
pub fn writeInventorySummary(writer: anytype, value: inventory.Inventory) !void {
    try inventory_summary.writeInventorySummary(writer, value);
}

// 输出迁移计划的人类可读摘要。
pub fn writePlanSummary(writer: anytype, value: plan.MigrationPlan) !void {
    try plan_summary.writePlanSummary(writer, value);
}

// 输出迁移计划 action 选择清单。
pub fn writePlanSelection(writer: anytype, value: plan.MigrationPlan) !void {
    try plan_summary.writePlanSelection(writer, value);
}

// 输出迁移计划里的迁移后健康检查报告。
pub fn writePlanHealthReport(writer: anytype, value: plan.MigrationPlan) !void {
    try plan_summary.writePlanHealthReport(writer, value);
}

// 输出迁移计划校验结果的人类可读摘要。
pub fn writePlanValidationSummary(writer: anytype, value: plan_validator.ValidationReport) !void {
    try plan_summary.writePlanValidationSummary(writer, value);
}
