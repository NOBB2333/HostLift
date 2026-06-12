const std = @import("std");

// CPU 架构枚举。
pub const CpuArch = enum {
    x86_64,
    aarch64,
    arm,
    riscv64,
    powerpc64le,
    s390x,
    unknown,

    // 将 Zig 内置 CPU 架构归一化成 HostLift 清单架构枚举。
    pub fn fromBuiltin(arch: std.Target.Cpu.Arch) CpuArch {
        return switch (arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            .arm, .armeb, .thumb, .thumbeb => .arm,
            .riscv64 => .riscv64,
            .powerpc64le => .powerpc64le,
            .s390x => .s390x,
            else => .unknown,
        };
    }
};

// 发行版信息（os-release）。
pub const DistroInfo = struct {
    id: []const u8,
    id_like: [][]const u8,
    version_id: []const u8,
    pretty_name: []const u8,
};

// 主机基本信息。
pub const HostInfo = struct {
    hostname: []const u8,
    machine_id_hash: ?[32]u8,
    kernel_release: []const u8,
    arch: CpuArch,
};

// 扫描元数据（时间戳和警告）。
pub const ScanMetadata = struct {
    scanned_at_unix: i64,
    warnings: [][]const u8,
};
