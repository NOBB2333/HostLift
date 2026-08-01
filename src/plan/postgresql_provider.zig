const std = @import("std");
const schema = @import("schema.zig");
const common = @import("modules/common.zig");
const artifacts = @import("../postgresql/artifacts.zig");

const manual_action_id = "appdata/dump-restore//var/lib/postgresql";

// 将 PostgreSQL 人工恢复项替换为显式、固定语义的五步 provider DAG；不存在源 PostgreSQL 时保持计划不变。
pub fn enable(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(schema.Action),
    source_inventory_hash: [32]u8,
) !void {
    const manual_index = findManualAction(actions.items) orelse return;
    const root = try artifacts.rootForInventoryHash(allocator, source_inventory_hash);
    defer allocator.free(root);

    var generated: std.ArrayList(schema.Action) = .empty;
    defer generated.deinit(allocator);
    errdefer for (generated.items) |action| schema.deinitAction(allocator, action);

    try common.appendAction(allocator, &generated, .{
        .id_prefix = "appdata/postgresql-dump",
        .name = "cluster",
        .subject = root,
        .module = .appdata,
        .action_type = .postgresql_dump,
        .risk = .critical,
        .requires_confirmation = true,
        .description = "Dump the quiesced PostgreSQL cluster into a mode-0600 logical backup; writers-stopped was explicitly acknowledged",
        .phase = .quiesce,
    });
    try common.appendAction(allocator, &generated, .{
        .id_prefix = "appdata/postgresql-target-baseline",
        .name = "cluster",
        .subject = root,
        .module = .appdata,
        .action_type = .postgresql_target_baseline,
        .risk = .critical,
        .requires_confirmation = true,
        .description = "Capture a mode-0600 logical baseline of the empty target PostgreSQL cluster for recovery evidence",
        .phase = .quiesce,
        .depends_on = &.{"appdata/postgresql-dump/cluster"},
    });
    try common.appendAction(allocator, &generated, .{
        .id_prefix = "appdata/postgresql-transfer",
        .name = "cluster",
        .subject = root,
        .module = .appdata,
        .action_type = .postgresql_transfer,
        .risk = .critical,
        .requires_confirmation = true,
        .description = "Transfer the encrypted-transport PostgreSQL dump artifact and compare SHA-256",
        .phase = .transfer,
        .depends_on = &.{"appdata/postgresql-target-baseline/cluster"},
    });
    try common.appendAction(allocator, &generated, .{
        .id_prefix = "appdata/postgresql-restore",
        .name = "cluster",
        .subject = root,
        .module = .appdata,
        .action_type = .postgresql_restore,
        .risk = .critical,
        .requires_confirmation = true,
        .description = "Restore the logical cluster dump into the verified empty target with psql ON_ERROR_STOP",
        .phase = .restore,
        .depends_on = &.{"appdata/postgresql-transfer/cluster"},
    });
    try common.appendAction(allocator, &generated, .{
        .id_prefix = "appdata/postgresql-verify",
        .name = "cluster",
        .subject = root,
        .module = .appdata,
        .action_type = .postgresql_verify,
        .risk = .high,
        .requires_confirmation = true,
        .description = "Compare source and target PostgreSQL database and role catalogs after restore",
        .phase = .verify,
        .depends_on = &.{"appdata/postgresql-restore/cluster"},
    });

    const old = actions.orderedRemove(manual_index);
    schema.deinitAction(allocator, old);
    try actions.appendSlice(allocator, generated.items);
    generated.clearRetainingCapacity();
}

fn findManualAction(actions: []const schema.Action) ?usize {
    for (actions, 0..) |action, index| {
        if (action.action_type == .manual_step and std.mem.eql(u8, action.id, manual_action_id)) return index;
    }
    return null;
}

test "postgresql provider replaces only the matching manual task with a five step dag" {
    var actions: std.ArrayList(schema.Action) = .empty;
    defer {
        for (actions.items) |action| schema.deinitAction(std.testing.allocator, action);
        actions.deinit(std.testing.allocator);
    }
    try common.appendAction(std.testing.allocator, &actions, .{
        .id_prefix = "appdata/dump-restore",
        .name = "/var/lib/postgresql",
        .module = .appdata,
        .action_type = .manual_step,
        .risk = .high,
        .requires_confirmation = true,
        .description = "manual PostgreSQL restore",
    });

    try enable(std.testing.allocator, &actions, [_]u8{0x12} ** 32);
    try std.testing.expectEqual(@as(usize, 5), actions.items.len);
    try std.testing.expectEqual(schema.ActionType.postgresql_dump, actions.items[0].action_type);
    try std.testing.expectEqual(schema.ActionType.postgresql_verify, actions.items[4].action_type);
    try std.testing.expectEqualStrings("appdata/postgresql-restore/cluster", actions.items[4].depends_on.?[0]);
    try artifacts.validateRoot(actions.items[0].subject);
}
