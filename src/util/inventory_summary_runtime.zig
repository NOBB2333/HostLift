const std = @import("std");
const inventory = @import("../inventory/schema.zig");

// 输出检测到的项目，并关联匹配的 Docker Compose 容器。
pub fn writeProjectSummary(writer: anytype, projects: inventory.ProjectInventory, docker: inventory.DockerInventory) !void {
    if (projects.projects.len == 0) return;
    try writer.writeAll("\nDetected projects:\n");
    for (projects.projects[0..@min(projects.projects.len, 40)]) |project| {
        try writer.print("  - {s} [{s}] manifest={s}\n", .{ project.root, @tagName(project.kind), project.manifest_path });
        var shown_containers: usize = 0;
        for (docker.containers) |container| {
            if (!containerBelongsToProject(container, project.root)) continue;
            try writer.print("      container={s} image={s}", .{ container.name, container.image });
            if (container.compose_service) |service| try writer.print(" service={s}", .{service});
            if (container.ports.len > 0) try writer.print(" ports={s}", .{container.ports});
            try writer.writeByte('\n');
            shown_containers += 1;
            if (shown_containers >= 12) {
                try writer.writeAll("      ... more containers omitted\n");
                break;
            }
        }
    }
    if (projects.projects.len > 40) try writer.print("  ... {d} more\n", .{projects.projects.len - 40});
    if (projects.truncated) try writer.writeAll("  ... project list truncated at scanner limit\n");
}

// 判断 Docker 容器是否属于指定项目根目录。
pub fn containerBelongsToProject(container: inventory.DockerContainer, project_root: []const u8) bool {
    if (container.compose_workdir) |workdir| {
        return std.mem.eql(u8, workdir, project_root);
    }
    return false;
}

// 输出运行中进程摘要。
pub fn writeProcessSummary(writer: anytype, processes: inventory.ProcessInventory) !void {
    if (processes.processes.len == 0) return;
    try writer.writeAll("\nRunning process summaries (argv omitted):\n");
    for (processes.processes[0..@min(processes.processes.len, 40)]) |process| {
        try writer.print("  - pid={d} user={s} command={s}\n", .{ process.pid, process.user, process.command });
    }
    if (processes.processes.len > 40) try writer.print("  ... {d} more\n", .{processes.processes.len - 40});
    if (processes.truncated) try writer.writeAll("  ... process list truncated at scanner limit\n");
}

// 输出监听端口摘要。
pub fn writeNetworkSummary(writer: anytype, network: inventory.NetworkInventory) !void {
    if (network.listeners.len == 0) return;
    try writer.writeAll("\nListening sockets:\n");
    for (network.listeners[0..@min(network.listeners.len, 40)]) |listener| {
        if (listener.process) |process| {
            try writer.print("  - {s} {s}:{d} process={s}\n", .{ listener.protocol, listener.address, listener.port, process });
        } else {
            try writer.print("  - {s} {s}:{d}\n", .{ listener.protocol, listener.address, listener.port });
        }
    }
    if (network.listeners.len > 40) try writer.print("  ... {d} more\n", .{network.listeners.len - 40});
    if (network.truncated) try writer.writeAll("  ... listener list truncated at scanner limit\n");
}

// 输出运行中 Docker 容器摘要。
pub fn writeDockerSummary(writer: anytype, docker: inventory.DockerInventory) !void {
    if (docker.runtimes.len == 0 and docker.containers.len == 0 and docker.volumes.len == 0 and docker.networks.len == 0 and docker.images.len == 0 and docker.compose_files.len == 0) return;

    if (docker.runtimes.len > 0) {
        try writer.writeAll("\nContainer runtimes:\n");
        for (docker.runtimes) |runtime| {
            try writer.print("  - {s} available={}\n", .{ @tagName(runtime.kind), runtime.available });
        }
    }

    if (docker.containers.len > 0) {
        try writer.writeAll("\nRunning containers:\n");
        for (docker.containers[0..@min(docker.containers.len, 40)]) |container| {
            try writer.print("  - {s}/{s} image={s} status={s}", .{ @tagName(container.runtime), container.name, container.image, container.status });
            if (container.ports.len > 0) try writer.print(" ports={s}", .{container.ports});
            if (container.compose_project) |project| try writer.print(" compose_project={s}", .{project});
            if (container.compose_service) |service| try writer.print(" compose_service={s}", .{service});
            if (container.compose_workdir) |workdir| try writer.print(" workdir={s}", .{workdir});
            try writer.writeByte('\n');
        }
        if (docker.containers.len > 40) try writer.print("  ... {d} more\n", .{docker.containers.len - 40});
    }

    if (docker.volumes.len > 0) {
        try writer.writeAll("\nContainer volumes:\n");
        for (docker.volumes[0..@min(docker.volumes.len, 40)]) |volume| {
            try writer.print("  - {s}/{s} driver={s}", .{ @tagName(volume.runtime), volume.name, volume.driver });
            if (volume.scope) |scope| try writer.print(" scope={s}", .{scope});
            if (volume.mountpoint) |mountpoint| try writer.print(" mountpoint={s}", .{mountpoint});
            try writer.writeByte('\n');
        }
        if (docker.volumes.len > 40) try writer.print("  ... {d} more\n", .{docker.volumes.len - 40});
    }

    if (docker.networks.len > 0) {
        try writer.writeAll("\nContainer networks:\n");
        for (docker.networks[0..@min(docker.networks.len, 40)]) |network| {
            try writer.print("  - {s}/{s} driver={s}", .{ @tagName(network.runtime), network.name, network.driver });
            if (network.scope) |scope| try writer.print(" scope={s}", .{scope});
            try writer.writeByte('\n');
        }
        if (docker.networks.len > 40) try writer.print("  ... {d} more\n", .{docker.networks.len - 40});
    }

    if (docker.images.len > 0) {
        try writer.writeAll("\nContainer images:\n");
        for (docker.images[0..@min(docker.images.len, 40)]) |image| {
            try writer.print("  - {s}/{s}:{s} id={s}\n", .{ @tagName(image.runtime), image.repository, image.tag, image.image_id });
        }
        if (docker.images.len > 40) try writer.print("  ... {d} more\n", .{docker.images.len - 40});
    }

    if (docker.compose_files.len > 0) {
        try writer.writeAll("\nCompose files:\n");
        for (docker.compose_files[0..@min(docker.compose_files.len, 40)]) |file| {
            try writer.print("  - root={s} path={s}\n", .{ file.project_root, file.path });
        }
        if (docker.compose_files.len > 40) try writer.print("  ... {d} more\n", .{docker.compose_files.len - 40});
    }

    if (docker.truncated) try writer.writeAll("  ... container runtime lists truncated at scanner limit\n");
}

// 输出 fstab 和当前挂载点摘要。
pub fn writeStorageSummary(writer: anytype, storage: inventory.StorageInventory) !void {
    if (storage.fstab_entries.len > 0) {
        try writer.writeAll("\nFstab entries:\n");
        for (storage.fstab_entries[0..@min(storage.fstab_entries.len, 30)]) |entry| {
            try writer.print("  - {s} on {s} type={s} options={s}\n", .{ entry.device, entry.mount_point, entry.fs_type, entry.options });
        }
        if (storage.fstab_entries.len > 30) try writer.print("  ... {d} more\n", .{storage.fstab_entries.len - 30});
    }

    if (storage.mounts.len > 0) {
        try writer.writeAll("\nMounted filesystems:\n");
        for (storage.mounts[0..@min(storage.mounts.len, 40)]) |entry| {
            try writer.print("  - {s} on {s} type={s} options={s}\n", .{ entry.source, entry.mount_point, entry.fs_type, entry.options });
        }
        if (storage.mounts.len > 40) try writer.print("  ... {d} more\n", .{storage.mounts.len - 40});
        if (storage.truncated) try writer.writeAll("  ... mount list truncated at scanner limit\n");
    }
}
