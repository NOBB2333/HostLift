const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const manual_common = @import("manual_common.zig");

// 规划容器运行时、volume、network 和 Compose 文件的人工审查动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.DockerInventory,
    target: inventory.DockerInventory,
) !void {
    for (source.runtimes) |runtime| {
        if (!runtime.available) continue;
        if (targetRuntimeAvailable(target.runtimes, runtime.kind)) continue;
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "docker/review-runtime",
            .name = @tagName(runtime.kind),
            .subject = @tagName(runtime.kind),
            .module = .docker,
            .risk = .high,
            .description = "Review container runtime availability before migration; HostLift does not install Docker or Podman automatically",
        });
    }
    for (source.volumes) |volume| {
        if (findVolume(target.volumes, volume.runtime, volume.name)) |_| continue;
        const action_name = try runtimeQualifiedName(allocator, volume.runtime, volume.name);
        defer allocator.free(action_name);
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "docker/review-volume",
            .name = action_name,
            .subject = volume.name,
            .module = .docker,
            .risk = .critical,
            .description = "Review container volume backup and restore plan before migration; HostLift only copies volume contents when explicitly selected",
        });
        if (volumeMountedByRunningContainer(source.containers, volume)) {
            try manual_common.appendManualStep(allocator, actions, .{
                .id_prefix = "docker/stop-writers",
                .name = action_name,
                .subject = volume.name,
                .module = .docker,
                .risk = .critical,
                .description = "Stop writers or take an application-consistent backup before copying this volume; a running container still references it",
            });
        }
        if (volume.mountpoint) |mountpoint| {
            try appendVolumeCopyAction(allocator, actions, volume.runtime, volume.name, mountpoint);
        }
    }
    for (source.networks) |network| {
        if (isDefaultNetwork(network.name)) continue;
        if (findNetwork(target.networks, network.runtime, network.name)) |_| continue;
        const action_name = try runtimeQualifiedName(allocator, network.runtime, network.name);
        defer allocator.free(action_name);
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "docker/review-network",
            .name = action_name,
            .subject = network.name,
            .module = .docker,
            .risk = .high,
            .description = "Recreate container network plan manually before starting containers; review driver, subnet, gateway and labels because HostLift does not auto-apply networks",
        });
    }
    for (source.images) |image| {
        if (findImage(target.images, image)) |_| continue;
        const action_name = try runtimeQualifiedName(allocator, image.runtime, image.image_id);
        defer allocator.free(action_name);
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "docker/review-image",
            .name = action_name,
            .subject = image.repository,
            .module = .docker,
            .risk = .high,
            .description = "Review container image availability before migration; pull from registry, rebuild from source or export/import manually",
        });
    }
    for (source.compose_files) |file| {
        if (findComposeFile(target.compose_files, file.project_root)) |_| continue;
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "docker/review-compose",
            .name = file.project_root,
            .subject = file.path,
            .module = .docker,
            .risk = .high,
            .description = "Review Compose file and runtime dependencies before migration; project copy may be separate from container state",
        });
    }
    for (source.containers) |container| {
        if (findContainer(target.containers, container.runtime, container.name)) |_| continue;
        const action_name = try runtimeQualifiedName(allocator, container.runtime, container.name);
        defer allocator.free(action_name);
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "docker/review-container",
            .name = action_name,
            .subject = container.image,
            .module = .docker,
            .risk = .high,
            .description = "Check container recreation and post-migration status; prefer Compose or explicit run command review because HostLift does not live-migrate containers",
        });
        const task_inputs = [_]@import("common.zig").ManualInputSpec{
            .{ .name = "runtime", .value = @tagName(container.runtime) },
            .{ .name = "container", .value = container.name },
        };
        const probe_target = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ @tagName(container.runtime), container.name });
        defer allocator.free(probe_target);
        const task_probes = [_]@import("common.zig").ManualProbeSpec{.{
            .kind = .container,
            .target = probe_target,
        }};
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "docker/check-container",
            .name = action_name,
            .subject = container.name,
            .module = .docker,
            .risk = .high,
            .description = "Verify container health, exposed ports and recent logs after migration",
            .task_provider = "container_status",
            .task_inputs = &task_inputs,
            .task_verify_probes = &task_probes,
        });
    }
    if (source.truncated) {
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "docker/review-truncated",
            .name = "scanner-limit",
            .subject = "docker",
            .module = .docker,
            .risk = .high,
            .description = "Review truncated container scan results before migration",
        });
    }
}

// 判断目标是否有指定容器运行时。
fn targetRuntimeAvailable(runtimes: []const inventory.ContainerRuntime, kind: inventory.ContainerRuntimeKind) bool {
    for (runtimes) |runtime| {
        if (runtime.kind == kind and runtime.available) return true;
    }
    return false;
}

// 查找指定运行时下的容器 volume。
fn findVolume(volumes: []const inventory.ContainerVolume, runtime: inventory.ContainerRuntimeKind, name: []const u8) ?inventory.ContainerVolume {
    for (volumes) |volume| {
        if (volume.runtime == runtime and std.mem.eql(u8, volume.name, name)) return volume;
    }
    return null;
}

// 查找指定运行时下的容器 network。
fn findNetwork(networks: []const inventory.ContainerNetwork, runtime: inventory.ContainerRuntimeKind, name: []const u8) ?inventory.ContainerNetwork {
    for (networks) |network| {
        if (network.runtime == runtime and std.mem.eql(u8, network.name, name)) return network;
    }
    return null;
}

// 查找同一运行时下的容器镜像标签或 ID。
fn findImage(images: []const inventory.DockerImage, needle: inventory.DockerImage) ?inventory.DockerImage {
    for (images) |image| {
        if (image.runtime != needle.runtime) continue;
        if (std.mem.eql(u8, image.image_id, needle.image_id)) return image;
        if (std.mem.eql(u8, image.repository, needle.repository) and std.mem.eql(u8, image.tag, needle.tag)) return image;
    }
    return null;
}

// 为容器 volume 挂载点生成高风险复制动作。
fn appendVolumeCopyAction(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    runtime: inventory.ContainerRuntimeKind,
    name: []const u8,
    mountpoint: []const u8,
) !void {
    const action_name = try runtimeQualifiedName(allocator, runtime, name);
    defer allocator.free(action_name);
    try @import("common.zig").appendAction(allocator, actions, .{
        .id_prefix = "docker/copy-volume",
        .name = action_name,
        .subject = mountpoint,
        .module = .docker,
        .action_type = .copy_data_path,
        .risk = .critical,
        .requires_confirmation = true,
        .description = "Copy container volume mountpoint after stopping writers or taking an application-consistent backup",
        .recursive = true,
    });
}

fn volumeMountedByRunningContainer(containers: []const inventory.DockerContainer, volume: inventory.ContainerVolume) bool {
    for (containers) |container| {
        if (container.runtime != volume.runtime) continue;
        const mounts = container.mounts orelse continue;
        if (mountsContainVolume(mounts, volume)) return true;
    }
    return false;
}

fn mountsContainVolume(mounts: []const u8, volume: inventory.ContainerVolume) bool {
    var entries = std.mem.splitScalar(u8, mounts, ';');
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        var fields = std.mem.splitScalar(u8, entry, '=');
        const source = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        if (std.mem.eql(u8, source, volume.name)) return true;
        if (volume.mountpoint) |mountpoint| {
            if (std.mem.eql(u8, source, mountpoint)) return true;
        }
    }
    return false;
}

// 查找 Compose 文件所在项目根目录。
fn findComposeFile(files: []const inventory.ComposeFile, project_root: []const u8) ?inventory.ComposeFile {
    for (files) |file| {
        if (std.mem.eql(u8, file.project_root, project_root)) return file;
    }
    return null;
}

// 查找指定运行时下的运行中容器名称。
fn findContainer(containers: []const inventory.DockerContainer, runtime: inventory.ContainerRuntimeKind, name: []const u8) ?inventory.DockerContainer {
    for (containers) |container| {
        if (container.runtime == runtime and std.mem.eql(u8, container.name, name)) return container;
    }
    return null;
}

// 判断是否是容器运行时默认网络。
fn isDefaultNetwork(name: []const u8) bool {
    return std.mem.eql(u8, name, "bridge") or
        std.mem.eql(u8, name, "host") or
        std.mem.eql(u8, name, "none");
}

// 生成带运行时前缀的资源限定名（Podman 资源加 podman/ 前缀）。
fn runtimeQualifiedName(allocator: std.mem.Allocator, runtime: inventory.ContainerRuntimeKind, name: []const u8) ![]const u8 {
    if (runtime == .docker) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ @tagName(runtime), name });
}

test "docker volume mount matching uses structured mount source" {
    const volume = inventory.ContainerVolume{
        .runtime = .docker,
        .name = "db",
        .driver = "local",
        .mountpoint = "/var/lib/docker/volumes/db/_data",
    };
    try std.testing.expect(mountsContainVolume("db=/var/lib/postgresql/data;", volume));
    try std.testing.expect(mountsContainVolume("/var/lib/docker/volumes/db/_data=/data;", volume));
    try std.testing.expect(!mountsContainVolume("dbdata=/data;", volume));
    try std.testing.expect(!mountsContainVolume("prefix-db=/data;", volume));
}
