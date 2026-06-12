const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const manual_common = @import("manual_common.zig");

// 规划 SELinux/AppArmor 状态差异的人工审查动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.SecurityPolicyInventory,
    target: inventory.SecurityPolicyInventory,
) !void {
    if (selinuxDiffers(source.selinux, target.selinux)) {
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "security-policy/review-selinux",
            .name = "selinux",
            .subject = "SELinux",
            .module = .security_policy,
            .risk = .critical,
            .description = "Review SELinux status and policy directories before manual migration; HostLift does not copy policy bodies",
        });
    }
    if (apparmorDiffers(source.apparmor, target.apparmor)) {
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "security-policy/review-apparmor",
            .name = "apparmor",
            .subject = "AppArmor",
            .module = .security_policy,
            .risk = .critical,
            .description = "Review AppArmor status and profiles before manual migration; HostLift does not copy policy bodies",
        });
    }
}

// 判断 SELinux 元数据是否变化。
fn selinuxDiffers(source: inventory.SelinuxInventory, target: inventory.SelinuxInventory) bool {
    return source.present != target.present or
        source.status != target.status or
        source.config_present != target.config_present or
        source.policy_dirs != target.policy_dirs;
}

// 判断 AppArmor 元数据是否变化。
fn apparmorDiffers(source: inventory.AppArmorInventory, target: inventory.AppArmorInventory) bool {
    return source.present != target.present or
        source.status != target.status or
        source.profiles_loaded != target.profiles_loaded or
        source.config_dirs != target.config_dirs;
}
