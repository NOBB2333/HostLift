const std = @import("std");
const common = @import("docker_common.zig");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 扫描运行中的 Docker 容器。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !common.ScanResult(schema.DockerContainer) {
    return scanRuntime(io, allocator, common.docker_provider);
}

// 按指定容器运行时扫描运行中容器。
pub fn scanRuntime(io: std.Io, allocator: std.mem.Allocator, provider: common.RuntimeProvider) !common.ScanResult(schema.DockerContainer) {
    const lines = probe.runLines(
        io,
        allocator,
        &.{ provider.command, "ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}\t{{.Label \"com.docker.compose.project.working_dir\"}}" },
        2 * 1024 * 1024,
    ) catch return common.emptyResult(schema.DockerContainer, allocator);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    var containers: std.ArrayList(schema.DockerContainer) = .empty;
    errdefer {
        free(allocator, containers.items);
        containers.deinit(allocator);
    }

    var truncated = false;
    for (lines) |line| {
        if (containers.items.len >= 512) {
            truncated = true;
            break;
        }
        const parsed = parseDockerContainerLine(line) orelse continue;
        const mounts = collectContainerMounts(io, allocator, provider, parsed.name) catch null;
        errdefer if (mounts) |value| allocator.free(value);
        try containers.append(allocator, .{
            .runtime = provider.kind,
            .name = try allocator.dupe(u8, parsed.name),
            .image = try allocator.dupe(u8, parsed.image),
            .status = try allocator.dupe(u8, parsed.status),
            .ports = try allocator.dupe(u8, parsed.ports),
            .mounts = mounts,
            .compose_project = if (parsed.compose_project) |value| try allocator.dupe(u8, value) else null,
            .compose_service = if (parsed.compose_service) |value| try allocator.dupe(u8, value) else null,
            .compose_workdir = if (parsed.compose_workdir) |value| try allocator.dupe(u8, value) else null,
        });
    }

    return .{ .items = try containers.toOwnedSlice(allocator), .truncated = truncated };
}

// 释放容器记录列表。
pub fn free(allocator: std.mem.Allocator, containers: []schema.DockerContainer) void {
    for (containers) |container| {
        allocator.free(container.name);
        allocator.free(container.image);
        allocator.free(container.status);
        allocator.free(container.ports);
        if (container.mounts) |mounts| allocator.free(mounts);
        if (container.compose_project) |value| allocator.free(value);
        if (container.compose_service) |value| allocator.free(value);
        if (container.compose_workdir) |value| allocator.free(value);
    }
}

fn collectContainerMounts(io: std.Io, allocator: std.mem.Allocator, provider: common.RuntimeProvider, name: []const u8) !?[]const u8 {
    const output = probe.runFirstLine(
        io,
        allocator,
        &.{ provider.command, "inspect", "--format", "{{range .Mounts}}{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}={{.Destination}};{{end}}", name },
    ) catch return null;
    defer allocator.free(output);
    if (output.len == 0 or std.mem.eql(u8, output, "<no value>")) return null;
    return @as(?[]const u8, try allocator.dupe(u8, output[0..@min(output.len, 1024)]));
}

// docker ps 输出解析后的容器字段。
const ParsedDockerContainer = struct {
    name: []const u8,
    image: []const u8,
    status: []const u8,
    ports: []const u8,
    compose_project: ?[]const u8,
    compose_service: ?[]const u8,
    compose_workdir: ?[]const u8,
};

// 解析 docker ps 输出行，提取容器名称、镜像、状态、端口和 Compose 标签。
fn parseDockerContainerLine(line: []const u8) ?ParsedDockerContainer {
    var parts = std.mem.splitScalar(u8, line, '\t');
    const name = parts.next() orelse return null;
    const image = parts.next() orelse return null;
    const status = parts.next() orelse return null;
    const ports = parts.next() orelse "";
    if (name.len == 0 or image.len == 0) return null;
    return .{
        .name = name,
        .image = image,
        .status = status,
        .ports = ports,
        .compose_project = common.normalizeLabel(parts.next()),
        .compose_service = common.normalizeLabel(parts.next()),
        .compose_workdir = common.normalizeLabel(parts.next()),
    };
}

test "docker ps parser extracts container fields" {
    const parsed = parseDockerContainerLine("web\tnginx:1.27\tUp 2 hours\t0.0.0.0:8080->80/tcp\tshop\tweb\t/srv/shop").?;
    try std.testing.expectEqualStrings("web", parsed.name);
    try std.testing.expectEqualStrings("nginx:1.27", parsed.image);
    try std.testing.expectEqualStrings("Up 2 hours", parsed.status);
    try std.testing.expectEqualStrings("0.0.0.0:8080->80/tcp", parsed.ports);
    try std.testing.expectEqualStrings("shop", parsed.compose_project.?);
    try std.testing.expectEqualStrings("web", parsed.compose_service.?);
    try std.testing.expectEqualStrings("/srv/shop", parsed.compose_workdir.?);

    try std.testing.expect(parseDockerContainerLine("\tnginx\tUp\t") == null);

    const unlabeled = parseDockerContainerLine("db\tpostgres\tUp\t5432/tcp\t<no value>\t<no value>\t<no value>").?;
    try std.testing.expect(unlabeled.compose_project == null);
    try std.testing.expect(unlabeled.compose_service == null);
    try std.testing.expect(unlabeled.compose_workdir == null);
}
