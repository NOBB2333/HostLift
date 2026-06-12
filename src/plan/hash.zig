const std = @import("std");
const inventory = @import("../inventory/schema.zig");

// 对 inventory JSON 表示计算 SHA-256，作为计划输入指纹。
pub fn inventoryHash(allocator: std.mem.Allocator, value: inventory.Inventory) ![32]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    var allocating_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &bytes);
    try std.json.Stringify.value(value, .{}, &allocating_writer.writer);
    bytes = allocating_writer.toArrayList();

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes.items, &hash, .{});
    return hash;
}

test "inventory hash changes when inventory changes" {
    const first = fixture("source");
    const second = fixture("target");

    const first_hash = try inventoryHash(std.testing.allocator, first);
    const second_hash = try inventoryHash(std.testing.allocator, second);

    try std.testing.expect(!std.mem.eql(u8, first_hash[0..], second_hash[0..]));
}

// 测试辅助：构造最小 inventory，用于验证输入指纹稳定性。
fn fixture(hostname: []const u8) inventory.Inventory {
    return .{
        .schema_version = inventory.schema_version,
        .host = .{
            .hostname = hostname,
            .machine_id_hash = null,
            .kernel_release = "test",
            .arch = .x86_64,
        },
        .distro = .{
            .id = "ubuntu",
            .id_like = &.{},
            .version_id = "24.04",
            .pretty_name = "Ubuntu 24.04 LTS",
        },
        .package_manager = .{
            .kind = .apt,
            .version = "apt test",
            .repos = &.{},
        },
        .modules = inventory.emptyModules(),
        .scan = .{
            .scanned_at_unix = 0,
            .warnings = &.{},
        },
    };
}
