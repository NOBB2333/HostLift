const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const manual_common = @import("manual_common.zig");

// 规划扩展 ACL 存在性差异的人工审查动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.AclInventory,
    target: inventory.AclInventory,
) !void {
    if (source.getfacl_available and !target.getfacl_available) {
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "acl/review-tooling",
            .name = "getfacl-missing",
            .subject = "getfacl",
            .module = .acl,
            .risk = .high,
            .description = "Install or verify ACL tooling on target before migrating paths with extended ACLs",
        });
    }
    for (source.paths) |path| {
        if (!path.present or !path.has_extended_acl) continue;
        const target_path = findAclPath(target.paths, path.path);
        if (target_path) |existing| {
            if (existing.present and existing.has_extended_acl) continue;
        }
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "acl/review",
            .name = path.path,
            .subject = path.path,
            .module = .acl,
            .risk = .high,
            .description = "Review extended POSIX ACL before manual migration; HostLift does not serialize ACL entries",
        });
    }
}

// 查找指定 ACL 路径。
fn findAclPath(paths: []const inventory.AclPath, path: []const u8) ?inventory.AclPath {
    for (paths) |candidate| {
        if (std.mem.eql(u8, candidate.path, path)) return candidate;
    }
    return null;
}
