const std = @import("std");
const acl_schema = @import("schema_parts/acl.zig");
const config_schema = @import("schema_parts/configs.zig");
const package_schema = @import("schema_parts/packages.zig");
const resource_schema = @import("schema_parts/resources.zig");
const runtime_schema = @import("schema_parts/runtime.zig");
const security_policy_schema = @import("schema_parts/security_policy.zig");
const service_schema = @import("schema_parts/services.zig");
const storage_schema = @import("schema_parts/storage.zig");
const system_baseline_schema = @import("schema_parts/system_baseline.zig");
const sudoers_schema = @import("schema_parts/sudoers.zig");
const user_schema = @import("schema_parts/users.zig");

// 完整模块清单，聚合所有子模块的扫描结果。
pub const ModuleInventory = struct {
    packages: package_schema.PackageInventory,
    services: service_schema.ServiceInventory,
    cron: service_schema.CronInventory,
    users: user_schema.UserInventory,
    ssh: user_schema.SshInventory,
    sudoers: sudoers_schema.SudoersInventory = .{ .entries = &.{}, .truncated = false },
    acl: acl_schema.AclInventory = .{ .getfacl_available = false, .paths = &.{}, .truncated = false },
    configs: config_schema.ConfigInventory,
    dev_env: config_schema.DevEnvInventory = .{
        .tools = &.{},
        .configs = &.{},
        .proxy_vars = &.{},
    },
    home_configs: config_schema.HomeConfigInventory = .{ .configs = &.{}, .truncated = false },
    appdata: runtime_schema.AppDataInventory = .{ .paths = &.{} },
    projects: runtime_schema.ProjectInventory = .{ .projects = &.{}, .truncated = false },
    processes: runtime_schema.ProcessInventory = .{ .processes = &.{}, .truncated = false },
    network: runtime_schema.NetworkInventory = .{ .listeners = &.{}, .truncated = false },
    docker: runtime_schema.DockerInventory = .{
        .runtimes = &.{},
        .containers = &.{},
        .volumes = &.{},
        .networks = &.{},
        .images = &.{},
        .compose_files = &.{},
        .truncated = false,
    },
    firewall: runtime_schema.FirewallInventory = .{ .backend = .unknown, .configs = &.{} },
    resources: resource_schema.ResourceInventory = .{},
    storage: storage_schema.StorageInventory = .{ .fstab_entries = &.{}, .mounts = &.{}, .truncated = false },
    system_baseline: system_baseline_schema.SystemBaselineInventory = .{},
    security_policy: security_policy_schema.SecurityPolicyInventory = .{},
};

// 构造一个静态空模块清单，用于不会调用 Inventory.deinit 的测试 fixture。
pub fn emptyModules() ModuleInventory {
    return .{
        .packages = .{
            .explicit = &.{},
            .held = &.{},
        },
        .services = .{
            .init_system = "unknown",
            .units = &.{},
            .drop_ins = &.{},
            .env_files = &.{},
            .timers = &.{},
            .sockets = &.{},
            .user_units = &.{},
            .xdg_autostart = &.{},
            .sysv_init = &.{},
            .openrc = &.{},
        },
        .cron = .{
            .entries = &.{},
        },
        .users = .{
            .users = &.{},
            .groups = &.{},
        },
        .ssh = .{
            .authorized_keys = &.{},
            .sshd_config_present = false,
            .client_config_present = false,
            .sshd_config = &.{},
            .host_keys = &.{},
        },
        .sudoers = .{
            .entries = &.{},
            .truncated = false,
        },
        .acl = .{
            .getfacl_available = false,
            .paths = &.{},
            .truncated = false,
        },
        .configs = .{
            .files = &.{},
        },
        .dev_env = .{
            .tools = &.{},
            .configs = &.{},
            .proxy_vars = &.{},
        },
        .home_configs = .{
            .configs = &.{},
            .truncated = false,
        },
        .appdata = .{
            .paths = &.{},
        },
        .projects = .{
            .projects = &.{},
            .truncated = false,
        },
        .processes = .{
            .processes = &.{},
            .truncated = false,
        },
        .network = .{
            .listeners = &.{},
            .truncated = false,
        },
        .docker = .{
            .runtimes = &.{},
            .containers = &.{},
            .volumes = &.{},
            .networks = &.{},
            .images = &.{},
            .compose_files = &.{},
            .truncated = false,
        },
        .firewall = .{
            .backend = .unknown,
            .configs = &.{},
        },
        .resources = .{},
        .storage = .{
            .fstab_entries = &.{},
            .mounts = &.{},
            .truncated = false,
        },
        .system_baseline = .{},
        .security_policy = .{},
    };
}

// 释放 ModuleInventory 中由扫描或 JSON 解析分配的字段。
pub fn deinitModules(allocator: std.mem.Allocator, modules: ModuleInventory) void {
    for (modules.packages.explicit) |pkg| allocator.free(pkg);
    allocator.free(modules.packages.explicit);
    for (modules.packages.held) |pkg| allocator.free(pkg);
    allocator.free(modules.packages.held);
    allocator.free(modules.services.init_system);
    for (modules.services.units) |unit| {
        allocator.free(unit.name);
        if (unit.path) |path| allocator.free(path);
        if (unit.dependency_summary) |summary| allocator.free(summary);
    }
    allocator.free(modules.services.units);
    for (modules.services.drop_ins) |drop_in| {
        allocator.free(drop_in.unit);
        allocator.free(drop_in.path);
    }
    allocator.free(modules.services.drop_ins);
    for (modules.services.env_files) |env_file| {
        allocator.free(env_file.unit);
        allocator.free(env_file.path);
    }
    allocator.free(modules.services.env_files);
    for (modules.services.timers) |timer| {
        allocator.free(timer.name);
        allocator.free(timer.activates);
        allocator.free(timer.schedule);
        if (timer.path) |path| allocator.free(path);
    }
    allocator.free(modules.services.timers);
    for (modules.services.sockets) |socket| {
        allocator.free(socket.name);
        if (socket.activates) |activates| allocator.free(activates);
        if (socket.path) |path| allocator.free(path);
    }
    allocator.free(modules.services.sockets);
    for (modules.services.user_units) |unit| {
        allocator.free(unit.user);
        allocator.free(unit.name);
        allocator.free(unit.path);
    }
    allocator.free(modules.services.user_units);
    for (modules.services.xdg_autostart) |entry| {
        if (entry.user) |user| allocator.free(user);
        allocator.free(entry.name);
        allocator.free(entry.path);
    }
    allocator.free(modules.services.xdg_autostart);
    for (modules.services.sysv_init) |script| {
        allocator.free(script.name);
        allocator.free(script.path);
        allocator.free(script.runlevels);
    }
    allocator.free(modules.services.sysv_init);
    for (modules.services.openrc) |service| {
        allocator.free(service.name);
        allocator.free(service.path);
        allocator.free(service.runlevels);
    }
    allocator.free(modules.services.openrc);
    for (modules.cron.entries) |entry| {
        allocator.free(entry.source);
        if (entry.owner) |owner| allocator.free(owner);
    }
    allocator.free(modules.cron.entries);
    for (modules.users.users) |user| {
        allocator.free(user.name);
        allocator.free(user.home);
        allocator.free(user.shell);
    }
    allocator.free(modules.users.users);
    for (modules.users.groups) |group| allocator.free(group.name);
    allocator.free(modules.users.groups);
    for (modules.ssh.authorized_keys) |keys| {
        allocator.free(keys.user);
        allocator.free(keys.path);
    }
    allocator.free(modules.ssh.authorized_keys);
    for (modules.ssh.sshd_config) |fact| {
        allocator.free(fact.key);
        allocator.free(fact.value);
    }
    allocator.free(modules.ssh.sshd_config);
    for (modules.ssh.host_keys) |host_key| {
        allocator.free(host_key.key_type);
        allocator.free(host_key.private_path);
        allocator.free(host_key.public_path);
        if (host_key.fingerprint) |fingerprint| allocator.free(fingerprint);
    }
    allocator.free(modules.ssh.host_keys);
    for (modules.sudoers.entries) |entry| allocator.free(entry.path);
    allocator.free(modules.sudoers.entries);
    for (modules.acl.paths) |path| allocator.free(path.path);
    allocator.free(modules.acl.paths);
    for (modules.configs.files) |file| allocator.free(file.path);
    allocator.free(modules.configs.files);
    for (modules.dev_env.tools) |tool| {
        allocator.free(tool.name);
        allocator.free(tool.version);
    }
    allocator.free(modules.dev_env.tools);
    for (modules.dev_env.configs) |config| {
        allocator.free(config.tool);
        allocator.free(config.path);
    }
    allocator.free(modules.dev_env.configs);
    for (modules.dev_env.proxy_vars) |proxy| allocator.free(proxy.name);
    allocator.free(modules.dev_env.proxy_vars);
    for (modules.home_configs.configs) |config| {
        allocator.free(config.user);
        allocator.free(config.path);
        allocator.free(config.relative_path);
    }
    allocator.free(modules.home_configs.configs);
    for (modules.appdata.paths) |path| {
        allocator.free(path.path);
        if (path.engine_hint) |hint| allocator.free(hint);
        if (path.dump_hint) |hint| allocator.free(hint);
        if (path.restore_hint) |hint| allocator.free(hint);
        if (path.consistency_hint) |hint| allocator.free(hint);
    }
    allocator.free(modules.appdata.paths);
    for (modules.projects.projects) |project| {
        allocator.free(project.root);
        allocator.free(project.manifest_path);
    }
    allocator.free(modules.projects.projects);
    for (modules.processes.processes) |process| {
        allocator.free(process.user);
        allocator.free(process.command);
    }
    allocator.free(modules.processes.processes);
    for (modules.network.listeners) |listener| {
        allocator.free(listener.protocol);
        allocator.free(listener.address);
        if (listener.process) |process| allocator.free(process);
    }
    allocator.free(modules.network.listeners);
    allocator.free(modules.docker.runtimes);
    for (modules.docker.containers) |container| {
        allocator.free(container.name);
        allocator.free(container.image);
        allocator.free(container.status);
        allocator.free(container.ports);
        if (container.mounts) |mounts| allocator.free(mounts);
        if (container.compose_project) |value| allocator.free(value);
        if (container.compose_service) |value| allocator.free(value);
        if (container.compose_workdir) |value| allocator.free(value);
    }
    allocator.free(modules.docker.containers);
    for (modules.docker.volumes) |volume| {
        allocator.free(volume.name);
        allocator.free(volume.driver);
        if (volume.scope) |value| allocator.free(value);
        if (volume.mountpoint) |value| allocator.free(value);
    }
    allocator.free(modules.docker.volumes);
    for (modules.docker.networks) |network| {
        allocator.free(network.name);
        allocator.free(network.driver);
        if (network.scope) |value| allocator.free(value);
    }
    allocator.free(modules.docker.networks);
    for (modules.docker.images) |image| {
        allocator.free(image.repository);
        allocator.free(image.tag);
        allocator.free(image.image_id);
    }
    allocator.free(modules.docker.images);
    for (modules.docker.compose_files) |compose| {
        allocator.free(compose.project_root);
        allocator.free(compose.path);
    }
    allocator.free(modules.docker.compose_files);
    for (modules.firewall.configs) |config| allocator.free(config.path);
    allocator.free(modules.firewall.configs);
    for (modules.resources.resources) |resource| {
        allocator.free(resource.path);
        if (resource.owner) |owner| allocator.free(owner);
        if (resource.owner_group) |owner_group| allocator.free(owner_group);
        if (resource.mode) |mode| allocator.free(mode);
        if (resource.mtime_unix) |mtime| allocator.free(mtime);
        if (resource.package_owner) |owner| allocator.free(owner);
        for (resource.evidence) |evidence| allocator.free(evidence);
        allocator.free(resource.evidence);
        if (resource.sha256) |sha256| allocator.free(sha256);
        if (resource.file_type) |file_type| allocator.free(file_type);
        if (resource.dynamic_link_summary) |summary| allocator.free(summary);
        if (resource.security_summary) |summary| allocator.free(summary);
    }
    allocator.free(modules.resources.resources);
    for (modules.storage.fstab_entries) |entry| {
        allocator.free(entry.device);
        allocator.free(entry.mount_point);
        allocator.free(entry.fs_type);
        allocator.free(entry.options);
    }
    allocator.free(modules.storage.fstab_entries);
    for (modules.storage.mounts) |entry| {
        allocator.free(entry.mount_point);
        allocator.free(entry.fs_type);
        allocator.free(entry.source);
        allocator.free(entry.options);
    }
    allocator.free(modules.storage.mounts);
    for (modules.system_baseline.paths) |path| allocator.free(path.path);
    allocator.free(modules.system_baseline.paths);
    for (modules.system_baseline.commands) |command| allocator.free(command.name);
    allocator.free(modules.system_baseline.commands);
    for (modules.system_baseline.config_facts) |fact| {
        allocator.free(fact.source);
        allocator.free(fact.key);
        allocator.free(fact.value);
    }
    allocator.free(modules.system_baseline.config_facts);
    for (modules.system_baseline.hosts_entries) |entry| {
        allocator.free(entry.address);
        allocator.free(entry.names);
    }
    allocator.free(modules.system_baseline.hosts_entries);
    for (modules.system_baseline.script_apps) |app| {
        allocator.free(app.name);
        allocator.free(app.path);
        if (app.evidence) |evidence| allocator.free(evidence);
        if (app.source_hint) |hint| allocator.free(hint);
        if (app.version_hint) |hint| allocator.free(hint);
        if (app.checksum_hint) |hint| allocator.free(hint);
        if (app.config_hint) |hint| allocator.free(hint);
        allocator.free(app.reinstall_hint);
    }
    allocator.free(modules.system_baseline.script_apps);
}
