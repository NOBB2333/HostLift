const std = @import("std");
const validation = @import("../security/validation.zig");

pub const base_root = "/var/lib/hostlift/artifacts/postgresql";
pub const source_dump_name = "source-cluster.sql";
pub const target_baseline_name = "target-baseline.sql";

// 用源 inventory hash 生成单次 PostgreSQL provider 的独占 artifact 根目录。
pub fn rootForInventoryHash(allocator: std.mem.Allocator, inventory_hash: [32]u8) ![]u8 {
    const hex = std.fmt.bytesToHex(inventory_hash, .lower);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_root, &hex });
}

// 校验 plan 中的 artifact 根目录属于 HostLift 固定前缀且末段是 64 位小写 SHA-256。
pub fn validateRoot(root: []const u8) !void {
    try validation.validatePath(root);
    const prefix = base_root ++ "/";
    if (!std.mem.startsWith(u8, root, prefix)) return error.InvalidPostgresqlArtifactRoot;
    const suffix = root[prefix.len..];
    if (suffix.len != 64 or std.mem.indexOfScalar(u8, suffix, '/') != null) return error.InvalidPostgresqlArtifactRoot;
    for (suffix) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidPostgresqlArtifactRoot;
    }
}

// 校验 artifact 根目录不仅格式合法，而且确实绑定到 plan 中的源 inventory hash。
pub fn validateRootForInventoryHash(root: []const u8, inventory_hash: [32]u8) !void {
    try validateRoot(root);
    const prefix = base_root ++ "/";
    const expected = std.fmt.bytesToHex(inventory_hash, .lower);
    if (!std.mem.eql(u8, root[prefix.len..], &expected)) return error.PostgresqlArtifactInventoryHashMismatch;
}

// 在已校验的 provider 根目录下生成源集群 dump 路径。
pub fn sourceDumpPath(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    try validateRoot(root);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, source_dump_name });
}

// 在已校验的 provider 根目录下生成目标基线 dump 路径。
pub fn targetBaselinePath(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    try validateRoot(root);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, target_baseline_name });
}

test "postgresql artifact paths bind to inventory hash" {
    const root = try rootForInventoryHash(std.testing.allocator, [_]u8{0xab} ** 32);
    defer std.testing.allocator.free(root);
    try validateRoot(root);
    try std.testing.expectEqualStrings(
        "/var/lib/hostlift/artifacts/postgresql/abababababababababababababababababababababababababababababababab",
        root,
    );
    const dump = try sourceDumpPath(std.testing.allocator, root);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.endsWith(u8, dump, "/source-cluster.sql"));
    try validateRootForInventoryHash(root, [_]u8{0xab} ** 32);
    try std.testing.expectError(
        error.PostgresqlArtifactInventoryHashMismatch,
        validateRootForInventoryHash(root, [_]u8{0xcd} ** 32),
    );
    try std.testing.expectError(error.InvalidPostgresqlArtifactRoot, validateRoot("/tmp/postgresql/cluster"));
}
