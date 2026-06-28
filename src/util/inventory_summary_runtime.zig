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

// 输出整机资源地图摘要，包含大小、磁盘占用、默认动作和证据。
pub fn writeResourceSummary(writer: anytype, resources: inventory.ResourceInventory) !void {
    if (resources.resources.len == 0) return;
    try writer.writeAll("\nResource map:\n");
    for (resources.resources[0..@min(resources.resources.len, 60)]) |resource| {
        try writer.print(
            "  - {s} [{s}] action={s} sensitivity={s} logical={d} disk={d} files={d}",
            .{
                resource.path,
                @tagName(resource.kind),
                @tagName(resource.default_action),
                @tagName(resource.sensitivity),
                resource.logical_size,
                resource.disk_usage,
                resource.file_count,
            },
        );
        if (resource.owner) |owner| try writer.print(" owner={s}", .{owner});
        if (resource.owner_group) |owner_group| try writer.print(" owner_group={s}", .{owner_group});
        if (resource.mode) |mode| try writer.print(" mode={s}", .{mode});
        if (resource.mtime_unix) |mtime| try writer.print(" mtime={s}", .{mtime});
        if (resource.package_owner) |owner| try writer.print(" package={s}", .{owner});
        if (resource.sha256) |sha256| try writer.print(" sha256={s}", .{sha256});
        if (resource.file_type) |file_type| try writer.print(" file_type={s}", .{file_type});
        if (resource.dynamic_link_summary) |summary| try writer.print(" dynamic_link={s}", .{summary});
        if (resource.security_summary) |summary| try writer.print(" security={s}", .{summary});
        if (resource.evidence.len > 0) try writer.print(" evidence={s}", .{resource.evidence[0]});
        try writer.writeByte('\n');
    }
    if (resources.resources.len > 60) try writer.print("  ... {d} more\n", .{resources.resources.len - 60});
    if (resources.truncated) try writer.writeAll("  ... resource map truncated at scanner limit\n");
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
            if (container.mounts) |mounts| {
                if (mounts.len > 0) try writer.print(" mounts={s}", .{mounts});
            }
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
            try writer.print("  - {s} on {s} type={s} options={s}", .{ entry.source, entry.mount_point, entry.fs_type, entry.options });
            if (entry.total_bytes > 0) try writer.print(" avail={d} total={d}", .{ entry.available_bytes, entry.total_bytes });
            if (entry.total_inodes > 0) try writer.print(" iavail={d} itotal={d}", .{ entry.available_inodes, entry.total_inodes });
            try writer.writeByte('\n');
        }
        if (storage.mounts.len > 40) try writer.print("  ... {d} more\n", .{storage.mounts.len - 40});
        if (storage.truncated) try writer.writeAll("  ... mount list truncated at scanner limit\n");
    }

    if (storage.memory_total_bytes > 0 or storage.swap_total_bytes > 0) {
        try writer.print(
            "\nCapacity summary:\n  memory_available={d} memory_total={d} swap_free={d} swap_total={d}\n",
            .{
                storage.memory_available_bytes,
                storage.memory_total_bytes,
                storage.swap_free_bytes,
                storage.swap_total_bytes,
            },
        );
    }
}
