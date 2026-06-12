const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");

// 规划项目目录复制，以及 Docker Compose 启动和状态验证动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.ProjectInventory,
    target: inventory.ProjectInventory,
) !void {
    for (source.projects) |project| {
        if (projectPresent(target.projects, project.root)) continue;
        try common.appendAction(allocator, actions, .{
            .id_prefix = "projects/copy",
            .name = project.root,
            .module = .projects,
            .action_type = .copy_project_path,
            .risk = if (project.kind == .docker_compose) .high else .medium,
            .requires_confirmation = true,
            .description = "Copy detected project path after manifest review",
        });
        if (project.kind == .docker_compose) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "projects/compose-up",
                .name = project.root,
                .subject = project.manifest_path,
                .module = .projects,
                .action_type = .start_compose_project,
                .risk = .high,
                .requires_confirmation = true,
                .description = "Start Docker Compose project after copy",
            });
            try common.appendAction(allocator, actions, .{
                .id_prefix = "projects/compose-verify",
                .name = project.root,
                .subject = project.manifest_path,
                .module = .projects,
                .action_type = .verify_compose_project,
                .risk = .low,
                .requires_confirmation = false,
                .description = "Verify Docker Compose project status after startup",
            });
        }
    }
}

// 判断目标清单中指定项目根目录是否存在。
fn projectPresent(projects: []const inventory.ProjectRef, root: []const u8) bool {
    for (projects) |project| {
        if (std.mem.eql(u8, project.root, root)) return true;
    }
    return false;
}
