const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const acl_review = @import("acl_review.zig");
const container_review = @import("container_review.zig");
const security_policy_review = @import("security_policy_review.zig");
const storage_review = @import("storage_review.zig");
const sudoers_review = @import("sudoers_review.zig");

// 为高风险 scan-only 模块生成人工审查动作，不生成自动 apply 动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.ModuleInventory,
    target: inventory.ModuleInventory,
) !void {
    try appendSudoersReviewActions(allocator, actions, source.sudoers, target.sudoers);
    try appendAclReviewActions(allocator, actions, source.acl, target.acl);
    try appendSecurityPolicyReviewActions(allocator, actions, source.security_policy, target.security_policy);
    try appendStorageReviewActions(allocator, actions, source.storage, target.storage);
    try appendContainerReviewActions(allocator, actions, source.docker, target.docker);
}

// 规划 sudoers 元数据差异的人工审查动作。
pub fn appendSudoersReviewActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.SudoersInventory,
    target: inventory.SudoersInventory,
) !void {
    try sudoers_review.appendActions(allocator, actions, source, target);
}

// 规划扩展 ACL 存在性差异的人工审查动作。
pub fn appendAclReviewActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.AclInventory,
    target: inventory.AclInventory,
) !void {
    try acl_review.appendActions(allocator, actions, source, target);
}

// 规划 SELinux/AppArmor 状态差异的人工审查动作。
pub fn appendSecurityPolicyReviewActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.SecurityPolicyInventory,
    target: inventory.SecurityPolicyInventory,
) !void {
    try security_policy_review.appendActions(allocator, actions, source, target);
}

// 规划 fstab 和挂载点事实差异的人工审查动作。
pub fn appendStorageReviewActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.StorageInventory,
    target: inventory.StorageInventory,
) !void {
    try storage_review.appendActions(allocator, actions, source, target);
}

// 规划容器运行时、volume、network 和 Compose 文件的人工审查动作。
pub fn appendContainerReviewActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.DockerInventory,
    target: inventory.DockerInventory,
) !void {
    try container_review.appendActions(allocator, actions, source, target);
}

test "manual review rules create high-risk actions without sensitive bodies" {
    var sudoers_entries = [_]inventory.SudoersEntry{.{
        .path = "/etc/sudoers.d/deploy",
        .present = true,
        .kind = .file,
        .size = 24,
        .mode = 440,
        .meaningful_lines = 1,
    }};
    var acl_paths = [_]inventory.AclPath{.{
        .path = "/srv/app",
        .present = true,
        .directory = true,
        .has_extended_acl = true,
    }};
    var fstab_entries = [_]inventory.FstabEntry{.{
        .device = "UUID=data",
        .mount_point = "/data",
        .fs_type = "xfs",
        .options = "defaults",
    }};
    var runtimes = [_]inventory.ContainerRuntime{.{ .kind = .docker, .available = true }};
    var volumes = [_]inventory.ContainerVolume{.{ .name = "app-data", .driver = "local", .scope = "local" }};
    var networks = [_]inventory.ContainerNetwork{.{ .name = "app-net", .driver = "bridge", .scope = "local" }};
    var compose_files = [_]inventory.ComposeFile{.{ .project_root = "/srv/app", .path = "/srv/app/compose.yml" }};
    var containers = [_]inventory.DockerContainer{.{
        .name = "app",
        .image = "example/app:1",
        .status = "Up",
        .ports = "8080/tcp",
    }};

    var source_modules = inventory.emptyModules();
    source_modules.sudoers = .{ .entries = sudoers_entries[0..], .truncated = false };
    source_modules.acl = .{ .getfacl_available = true, .paths = acl_paths[0..], .truncated = false };
    source_modules.security_policy = .{ .selinux = .{ .present = true, .status = .enforcing, .config_present = true, .policy_dirs = 2 } };
    source_modules.storage = .{ .fstab_entries = fstab_entries[0..], .mounts = &.{}, .truncated = false };
    source_modules.docker = .{
        .runtimes = runtimes[0..],
        .containers = containers[0..],
        .volumes = volumes[0..],
        .networks = networks[0..],
        .compose_files = compose_files[0..],
        .truncated = false,
    };

    var actions: std.ArrayList(plan.Action) = .empty;
    defer {
        for (actions.items) |action| {
            std.testing.allocator.free(action.id);
            std.testing.allocator.free(action.subject);
            std.testing.allocator.free(action.description);
        }
        actions.deinit(std.testing.allocator);
    }

    try appendActions(std.testing.allocator, &actions, source_modules, inventory.emptyModules());

    try std.testing.expect(hasAction(actions.items, "sudoers/review//etc/sudoers.d/deploy"));
    try std.testing.expect(hasAction(actions.items, "acl/review//srv/app"));
    try std.testing.expect(hasAction(actions.items, "security-policy/review-selinux/selinux"));
    try std.testing.expect(hasAction(actions.items, "storage/review-fstab//data"));
    try std.testing.expect(hasAction(actions.items, "docker/review-runtime/docker"));
    try std.testing.expect(hasAction(actions.items, "docker/review-volume/app-data"));
    try std.testing.expect(hasAction(actions.items, "docker/review-network/app-net"));
    try std.testing.expect(hasAction(actions.items, "docker/review-compose//srv/app"));
    try std.testing.expect(hasAction(actions.items, "docker/review-container/app"));
    for (actions.items) |action| {
        try std.testing.expectEqual(plan.ActionType.manual_step, action.action_type);
        try std.testing.expect(action.requires_confirmation);
        try std.testing.expect(action.risk == .high or action.risk == .critical);
        try std.testing.expect(std.mem.indexOf(u8, action.description, "ALL=(") == null);
    }
}

// 测试辅助：判断 action id 是否存在。
fn hasAction(actions: []const plan.Action, id: []const u8) bool {
    for (actions) |action| {
        if (std.mem.eql(u8, action.id, id)) return true;
    }
    return false;
}
