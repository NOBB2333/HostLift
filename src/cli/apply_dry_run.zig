const std = @import("std");
const apply_executor = @import("../apply/executor.zig");
const plan_filter = @import("../plan/filter.zig");
const plan_schema = @import("../plan/schema.zig");

// 输出 apply dry-run 预览，列出过滤后会执行的 action。
pub fn write(
    writer: anytype,
    plan: plan_schema.MigrationPlan,
    filter: plan_filter.ActionFilter,
    selected_action_count: usize,
    options: apply_executor.Options,
) !void {
    try writer.writeAll("\nDry-run actions:\n");
    try writer.print("  Recursive transfer manifest verify: {s} (max entries: {d})\n", .{
        if (options.transfer_manifest_verify) "enabled" else "disabled",
        options.transfer_manifest_max_entries,
    });
    if (selected_action_count == 0) {
        try writer.writeAll("  No actions would be applied.\n");
        return;
    }
    for (plan.actions) |action| {
        if (!filter.matches(action)) continue;
        try writer.print(
            "  - {s} [{s}/{s}] phase={s} deps={d} confirm={}: {s}\n",
            .{ action.id, @tagName(action.module), @tagName(action.risk), if (action.phase) |phase| @tagName(phase) else "legacy", plan_schema.dependencies(action).len, action.requires_confirmation, action.description },
        );
    }
}

test "apply dry run exposes recursive manifest verification options" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var output: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    const plan = plan_schema.MigrationPlan{
        .schema_version = plan_schema.schema_version_v2,
        .source_inventory_hash = [_]u8{0} ** 32,
        .target_inventory_hash = [_]u8{1} ** 32,
        .compatibility = .{
            .compatible = true,
            .same_distro = true,
            .same_version = true,
            .same_package_manager = true,
            .same_arch = true,
            .reason = "compatible",
        },
        .actions = &.{},
        .created_at = 0,
    };
    try write(&output.writer, plan, .empty, 0, .{
        .transfer_manifest_verify = false,
        .transfer_manifest_max_entries = 4096,
    });
    buffer = output.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "disabled (max entries: 4096)") != null);
}
