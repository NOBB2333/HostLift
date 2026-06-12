const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const details = @import("inventory_summary_details.zig");
const overview = @import("inventory_summary_overview.zig");

// 输出主机清单摘要，帮助用户先判断哪些内容值得迁移。
pub fn writeInventorySummary(writer: anytype, value: inventory.Inventory) !void {
    try overview.writeOverview(writer, value);

    if (value.scan.warnings.len > 0) {
        try writer.print("Scan warnings: {d}\n", .{value.scan.warnings.len});
        for (value.scan.warnings) |warning| {
            try writer.print("  - {s}\n", .{warning});
        }
        try writer.writeAll("\n");
    }

    try details.writeDetails(writer, value);
}

test "summary includes compact section names" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    var warning_items = [_][]const u8{"scan module docker failed: DockerUnavailable"};
    const value = inventory.Inventory{
        .schema_version = inventory.schema_version,
        .host = .{
            .hostname = "source",
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
            .warnings = warning_items[0..],
        },
    };

    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    try writeInventorySummary(&writer.writer, value);
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "HostLift inventory summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Packages:") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Scan warnings: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "scan module docker failed") != null);
}

test "summary associates compose containers with detected projects" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    var projects = [_]inventory.ProjectRef{.{
        .root = "/srv/shop",
        .kind = .docker_compose,
        .manifest_path = "/srv/shop/docker-compose.yml",
    }};
    var containers = [_]inventory.DockerContainer{.{
        .name = "shop-web-1",
        .image = "nginx:1.27",
        .status = "Up",
        .ports = "0.0.0.0:8080->80/tcp",
        .compose_project = "shop",
        .compose_service = "web",
        .compose_workdir = "/srv/shop",
    }};

    const value = inventory.Inventory{
        .schema_version = inventory.schema_version,
        .host = .{
            .hostname = "source",
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
        .modules = blk: {
            var modules = inventory.emptyModules();
            modules.projects = .{ .projects = projects[0..], .truncated = false };
            modules.docker = .{ .containers = containers[0..], .truncated = false };
            break :blk modules;
        },
        .scan = .{
            .scanned_at_unix = 0,
            .warnings = &.{},
        },
    };

    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    try writeInventorySummary(&writer.writer, value);
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "container=shop-web-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "service=web") != null);
}
