const std = @import("std");
const security = @import("../security/validation.zig");
const recipe_schema = @import("schema.zig");

pub const base_root = "/var/lib/hostlift/artifacts/reinstall";
pub const artifact_name = "verified-artifact";

// 用源 inventory hash 和 recipe ID 生成独占的重装 artifact 根目录。
pub fn rootForRecipe(allocator: std.mem.Allocator, inventory_hash: [32]u8, recipe_id: []const u8) ![]u8 {
    try recipe_schema.validateId(recipe_id);
    const hex = std.fmt.bytesToHex(inventory_hash, .lower);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ base_root, &hex, recipe_id });
}

// 校验 artifact 根目录与 plan 的源 inventory hash、recipe ID 完全绑定。
pub fn validateRoot(root: []const u8, inventory_hash: [32]u8, recipe_id: []const u8) !void {
    try security.validatePath(root);
    const expected = try rootForRecipe(std.heap.page_allocator, inventory_hash, recipe_id);
    defer std.heap.page_allocator.free(expected);
    if (!std.mem.eql(u8, root, expected)) return error.ReinstallArtifactBindingMismatch;
}

// 在已绑定的 recipe 根目录下生成下载 artifact 路径。
pub fn artifactPath(allocator: std.mem.Allocator, root: []const u8, inventory_hash: [32]u8, recipe_id: []const u8) ![]u8 {
    try validateRoot(root, inventory_hash, recipe_id);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, artifact_name });
}

test "reinstall artifact root binds source hash and recipe" {
    const root = try rootForRecipe(std.testing.allocator, [_]u8{0xab} ** 32, "tool-v1");
    defer std.testing.allocator.free(root);
    try validateRoot(root, [_]u8{0xab} ** 32, "tool-v1");
    try std.testing.expectError(error.ReinstallArtifactBindingMismatch, validateRoot(root, [_]u8{0xcd} ** 32, "tool-v1"));
}
