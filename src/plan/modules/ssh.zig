const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual_common = @import("manual_common.zig");

// 规划 authorized_keys 复制动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.SshInventory,
    target: inventory.SshInventory,
) !void {
    for (source.authorized_keys) |keys| {
        if (hasAuthorizedKeys(target.authorized_keys, keys.user, keys.path)) continue;
        try common.appendAction(allocator, actions, .{
            .id_prefix = "ssh/authorized-keys",
            .name = keys.user,
            .subject = keys.path,
            .module = .ssh,
            .action_type = .add_authorized_key,
            .risk = .medium,
            .requires_confirmation = true,
            .description = "Append authorized_keys entries for selected user",
        });
    }
    for (source.sshd_config) |fact| {
        if (hasSshdConfigFact(target.sshd_config, fact)) continue;
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "ssh/review-sshd-config",
            .name = fact.key,
            .subject = fact.value,
            .module = .ssh,
            .risk = .high,
            .description = "Review sshd_config authentication or connectivity directive before migration",
        });
    }
}

// 判断目标是否已有指定用户的 authorized_keys 路径。
fn hasAuthorizedKeys(keys_list: []const inventory.AuthorizedKeys, user: []const u8, path: []const u8) bool {
    for (keys_list) |keys| {
        if (std.mem.eql(u8, keys.user, user) and std.mem.eql(u8, keys.path, path)) return true;
    }
    return false;
}

// 判断目标是否已有相同的 sshd_config 指令。
fn hasSshdConfigFact(facts: []const inventory.SshdConfigFact, needle: inventory.SshdConfigFact) bool {
    for (facts) |fact| {
        if (std.ascii.eqlIgnoreCase(fact.key, needle.key) and std.mem.eql(u8, fact.value, needle.value)) return true;
    }
    return false;
}
