const std = @import("std");
const inventory_schema = @import("../../inventory/schema.zig");
const common = @import("common.zig");
const package_provider = @import("package_provider.zig");

// 根据目标包管理器生成安装包命令。
pub fn installCommand(
    allocator: std.mem.Allocator,
    package_manager: inventory_schema.PackageManagerKind,
    package: []const u8,
) !common.Command {
    return commandWithPackage(allocator, package_manager, .install, package);
}

// 根据目标包管理器生成包存在性验证命令。
pub fn verifyCommand(
    allocator: std.mem.Allocator,
    package_manager: inventory_schema.PackageManagerKind,
    package: []const u8,
) !common.Command {
    return commandWithPackage(allocator, package_manager, .verify, package);
}

// 根据目标包管理器生成卸载包命令，用于回滚 HostLift 安装的包。
pub fn removeCommand(
    allocator: std.mem.Allocator,
    package_manager: inventory_schema.PackageManagerKind,
    package: []const u8,
) !common.Command {
    if (package.len == 0) return error.MissingApplySubject;
    return commandWithPackage(allocator, package_manager, .remove, package);
}

// 拼接包管理器前缀和包名，生成完整的包操作命令。
fn commandWithPackage(
    allocator: std.mem.Allocator,
    package_manager: inventory_schema.PackageManagerKind,
    operation: package_provider.PackageOperation,
    package: []const u8,
) !common.Command {
    if (package.len == 0) return error.MissingApplySubject;
    const prefix = package_provider.commandPrefix(package_manager, operation) orelse return error.UnsupportedPackageManager;
    var argv = try allocator.alloc([]const u8, prefix.len + 1);
    @memcpy(argv[0..prefix.len], prefix);
    argv[prefix.len] = package;
    return common.commandWithoutOwned(allocator, argv);
}
