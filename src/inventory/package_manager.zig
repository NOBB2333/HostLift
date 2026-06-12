const std = @import("std");
const schema = @import("schema.zig");

// 包管理器候选，关联可执行文件名和类型。
pub const Candidate = struct {
    executable: []const u8,
    kind: schema.PackageManagerKind,
};

pub const RepositorySource = union(enum) {
    file: []const u8,
    dir: []const u8,
};

// 返回当前支持探测的包管理器候选列表。
pub fn candidates() []const Candidate {
    return &.{
        .{ .executable = "apt", .kind = .apt },
        .{ .executable = "dnf", .kind = .dnf },
        .{ .executable = "yum", .kind = .yum },
        .{ .executable = "pacman", .kind = .pacman },
        .{ .executable = "zypper", .kind = .zypper },
    };
}

// 返回包管理器版本探测命令。
pub fn versionCommand(kind: schema.PackageManagerKind) ?[]const []const u8 {
    return switch (kind) {
        .apt => &.{ "apt", "--version" },
        .dnf => &.{ "dnf", "--version" },
        .yum => &.{ "yum", "--version" },
        .pacman => &.{ "pacman", "--version" },
        .zypper => &.{ "zypper", "--version" },
        .unknown => null,
    };
}

// 返回包管理器仓库配置来源。
pub fn repositorySources(kind: schema.PackageManagerKind) []const RepositorySource {
    return switch (kind) {
        .apt => &.{
            .{ .file = "/etc/apt/sources.list" },
            .{ .dir = "/etc/apt/sources.list.d" },
        },
        .dnf, .yum => &.{.{ .dir = "/etc/yum.repos.d" }},
        .pacman => &.{.{ .file = "/etc/pacman.conf" }},
        .zypper => &.{.{ .dir = "/etc/zypp/repos.d" }},
        .unknown => &.{},
    };
}

// 返回显式安装包扫描命令；executable 用于先判断命令是否存在。
pub fn explicitPackagesCommand(kind: schema.PackageManagerKind) ?CandidateCommand {
    return switch (kind) {
        .apt => .{ .executable = "apt-mark", .argv = &.{ "apt-mark", "showmanual" } },
        .dnf => .{ .executable = "dnf", .argv = &.{ "dnf", "repoquery", "--userinstalled" } },
        .yum => .{ .executable = "yum", .argv = &.{ "yum", "repoquery", "--userinstalled" } },
        .pacman => .{ .executable = "pacman", .argv = &.{ "pacman", "-Qqe" } },
        .zypper => .{ .executable = "zypper", .argv = &.{ "zypper", "search", "--installed-only" } },
        .unknown => null,
    };
}

// 返回 hold/lock 包扫描命令；当前只有 apt 支持。
pub fn heldPackagesCommand(kind: schema.PackageManagerKind) ?CandidateCommand {
    return switch (kind) {
        .apt => .{ .executable = "apt-mark", .argv = &.{ "apt-mark", "showhold" } },
        else => null,
    };
}

// 包管理器扫描命令，关联可执行文件名和完整 argv。
pub const CandidateCommand = struct {
    executable: []const u8,
    argv: []const []const u8,
};

test "package manager provider exposes detection order" {
    const values = candidates();
    try std.testing.expectEqual(@as(usize, 5), values.len);
    try std.testing.expectEqual(schema.PackageManagerKind.apt, values[0].kind);
    try std.testing.expectEqualStrings("apt", values[0].executable);
    try std.testing.expectEqual(schema.PackageManagerKind.zypper, values[4].kind);
}

test "package manager provider maps repository sources" {
    const apt_sources = repositorySources(.apt);
    try std.testing.expectEqual(@as(usize, 2), apt_sources.len);
    try std.testing.expectEqualStrings("/etc/apt/sources.list", apt_sources[0].file);
    try std.testing.expectEqualStrings("/etc/apt/sources.list.d", apt_sources[1].dir);

    const dnf_sources = repositorySources(.dnf);
    try std.testing.expectEqual(@as(usize, 1), dnf_sources.len);
    try std.testing.expectEqualStrings("/etc/yum.repos.d", dnf_sources[0].dir);

    try std.testing.expectEqual(@as(usize, 0), repositorySources(.unknown).len);
}

test "package manager provider maps scan commands" {
    const apt_explicit = explicitPackagesCommand(.apt).?;
    try std.testing.expectEqualStrings("apt-mark", apt_explicit.executable);
    try std.testing.expectEqualStrings("showmanual", apt_explicit.argv[1]);

    const pacman_explicit = explicitPackagesCommand(.pacman).?;
    try std.testing.expectEqualStrings("pacman", pacman_explicit.executable);
    try std.testing.expectEqualStrings("-Qqe", pacman_explicit.argv[1]);

    const apt_held = heldPackagesCommand(.apt).?;
    try std.testing.expectEqualStrings("showhold", apt_held.argv[1]);
    try std.testing.expect(heldPackagesCommand(.dnf) == null);
}
