const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const plan = @import("schema.zig");

// 比较源/目标清单的发行版、版本、包管理器和架构兼容性。
pub fn check(source: inventory.Inventory, target: inventory.Inventory) plan.CompatibilityResult {
    const same_distro = std.mem.eql(u8, source.distro.id, target.distro.id);
    const same_version = std.mem.eql(u8, source.distro.version_id, target.distro.version_id);
    const same_package_manager = source.package_manager.kind == target.package_manager.kind;
    const same_arch = source.host.arch == target.host.arch;
    const compatible = same_distro and same_version and same_package_manager;

    return .{
        .compatible = compatible,
        .same_distro = same_distro,
        .same_version = same_version,
        .same_package_manager = same_package_manager,
        .same_arch = same_arch,
        .reason = if (compatible) "compatible" else "source and target must have the same distro, version, and package manager",
    };
}

test "same distro version and package manager is compatible even across arch" {
    const source = fixture(.x86_64, .apt, "ubuntu", "24.04");
    const target = fixture(.aarch64, .apt, "ubuntu", "24.04");

    const result = check(source, target);

    try std.testing.expect(result.compatible);
    try std.testing.expect(!result.same_arch);
}

test "different distro version is incompatible" {
    const source = fixture(.x86_64, .apt, "ubuntu", "22.04");
    const target = fixture(.x86_64, .apt, "ubuntu", "24.04");

    const result = check(source, target);

    try std.testing.expect(!result.compatible);
    try std.testing.expect(!result.same_version);
}

// 构造测试用的 inventory fixture。
fn fixture(
    arch: inventory.CpuArch,
    package_manager: inventory.PackageManagerKind,
    distro_id: []const u8,
    version_id: []const u8,
) inventory.Inventory {
    return .{
        .schema_version = inventory.schema_version,
        .host = .{
            .hostname = "host",
            .machine_id_hash = null,
            .kernel_release = "test",
            .arch = arch,
        },
        .distro = .{
            .id = distro_id,
            .id_like = &.{},
            .version_id = version_id,
            .pretty_name = "Test Linux",
        },
        .package_manager = .{
            .kind = package_manager,
            .version = "test",
            .repos = &.{},
        },
        .modules = inventory.emptyModules(),
        .scan = .{
            .scanned_at_unix = 0,
            .warnings = &.{},
        },
    };
}
