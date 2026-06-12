const std = @import("std");
const common = @import("docker_common.zig");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 扫描 Docker volume 元数据，不读取 volume 内容。
pub fn scanVolumes(io: std.Io, allocator: std.mem.Allocator) !common.ScanResult(schema.ContainerVolume) {
    return scanVolumesRuntime(io, allocator, common.docker_provider);
}

// 按指定容器运行时扫描 volume 元数据，不读取 volume 内容。
pub fn scanVolumesRuntime(io: std.Io, allocator: std.mem.Allocator, provider: common.RuntimeProvider) !common.ScanResult(schema.ContainerVolume) {
    const format = switch (provider.kind) {
        .docker => "{{.Name}}\t{{.Driver}}\t{{.Scope}}",
        .podman => "{{.Name}}\t{{.Driver}}",
    };
    const lines = probe.runLines(
        io,
        allocator,
        &.{ provider.command, "volume", "ls", "--format", format },
        512 * 1024,
    ) catch return common.emptyResult(schema.ContainerVolume, allocator);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    var volumes: std.ArrayList(schema.ContainerVolume) = .empty;
    errdefer {
        freeVolumes(allocator, volumes.items);
        volumes.deinit(allocator);
    }

    var truncated = false;
    for (lines) |line| {
        if (volumes.items.len >= 512) {
            truncated = true;
            break;
        }
        const parsed = parseRuntimeAssetLine(line) orelse continue;
        const mountpoint = scanVolumeMountpoint(io, allocator, provider, parsed.name) catch null;
        try volumes.append(allocator, .{
            .runtime = provider.kind,
            .name = try allocator.dupe(u8, parsed.name),
            .driver = try allocator.dupe(u8, parsed.driver),
            .scope = if (parsed.scope) |value| try allocator.dupe(u8, value) else null,
            .mountpoint = mountpoint,
        });
    }
    return .{ .items = try volumes.toOwnedSlice(allocator), .truncated = truncated };
}

// 扫描 Docker network 元数据，不修改网络。
pub fn scanNetworks(io: std.Io, allocator: std.mem.Allocator) !common.ScanResult(schema.ContainerNetwork) {
    return scanNetworksRuntime(io, allocator, common.docker_provider);
}

// 按指定容器运行时扫描 network 元数据，不修改网络。
pub fn scanNetworksRuntime(io: std.Io, allocator: std.mem.Allocator, provider: common.RuntimeProvider) !common.ScanResult(schema.ContainerNetwork) {
    const format = switch (provider.kind) {
        .docker => "{{.Name}}\t{{.Driver}}\t{{.Scope}}",
        .podman => "{{.Name}}\t{{.Driver}}",
    };
    const lines = probe.runLines(
        io,
        allocator,
        &.{ provider.command, "network", "ls", "--format", format },
        512 * 1024,
    ) catch return common.emptyResult(schema.ContainerNetwork, allocator);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    var networks: std.ArrayList(schema.ContainerNetwork) = .empty;
    errdefer {
        freeNetworks(allocator, networks.items);
        networks.deinit(allocator);
    }

    var truncated = false;
    for (lines) |line| {
        if (networks.items.len >= 512) {
            truncated = true;
            break;
        }
        const parsed = parseRuntimeAssetLine(line) orelse continue;
        try networks.append(allocator, .{
            .runtime = provider.kind,
            .name = try allocator.dupe(u8, parsed.name),
            .driver = try allocator.dupe(u8, parsed.driver),
            .scope = if (parsed.scope) |value| try allocator.dupe(u8, value) else null,
        });
    }
    return .{ .items = try networks.toOwnedSlice(allocator), .truncated = truncated };
}

// 扫描本地 Docker 镜像标签和 ID，不导出镜像层。
pub fn scanImages(io: std.Io, allocator: std.mem.Allocator) !common.ScanResult(schema.DockerImage) {
    return scanImagesRuntime(io, allocator, common.docker_provider);
}

// 按指定容器运行时扫描本地镜像标签和 ID，不导出镜像层。
pub fn scanImagesRuntime(io: std.Io, allocator: std.mem.Allocator, provider: common.RuntimeProvider) !common.ScanResult(schema.DockerImage) {
    const lines = probe.runLines(
        io,
        allocator,
        &.{ provider.command, "image", "ls", "--format", "{{.Repository}}\t{{.Tag}}\t{{.ID}}" },
        512 * 1024,
    ) catch return common.emptyResult(schema.DockerImage, allocator);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    var images: std.ArrayList(schema.DockerImage) = .empty;
    errdefer {
        freeImages(allocator, images.items);
        images.deinit(allocator);
    }

    var truncated = false;
    for (lines) |line| {
        if (images.items.len >= 512) {
            truncated = true;
            break;
        }
        const parsed = parseImageLine(line) orelse continue;
        try images.append(allocator, .{
            .runtime = provider.kind,
            .repository = try allocator.dupe(u8, parsed.repository),
            .tag = try allocator.dupe(u8, parsed.tag),
            .image_id = try allocator.dupe(u8, parsed.image_id),
        });
    }
    return .{ .items = try images.toOwnedSlice(allocator), .truncated = truncated };
}

// 释放 volume 记录列表。
pub fn freeVolumes(allocator: std.mem.Allocator, volumes: []schema.ContainerVolume) void {
    for (volumes) |volume| {
        allocator.free(volume.name);
        allocator.free(volume.driver);
        if (volume.scope) |value| allocator.free(value);
        if (volume.mountpoint) |value| allocator.free(value);
    }
}

// 释放 network 记录列表。
pub fn freeNetworks(allocator: std.mem.Allocator, networks: []schema.ContainerNetwork) void {
    for (networks) |network| {
        allocator.free(network.name);
        allocator.free(network.driver);
        if (network.scope) |value| allocator.free(value);
    }
}

// 释放 Docker image 记录列表。
pub fn freeImages(allocator: std.mem.Allocator, images: []schema.DockerImage) void {
    for (images) |image| {
        allocator.free(image.repository);
        allocator.free(image.tag);
        allocator.free(image.image_id);
    }
}

// volume/network ls 输出解析后的资源字段。
const ParsedRuntimeAsset = struct {
    name: []const u8,
    driver: []const u8,
    scope: ?[]const u8,
};

// image ls 输出解析后的镜像字段。
const ParsedImage = struct {
    repository: []const u8,
    tag: []const u8,
    image_id: []const u8,
};

// 解析 volume/network ls 输出行，提取名称、驱动和作用域。
fn parseRuntimeAssetLine(line: []const u8) ?ParsedRuntimeAsset {
    var parts = std.mem.splitScalar(u8, line, '\t');
    const name = parts.next() orelse return null;
    const driver = parts.next() orelse return null;
    if (name.len == 0 or driver.len == 0) return null;
    return .{
        .name = name,
        .driver = driver,
        .scope = common.normalizeLabel(parts.next()),
    };
}

// 解析 image ls 输出行，提取仓库、标签和镜像 ID；跳过 dangling 镜像。
fn parseImageLine(line: []const u8) ?ParsedImage {
    var parts = std.mem.splitScalar(u8, line, '\t');
    const repository = parts.next() orelse return null;
    const tag = parts.next() orelse return null;
    const image_id = parts.next() orelse return null;
    if (repository.len == 0 or tag.len == 0 or image_id.len == 0) return null;
    if (std.mem.eql(u8, repository, "<none>") and std.mem.eql(u8, tag, "<none>")) return null;
    return .{
        .repository = repository,
        .tag = tag,
        .image_id = image_id,
    };
}

// 通过 docker volume inspect 获取卷的挂载点路径。
fn scanVolumeMountpoint(io: std.Io, allocator: std.mem.Allocator, provider: common.RuntimeProvider, name: []const u8) !?[]const u8 {
    const output = probe.runFirstLine(
        io,
        allocator,
        &.{ provider.command, "volume", "inspect", name, "--format", "{{.Mountpoint}}" },
    ) catch return null;
    errdefer allocator.free(output);
    if (output.len == 0 or std.mem.eql(u8, output, "<no value>")) {
        allocator.free(output);
        return null;
    }
    return output;
}

test "runtime asset parser extracts name driver and scope" {
    const parsed = parseRuntimeAssetLine("uploads\tlocal\tlocal").?;
    try std.testing.expectEqualStrings("uploads", parsed.name);
    try std.testing.expectEqualStrings("local", parsed.driver);
    try std.testing.expectEqualStrings("local", parsed.scope.?);

    const no_scope = parseRuntimeAssetLine("bridge\tbridge\t<no value>").?;
    try std.testing.expect(no_scope.scope == null);
    try std.testing.expect(parseRuntimeAssetLine("\tlocal\tlocal") == null);
}

test "image parser skips dangling images" {
    const parsed = parseImageLine("redis\t7\tabc123").?;
    try std.testing.expectEqualStrings("redis", parsed.repository);
    try std.testing.expectEqualStrings("7", parsed.tag);
    try std.testing.expectEqualStrings("abc123", parsed.image_id);
    try std.testing.expect(parseImageLine("<none>\t<none>\tdeadbeef") == null);
}
