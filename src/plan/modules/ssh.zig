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
    for (source.host_keys) |host_key| {
        if (hasEquivalentHostKey(target.host_keys, host_key)) continue;
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "ssh/review-host-key",
            .name = host_key.key_type,
            .subject = host_key.public_path,
            .module = .ssh,
            .risk = .critical,
            .description = "Choose SSH host identity policy: keep target key, copy source key, or only record source fingerprint; copying avoids client warnings but moves host identity",
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

// 判断目标是否已有相同类型且同指纹的 SSH host key。
fn hasEquivalentHostKey(facts: []const inventory.SshHostKeyFact, needle: inventory.SshHostKeyFact) bool {
    for (facts) |fact| {
        if (!std.mem.eql(u8, fact.key_type, needle.key_type)) continue;
        if (needle.fingerprint == null and fact.fingerprint == null) return fact.private_present == needle.private_present and fact.public_present == needle.public_present;
        if (needle.fingerprint == null or fact.fingerprint == null) return false;
        return std.mem.eql(u8, fact.fingerprint.?, needle.fingerprint.?);
    }
    return false;
}

test "ssh plan reviews changed host key identity" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer {
        for (actions.items) |action| plan.deinitAction(std.testing.allocator, action);
        actions.deinit(std.testing.allocator);
    }

    var source_keys = [_]inventory.SshHostKeyFact{.{
        .key_type = "ed25519",
        .private_path = "/etc/ssh/ssh_host_ed25519_key",
        .public_path = "/etc/ssh/ssh_host_ed25519_key.pub",
        .private_present = true,
        .public_present = true,
        .fingerprint = "SHA256:source",
    }};
    var target_keys = [_]inventory.SshHostKeyFact{.{
        .key_type = "ed25519",
        .private_path = "/etc/ssh/ssh_host_ed25519_key",
        .public_path = "/etc/ssh/ssh_host_ed25519_key.pub",
        .private_present = true,
        .public_present = true,
        .fingerprint = "SHA256:target",
    }};

    try appendActions(std.testing.allocator, &actions, .{
        .authorized_keys = &.{},
        .sshd_config_present = false,
        .client_config_present = false,
        .host_keys = source_keys[0..],
    }, .{
        .authorized_keys = &.{},
        .sshd_config_present = false,
        .client_config_present = false,
        .host_keys = target_keys[0..],
    });

    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    try std.testing.expectEqualStrings("ssh/review-host-key/ed25519", actions.items[0].id);
    try std.testing.expectEqual(plan.RiskLevel.critical, actions.items[0].risk);
}
