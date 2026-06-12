const std = @import("std");
const action_policy = @import("action.zig");
const manifest_hash = @import("../manifest/hash.zig");
const fs_util = @import("../util/fs.zig");

pub const max_policy_bytes = 1024 * 1024;

// 策略文件解析结果，持有规则集和原始文件 SHA-256。
pub const Parsed = struct {
    parsed: std.json.Parsed(action_policy.RuleSet),
    hash: []const u8,

    // 释放解析后的 policy 和原始文件 hash。
    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.hash);
    }

    // 返回解析后的策略值。
    pub fn value(self: Parsed) action_policy.RuleSet {
        return self.parsed.value;
    }
};

// 从 JSON bytes 解析 action policy，同时计算原始内容 SHA-256。
pub fn parseBytesWithHash(allocator: std.mem.Allocator, bytes: []const u8) !Parsed {
    const policy_hash = try manifest_hash.sha256BytesHexAlloc(allocator, bytes);
    errdefer allocator.free(policy_hash);
    return .{
        .parsed = try action_policy.parseFromSlice(allocator, bytes),
        .hash = policy_hash,
    };
}

// 读取并解析 action policy JSON，同时返回原始策略文件 SHA-256。
pub fn readWithHash(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Parsed {
    const policy_bytes = try fs_util.readFileAlloc(io, allocator, path, max_policy_bytes);
    defer allocator.free(policy_bytes);
    return parseBytesWithHash(allocator, policy_bytes);
}

test "parseBytesWithHash returns parsed policy and raw content hash" {
    const bytes =
        \\{
        \\  "schema_version": "hostlift.policy.v1",
        \\  "default": "deny",
        \\  "allow_hosts": ["root@192.0.2.10"]
        \\}
    ;

    var parsed = try parseBytesWithHash(std.testing.allocator, bytes);
    defer parsed.deinit(std.testing.allocator);
    const expected_hash = try manifest_hash.sha256BytesHexAlloc(std.testing.allocator, bytes);
    defer std.testing.allocator.free(expected_hash);

    try std.testing.expectEqual(action_policy.Decision.deny, parsed.value().default);
    try std.testing.expectEqualStrings("root@192.0.2.10", parsed.value().allow_hosts[0]);
    try std.testing.expectEqualStrings(expected_hash, parsed.hash);
}
