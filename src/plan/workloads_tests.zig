const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const builder = @import("builder.zig");
const workload_schema = @import("workload_schema.zig");
const workloads = @import("workloads.zig");
const json_util = @import("../util/json.zig");

test "workload report aggregates five workload kinds with fail-closed statuses" {
    var source_units = [_]inventory.ServiceUnit{.{
        .name = "nginx.service",
        .state = .enabled,
        .active_state = .inactive,
        .custom = false,
    }};
    var target_units = source_units;
    var source_projects = [_]inventory.ProjectRef{.{
        .root = "/srv/api",
        .kind = .node,
        .manifest_path = "/srv/api/package.json",
    }};
    var source_data = [_]inventory.DataPath{.{
        .path = "/var/lib/postgresql",
        .present = true,
        .kind = .database_data,
        .size = 1024,
        .engine_hint = "postgresql",
    }};
    var source_runtimes = [_]inventory.ContainerRuntime{.{ .kind = .docker, .available = true }};
    var target_runtimes = source_runtimes;
    var source_containers = [_]inventory.DockerContainer{.{
        .runtime = .docker,
        .name = "api",
        .image = "example/api:1",
        .status = "Up",
        .ports = "0.0.0.0:8080->8080/tcp",
        .mounts = "api-data=/data;",
    }};
    var source_resources = [_]inventory.ResourceRef{.{
        .path = "/usr/local/bin/custom-tool",
        .kind = .unmanaged_executable,
        .default_action = .review,
    }};
    var source_packages = [_][]const u8{"curl"};

    var source_modules = inventory.emptyModules();
    source_modules.packages.explicit = source_packages[0..];
    source_modules.services.units = source_units[0..];
    source_modules.projects = .{ .projects = source_projects[0..], .truncated = false };
    source_modules.appdata.paths = source_data[0..];
    source_modules.docker = .{
        .runtimes = source_runtimes[0..],
        .containers = source_containers[0..],
        .truncated = true,
    };
    source_modules.resources.resources = source_resources[0..];

    var target_modules = inventory.emptyModules();
    target_modules.services.units = target_units[0..];
    target_modules.docker.runtimes = target_runtimes[0..];

    const source = fixture("source", "ubuntu", source_modules);
    const target = fixture("target", "ubuntu", target_modules);
    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);
    var report = try workloads.build(std.testing.allocator, source, target, migration_plan);
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), report.summary.total);
    try std.testing.expectEqual(workload_schema.Status.complete, findWorkload(report.workloads, "systemd/nginx.service").status);
    const project = findWorkload(report.workloads, "project//srv/api");
    try std.testing.expectEqual(workload_schema.Status.pending, project.status);
    try std.testing.expect(componentHasAction(project, "projects/copy//srv/api"));
    try std.testing.expectEqual(workload_schema.Status.blocked, findWorkload(report.workloads, "appdata//var/lib/postgresql").status);
    try std.testing.expectEqual(workload_schema.Status.unknown, findWorkload(report.workloads, "container/docker/api").status);
    try std.testing.expectEqual(workload_schema.Status.blocked, findWorkload(report.workloads, "resource//usr/local/bin/custom-tool").status);
    try std.testing.expectEqual(workload_schema.Status.unknown, report.host_status);
    try std.testing.expect(!report.all_workloads_complete);
    try std.testing.expect(report.summary.unassigned_actions > 0);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &bytes);
    try json_util.writeWorkloadReport(&writer.writer, report);
    bytes = writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, workload_schema.schema_version) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"host_status\": \"unknown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"unassigned_action_ids\"") != null);
}

test "workload report blocks distro-bound service but keeps portable project pending" {
    var source_units = [_]inventory.ServiceUnit{.{
        .name = "app.service",
        .state = .disabled,
        .custom = true,
        .path = "/etc/systemd/system/app.service",
    }};
    var source_projects = [_]inventory.ProjectRef{.{
        .root = "/srv/app",
        .kind = .node,
        .manifest_path = "/srv/app/package.json",
    }};
    var source_modules = inventory.emptyModules();
    source_modules.services.units = source_units[0..];
    source_modules.projects = .{ .projects = source_projects[0..], .truncated = false };
    const source = fixture("source", "ubuntu", source_modules);
    const target = fixture("target", "debian", inventory.emptyModules());

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);
    var report = try workloads.build(std.testing.allocator, source, target, migration_plan);
    defer report.deinit(std.testing.allocator);

    const service = findWorkload(report.workloads, "systemd/app.service");
    try std.testing.expectEqual(workload_schema.Status.blocked, service.status);
    try std.testing.expect(hasBlocker(service.blockers, .incompatible_target));
    const project = findWorkload(report.workloads, "project//srv/app");
    try std.testing.expectEqual(workload_schema.Status.pending, project.status);
    try std.testing.expect(!hasBlocker(project.blockers, .incompatible_target));
    try std.testing.expectEqual(workload_schema.Status.blocked, report.host_status);
}

test "workload report treats missing target fact without action as unknown" {
    var source_units = [_]inventory.ServiceUnit{.{
        .name = "optional.service",
        .state = .disabled,
        .custom = false,
    }};
    var source_modules = inventory.emptyModules();
    source_modules.services.units = source_units[0..];
    const source = fixture("source", "ubuntu", source_modules);
    const target = fixture("target", "ubuntu", inventory.emptyModules());

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), migration_plan.actions.len);
    var report = try workloads.build(std.testing.allocator, source, target, migration_plan);
    defer report.deinit(std.testing.allocator);

    const service = findWorkload(report.workloads, "systemd/optional.service");
    try std.testing.expectEqual(workload_schema.Status.unknown, service.status);
    try std.testing.expect(hasBlocker(service.blockers, .target_fact_missing));
    try std.testing.expectEqual(workload_schema.Status.unknown, report.host_status);
}

test "workload report does not treat same-name project and container as equivalent" {
    var source_projects = [_]inventory.ProjectRef{.{
        .root = "/srv/app",
        .kind = .node,
        .manifest_path = "/srv/app/package.json",
    }};
    var target_projects = [_]inventory.ProjectRef{.{
        .root = "/srv/app",
        .kind = .python,
        .manifest_path = "/srv/app/pyproject.toml",
    }};
    var source_runtimes = [_]inventory.ContainerRuntime{.{ .kind = .docker, .available = true }};
    var target_runtimes = source_runtimes;
    var source_containers = [_]inventory.DockerContainer{.{
        .name = "app",
        .image = "example/app:1",
        .status = "Up",
        .ports = "8080/tcp",
    }};
    var target_containers = [_]inventory.DockerContainer{.{
        .name = "app",
        .image = "example/app:2",
        .status = "Up",
        .ports = "9090/tcp",
    }};

    var source_modules = inventory.emptyModules();
    source_modules.projects.projects = source_projects[0..];
    source_modules.docker.runtimes = source_runtimes[0..];
    source_modules.docker.containers = source_containers[0..];
    var target_modules = inventory.emptyModules();
    target_modules.projects.projects = target_projects[0..];
    target_modules.docker.runtimes = target_runtimes[0..];
    target_modules.docker.containers = target_containers[0..];
    const source = fixture("source", "ubuntu", source_modules);
    const target = fixture("target", "ubuntu", target_modules);

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), migration_plan.actions.len);
    var report = try workloads.build(std.testing.allocator, source, target, migration_plan);
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(workload_schema.Status.unknown, findWorkload(report.workloads, "project//srv/app").status);
    try std.testing.expectEqual(workload_schema.Status.unknown, findWorkload(report.workloads, "container/docker/app").status);
    try std.testing.expectEqual(workload_schema.Status.unknown, report.host_status);
}

test "workload report rejects partial or legacy scan scope as unknown" {
    var units = [_]inventory.ServiceUnit{.{
        .name = "app.service",
        .state = .enabled,
        .custom = false,
    }};
    var source_modules = inventory.emptyModules();
    source_modules.services.units = units[0..];
    var target_modules = inventory.emptyModules();
    target_modules.services.units = units[0..];
    var source = fixture("source", "ubuntu", source_modules);
    const target = fixture("target", "ubuntu", target_modules);
    source.scan.full_scan = false;

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);
    var report = try workloads.build(std.testing.allocator, source, target, migration_plan);
    defer report.deinit(std.testing.allocator);

    const service = findWorkload(report.workloads, "systemd/app.service");
    try std.testing.expectEqual(workload_schema.Status.unknown, service.status);
    try std.testing.expect(hasBlocker(service.blockers, .scan_incomplete));
    try std.testing.expectEqual(workload_schema.Status.unknown, report.host_status);
    try std.testing.expect(hasBlocker(report.global_blockers, .scan_incomplete));
}

fn fixture(hostname: []const u8, distro_id: []const u8, modules: inventory.ModuleInventory) inventory.Inventory {
    return .{
        .schema_version = inventory.schema_version,
        .host = .{
            .hostname = hostname,
            .machine_id_hash = null,
            .kernel_release = "test",
            .arch = .x86_64,
        },
        .distro = .{
            .id = distro_id,
            .id_like = &.{},
            .version_id = "24.04",
            .pretty_name = distro_id,
        },
        .package_manager = .{
            .kind = .apt,
            .version = "test",
            .repos = &.{},
        },
        .modules = modules,
        .scan = .{ .scanned_at_unix = 0, .warnings = &.{}, .full_scan = true },
    };
}

fn findWorkload(values: []const workload_schema.Workload, id: []const u8) workload_schema.Workload {
    for (values) |value| if (std.mem.eql(u8, value.id, id)) return value;
    unreachable;
}

fn componentHasAction(workload: workload_schema.Workload, action_id: []const u8) bool {
    for (workload.components) |component| {
        for (component.action_ids) |candidate| {
            if (std.mem.eql(u8, candidate, action_id)) return true;
        }
    }
    return false;
}

fn hasBlocker(blockers: []const workload_schema.Blocker, kind: workload_schema.BlockerKind) bool {
    for (blockers) |blocker| if (blocker.kind == kind) return true;
    return false;
}
