const std = @import("std");
const common = @import("docker_common.zig");
const compose_scanner = @import("docker_compose.zig");
const container_scanner = @import("docker_containers.zig");
const resource_scanner = @import("docker_resources.zig");
const runtime_scanner = @import("docker_runtime.zig");
const schema = @import("schema.zig");

// 扫描运行中 Docker 容器和 Compose labels。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.DockerInventory {
    const availability = runtime_scanner.detect(io, allocator);
    const containers = try scanContainers(io, allocator, availability);
    errdefer {
        container_scanner.free(allocator, containers.items);
        allocator.free(containers.items);
    }
    const volumes = try scanVolumes(io, allocator, availability);
    errdefer {
        resource_scanner.freeVolumes(allocator, volumes.items);
        allocator.free(volumes.items);
    }
    const networks = try scanNetworks(io, allocator, availability);
    errdefer {
        resource_scanner.freeNetworks(allocator, networks.items);
        allocator.free(networks.items);
    }
    const images = try scanImages(io, allocator, availability);
    errdefer {
        resource_scanner.freeImages(allocator, images.items);
        allocator.free(images.items);
    }
    const compose_files = try compose_scanner.scan(io, allocator);
    errdefer {
        compose_scanner.free(allocator, compose_files.items);
        allocator.free(compose_files.items);
    }

    return .{
        .runtimes = try runtime_scanner.scan(allocator, availability),
        .containers = containers.items,
        .volumes = volumes.items,
        .networks = networks.items,
        .images = images.items,
        .compose_files = compose_files.items,
        .truncated = containers.truncated or volumes.truncated or networks.truncated or images.truncated or compose_files.truncated,
    };
}

// 根据运行时可用性返回要扫描的 provider 列表。
fn providersForAvailability(availability: runtime_scanner.RuntimeAvailability) [2]?common.RuntimeProvider {
    return .{
        if (availability.docker) common.docker_provider else null,
        if (availability.podman) common.podman_provider else null,
    };
}

// 按所有可用运行时扫描容器并合并结果。
fn scanContainers(io: std.Io, allocator: std.mem.Allocator, availability: runtime_scanner.RuntimeAvailability) !common.ScanResult(schema.DockerContainer) {
    var items: std.ArrayList(schema.DockerContainer) = .empty;
    errdefer {
        container_scanner.free(allocator, items.items);
        items.deinit(allocator);
    }
    var truncated = false;
    for (providersForAvailability(availability)) |maybe_provider| {
        const provider = maybe_provider orelse continue;
        const result = try container_scanner.scanRuntime(io, allocator, provider);
        defer allocator.free(result.items);
        try items.appendSlice(allocator, result.items);
        truncated = truncated or result.truncated;
    }
    return .{ .items = try items.toOwnedSlice(allocator), .truncated = truncated };
}

// 按所有可用运行时扫描 volume 并合并结果。
fn scanVolumes(io: std.Io, allocator: std.mem.Allocator, availability: runtime_scanner.RuntimeAvailability) !common.ScanResult(schema.ContainerVolume) {
    var items: std.ArrayList(schema.ContainerVolume) = .empty;
    errdefer {
        resource_scanner.freeVolumes(allocator, items.items);
        items.deinit(allocator);
    }
    var truncated = false;
    for (providersForAvailability(availability)) |maybe_provider| {
        const provider = maybe_provider orelse continue;
        const result = try resource_scanner.scanVolumesRuntime(io, allocator, provider);
        defer allocator.free(result.items);
        try items.appendSlice(allocator, result.items);
        truncated = truncated or result.truncated;
    }
    return .{ .items = try items.toOwnedSlice(allocator), .truncated = truncated };
}

// 按所有可用运行时扫描 network 并合并结果。
fn scanNetworks(io: std.Io, allocator: std.mem.Allocator, availability: runtime_scanner.RuntimeAvailability) !common.ScanResult(schema.ContainerNetwork) {
    var items: std.ArrayList(schema.ContainerNetwork) = .empty;
    errdefer {
        resource_scanner.freeNetworks(allocator, items.items);
        items.deinit(allocator);
    }
    var truncated = false;
    for (providersForAvailability(availability)) |maybe_provider| {
        const provider = maybe_provider orelse continue;
        const result = try resource_scanner.scanNetworksRuntime(io, allocator, provider);
        defer allocator.free(result.items);
        try items.appendSlice(allocator, result.items);
        truncated = truncated or result.truncated;
    }
    return .{ .items = try items.toOwnedSlice(allocator), .truncated = truncated };
}

// 按所有可用运行时扫描镜像并合并结果。
fn scanImages(io: std.Io, allocator: std.mem.Allocator, availability: runtime_scanner.RuntimeAvailability) !common.ScanResult(schema.DockerImage) {
    var items: std.ArrayList(schema.DockerImage) = .empty;
    errdefer {
        resource_scanner.freeImages(allocator, items.items);
        items.deinit(allocator);
    }
    var truncated = false;
    for (providersForAvailability(availability)) |maybe_provider| {
        const provider = maybe_provider orelse continue;
        const result = try resource_scanner.scanImagesRuntime(io, allocator, provider);
        defer allocator.free(result.items);
        try items.appendSlice(allocator, result.items);
        truncated = truncated or result.truncated;
    }
    return .{ .items = try items.toOwnedSlice(allocator), .truncated = truncated };
}
