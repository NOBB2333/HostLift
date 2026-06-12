const std = @import("std");
const schema = @import("schema.zig");

// 容器运行时提供者，绑定运行时类型和对应 CLI 命令名。
pub const RuntimeProvider = struct {
    kind: schema.ContainerRuntimeKind,
    command: []const u8,
};

// Docker 运行时提供者。
pub const docker_provider: RuntimeProvider = .{ .kind = .docker, .command = "docker" };
// Podman 运行时提供者。
pub const podman_provider: RuntimeProvider = .{ .kind = .podman, .command = "podman" };

// 构造带截断标记的通用扫描结果类型。
pub fn ScanResult(comptime T: type) type {
    return struct {
        items: []T,
        truncated: bool,
    };
}

// 构造指定类型的空扫描结果。
pub fn emptyResult(comptime T: type, allocator: std.mem.Allocator) !ScanResult(T) {
    return .{ .items = try allocator.alloc(T, 0), .truncated = false };
}

// 归一化 Docker Go template 输出中的空 label。
pub fn normalizeLabel(value: ?[]const u8) ?[]const u8 {
    const label = value orelse return null;
    if (label.len == 0 or std.mem.eql(u8, label, "<no value>")) return null;
    return label;
}
