const std = @import("std");
const inventory_schema = @import("../../inventory/schema.zig");

// 包操作类型枚举：安装、验证、移除。
pub const PackageOperation = enum {
    install,
    verify,
    remove,
};

// 根据包管理器和操作生成不含包名的命令前缀。
pub fn commandPrefix(
    package_manager: inventory_schema.PackageManagerKind,
    operation: PackageOperation,
) ?[]const []const u8 {
    return switch (operation) {
        .install => installPrefix(package_manager),
        .verify => verifyPrefix(package_manager),
        .remove => removePrefix(package_manager),
    };
}

// 返回 apt/dnf/yum 等包管理器的安装命令前缀。
fn installPrefix(package_manager: inventory_schema.PackageManagerKind) ?[]const []const u8 {
    return switch (package_manager) {
        .apt => &.{ "apt-get", "install", "-y" },
        .dnf => &.{ "dnf", "install", "-y" },
        .yum => &.{ "yum", "install", "-y" },
        .zypper => &.{ "zypper", "--non-interactive", "install" },
        .pacman => &.{ "pacman", "-S", "--noconfirm" },
        .unknown => null,
    };
}

// 返回各包管理器的包存在性验证命令前缀。
fn verifyPrefix(package_manager: inventory_schema.PackageManagerKind) ?[]const []const u8 {
    return switch (package_manager) {
        .apt => &.{ "dpkg-query", "-W" },
        .dnf, .yum, .zypper => &.{ "rpm", "-q" },
        .pacman => &.{ "pacman", "-Q" },
        .unknown => null,
    };
}

// 返回各包管理器的包移除命令前缀。
fn removePrefix(package_manager: inventory_schema.PackageManagerKind) ?[]const []const u8 {
    return switch (package_manager) {
        .apt => &.{ "apt-get", "remove", "-y" },
        .dnf => &.{ "dnf", "remove", "-y" },
        .yum => &.{ "yum", "remove", "-y" },
        .zypper => &.{ "zypper", "--non-interactive", "remove" },
        .pacman => &.{ "pacman", "-R", "--noconfirm" },
        .unknown => null,
    };
}

test "package provider maps install prefixes" {
    const apt = commandPrefix(.apt, .install).?;
    try std.testing.expectEqualStrings("apt-get", apt[0]);
    try std.testing.expectEqualStrings("install", apt[1]);
    try std.testing.expectEqualStrings("-y", apt[2]);

    const pacman = commandPrefix(.pacman, .install).?;
    try std.testing.expectEqualStrings("pacman", pacman[0]);
    try std.testing.expectEqualStrings("-S", pacman[1]);
    try std.testing.expectEqualStrings("--noconfirm", pacman[2]);
}

test "package provider maps verify prefixes" {
    const zypper = commandPrefix(.zypper, .verify).?;
    try std.testing.expectEqualStrings("rpm", zypper[0]);
    try std.testing.expectEqualStrings("-q", zypper[1]);

    const pacman = commandPrefix(.pacman, .verify).?;
    try std.testing.expectEqualStrings("pacman", pacman[0]);
    try std.testing.expectEqualStrings("-Q", pacman[1]);
}

test "package provider maps remove prefixes" {
    const yum = commandPrefix(.yum, .remove).?;
    try std.testing.expectEqualStrings("yum", yum[0]);
    try std.testing.expectEqualStrings("remove", yum[1]);
    try std.testing.expectEqualStrings("-y", yum[2]);

    const unknown = commandPrefix(.unknown, .remove);
    try std.testing.expect(unknown == null);
}
