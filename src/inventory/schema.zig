const std = @import("std");
const acl_schema = @import("schema_parts/acl.zig");
const host_schema = @import("schema_parts/host.zig");
const package_schema = @import("schema_parts/packages.zig");
const service_schema = @import("schema_parts/services.zig");
const user_schema = @import("schema_parts/users.zig");
const config_schema = @import("schema_parts/configs.zig");
const runtime_schema = @import("schema_parts/runtime.zig");
const security_policy_schema = @import("schema_parts/security_policy.zig");
const storage_schema = @import("schema_parts/storage.zig");
const system_baseline_schema = @import("schema_parts/system_baseline.zig");
const sudoers_schema = @import("schema_parts/sudoers.zig");
const module_inventory = @import("module_inventory.zig");

pub const schema_version = "hostlift.inventory.v1";

pub const CpuArch = host_schema.CpuArch;
pub const DistroInfo = host_schema.DistroInfo;
pub const HostInfo = host_schema.HostInfo;
pub const ScanMetadata = host_schema.ScanMetadata;

pub const PackageManagerKind = package_schema.PackageManagerKind;
pub const RepositoryRef = package_schema.RepositoryRef;
pub const PackageManagerInfo = package_schema.PackageManagerInfo;
pub const PackageInventory = package_schema.PackageInventory;

pub const ServiceState = service_schema.ServiceState;
pub const ServiceActiveState = service_schema.ServiceActiveState;
pub const ServiceUnit = service_schema.ServiceUnit;
pub const SystemdTimer = service_schema.SystemdTimer;
pub const SystemdSocket = service_schema.SystemdSocket;
pub const UserSystemdUnitKind = service_schema.UserSystemdUnitKind;
pub const UserSystemdUnit = service_schema.UserSystemdUnit;
pub const XdgAutostartScope = service_schema.XdgAutostartScope;
pub const XdgAutostartEntry = service_schema.XdgAutostartEntry;
pub const SysvInitScript = service_schema.SysvInitScript;
pub const OpenRcService = service_schema.OpenRcService;
pub const ServiceInventory = service_schema.ServiceInventory;
pub const CronEntry = service_schema.CronEntry;
pub const CronInventory = service_schema.CronInventory;

pub const UserAccount = user_schema.UserAccount;
pub const GroupAccount = user_schema.GroupAccount;
pub const UserInventory = user_schema.UserInventory;
pub const AuthorizedKeys = user_schema.AuthorizedKeys;
pub const SshdConfigFact = user_schema.SshdConfigFact;
pub const SshInventory = user_schema.SshInventory;
pub const SudoersPathKind = sudoers_schema.SudoersPathKind;
pub const SudoersEntry = sudoers_schema.SudoersEntry;
pub const SudoersInventory = sudoers_schema.SudoersInventory;
pub const AclPath = acl_schema.AclPath;
pub const AclInventory = acl_schema.AclInventory;

pub const ConfigFile = config_schema.ConfigFile;
pub const ConfigInventory = config_schema.ConfigInventory;
pub const DevTool = config_schema.DevTool;
pub const DevConfig = config_schema.DevConfig;
pub const ProxySetting = config_schema.ProxySetting;
pub const DevEnvInventory = config_schema.DevEnvInventory;
pub const HomeConfigKind = config_schema.HomeConfigKind;
pub const HomeConfig = config_schema.HomeConfig;
pub const HomeConfigInventory = config_schema.HomeConfigInventory;

pub const DataPathKind = runtime_schema.DataPathKind;
pub const DataPath = runtime_schema.DataPath;
pub const AppDataInventory = runtime_schema.AppDataInventory;
pub const ProjectKind = runtime_schema.ProjectKind;
pub const ProjectRef = runtime_schema.ProjectRef;
pub const ProjectInventory = runtime_schema.ProjectInventory;
pub const ProcessSummary = runtime_schema.ProcessSummary;
pub const ProcessInventory = runtime_schema.ProcessInventory;
pub const ListeningSocket = runtime_schema.ListeningSocket;
pub const NetworkInventory = runtime_schema.NetworkInventory;
pub const DockerContainer = runtime_schema.DockerContainer;
pub const ContainerRuntimeKind = runtime_schema.ContainerRuntimeKind;
pub const ContainerRuntime = runtime_schema.ContainerRuntime;
pub const ContainerVolume = runtime_schema.ContainerVolume;
pub const ContainerNetwork = runtime_schema.ContainerNetwork;
pub const DockerImage = runtime_schema.DockerImage;
pub const ComposeFile = runtime_schema.ComposeFile;
pub const DockerInventory = runtime_schema.DockerInventory;
pub const FirewallBackend = runtime_schema.FirewallBackend;
pub const FirewallConfig = runtime_schema.FirewallConfig;
pub const FirewallInventory = runtime_schema.FirewallInventory;
pub const FstabEntry = storage_schema.FstabEntry;
pub const MountEntry = storage_schema.MountEntry;
pub const StorageInventory = storage_schema.StorageInventory;
pub const SystemPathKind = system_baseline_schema.SystemPathKind;
pub const SystemPathFact = system_baseline_schema.SystemPathFact;
pub const CommandFact = system_baseline_schema.CommandFact;
pub const HostsEntry = system_baseline_schema.HostsEntry;
pub const SystemConfigFact = system_baseline_schema.SystemConfigFact;
pub const ScriptInstallKind = system_baseline_schema.ScriptInstallKind;
pub const ScriptInstallCandidate = system_baseline_schema.ScriptInstallCandidate;
pub const SystemBaselineInventory = system_baseline_schema.SystemBaselineInventory;
pub const PolicyStatus = security_policy_schema.PolicyStatus;
pub const SelinuxInventory = security_policy_schema.SelinuxInventory;
pub const AppArmorInventory = security_policy_schema.AppArmorInventory;
pub const SecurityPolicyInventory = security_policy_schema.SecurityPolicyInventory;

pub const ModuleInventory = module_inventory.ModuleInventory;
pub const emptyModules = module_inventory.emptyModules;
pub const deinitModules = module_inventory.deinitModules;

// 完整 inventory 结构体，聚合主机、发行版、包管理和模块信息。
pub const Inventory = struct {
    schema_version: []const u8,
    host: HostInfo,
    distro: DistroInfo,
    package_manager: PackageManagerInfo,
    modules: ModuleInventory,
    scan: ScanMetadata,

    // 释放从 JSON 解析或扫描过程中分配出来的清单内存。
    pub fn deinit(self: *Inventory, allocator: std.mem.Allocator) void {
        allocator.free(self.host.hostname);
        allocator.free(self.host.kernel_release);
        allocator.free(self.distro.id);
        for (self.distro.id_like) |item| allocator.free(item);
        allocator.free(self.distro.id_like);
        allocator.free(self.distro.version_id);
        allocator.free(self.distro.pretty_name);
        allocator.free(self.package_manager.version);
        for (self.package_manager.repos) |repo| allocator.free(repo.id);
        allocator.free(self.package_manager.repos);
        deinitModules(allocator, self.modules);
        for (self.scan.warnings) |warning| allocator.free(warning);
        allocator.free(self.scan.warnings);
    }
};

test "inventory json without dev_env uses empty default" {
    const bytes =
        \\{
        \\  "schema_version": "hostlift.inventory.v1",
        \\  "host": {
        \\    "hostname": "source",
        \\    "machine_id_hash": null,
        \\    "kernel_release": "test",
        \\    "arch": "x86_64"
        \\  },
        \\  "distro": {
        \\    "id": "ubuntu",
        \\    "id_like": [],
        \\    "version_id": "24.04",
        \\    "pretty_name": "Ubuntu 24.04 LTS"
        \\  },
        \\  "package_manager": {
        \\    "kind": "apt",
        \\    "version": "apt test",
        \\    "repos": []
        \\  },
        \\  "modules": {
        \\    "packages": { "explicit": [], "held": [] },
        \\    "services": {
        \\      "init_system": "systemd",
        \\      "units": [
        \\        { "name": "legacy.service", "state": "enabled", "custom": false }
        \\      ]
        \\    },
        \\    "cron": { "entries": [] },
        \\    "users": { "users": [], "groups": [] },
        \\    "ssh": {
        \\      "authorized_keys": [],
        \\      "sshd_config_present": false,
        \\      "client_config_present": false
        \\    },
        \\    "configs": { "files": [] }
        \\  },
        \\  "scan": {
        \\    "scanned_at_unix": 0,
        \\    "warnings": []
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Inventory, std.testing.allocator, bytes, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.dev_env.tools.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.modules.services.units.len);
    try std.testing.expectEqual(ServiceActiveState.unknown, parsed.value.modules.services.units[0].active_state);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.services.timers.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.services.sockets.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.services.user_units.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.services.xdg_autostart.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.services.sysv_init.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.services.openrc.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.dev_env.configs.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.dev_env.proxy_vars.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.sudoers.entries.len);
    try std.testing.expect(!parsed.value.modules.sudoers.truncated);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.acl.paths.len);
    try std.testing.expect(!parsed.value.modules.acl.getfacl_available);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.home_configs.configs.len);
    try std.testing.expect(!parsed.value.modules.home_configs.truncated);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.appdata.paths.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.processes.processes.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.docker.runtimes.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.docker.volumes.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.docker.networks.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.docker.images.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.docker.compose_files.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.storage.fstab_entries.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.storage.mounts.len);
    try std.testing.expect(!parsed.value.modules.storage.truncated);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.system_baseline.paths.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.system_baseline.config_facts.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.system_baseline.hosts_entries.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.modules.system_baseline.script_apps.len);
    try std.testing.expectEqual(PolicyStatus.unknown, parsed.value.modules.security_policy.selinux.status);
    try std.testing.expectEqual(PolicyStatus.unknown, parsed.value.modules.security_policy.apparmor.status);
}
