const std = @import("std");
const plan_filter = @import("../plan/filter.zig");
const plan_schema = @import("../plan/schema.zig");

// 输出 apply dry-run 预览，列出过滤后会执行的 action。
pub fn write(
    writer: anytype,
    plan: plan_schema.MigrationPlan,
    filter: plan_filter.ActionFilter,
    selected_action_count: usize,
) !void {
    try writer.writeAll("\nDry-run actions:\n");
    if (selected_action_count == 0) {
        try writer.writeAll("  No actions would be applied.\n");
        return;
    }
    for (plan.actions) |action| {
        if (!filter.matches(action)) continue;
        try writer.print(
            "  - {s} [{s}/{s}] confirm={}: {s}\n",
            .{ action.id, @tagName(action.module), @tagName(action.risk), action.requires_confirmation, action.description },
        );
    }
}
