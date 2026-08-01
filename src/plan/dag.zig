const std = @import("std");
const schema = @import("schema.zig");

// 为已生成 action 补充可确定的依赖边，保持当前数组顺序同时形成显式 DAG。
pub fn enrich(allocator: std.mem.Allocator, actions: []schema.Action) !void {
    for (actions) |*action| {
        if (dependencyCandidate(actions, action.*)) |dependency_id| {
            try appendDependency(allocator, action, dependency_id);
        }
    }
}

fn dependencyCandidate(actions: []const schema.Action, action: schema.Action) ?[]const u8 {
    const mappings = [_]struct { child: []const u8, parent: []const u8 }{
        .{ .child = "projects/compose-up/", .parent = "projects/copy/" },
        .{ .child = "projects/compose-verify/", .parent = "projects/compose-up/" },
        .{ .child = "services/enable/", .parent = "services/install-unit/" },
        .{ .child = "services/enable-user-unit/", .parent = "services/install-user-unit/" },
        .{ .child = "services/enable-sysv-init/", .parent = "services/install-sysv-init/" },
        .{ .child = "services/enable-openrc/", .parent = "services/install-openrc/" },
        .{ .child = "users/create-user/", .parent = "users/create-group/" },
    };
    for (mappings) |mapping| {
        if (!std.mem.startsWith(u8, action.id, mapping.child)) continue;
        const suffix = action.id[mapping.child.len..];
        for (actions) |candidate| {
            if (!std.mem.startsWith(u8, candidate.id, mapping.parent)) continue;
            if (std.mem.eql(u8, candidate.id[mapping.parent.len..], suffix)) return candidate.id;
        }
    }
    return null;
}

fn appendDependency(allocator: std.mem.Allocator, action: *schema.Action, dependency_id: []const u8) !void {
    const existing = action.depends_on orelse &.{};
    for (existing) |value| {
        if (std.mem.eql(u8, value, dependency_id)) return;
    }
    const result = try allocator.alloc([]const u8, existing.len + 1);
    errdefer allocator.free(result);
    @memcpy(result[0..existing.len], existing);
    result[existing.len] = try allocator.dupe(u8, dependency_id);
    if (action.depends_on) |old| allocator.free(old);
    action.depends_on = result;
}

test "dag enrichment links compose and user lifecycle actions" {
    var actions = [_]schema.Action{
        .{ .id = "projects/copy//srv/app", .module = .projects, .action_type = .copy_project_path, .description = "copy", .risk = .high, .requires_confirmation = true },
        .{ .id = "projects/compose-up//srv/app", .module = .projects, .action_type = .start_compose_project, .description = "start", .risk = .high, .requires_confirmation = true },
        .{ .id = "projects/compose-verify//srv/app", .module = .projects, .action_type = .verify_compose_project, .description = "verify", .risk = .low, .requires_confirmation = false },
    };
    try enrich(std.testing.allocator, &actions);
    defer {
        for (&actions) |action| {
            if (action.depends_on) |dependencies| {
                for (dependencies) |dependency| std.testing.allocator.free(dependency);
                std.testing.allocator.free(dependencies);
            }
        }
    }
    try std.testing.expectEqualStrings("projects/copy//srv/app", actions[1].depends_on.?[0]);
    try std.testing.expectEqualStrings("projects/compose-up//srv/app", actions[2].depends_on.?[0]);
}
