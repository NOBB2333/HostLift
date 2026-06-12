const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 容器运行时可用性检测结果。
pub const RuntimeAvailability = struct {
    docker: bool,
    podman: bool,
};

// 检测本机可用的容器运行时。
pub fn detect(io: std.Io, allocator: std.mem.Allocator) RuntimeAvailability {
    return .{
        .docker = probe.executableExists(io, allocator, "docker"),
        .podman = probe.executableExists(io, allocator, "podman"),
    };
}

// 构造容器运行时事实列表。
pub fn scan(
    allocator: std.mem.Allocator,
    availability: RuntimeAvailability,
) ![]schema.ContainerRuntime {
    var runtimes: std.ArrayList(schema.ContainerRuntime) = .empty;
    errdefer runtimes.deinit(allocator);

    try runtimes.append(allocator, .{ .kind = .docker, .available = availability.docker });
    try runtimes.append(allocator, .{ .kind = .podman, .available = availability.podman });
    return runtimes.toOwnedSlice(allocator);
}
