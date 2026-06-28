const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual_common = @import("manual_common.zig");

// 规划防火墙持久化配置复制动作；backend 不匹配时不自动迁移。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.FirewallInventory,
    target: inventory.FirewallInventory,
) !void {
    if (source.backend == .unknown) return;
    if (source.backend != target.backend) {
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "firewall/review-backend",
            .name = @tagName(source.backend),
            .subject = @tagName(target.backend),
            .module = .firewall,
            .risk = .high,
            .description = "Review firewall backend mismatch before migration; verify SSH and business ports manually because HostLift does not rewrite firewall stacks automatically",
        });
        return;
    }
    for (source.configs) |config| {
        if (!config.present) continue;
        if (firewallConfigPresent(target.configs, config.path)) continue;
        try common.appendAction(allocator, actions, .{
            .id_prefix = "firewall/apply-config",
            .name = config.path,
            .module = .firewall,
            .action_type = .apply_firewall_config,
            .risk = .high,
            .requires_confirmation = true,
            .description = "Copy selected firewall config after SSH lockout review",
        });
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "firewall/check-connectivity",
            .name = config.path,
            .subject = config.path,
            .module = .firewall,
            .risk = .high,
            .description = "Verify SSH and migrated business ports after firewall config review; keep an out-of-band recovery path before reload",
        });
    }
}

// 判断目标清单中指定防火墙配置是否存在。
fn firewallConfigPresent(configs: []const inventory.FirewallConfig, needle: []const u8) bool {
    for (configs) |config| {
        if (config.present and std.mem.eql(u8, config.path, needle)) return true;
    }
    return false;
}
