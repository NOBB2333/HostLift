const std = @import("std");
const remote_schema = @import("../remote/schema.zig");

// 构造整目录 chunk 上传 argv；保留给兼容测试和后续 fallback 使用。
pub fn appendDirectoryUploadArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    transfer_plan: remote_schema.TransferPlan,
    source_path: []const u8,
    remote_target: []const u8,
    bandwidth_limit_arg: ?[]const u8,
) !void {
    try argv.append(allocator, "scp");
    if (transfer_plan.ssh_identity_file) |path| try argv.appendSlice(allocator, &.{ "-i", path });
    if (bandwidth_limit_arg) |value| try argv.appendSlice(allocator, &.{ "-l", value });
    try argv.append(allocator, "-r");
    if (transfer_plan.preserve_metadata) try argv.append(allocator, "-p");
    try argv.append(allocator, source_path);
    try argv.append(allocator, remote_target);
}

// 构造单文件 chunk 上传 argv。
pub fn appendFileUploadArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    transfer_plan: remote_schema.TransferPlan,
    source_path: []const u8,
    remote_target: []const u8,
    bandwidth_limit_arg: ?[]const u8,
) !void {
    try argv.append(allocator, "scp");
    if (transfer_plan.ssh_identity_file) |path| try argv.appendSlice(allocator, &.{ "-i", path });
    if (bandwidth_limit_arg) |value| try argv.appendSlice(allocator, &.{ "-l", value });
    if (transfer_plan.preserve_metadata) try argv.append(allocator, "-p");
    try argv.append(allocator, source_path);
    try argv.append(allocator, remote_target);
}

test "chunk directory upload argv uses scp recursive staging target" {
    const plan = remote_schema.TransferPlan{
        .schema_version = remote_schema.transfer_plan_schema_version,
        .host = "root@192.0.2.10",
        .source_path = "/srv/app",
        .target_path = "/srv/app",
        .recursive = true,
        .preserve_metadata = true,
        .verify_checksum = false,
        .transport = .chunk,
        .ssh_identity_file = "/home/me/.ssh/id_ed25519",
        .risk = .high,
        .requires_approval = true,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendDirectoryUploadArgv(std.testing.allocator, &argv, plan, "/srv/app", "root@192.0.2.10:/tmp/hostlift-chunk-test", null);

    try std.testing.expectEqualStrings("scp", argv.items[0]);
    try std.testing.expectEqualStrings("-i", argv.items[1]);
    try std.testing.expectEqualStrings("/home/me/.ssh/id_ed25519", argv.items[2]);
    try std.testing.expectEqualStrings("-r", argv.items[3]);
    try std.testing.expectEqualStrings("-p", argv.items[4]);
    try std.testing.expectEqualStrings("root@192.0.2.10:/tmp/hostlift-chunk-test", argv.items[6]);
}

test "chunk file upload argv omits recursive flag" {
    const plan = remote_schema.TransferPlan{
        .schema_version = remote_schema.transfer_plan_schema_version,
        .host = "root@192.0.2.10",
        .source_path = "/srv/app",
        .target_path = "/srv/app",
        .recursive = true,
        .preserve_metadata = true,
        .verify_checksum = false,
        .transport = .chunk,
        .ssh_identity_file = "/home/me/.ssh/id_ed25519",
        .risk = .high,
        .requires_approval = true,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendFileUploadArgv(std.testing.allocator, &argv, plan, "/srv/app/a.txt", "root@192.0.2.10:/tmp/hostlift-chunk-test/a.txt", null);

    try std.testing.expectEqualStrings("scp", argv.items[0]);
    try std.testing.expectEqualStrings("-i", argv.items[1]);
    try std.testing.expectEqualStrings("-p", argv.items[3]);
    try std.testing.expectEqualStrings("/srv/app/a.txt", argv.items[4]);
    try std.testing.expectEqualStrings("root@192.0.2.10:/tmp/hostlift-chunk-test/a.txt", argv.items[5]);
}
